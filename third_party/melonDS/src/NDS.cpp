/*
    Copyright 2016-2026 melonDS team

    This file is part of melonDS.

    melonDS is free software: you can redistribute it and/or modify it under
    the terms of the GNU General Public License as published by the Free
    Software Foundation, either version 3 of the License, or (at your option)
    any later version.

    melonDS is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with melonDS. If not, see http://www.gnu.org/licenses/.
*/

#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <inttypes.h>
#include <chrono>
#include <limits>
#include "NDS.h"
#include "ARM.h"
#include "NDSCart.h"
#include "GBACart.h"
#include "DMA.h"
#include "FIFO.h"
#include "GPU.h"
#include "SPU.h"
#include "SPI.h"
#include "RTC.h"
#include "Wifi.h"
#include "AREngine.h"
#include "Platform.h"
#include "FreeBIOS.h"
#include "Args.h"
#include "version.h"

#include "DSi.h"
#include "DSi_SPI_TSC.h"
#include "DSi_NWifi.h"
#include "DSi_Camera.h"
#include "DSi_DSP.h"
#include "ARMJIT.h"
#include "ARMJIT_Memory.h"

namespace melonDS
{

namespace
{

double PerfElapsedSeconds(std::chrono::steady_clock::time_point start,
                          std::chrono::steady_clock::time_point end)
{
    return std::chrono::duration<double>(end - start).count();
}

}
using namespace Platform;

const s32 kMaxIterationCycles = 64;
const s32 kIterationCycleMargin = 8;

// timing notes
//
// * this implementation is technically wrong for VRAM
//   each bank is considered a separate region
//   but this would only matter in specific VRAM->VRAM DMA transfers or
//   when running code in VRAM, which is way unlikely
//
// bus/basedelay/nspenalty
//
// bus types:
// * 0 / 32-bit: nothing special
// * 1 / 16-bit: 32-bit accesses split into two 16-bit accesses, second is always sequential
// * 2 / 8-bit/GBARAM: (presumably) split into multiple 8-bit accesses?
// * 3 / ARM9 internal: cache/TCM
//
// ARM9 always gets 3c nonseq penalty when using the bus (except for mainRAM where the penalty is 7c)
// /!\ 3c penalty doesn't apply to DMA!
//
// ARM7 only gets nonseq penalty when accessing mainRAM (7c as for ARM9)
//
// timings for GBA slot and wifi are set up at runtime

thread_local NDS* NDS::Current = nullptr;

NDS::NDS() noexcept :
    NDS(
        NDSArgs {
            std::make_unique<ARM9BIOSImage>(FreeBIOSGetNtrArm9()),
            std::make_unique<ARM7BIOSImage>(FreeBIOSGetNtrArm7()),
            Firmware(0),
        }
    )
{
}

NDS::NDS(NDSArgs&& args, int type, void* userdata) noexcept :
    ConsoleType(type),
    UserData(userdata),
    ARM7BIOS(*args.ARM7BIOS),
    ARM9BIOS(*args.ARM9BIOS),
    ARM7BIOSNative(CRC32(ARM7BIOS.data(), ARM7BIOS.size()) == ARM7BIOSCRC32),
    ARM9BIOSNative(CRC32(ARM9BIOS.data(), ARM9BIOS.size()) == ARM9BIOSCRC32),
    JIT(*this, args.JIT),
    SPU(*this, args.BitDepth, args.Interpolation, args.OutputSampleRate),
    Mic(*this),
    GPU(*this, std::move(args.Renderer)),
    SPI(*this, std::move(args.Firmware)),
    RTC(*this),
    Wifi(*this),
    NDSCartSlot(*this, 0, nullptr),
    GBACartSlot(*this, nullptr),
    AREngine(*this),
    ARM9(*this, args.GDB, args.JIT.has_value()),
    ARM7(*this, args.GDB, args.JIT.has_value()),
#ifdef GDBSTUB_ENABLED
    EnableGDBStub(args.GDB.has_value()),
#endif
#ifdef JIT_ENABLED
    EnableJIT(args.JIT.has_value()),
#endif
    DMAs {
        DMA(0, 0, *this),
        DMA(0, 1, *this),
        DMA(0, 2, *this),
        DMA(0, 3, *this),
        DMA(1, 0, *this),
        DMA(1, 1, *this),
        DMA(1, 2, *this),
        DMA(1, 3, *this),
    }
{
    NDSCartSlots[0] = &NDSCartSlot;
    NDSCartSlots[1] = nullptr;

    RegisterEventFuncs(Event_Div, this, {MakeEventThunk(NDS, DivDone)});
    RegisterEventFuncs(Event_Sqrt, this, {MakeEventThunk(NDS, SqrtDone)});

    MainRAM = JIT.Memory.GetMainRAM();
    SharedWRAM = JIT.Memory.GetSharedWRAM();
    ARM7WRAM = JIT.Memory.GetARM7WRAM();
}

NDS::~NDS() noexcept
{
    UnregisterEventFuncs(Event_Div);
    UnregisterEventFuncs(Event_Sqrt);
    // The destructor for each component is automatically called by the compiler
}


void NDS::SetARM9RegionTimings(u32 addrstart, u32 addrend, u32 region, int buswidth, int nonseq, int seq)
{
    addrstart >>= 2;
    addrend   >>= 2;

    int N16, S16, N32, S32, cpuN;
    N16 = nonseq;
    S16 = seq;
    if (buswidth == 16)
    {
        N32 = N16 + S16;
        S32 = S16 + S16;
    }
    else
    {
        N32 = N16;
        S32 = S16;
    }

    // nonseq accesses on the CPU get a 3-cycle penalty for all regions except main RAM
    cpuN = (region == Mem9_MainRAM) ? 0 : 3;

    for (u32 i = addrstart; i < addrend; i++)
    {
        // CPU timings
        ARM9MemTimings[i][0] = N16 + cpuN;
        ARM9MemTimings[i][1] = S16;
        ARM9MemTimings[i][2] = N32 + cpuN;
        ARM9MemTimings[i][3] = S32;

        // DMA timings
        ARM9MemTimings[i][4] = N16;
        ARM9MemTimings[i][5] = S16;
        ARM9MemTimings[i][6] = N32;
        ARM9MemTimings[i][7] = S32;

        ARM9Regions[i] = region;
    }

    ARM9.UpdateRegionTimings(addrstart<<2, addrend<<2);
}

void NDS::SetARM7RegionTimings(u32 addrstart, u32 addrend, u32 region, int buswidth, int nonseq, int seq)
{
    addrstart >>= 3;
    addrend   >>= 3;

    int N16, S16, N32, S32;
    N16 = nonseq;
    S16 = seq;
    if (buswidth == 16)
    {
        N32 = N16 + S16;
        S32 = S16 + S16;
    }
    else
    {
        N32 = N16;
        S32 = S16;
    }

    for (u32 i = addrstart; i < addrend; i++)
    {
        // CPU and DMA timings are the same
        ARM7MemTimings[i][0] = N16;
        ARM7MemTimings[i][1] = S16;
        ARM7MemTimings[i][2] = N32;
        ARM7MemTimings[i][3] = S32;

        ARM7Regions[i] = region;
    }
}

#ifdef JIT_ENABLED
void NDS::SetJITArgs(std::optional<JITArgs> args) noexcept
{
    if (args)
    { // If we want to turn the JIT on...
        JIT.SetJITArgs(*args);
    }
    else if (args.has_value() != EnableJIT)
    { // Else if we want to turn the JIT off, and it wasn't already off...
        JIT.Reset();
    }

    EnableJIT = args.has_value();
}
#endif

#ifdef GDBSTUB_ENABLED
void NDS::SetGdbArgs(std::optional<GDBArgs> args) noexcept
{
    ARM9.SetGdbArgs(args);
    ARM7.SetGdbArgs(args);
    EnableGDBStub = args.has_value();
}
#endif

void NDS::InitTimings()
{
    // TODO, eventually:
    // VRAM is initially unmapped. The timings should be those of void regions.
    // Similarly for any unmapped VRAM area.
    // Need to check whether supporting these timing characteristics would impact performance
    // (especially wrt VRAM mirroring and overlapping and whatnot).
    // Also, each VRAM bank is its own memory region. This would matter when DMAing from a VRAM
    // bank to another (if this is a thing) for example.

    // TODO: check in detail how WRAM works, although it seems to be one region.

    // TODO: DSi-specific timings!!

    SetARM9RegionTimings(0x00000, 0x100000, 0, 32, 1, 1); // void

    SetARM9RegionTimings(0xFFFF0, 0x100000, Mem9_BIOS,    32, 1, 1); // BIOS
    SetARM9RegionTimings(0x02000, 0x03000,  Mem9_MainRAM, 16, 8, 1);     // main RAM
    SetARM9RegionTimings(0x03000, 0x04000,  Mem9_WRAM,    32, 1, 1); // ARM9/shared WRAM
    SetARM9RegionTimings(0x04000, 0x05000,  Mem9_IO,      32, 1, 1); // IO
    SetARM9RegionTimings(0x05000, 0x06000,  Mem9_Pal,     16, 1, 1); // palette
    SetARM9RegionTimings(0x06000, 0x07000,  Mem9_VRAM,    16, 1, 1); // VRAM
    SetARM9RegionTimings(0x07000, 0x08000,  Mem9_OAM,     32, 1, 1); // OAM

    // ARM7

    SetARM7RegionTimings(0x00000, 0x100000, 0, 32, 1, 1); // void

    SetARM7RegionTimings(0x00000, 0x00010, Mem7_BIOS,    32, 1, 1); // BIOS
    SetARM7RegionTimings(0x02000, 0x03000, Mem7_MainRAM, 16, 8, 1); // main RAM
    SetARM7RegionTimings(0x03000, 0x04000, Mem7_WRAM,    32, 1, 1); // ARM7/shared WRAM
    SetARM7RegionTimings(0x04000, 0x04800, Mem7_IO,      32, 1, 1); // IO
    SetARM7RegionTimings(0x06000, 0x07000, Mem7_VRAM,    16, 1, 1); // ARM7 VRAM

    // handled later: GBA slot, wifi
}

bool NDS::NeedsDirectBoot() const
{
    // DSi/3DS firmwares aren't bootable, neither is the generated firmware
    if (!SPI.GetFirmware().IsBootable())
        return true;

    // FreeBIOS requires direct boot (it can't boot firmware)
    if (!IsLoadedARM9BIOSKnownNative() || !IsLoadedARM7BIOSKnownNative())
        return true;

    return false;
}

void NDS::SetupDirectBoot()
{
    const NDSHeader& header = NDSCartSlot.GetCart()->GetHeader();
    u32 cartid = NDSCartSlot.GetCart()->ID();
    const u8* cartrom = NDSCartSlot.GetCart()->GetROM();
    MapSharedWRAM(3);

    // Copy the Nintendo logo from the NDS ROM header to the ARM9 BIOS if using FreeBIOS
    // Games need this for DS<->GBA comm to work
    if (!IsLoadedARM9BIOSKnownNative())
    {
        memcpy(ARM9BIOS.data() + 0x20, header.NintendoLogo, 0x9C);
    }

    // setup main RAM data

    for (u32 i = 0; i < 0x170; i+=4)
    {
        u32 tmp = *(u32*)&cartrom[i];
        NDS::ARM9Write32(0x027FFE00+i, tmp);
    }

    NDS::ARM9Write32(0x027FF800, cartid);
    NDS::ARM9Write32(0x027FF804, cartid);
    NDS::ARM9Write16(0x027FF808, header.HeaderCRC16);
    NDS::ARM9Write16(0x027FF80A, header.SecureAreaCRC16);

    NDS::ARM9Write16(0x027FF850, 0x5835);

    NDS::ARM9Write32(0x027FFC00, cartid);
    NDS::ARM9Write32(0x027FFC04, cartid);
    NDS::ARM9Write16(0x027FFC08, header.HeaderCRC16);
    NDS::ARM9Write16(0x027FFC0A, header.SecureAreaCRC16);

    NDS::ARM9Write16(0x027FFC10, 0x5835);
    NDS::ARM9Write16(0x027FFC30, 0xFFFF);
    NDS::ARM9Write16(0x027FFC40, 0x0001);

    u32 arm9start = 0;

    // load the ARM9 secure area
    if (header.ARM9ROMOffset >= 0x4000 && header.ARM9ROMOffset < 0x8000)
    {
        u8 securearea[0x800];
        NDSCartSlot.DecryptSecureArea(securearea);

        for (u32 i = 0; i < 0x800; i+=4)
        {
            NDS::ARM9Write32(header.ARM9RAMAddress+i, *(u32*)&securearea[i]);
            arm9start += 4;
        }
    }

    // CHECKME: firmware seems to load this in 0x200 byte chunks

    for (u32 i = arm9start; i < header.ARM9Size; i+=4)
    {
        u32 tmp = *(u32*)&cartrom[header.ARM9ROMOffset+i];
        NDS::ARM9Write32(header.ARM9RAMAddress+i, tmp);
    }

    for (u32 i = 0; i < header.ARM7Size; i+=4)
    {
        u32 tmp = *(u32*)&cartrom[header.ARM7ROMOffset+i];
        NDS::ARM7Write32(header.ARM7RAMAddress+i, tmp);
    }

    ARM7BIOSProt = 0x1204;

    SPI.GetFirmwareMem()->SetupDirectBoot();

    ARM9.CP15Write(0x100, 0x00052078);
    ARM9.CP15Write(0x200, 0x00000042);
    ARM9.CP15Write(0x201, 0x00000042);
    ARM9.CP15Write(0x300, 0x00000002);
    ARM9.CP15Write(0x502, 0x15111011);
    ARM9.CP15Write(0x503, 0x05100011);
    ARM9.CP15Write(0x600, 0x04000033);
    ARM9.CP15Write(0x601, 0x04000033);
    ARM9.CP15Write(0x610, 0x0200002B);
    ARM9.CP15Write(0x611, 0x0200002B);
    ARM9.CP15Write(0x620, 0x00000000);
    ARM9.CP15Write(0x621, 0x00000000);
    ARM9.CP15Write(0x630, 0x08000035);
    ARM9.CP15Write(0x631, 0x08000035);
    ARM9.CP15Write(0x640, 0x0300001B);
    ARM9.CP15Write(0x641, 0x0300001B);
    ARM9.CP15Write(0x650, 0x00000000);
    ARM9.CP15Write(0x651, 0x00000000);
    ARM9.CP15Write(0x660, 0xFFFF001D);
    ARM9.CP15Write(0x661, 0xFFFF001D);
    ARM9.CP15Write(0x670, 0x027FF017);
    ARM9.CP15Write(0x671, 0x027FF017);
    ARM9.CP15Write(0x910, 0x0300000A);
    ARM9.CP15Write(0x911, 0x00000020);
}

void NDS::SetupDirectBoot(const std::string& romname)
{
    const NDSHeader& header = NDSCartSlot.GetCart()->GetHeader();
    SetupDirectBoot();

    NDSCartSlot.SetupDirectBoot(romname);

    ARM9.R[12] = header.ARM9EntryAddress;
    ARM9.R[13] = 0x03002F7C;
    ARM9.R[14] = header.ARM9EntryAddress;
    ARM9.R_IRQ[0] = 0x03003F80;
    ARM9.R_SVC[0] = 0x03003FC0;

    ARM7.R[12] = header.ARM7EntryAddress;
    ARM7.R[13] = 0x0380FD80;
    ARM7.R[14] = header.ARM7EntryAddress;
    ARM7.R_IRQ[0] = 0x0380FF80;
    ARM7.R_SVC[0] = 0x0380FFC0;

    ARM9.JumpTo(header.ARM9EntryAddress);
    ARM7.JumpTo(header.ARM7EntryAddress);

    SetExMemCnt(0, 0xE880, 0xFFFF);
    SetExMemCnt(1, 0x0080, 0x00FF);

    PostFlag9 = 0x01;
    PostFlag7 = 0x01;

    PowerControl9 = 0x820F;
    GPU.SetPowerCnt(PowerControl9);

    PowerControl7 = 0x0001;
    SPU.SetPowerCnt(PowerControl7 & 0x0001);
    Wifi.SetPowerCnt(PowerControl7 & 0x0002);

    // checkme
    RCnt = 0x8000;

    //NDSCartSlot.SetSPICnt(0x8000);
    // TODO CHECK ME
    NDSCartSlot.WriteSPICnt(0, 0x8000, 0xFFFF);
    NDSCartSlot.WriteSPICnt(1, 0x8000, 0xFFFF);

    SPU.SetBias(0x200);

    SetWifiWaitCnt(0x0030);
}

void NDS::Reset()
{
    Platform::FileHandle* f;
    u32 i;

    // Reset is the only recovery boundary for a failed external time-window
    // epoch. Runtime disable/re-enable deliberately cannot erase a closure
    // or observer fault after architectural state may already have changed.
    ExternalTimeWindowEnabled_ = false;
    ExternalLCDRendererEnabled_ = false;
    ExternalTimeWindowClosureActive_ = false;
    ExternalTimeWindowFaulted_ = false;
    ExternalTimeWindowObserverFailed_ = false;
    ExternalTimeWindowHaveFrontier_ = false;
    ExternalTimeWindowEventSequence_ = 0;
    ExternalTimeWindowLastProcessed_ = 0;
    ExternalTimeWindowLastRunSafe_ = 0;
    ExternalTimeWindowProfile_ = {};
    ExternalTimeWindowCPUReached_[0] = 0;
    ExternalTimeWindowCPUReached_[1] = 0;
    ExternalTimeWindowObservedIF_[0] = 0;
    ExternalTimeWindowObservedIF_[1] = 0;
    ExternalTimeWindowHaveVerifiedGrant_ = false;
    ExternalTimeWindowVerifiedCloseActive_ = false;
    ExternalTimeWindowVerifiedEpoch_ = 0;
    ExternalTimeWindowVerifiedGrantSequence_ = 0;
    ExternalTimeWindowVerifiedProducerFence_ = 0;
    ExternalTimeWindowHaveSourceSequence_ = false;
    ExternalTimeWindowLastSourceSequence_ = 0;
    ExternalARM9IFW1CActive_ = false;
    ExternalARM9IFW1CFailed_ = false;
    ExternalARM9IFW1CHaveLast_ = false;
    ExternalARM9IFW1CExpectedGXFIFOSet_ = false;
    ExternalARM9IFW1CPhase_ = 0;
    ExternalARM9IFW1CExpectedPhases_ = 0;
    ExternalARM9IFW1CExpectedClearMask_ = 0;
    ExternalARM9IFW1CLastSourceSequence_ = 0;
    ExternalARM9IFW1CLastTimestamp_ = 0;
    ExternalBlockingMMIOBarrierActive_ = false;
    ExternalBlockingMMIOAccessClaimed_ = false;
    ExternalBlockingMMIOAccessComplete_ = false;
    ExternalBlockingMMIOHaveIdentity_ = false;
    ExternalBlockingMMIOEpoch_ = 0;
    ExternalBlockingMMIOLastSourceSequence_ = 0;
    ExternalBlockingMMIOLastBarrierSequence_ = 0;
    ExternalBlockingMMIOBarrierTimestamp_ = 0;
    ExternalBlockingMMIORequest_ = {};
    ExternalBlockingMMIOIEAfterAccess_[0] = 0;
    ExternalBlockingMMIOIEAfterAccess_[1] = 0;
    ExternalBlockingMMIOIMEAfterAccess_[0] = 0;
    ExternalBlockingMMIOIMEAfterAccess_[1] = 0;
    ExternalBlockingMMIOIF2AfterAccess_ = 0;
    ExternalBlockingMMIOIE2AfterAccess_ = 0;
    ExternalBlockingMMIONonDMAStopAfterAccess_ = 0;

    RunningGame = false;
    LastSysClockCycles = 0;

    // BIOS files are now loaded by the frontend

    JIT.Reset();

    if (ConsoleType == 1)
    {
        // BIOS files are now loaded by the frontend

        ARM9ClockShift = 2;
        MainRAMMask = 0xFFFFFF;
    }
    else
    {
        ARM9ClockShift = 1;
        MainRAMMask = 0x3FFFFF;
    }
    // has to be called before InitTimings
    // otherwise some PU settings are completely
    // unitialised on the first run
    ARM9.CP15Reset();

    ARM9Timestamp = 0; ARM9Target = 0;
    ARM7Timestamp = 0; ARM7Target = 0;
    SysTimestamp = 0;
    ExternalSchedulerStarted = false;

    InitTimings();

    memset(MainRAM, 0, MainRAMMask + 1);
    memset(SharedWRAM, 0, 0x8000);
    memset(ARM7WRAM, 0, 0x10000);

    MapSharedWRAM(0);

    // TODO FIX THOSE VALUES
    // TODO figure out what they should be
    ExMemCnt[0] = 0x6000;
    ExMemCnt[1] = 0x6000;
    SetGBASlotTimings();

    IME[0] = 0;
    IE[0] = 0;
    IF[0] = 0;
    IME[1] = 0;
    IE[1] = 0;
    IF[1] = 0;
    IE2 = 0;
    IF2 = 0;

    PostFlag9 = 0x00;
    PostFlag7 = 0x00;
    PowerControl9 = 0x0000;
    PowerControl7 = 0x0000;

    WifiWaitCnt = 0xFFFF; // temp
    SetWifiWaitCnt(0);

    ARM7BIOSProt = 0;

    IPCSync9 = 0;
    IPCSync7 = 0;
    IPCFIFOCnt9 = 0;
    IPCFIFOCnt7 = 0;
    IPCFIFO9.Clear();
    IPCFIFO7.Clear();

    DivCnt = 0;
    SqrtCnt = 0;

    ARM9.Reset();
    ARM7.Reset();

    CPUStop = 0;

    memset(Timers, 0, 8*sizeof(Timer));
    TimerCheckMask[0] = 0;
    TimerCheckMask[1] = 0;
    TimerTimestamp[0] = 0;
    TimerTimestamp[1] = 0;

    for (i = 0; i < 8; i++) DMAs[i].Reset();
    memset(DMA9Fill, 0, 4*4);

    for (i = 0; i < Event_MAX; i++)
    {
        SchedEvent& evt = SchedList[i];

        evt.Timestamp = 0;
        evt.FuncID = 0;
        evt.Param = 0;
    }
    SchedListMask = 0;

    KeyInput = 0x007F03FF;
    KeyCnt[0] = 0;
    KeyCnt[1] = 0;
    RCnt = 0;

    GPU.Reset();
    NDSCartSlot.Reset();
    GBACartSlot.Reset();
    SPU.Reset();
    Mic.Reset();
    SPI.Reset();
    RTC.Reset();
    Wifi.Reset();
}

void NDS::Start()
{
    Running = true;

    if (ConsoleType != 0)
        return;

    auto* ndscart = NDSCartSlot.GetCart();
    if (!ndscart)
        return;

    if (auto* cart = GBACartSlot.GetCart(); cart && cart->Type() == GBACart::CartType::GameSolarSensor)
    { // If we have a solar sensor cart inserted...
        auto& solarcart = *static_cast<GBACart::CartGameSolarSensor*>(cart);
        GBACart::GBAHeader& header = solarcart.GetHeader();
        if (strncmp(header.Title, GBACart::BOKTAI_STUB_TITLE, sizeof(header.Title)) == 0) {
            // If this is a stub Boktai cart (so we can use the sensor without a full ROM)...

            // ...then copy the Nintendo logo data from the NDS ROM into the stub GBA ROM.
            // Otherwise, the GBA cart won't be recognized.
            memcpy(header.NintendoLogo, ndscart->GetHeader().NintendoLogo, sizeof(header.NintendoLogo));
        }
    }
}

static const char* StopReasonName(Platform::StopReason reason)
{
    switch (reason)
    {
        case Platform::StopReason::External:
            return "External";
        case Platform::StopReason::PowerOff:
            return "PowerOff";
        case Platform::StopReason::GBAModeNotSupported:
            return "GBAModeNotSupported";
        case Platform::StopReason::BadExceptionRegion:
            return "BadExceptionRegion";
        default:
            return "Unknown";
    }
}

void NDS::Stop(Platform::StopReason reason)
{
    Platform::LogLevel level;
    switch (reason)
    {
        case Platform::StopReason::External:
        case Platform::StopReason::PowerOff:
            level = LogLevel::Info;
            break;
        case Platform::StopReason::GBAModeNotSupported:
        case Platform::StopReason::BadExceptionRegion:
            level = LogLevel::Error;
            break;
        default:
            level = LogLevel::Warn;
            break;
    }

    Log(level, "Stopping emulated console (Reason: %s)\n", StopReasonName(reason));
    Running = false;
    Platform::SignalStop(reason, UserData);
    GPU.Stop();
    SPU.Stop();
    Mic.StopAll();
}

u32 NDS::GetSavestateConfig()
{
    u32 ret = 0;

    if (ConsoleType == 1)
        ret |= SC_Console_DSi;

    return ret;
}

bool NDS::DoSavestate(Savestate* file)
{
    file->Section("NDSG");

    u32 config = GetSavestateConfig();
    if (file->Saving)
    {
        file->Var32(&config);
    }
    else
    {
        u32 config_chk;
        file->Var32(&config_chk);
        if (config_chk != config)
        {
            Log(LogLevel::Error, "savestate: Expected config word %08X, got %08X. cannot load.\n", config, config_chk);
            return false;
        }
    }

    file->VarArray(MainRAM, MainRAMMaxSize);
    file->VarArray(SharedWRAM, SharedWRAMSize);
    file->VarArray(ARM7WRAM, ARM7WRAMSize);

    //file->VarArray(ARM9BIOS, 0x1000);
    //file->VarArray(ARM7BIOS, 0x4000);

    file->VarArray(ExMemCnt, 2*sizeof(u16));

    file->Var16(&WifiWaitCnt);

    file->VarArray(IME, 2*sizeof(u32));
    file->VarArray(IE, 2*sizeof(u32));
    file->VarArray(IF, 2*sizeof(u32));
    file->Var32(&IE2);
    file->Var32(&IF2);

    file->Var8(&PostFlag9);
    file->Var8(&PostFlag7);
    file->Var16(&PowerControl9);
    file->Var16(&PowerControl7);

    file->Var16(&ARM7BIOSProt);

    file->Var16(&IPCSync9);
    file->Var16(&IPCSync7);
    file->Var16(&IPCFIFOCnt9);
    file->Var16(&IPCFIFOCnt7);
    IPCFIFO9.DoSavestate(file);
    IPCFIFO7.DoSavestate(file);

    file->Var16(&DivCnt);
    file->Var16(&SqrtCnt);

    file->Var32(&CPUStop);

    for (int i = 0; i < 8; i++)
    {
        Timer* timer = &Timers[i];

        file->Var16(&timer->Reload);
        file->Var16(&timer->Cnt);
        file->Var32(&timer->Counter);
        file->Var32(&timer->CycleShift);
    }
    file->VarArray(TimerCheckMask, 2*sizeof(u8));
    file->VarArray(TimerTimestamp, 2*sizeof(u64));

    file->VarArray(DMA9Fill, 4*sizeof(u32));

    for (int i = 0; i < Event_MAX; i++)
    {
        SchedEvent& evt = SchedList[i];

        file->Var64(&evt.Timestamp);
        file->Var32(&evt.FuncID);
        file->Var32(&evt.Param);
    }
    file->Var32(&SchedListMask);
    file->Var64(&ARM9Timestamp);
    file->Var64(&ARM9Target);
    file->Var64(&ARM7Timestamp);
    file->Var64(&ARM7Target);
    file->Var64(&SysTimestamp);
    file->Var64(&LastSysClockCycles);
    file->Var64(&FrameStartTimestamp);
    file->Var32(&NumFrames);
    file->Var32(&NumLagFrames);
    file->Bool32(&LagFrameFlag);

    // TODO: save KeyInput????
    file->VarArray(KeyCnt, 2*sizeof(u16));
    file->Var16(&RCnt);

    file->Var8(&WRAMCnt);

    file->Bool32(&RunningGame);

    if (!file->Saving)
    {
        // 'dept of redundancy dept'
        // but we do need to update the mappings
        MapSharedWRAM(WRAMCnt);

        InitTimings();
        SetGBASlotTimings();

        UpdateWifiTimings();
    }

    for (int i = 0; i < 8; i++)
        DMAs[i].DoSavestate(file);

    ARM9.DoSavestate(file);
    ARM7.DoSavestate(file);

    NDSCartSlot.DoSavestate(file);
    if (ConsoleType == 0)
        GBACartSlot.DoSavestate(file);
    GPU.DoSavestate(file);
    SPU.DoSavestate(file);
    Mic.DoSavestate(file);
    SPI.DoSavestate(file);
    RTC.DoSavestate(file);
    Wifi.DoSavestate(file);

    DoSavestateExtra(file); // Handles DSi state if applicable

    if (!file->Saving)
    {
        GPU.SetPowerCnt(PowerControl9);

        SPU.SetPowerCnt(PowerControl7 & 0x0001);
        Wifi.SetPowerCnt(PowerControl7 & 0x0002);

#ifdef JIT_ENABLED
        JIT.Reset();
#endif
    }

    file->Finish();

    return true;
}

void NDS::SetNDSCart(std::unique_ptr<NDSCart::CartCommon>&& cart)
{
    NDSCartSlot.SetCart(std::move(cart));
    // The existing cart will always be ejected;
    // if cart is null, then that's equivalent to ejecting a cart
    // without inserting a new one.
}

void NDS::SetNDSSave(const u8* savedata, u32 savelen)
{
    if (savedata && savelen)
        NDSCartSlot.SetSaveMemory(savedata, savelen);
}

void NDS::SetGBASave(const u8* savedata, u32 savelen)
{
    if (ConsoleType == 0 && savedata && savelen)
    {
        GBACartSlot.SetSaveMemory(savedata, savelen);
    }

}

void NDS::LoadBIOS()
{
    Reset();
}

void NDS::SetARM7BIOS(const std::array<u8, ARM7BIOSSize>& bios) noexcept
{
    ARM7BIOS = bios;
    ARM7BIOSNative = CRC32(ARM7BIOS.data(), ARM7BIOS.size()) == ARM7BIOSCRC32;
}

void NDS::SetARM9BIOS(const std::array<u8, ARM9BIOSSize>& bios) noexcept
{
    ARM9BIOS = bios;
    ARM9BIOSNative = CRC32(ARM9BIOS.data(), ARM9BIOS.size()) == ARM9BIOSCRC32;
}

u64 NDS::NextTarget()
{
    u64 minEvent = UINT64_MAX;

    u32 mask = SchedListMask;
    for (int i = 0; i < Event_MAX; i++)
    {
        if (!mask) break;
        if (mask & 0x1)
        {
            if (SchedList[i].Timestamp < minEvent)
                minEvent = SchedList[i].Timestamp;
        }

        mask >>= 1;
    }

    u64 max = SysTimestamp + kMaxIterationCycles;

    if (minEvent < max + kIterationCycleMargin)
        return minEvent;

    return max;
}

void NDS::RunSystem(u64 timestamp)
{
#if NDS4MISTER_EXTERNAL_TIME_WINDOW
    // Once the proof protocol is enabled, only the explicit close operation
    // may move scheduler time. Otherwise a callback could mutate IF while no
    // transition batch exists to name that mutation.
    if (ExternalTimeWindowEnabled_ && !ExternalTimeWindowClosureActive_)
    {
        ExternalTimeWindowFaulted_ = true;
        return;
    }
#endif
    SysTimestamp = timestamp;

    u32 mask = SchedListMask;
    for (int i = 0; i < Event_MAX; i++)
    {
        if (!mask) break;
        if (mask & 0x1)
        {
            SchedEvent& evt = SchedList[i];

            if (evt.Timestamp <= SysTimestamp)
            {
                SchedListMask &= ~(1<<i);

                EventFunc func = evt.Funcs[evt.FuncID];
                func(evt.That, evt.Param);
            }
        }

        mask >>= 1;
    }
}

u64 NDS::NextTargetSleep()
{
    u64 minEvent = UINT64_MAX;

    u32 mask = SchedListMask;
    for (int i = 0; i < Event_MAX; i++)
    {
        if (!mask) break;
        if (i == Event_SPU || i == Event_RTC)
        {
            if (mask & 0x1)
            {
                if (SchedList[i].Timestamp < minEvent)
                    minEvent = SchedList[i].Timestamp;
            }
        }

        mask >>= 1;
    }

    return minEvent;
}

void NDS::RunSystemSleep(u64 timestamp)
{
#if NDS4MISTER_EXTERNAL_TIME_WINDOW
    if (ExternalTimeWindowEnabled_ && !ExternalTimeWindowClosureActive_)
    {
        ExternalTimeWindowFaulted_ = true;
        return;
    }
#endif
    u64 offset = timestamp - SysTimestamp;
    SysTimestamp = timestamp;

    u32 mask = SchedListMask;
    for (int i = 0; i < Event_MAX; i++)
    {
        if (!mask) break;
        if (i == Event_RTC)
        {
            if (mask & 0x1)
            {
                SchedEvent& evt = SchedList[i];

                if (evt.Timestamp <= SysTimestamp)
                {
                    SchedListMask &= ~(1<<i);

                    EventFunc func = evt.Funcs[evt.FuncID];
                    func(evt.That, evt.Param);
                }
            }
        }
        else if (mask & 0x1)
        {
            if (SchedList[i].Timestamp <= SysTimestamp)
            {
                SchedList[i].Timestamp += offset;
            }
        }

        mask >>= 1;
    }
}

template <CPUExecuteMode cpuMode>
u32 NDS::RunFrame()
{
    Current = this;

    double perfGPUSeconds = 0.0;
    double perfAudioSeconds = 0.0;
#if NDS4MISTER_CORE_TIMING
    const auto perfFrameStart = std::chrono::steady_clock::now();
#endif

    FrameStartTimestamp = SysTimestamp;

    GPU.TotalScanlines = 0;

    LagFrameFlag = true;
    bool runFrame = Running && !(CPUStop & CPUStop_Sleep);
    while (Running)
    {
        u64 frametarget = SysTimestamp + 560190;

        if (CPUStop & CPUStop_Sleep)
        {
            // we are running in sleep mode
            // we still need to run the RTC during this mode
            // we also keep outputting audio, so that frontends using audio sync don't skyrocket to 1000+FPS

            while (Running && (SysTimestamp < frametarget))
            {
                u64 target = NextTargetSleep();
                if (target > frametarget)
                    target = frametarget;

                ARM9Timestamp = target << ARM9ClockShift;
                ARM7Timestamp = target;
                TimerTimestamp[0] = target;
                TimerTimestamp[1] = target;
                GPU.GPU3D.Timestamp = target;
                RunSystemSleep(target);

                if (!(CPUStop & CPUStop_Sleep))
                    break;
            }

            if (SysTimestamp >= frametarget)
            {
#if NDS4MISTER_CORE_TIMING
                const auto perfStart = std::chrono::steady_clock::now();
#endif
                GPU.BlankFrame();
#if NDS4MISTER_CORE_TIMING
                perfGPUSeconds += PerfElapsedSeconds(perfStart, std::chrono::steady_clock::now());
#endif
            }
        }
        else
        {
            if (cpuMode == CPUExecuteMode::InterpreterGDB)
            {
                ARM9.CheckGdbIncoming();
                ARM7.CheckGdbIncoming();
            }

            if (!(CPUStop & CPUStop_Wakeup))
            {
#if NDS4MISTER_CORE_TIMING
                const auto perfStart = std::chrono::steady_clock::now();
#endif
                GPU.StartFrame();
#if NDS4MISTER_CORE_TIMING
                perfGPUSeconds += PerfElapsedSeconds(perfStart, std::chrono::steady_clock::now());
#endif
            }
            CPUStop &= ~CPUStop_Wakeup;

            while (Running && GPU.TotalScanlines==0)
            {
                u64 target = NextTarget();
                ARM9Target = target << ARM9ClockShift;
                CurCPU = 0;

                if (CPUStop & CPUStop_GXStall)
                {
                    // GXFIFO stall
                    s32 cycles = GPU.GPU3D.CyclesToRunFor();

                    ARM9Timestamp = std::min(ARM9Target, ARM9Timestamp+(cycles<<ARM9ClockShift));
                }
                else if (CPUStop & CPUStop_DMA9)
                {
                    DMAs[0].Run();
                    if (!(CPUStop & CPUStop_GXStall)) DMAs[1].Run();
                    if (!(CPUStop & CPUStop_GXStall)) DMAs[2].Run();
                    if (!(CPUStop & CPUStop_GXStall)) DMAs[3].Run();
                    if (ConsoleType == 1)
                    {
                        auto& dsi = dynamic_cast<melonDS::DSi&>(*this);
                        dsi.RunNDMAs(0);
                    }
                }
                else
                {
                    ARM9.Execute<cpuMode>();
                }

                RunTimers(0);
#if NDS4MISTER_CORE_TIMING
                const auto perfStart = std::chrono::steady_clock::now();
#endif
                GPU.GPU3D.Run();
#if NDS4MISTER_CORE_TIMING
                perfGPUSeconds += PerfElapsedSeconds(perfStart, std::chrono::steady_clock::now());
#endif

                target = ARM9Timestamp >> ARM9ClockShift;
                CurCPU = 1;

                while (ARM7Timestamp < target)
                {
                    ARM7Target = target; // might be changed by a reschedule

                    if (CPUStop & CPUStop_DMA7)
                    {
                        DMAs[4].Run();
                        DMAs[5].Run();
                        DMAs[6].Run();
                        DMAs[7].Run();
                        if (ConsoleType == 1)
                        {
                            auto& dsi = dynamic_cast<melonDS::DSi&>(*this);
                            dsi.RunNDMAs(1);
                        }
                    }
                    else
                    {
                        ARM7.Execute<cpuMode>();
                    }

                    RunTimers(1);
                }

                RunSystem(target);

                if (CPUStop & CPUStop_Sleep)
                {
                    break;
                }
            }
        }

        if (GPU.TotalScanlines == 0)
            continue;

#ifdef DEBUG_CHECK_DESYNC
        Log(LogLevel::Debug, "[%08X%08X] ARM9=%ld, ARM7=%ld, GPU=%ld\n",
            (u32)(SysTimestamp>>32), (u32)SysTimestamp,
            (ARM9Timestamp>>1)-SysTimestamp,
            ARM7Timestamp-SysTimestamp,
            GPU.GPU3D.Timestamp-SysTimestamp);
#endif
        break;
    }

    // Ensure the last audio samples produced for this frame are available to the frontend immediately
#if NDS4MISTER_CORE_TIMING
    const auto perfAudioStart = std::chrono::steady_clock::now();
#endif
    SPU.BufferAudio();
#if NDS4MISTER_CORE_TIMING
    perfAudioSeconds += PerfElapsedSeconds(perfAudioStart, std::chrono::steady_clock::now());

    const double perfTotalSeconds = PerfElapsedSeconds(perfFrameStart, std::chrono::steady_clock::now());
    LastFramePerformance.GPUSeconds = perfGPUSeconds;
    LastFramePerformance.AudioSeconds = perfAudioSeconds;
    LastFramePerformance.CPUSeconds = perfTotalSeconds > (perfGPUSeconds + perfAudioSeconds)
        ? perfTotalSeconds - perfGPUSeconds - perfAudioSeconds
        : 0.0;
#endif

    // In the context of TASes, frame count is traditionally the primary measure of emulated time,
    // so it needs to be tracked even if NDS is powered off.
    NumFrames++;
    if (LagFrameFlag)
        NumLagFrames++;

    if (Running)
        return GPU.TotalScanlines;
    else
        return 263;
}

u64 NDS::AdvanceExternalCPU(u32 cpu, u32 cycles)
{
#if NDS4MISTER_EXTERNAL_TIME_WINDOW
    // This legacy helper executes timers/private callbacks and may call
    // RunSystem. It cannot be mixed with a named time-window transaction;
    // use ReportExternalTimeWindowCPUReached plus
    // AdvanceAndCloseExternalTimeWindow instead.
    if (ExternalTimeWindowEnabled_)
    {
        ExternalTimeWindowFaulted_ = true;
        return SysTimestamp;
    }
#endif
    // Peripheral writes schedule events relative to CurCPU. In hybrid mode
    // the FPGA CPUs perform bus accesses outside RunFrame(), so establish the
    // issuing CPU context here and leave it active for the following access.
    CurCPU = cpu;
    if (!ExternalSchedulerStarted)
    {
        GPU.StartFrame();
        ExternalSchedulerStarted = true;
    }
    if (cpu == 0)
        ARM9Timestamp += static_cast<u64>(cycles) << ARM9ClockShift;
    else
        ARM7Timestamp += cycles;
    RunTimers(cpu);
    // The cartridge interface has a distinct transfer event for each CPU.
    // In external-CPU mode, holding that event behind min(ARM9, ARM7) can
    // leave the issuing CPU polling ROMCTRL BUSY forever while the other CPU
    // is executing a long FPGA-local block. Service the issuing interface at
    // its authoritative CPU timestamp. A callback can schedule its next word
    // at a later timestamp, so consume every event already reached by this
    // CPU while stopping naturally when the cartridge FIFO becomes full.
    const u32 cartROMEvent = cpu == 0
        ? Event_CartROMTransfer9 : Event_CartROMTransfer7;
    const u64 cpuTimestamp = cpu == 0
        ? (ARM9Timestamp >> ARM9ClockShift) : ARM7Timestamp;
    while (SchedListMask & (1u << cartROMEvent))
    {
        SchedEvent& evt = SchedList[cartROMEvent];
        if (evt.Timestamp > cpuTimestamp)
            break;
        SchedListMask &= ~(1u << cartROMEvent);
        EventFunc func = evt.Funcs[evt.FuncID];
        func(evt.That, evt.Param);
    }
    // AUXSPI completion is also local to the issuing cartridge interface.
    const u32 cartSPIEvent = cpu == 0
        ? Event_CartSPITransfer9 : Event_CartSPITransfer7;
    if (SchedListMask & (1u << cartSPIEvent))
    {
        SchedEvent& evt = SchedList[cartSPIEvent];
        if (evt.Timestamp <= cpuTimestamp)
        {
            SchedListMask &= ~(1u << cartSPIEvent);
            EventFunc func = evt.Funcs[evt.FuncID];
            func(evt.That, evt.Param);
        }
    }
    // The hardware divider and square-root unit are ARM9-local peripherals.
    // Their completion cannot wait for ARM7 to catch up to the shared system
    // timestamp: the ARM9 BIOS saves/restores these registers in its IRQ
    // wrapper and observes BUSY directly.  Leaving these events behind
    // min(ARM9, ARM7) can turn a completed divide-by-zero into a stale BUSY
    // result and corrupt the interrupted calculation's restored state.
    if (cpu == 0)
    {
        for (const u32 event : {Event_Div, Event_Sqrt})
        {
            if (!(SchedListMask & (1u << event)))
                continue;
            SchedEvent& evt = SchedList[event];
            if (evt.Timestamp > cpuTimestamp)
                continue;
            SchedListMask &= ~(1u << event);
            EventFunc func = evt.Funcs[evt.FuncID];
            func(evt.That, evt.Param);
        }
    }
    // SPI belongs exclusively to ARM7. In external-CPU mode ARM7 can enter
    // its BUSY polling loop while ARM9 is executing a long FPGA-local block
    // and has not reached the next timing-mailbox batch. Holding this event
    // behind min(ARM9, ARM7) makes BUSY permanent from ARM7's point of view
    // and turns a three-read native poll into hundreds of thousands of HPS
    // round trips. Complete only this CPU-local event at ARM7's authoritative
    // timestamp; shared LCD/audio/DMA events remain causally gated below.
    if (cpu == 1 && (SchedListMask & (1u << Event_SPITransfer)))
    {
        SchedEvent& evt = SchedList[Event_SPITransfer];
        if (evt.Timestamp <= ARM7Timestamp)
        {
            SchedListMask &= ~(1u << Event_SPITransfer);
            EventFunc func = evt.Funcs[evt.FuncID];
            func(evt.That, evt.Param);
        }
    }
    if (cpu == 0) GPU.GPU3D.Run();
    // A halted CPU's time still passes. Execute() jumps a halted core straight
    // to its target (ARM.cpp, "NDS.ARM9Timestamp = NDS.ARM9Target"), so the
    // halted peer never gates the scheduler in stock melonDS. In hybrid mode
    // the FPGA only creeps a halted ARM7 forward one HALT_ADVANCE_CYCLES batch
    // per HALT_POLL_CLOCKS, which throttles min(ARM9, ARM7) -- and therefore
    // every shared LCD/audio/DMA event -- to that poll cadence.
    //
    // Advance the halted peer, but never past the next scheduled event: that
    // event may be the very interrupt that wakes it, and stepping over a wake
    // is what corrupts state. Each call closes part of the gap; the shared
    // loop below then runs events up to the new bound and may clear Halted.
    if (ExternalHaltedPeerAdvance)
    {
        if (cpu == 0 && ARM7.Halted == 1 && !HaltInterrupted(1))
        {
            const u64 arm9Now = ARM9Timestamp >> ARM9ClockShift;
            if (ARM7Timestamp < arm9Now)
            {
                const u64 next = NextTarget();
                ARM7Timestamp = next < arm9Now ? next : arm9Now;
            }
        }
        else if (cpu == 1 && ARM9.Halted == 1 && !HaltInterrupted(0))
        {
            const u64 arm9Now = ARM9Timestamp >> ARM9ClockShift;
            if (arm9Now < ARM7Timestamp)
            {
                const u64 next = NextTarget();
                const u64 bound = next < ARM7Timestamp ? next : ARM7Timestamp;
                ARM9Timestamp = bound << ARM9ClockShift;
            }
        }
    }
    // The FPGA CPUs execute independently between mailbox flushes. Advancing
    // peripherals to whichever CPU reported most recently lets the faster CPU
    // drag LCD/audio/IRQ time past work the other CPU has not executed yet.
    // Only time reached by both CPUs is causally safe.
    const u64 timestamp = std::min(
        ARM9Timestamp >> ARM9ClockShift, ARM7Timestamp);
    // Run each event at its scheduled timestamp. Jumping directly to the CPU
    // timestamp causes periodic LCD/SPU callbacks to schedule their successor
    // relative to an already-late time and silently drops most scanlines.
    while (SysTimestamp < timestamp)
    {
        u64 target = NextTarget();
        if (target > timestamp) target = timestamp;
        RunSystem(target);
        // GPU scan events can start HBlank/VBlank/immediate DMA. In hybrid
        // mode there is no melonDS CPU execution loop to service CPUStop_DMA,
        // so complete the memory-side DMA work while the FPGA is blocked on
        // this mailbox transaction. Preserve external CPU timestamps: the
        // FPGA remains the authoritative source of elapsed CPU time.
        const u64 saved9 = ARM9Timestamp, saved7 = ARM7Timestamp;
        const u64 saved9Target = ARM9Target, saved7Target = ARM7Target;
        if (CPUStop & CPUStop_DMA9)
        {
            ARM9Target = ARM9Timestamp + (static_cast<u64>(1) << 32);
            for (unsigned pass = 0; pass < 1024 &&
                 (CPUStop & CPUStop_DMA9); ++pass)
            {
                DMAs[0].Run();
                if (!(CPUStop & CPUStop_GXStall)) DMAs[1].Run();
                if (!(CPUStop & CPUStop_GXStall)) DMAs[2].Run();
                if (!(CPUStop & CPUStop_GXStall)) DMAs[3].Run();
            }
        }
        if (CPUStop & CPUStop_DMA7)
        {
            ARM7Target = ARM7Timestamp + (static_cast<u64>(1) << 32);
            for (unsigned pass = 0; pass < 1024 &&
                 (CPUStop & CPUStop_DMA7); ++pass)
            {
                DMAs[4].Run(); DMAs[5].Run();
                DMAs[6].Run(); DMAs[7].Run();
            }
        }
        ARM9Timestamp = saved9; ARM7Timestamp = saved7;
        ARM9Target = saved9Target; ARM7Target = saved7Target;
        if (!ExternalLCDRendererEnabled_ && GPU.TotalScanlines != 0)
            GPU.StartFrame();
    }
    return SysTimestamp;
}

// Advance the whole system coherently to its next scheduled event.
//
// The hybrid replaced RunFrame()'s scheduler advance with per-access
// AdvanceExternalCPU, which only services the issuing CPU's private events.
// A CPU spin-polling a hardware-owned register (VCOUNT, ROMCTRL) therefore
// burns one FPGA<->HPS round trip per poll while waiting for a value that a
// one-sided advance can never change.
//
// This is melonDS's own NextTarget()/RunSystem() path, so shared LCD, audio
// and DMA events genuinely fire. The caller must only use it when the external
// CPU really is waiting on time to pass -- it credits the spinning CPU with
// the cycles it is about to spend in that loop.
//
// `bound` optionally caps how far the clock may jump (0 = no cap). A running
// ARM7 stays authoritative and caps the target on its own; only a halted ARM7
// yields its time, matching Execute()'s halt behaviour.
bool NDS::ExternalGXFIFODMAActive() const
{
    for (int i = 0; i < 4; ++i)
        if (DMAs[i].IsInMode(0x07) && DMAs[i].IsRunning())
            return true;
    return false;
}

bool NDS::CompleteExternalDMA(u32 cpu)
{
    const u32 mask = cpu == 0 ? CPUStop_DMA9 : CPUStop_DMA7;
    if (!(CPUStop & mask)) return true;

    const u64 saved9 = ARM9Timestamp, saved7 = ARM7Timestamp;
    const u64 saved9Target = ARM9Target, saved7Target = ARM7Target;
    if (cpu == 0)
    {
        ARM9Target = ARM9Timestamp + (static_cast<u64>(1) << 32);
        for (unsigned pass = 0; pass < 1024 && (CPUStop & mask); ++pass)
        {
            if (CPUStop & CPUStop_GXStall) GPU.GPU3D.Run();
            DMAs[0].Run();
            if (!(CPUStop & CPUStop_GXStall)) DMAs[1].Run();
            if (!(CPUStop & CPUStop_GXStall)) DMAs[2].Run();
            if (!(CPUStop & CPUStop_GXStall)) DMAs[3].Run();
        }
    }
    else
    {
        ARM7Target = ARM7Timestamp + (static_cast<u64>(1) << 32);
        for (unsigned pass = 0; pass < 1024 && (CPUStop & mask); ++pass)
        {
            DMAs[4].Run(); DMAs[5].Run();
            DMAs[6].Run(); DMAs[7].Run();
        }
    }
    ARM9Timestamp = saved9; ARM7Timestamp = saved7;
    ARM9Target = saved9Target; ARM7Target = saved7Target;
    return (CPUStop & mask) == 0;
}

bool NDS::SetExternalTimeWindowEnabled(bool enabled) noexcept
{
#if NDS4MISTER_EXTERNAL_TIME_WINDOW
    if (!enabled)
    {
        const bool wasEnabled = ExternalTimeWindowEnabled_;
        const bool wasFaulted = ExternalTimeWindowFaulted_;
        ExternalTimeWindowEnabled_ = false;
        ExternalTimeWindowClosureActive_ = false;
        ExternalARM9IFW1CActive_ = false;
        // A published P/R grant is an epoch commitment. Silently disabling
        // and later starting sequence 1/P0 again could detach queued IRQ
        // records from their transaction. Require Reset for a clean restart.
        if (wasEnabled && !wasFaulted && ExternalTimeWindowHaveFrontier_)
        {
            ExternalTimeWindowFaulted_ = true;
            return false;
        }
        return true;
    }
    // Once closure may have changed architectural state without publishing a
    // complete transaction, only Reset can establish a new trustworthy epoch.
    if (ExternalTimeWindowFaulted_)
        return false;
    if (ExternalTimeWindowEnabled_)
        return true;

    ExternalTimeWindowClosureActive_ = false;
    ExternalTimeWindowObserverFailed_ = false;
    ExternalTimeWindowHaveFrontier_ = false;
    ExternalTimeWindowEventSequence_ = 0;
    ExternalTimeWindowLastProcessed_ = 0;
    ExternalTimeWindowLastRunSafe_ = 0;
    ExternalTimeWindowProfile_ = {};
    ExternalTimeWindowCPUReached_[0] = ARM9Timestamp >> ARM9ClockShift;
    ExternalTimeWindowCPUReached_[1] = ARM7Timestamp;
    ExternalTimeWindowObservedIF_[0] = 0;
    ExternalTimeWindowObservedIF_[1] = 0;
    ExternalTimeWindowHaveVerifiedGrant_ = false;
    ExternalTimeWindowVerifiedCloseActive_ = false;
    ExternalTimeWindowVerifiedEpoch_ = 0;
    ExternalTimeWindowVerifiedGrantSequence_ = 0;
    ExternalTimeWindowVerifiedProducerFence_ = 0;
    ExternalTimeWindowHaveSourceSequence_ = false;
    ExternalTimeWindowLastSourceSequence_ = 0;
    ExternalARM9IFW1CActive_ = false;
    ExternalARM9IFW1CFailed_ = false;
    ExternalARM9IFW1CHaveLast_ = false;
    ExternalARM9IFW1CExpectedGXFIFOSet_ = false;
    ExternalARM9IFW1CPhase_ = 0;
    ExternalARM9IFW1CExpectedPhases_ = 0;
    ExternalARM9IFW1CExpectedClearMask_ = 0;
    ExternalARM9IFW1CLastSourceSequence_ = 0;
    ExternalARM9IFW1CLastTimestamp_ = 0;
    ExternalBlockingMMIOBarrierActive_ = false;
    ExternalBlockingMMIOAccessClaimed_ = false;
    ExternalBlockingMMIOAccessComplete_ = false;
    ExternalBlockingMMIOHaveIdentity_ = false;
    ExternalBlockingMMIOEpoch_ = 0;
    ExternalBlockingMMIOLastSourceSequence_ = 0;
    ExternalBlockingMMIOLastBarrierSequence_ = 0;
    ExternalBlockingMMIOBarrierTimestamp_ = 0;
    ExternalBlockingMMIORequest_ = {};
    ExternalBlockingMMIOIEAfterAccess_[0] = 0;
    ExternalBlockingMMIOIEAfterAccess_[1] = 0;
    ExternalBlockingMMIOIMEAfterAccess_[0] = 0;
    ExternalBlockingMMIOIMEAfterAccess_[1] = 0;
    ExternalBlockingMMIOIF2AfterAccess_ = 0;
    ExternalBlockingMMIOIE2AfterAccess_ = 0;
    ExternalBlockingMMIONonDMAStopAfterAccess_ = 0;
    // The legacy external-CPU path starts the LCD scheduler on its first
    // cycle report. ETW replaces that path entirely, so it must establish the
    // same frame bootstrap here or Event_LCD is never scheduled and no frame
    // can ever be rendered or published.
    if (!ExternalSchedulerStarted && !ExternalLCDRendererEnabled_)
    {
        GPU.StartFrame();
        ExternalSchedulerStarted = true;
    }
    ExternalTimeWindowEnabled_ = true;
    return true;
#else
    (void)enabled;
    return !enabled;
#endif
}

bool NDS::SetExternalOfflineFastBeta(bool enabled) noexcept
{
    if (!enabled)
        return !ExternalOfflineFastBeta_;
    if (ExternalOfflineFastBeta_)
        return true;
    if (ExternalTimeWindowEnabled_ || ExternalTimeWindowHaveFrontier_ ||
        ExternalTimeWindowClosureActive_)
        return false;

    RTC.EnableOfflineStub();
    Wifi.EnableOfflineStub();
    ExternalOfflineFastBeta_ = true;
    return true;
}

bool NDS::SelfTestExternalOfflineFastBeta()
{
    auto offlineStorage = std::make_unique<NDS>();
    NDS& offline = *offlineStorage;
    offline.Reset();
    offline.Wifi.Write(0x04800036u, 0);
    offline.Wifi.SetPowerCnt(2);
    if (!(offline.SchedListMask & (1u << Event_RTC)) ||
        !(offline.SchedListMask & (1u << Event_Wifi)) ||
        offline.RTC.OfflineStubEnabled() ||
        offline.Wifi.OfflineStubEnabled())
        return false;

    RTC::StateData beforeRTC {};
    RTC::StateData afterRTC {};
    offline.RTC.GetState(beforeRTC);
    offline.SetIRQ(1, IRQ_RTC);
    offline.SetIRQ(1, IRQ_Wifi);
    offline.SetIRQ(1, IRQ_Timer0);
    if (!offline.SetExternalOfflineFastBeta(true) ||
        !offline.ExternalOfflineFastBetaEnabled() ||
        !offline.RTC.OfflineStubEnabled() ||
        !offline.Wifi.OfflineStubEnabled() ||
        (offline.SchedListMask &
            ((1u << Event_RTC) | (1u << Event_Wifi))) ||
        (offline.IF[1] &
            ((1u << IRQ_RTC) | (1u << IRQ_Wifi))) ||
        !(offline.IF[1] & (1u << IRQ_Timer0)))
        return false;

    offline.RTC.ClockTimer(0);
    offline.Wifi.USTimer(0);
    offline.Wifi.SetPowerCnt(2);
    offline.Wifi.Write(0x04800036u, 0);
    offline.RTC.GetState(afterRTC);
    if (memcmp(&beforeRTC, &afterRTC, sizeof(beforeRTC)) != 0 ||
        offline.Wifi.Read(0x04800000u) != 0 ||
        (offline.SchedListMask &
            ((1u << Event_RTC) | (1u << Event_Wifi))))
        return false;

    offline.Reset();
    offline.Wifi.SetPowerCnt(2);
    if (!offline.RTC.OfflineStubEnabled() ||
        !offline.Wifi.OfflineStubEnabled() ||
        (offline.SchedListMask &
            ((1u << Event_RTC) | (1u << Event_Wifi))) ||
        offline.Wifi.Read(0x04800000u) != 0 ||
        offline.SetExternalOfflineFastBeta(false))
        return false;

#if NDS4MISTER_EXTERNAL_TIME_WINDOW
    auto lateStorage = std::make_unique<NDS>();
    NDS& late = *lateStorage;
    late.Reset();
    if (!late.SetExternalTimeWindowEnabled(true) ||
        late.SetExternalOfflineFastBeta(true) ||
        late.ExternalOfflineFastBetaEnabled() ||
        late.RTC.OfflineStubEnabled() ||
        late.Wifi.OfflineStubEnabled())
        return false;
#endif
    return true;
}

bool NDS::SetExternalLCDRendererEnabled(bool enabled) noexcept
{
#if NDS4MISTER_EXTERNAL_TIME_WINDOW
    // Authority selection is an epoch rule. Changing it after ETW admission
    // could leave a stock LCD callback and a queue descriptor in one epoch.
    if (ExternalTimeWindowEnabled_ || ExternalTimeWindowHaveFrontier_)
        return false;
    if (enabled &&
        (SchedListMask & ((1u << Event_LCD) | (1u << Event_DisplayFIFO))))
        return false;
    ExternalLCDRendererEnabled_ = enabled;
    return true;
#else
    return !enabled;
#endif
}

bool NDS::ApplyExternalLCDRendererPhase(
    u32 kind, u32 line, u32 vcount, u32 dispstat9, u32 dispstat7,
    u32 frameSequence, bool render, bool resync) noexcept
{
#if NDS4MISTER_EXTERNAL_TIME_WINDOW
    if (!ExternalLCDRendererEnabled_ || !ExternalTimeWindowEnabled_ ||
        ExternalTimeWindowFaulted_ || ExternalBlockingMMIOAccessClaimed_ ||
        kind > 2 || line > 262 || vcount > 511)
        return false;
    return GPU.ApplyExternalRendererPhase(
        kind, line, vcount, dispstat9, dispstat7,
        frameSequence, render, resync);
#else
    (void)kind;
    (void)line;
    (void)vcount;
    (void)dispstat9;
    (void)dispstat7;
    (void)frameSequence;
    (void)render;
    (void)resync;
    return false;
#endif
}

ExternalTimeWindowResult NDS::ReportExternalTimeWindowCPUReached(
    u32 cpu, u64 normalizedTimestamp) noexcept
{
#if !NDS4MISTER_EXTERNAL_TIME_WINDOW
    (void)cpu;
    (void)normalizedTimestamp;
    return ExternalTimeWindowResult::CapabilityDisabled;
#else
    if (ExternalTimeWindowFaulted_)
        return ExternalTimeWindowResult::ProtocolFaulted;
    if (!ExternalTimeWindowEnabled_)
        return ExternalTimeWindowResult::NotEnabled;
    if (ExternalBlockingMMIOBarrierActive_)
    {
        // Barrier admission has already truncated the grant and moved model
        // time. Only its one claimed access followed by Close may proceed.
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::BlockingMMIOBarrierStateMismatch;
    }
    if (!ExternalTimeWindowHaveFrontier_)
        return ExternalTimeWindowResult::NoActiveGrant;
    if (cpu > 1)
        return ExternalTimeWindowResult::InvalidCPU;
    if (normalizedTimestamp < ExternalTimeWindowCPUReached_[cpu])
        return ExternalTimeWindowResult::CPUProgressRegressed;
    if (normalizedTimestamp > ExternalTimeWindowLastRunSafe_)
    {
        // The FPGA has claimed execution beyond the inclusive grant. Its
        // architectural state can no longer be reconciled by retrying.
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::CPUProgressBeyondRunSafe;
    }
    if (cpu == 0 &&
        normalizedTimestamp >
            (std::numeric_limits<u64>::max() >> ARM9ClockShift))
        return ExternalTimeWindowResult::TimestampOverflow;

    ExternalTimeWindowCPUReached_[cpu] = normalizedTimestamp;
    if (cpu == 0)
        ARM9Timestamp = normalizedTimestamp << ARM9ClockShift;
    else
        ARM7Timestamp = normalizedTimestamp;
    return ExternalTimeWindowResult::Success;
#endif
}

ExternalTimeWindowResult NDS::AdvanceAndCloseExternalTimeWindow(
    u64 closeThrough, u64 finiteBound,
    u64 fpgaAuthoritativeEventMask,
    ExternalTimeWindow& out) noexcept
{
    out = {};
#if !NDS4MISTER_EXTERNAL_TIME_WINDOW
    (void)closeThrough;
    (void)finiteBound;
    (void)fpgaAuthoritativeEventMask;
    return ExternalTimeWindowResult::CapabilityDisabled;
#else
    if (ExternalTimeWindowFaulted_)
        return ExternalTimeWindowResult::ProtocolFaulted;
    if (!ExternalTimeWindowEnabled_)
        return ExternalTimeWindowResult::NotEnabled;
    if (ExternalTimeWindowHaveVerifiedGrant_ &&
        !ExternalTimeWindowVerifiedCloseActive_)
        return ExternalTimeWindowResult::InvalidExternalTimeWindowIdentity;
    const bool finishingBlockingMMIO =
        ExternalBlockingMMIOBarrierActive_;
    const auto reject = [&](ExternalTimeWindowResult result) noexcept {
        // Once BeginExternalBlockingMMIOBarrier succeeds, model time, both
        // effective CPU timestamps, and the old R have changed. Any malformed
        // completion is therefore reset-only; retrying could apply the HPS
        // access twice or detach its IRQs from their source identity.
        if (finishingBlockingMMIO)
            ExternalTimeWindowFaulted_ = true;
        return result;
    };
    if (finishingBlockingMMIO &&
        (!ExternalTimeWindowVerifiedCloseActive_ ||
         !ExternalTimeWindowClosureActive_ ||
         !ExternalBlockingMMIOAccessClaimed_ ||
         !ExternalBlockingMMIOAccessComplete_ ||
         closeThrough != ExternalBlockingMMIOBarrierTimestamp_ ||
         SysTimestamp != ExternalBlockingMMIOBarrierTimestamp_ ||
         ExternalTimeWindowLastProcessed_ !=
             ExternalBlockingMMIOBarrierTimestamp_ ||
         ExternalTimeWindowLastRunSafe_ !=
             ExternalBlockingMMIOBarrierTimestamp_))
        return reject(ExternalTimeWindowResult::BlockingMMIOAccessRequired);
    if (!finishingBlockingMMIO && ExternalTimeWindowClosureActive_)
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::BlockingMMIOBarrierStateMismatch;
    }
    // Excluding an event transfers its time/side-effect authority to FPGA.
    // No event class has completed that proof yet.
    if (fpgaAuthoritativeEventMask != 0)
        return reject(
            ExternalTimeWindowResult::UnsupportedAuthoritativeEventMask);
    // UINT64_MAX is conventionally the no-event sentinel.  Requiring a real
    // finite cap makes E-1 and all monotonic comparisons unambiguous.
    if (finiteBound == std::numeric_limits<u64>::max())
        return reject(ExternalTimeWindowResult::InvalidFiniteBound);

    const u64 target = closeThrough;
    if (finiteBound < target)
        return reject(ExternalTimeWindowResult::BoundBeforeProcessed);

    u64 requiredCPUProgress = target;
    if (!ExternalTimeWindowHaveFrontier_)
    {
        // The first transaction closes the scheduler's current instant. It
        // cannot manufacture an unseen history between two arbitrary times.
        if (target != SysTimestamp)
            return reject(ExternalTimeWindowResult::BoundarySkipped);
    }
    else
    {
        if (SysTimestamp != ExternalTimeWindowLastProcessed_)
        {
            ExternalTimeWindowFaulted_ = true;
            return ExternalTimeWindowResult::SchedulerAdvancedOutsideClosure;
        }
        if (target < ExternalTimeWindowLastProcessed_ ||
            finiteBound < ExternalTimeWindowLastRunSafe_)
            return reject(ExternalTimeWindowResult::FrontierRegressed);

        if (target > ExternalTimeWindowLastRunSafe_)
        {
            const bool exactNextBoundary =
                ExternalTimeWindowLastRunSafe_ !=
                    std::numeric_limits<u64>::max() &&
                target == ExternalTimeWindowLastRunSafe_ + 1;
            if (!exactNextBoundary)
                return reject(ExternalTimeWindowResult::BoundarySkipped);
            // CPUs are forbidden from executing the not-yet-granted boundary
            // itself. Reaching the preceding inclusive R is sufficient for
            // Close to process the event at R+1 atomically.
            requiredCPUProgress = ExternalTimeWindowLastRunSafe_;
        }
    }
    if (ExternalTimeWindowCPUReached_[0] < requiredCPUProgress ||
        ExternalTimeWindowCPUReached_[1] < requiredCPUProgress)
        return reject(ExternalTimeWindowResult::CausalTargetNotReached);

    const auto earliestScheduledEvent = [&](u32* earliestID = nullptr) noexcept {
        u64 earliest = std::numeric_limits<u64>::max();
        u32 selected = Event_MAX;
        u32 mask = SchedListMask;
        for (u32 id = 0; id < Event_MAX && mask; ++id, mask >>= 1)
            if ((mask & 1u) && SchedList[id].Timestamp < earliest)
            {
                earliest = SchedList[id].Timestamp;
                selected = id;
            }
        if (earliestID) *earliestID = selected;
        return earliest;
    };
    const u64 preClosureEarliest = earliestScheduledEvent();
    // Detect a newly inserted event before mutating the scheduler.  Consuming
    // it first would erase the proof that it landed inside an already-issued
    // inclusive grant.
    if (ExternalTimeWindowHaveFrontier_ &&
        preClosureEarliest <= ExternalTimeWindowLastRunSafe_ &&
        !(finishingBlockingMMIO && preClosureEarliest == target))
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::LateEvent;
    }
    // This scoped API closes only the exact current causal target.  Executing
    // an overdue callback at `target` would give every resulting IRQ the wrong
    // timestamp; explicit earliest-event stepping belongs to the later
    // boundary protocol.
    if (preClosureEarliest < target)
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::EventBeforeClosureTarget;
    }

    // Re-querying the same processed instant is idempotent, but cannot extend
    // R: CPU/MMIO activity inside the existing grant may have staged DMA/GPU
    // work that only a new explicit boundary is allowed to close.
    if (!finishingBlockingMMIO && ExternalTimeWindowHaveFrontier_ &&
        target == ExternalTimeWindowLastProcessed_)
    {
        if (finiteBound != ExternalTimeWindowLastRunSafe_)
            return reject(ExternalTimeWindowResult::BoundarySkipped);

        out.ProcessedThrough = target;
        out.RunSafeThrough = ExternalTimeWindowLastRunSafe_;
        out.LastEventSequence = ExternalTimeWindowEventSequence_;
        return ExternalTimeWindowResult::Success;
    }

    const u32 ifBefore[2] = {IF[0], IF[1]};
    const u32 ieBefore[2] = {
        finishingBlockingMMIO ? ExternalBlockingMMIOIEAfterAccess_[0]
                              : IE[0],
        finishingBlockingMMIO ? ExternalBlockingMMIOIEAfterAccess_[1]
                              : IE[1]};
    const u32 imeBefore[2] = {
        finishingBlockingMMIO ? ExternalBlockingMMIOIMEAfterAccess_[0]
                              : IME[0],
        finishingBlockingMMIO ? ExternalBlockingMMIOIMEAfterAccess_[1]
                              : IME[1]};
    const u32 if2Before = finishingBlockingMMIO
        ? ExternalBlockingMMIOIF2AfterAccess_ : IF2;
    const u32 ie2Before = finishingBlockingMMIO
        ? ExternalBlockingMMIOIE2AfterAccess_ : IE2;
    const u32 nonDmaStopBefore = finishingBlockingMMIO
        ? ExternalBlockingMMIONonDMAStopAfterAccess_
        : CPUStop & ~(CPUStop_DMA9 | CPUStop_DMA7);
    if (!finishingBlockingMMIO)
    {
        ExternalTimeWindowObservedIF_[0] = IF[0];
        ExternalTimeWindowObservedIF_[1] = IF[1];
        ExternalTimeWindowObserverFailed_ = false;
        ExternalTimeWindowClosureActive_ = true;
    }

    bool closed = false;
    bool dmaFailed = false;
    bool eventBeforeTarget = false;
    bool quiescentVerificationPass = false;
    constexpr unsigned kClosurePassLimit = 64;
    for (unsigned pass = 0; pass < kClosurePassLimit; ++pass)
    {
        if (earliestScheduledEvent() < target)
        {
            eventBeforeTarget = true;
            break;
        }
        // RunSystem snapshots SchedListMask.  A callback can schedule an
        // earlier event ID at this same timestamp, so rescan until no due
        // event remains instead of assuming one pass establishes closure.
        RunSystem(target);
        GPU.GPU3D.Run();

        const bool dma9Closed = CompleteExternalDMA(0);
        const bool dma7Closed = CompleteExternalDMA(1);
        dmaFailed = !dma9Closed || !dma7Closed;

        // AdvanceExternalCPU restarts the raster scheduler as soon as
        // FinishFrame publishes TotalScanlines. ETW replaces that legacy
        // path, so carry the same transition inside the causal closure. If
        // this is omitted, the first frame finishes and Event_LCD silently
        // disappears forever while unrelated events (notably RTC) continue.
        if (!ExternalLCDRendererEnabled_ && GPU.TotalScanlines != 0)
            GPU.StartFrame();

        bool due = false;
        u32 mask = SchedListMask;
        for (u32 id = 0; id < Event_MAX && mask; ++id, mask >>= 1)
        {
            if ((mask & 1u) && SchedList[id].Timestamp <= target)
            {
                due = true;
                break;
            }
        }
        if (!due &&
            (CPUStop & (CPUStop_DMA9 | CPUStop_DMA7)) == 0)
        {
            if (quiescentVerificationPass)
            {
                closed = true;
                dmaFailed = false;
                break;
            }
            // DMA can enqueue GX work after the GPU pass above.  Require one
            // full additional scheduler/GPU/DMA pass before declaring the
            // closure a fixed point.
            quiescentVerificationPass = true;
        }
        else
        {
            quiescentVerificationPass = false;
        }
    }
    ExternalTimeWindowClosureActive_ = false;

    if (eventBeforeTarget)
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::EventBeforeClosureTarget;
    }

    if (!closed)
    {
        ExternalTimeWindowFaulted_ = true;
        return dmaFailed ? ExternalTimeWindowResult::DMAClosureFailed
                         : ExternalTimeWindowResult::ClosureDidNotConverge;
    }
    if (ExternalTimeWindowEventSequence_ ==
        std::numeric_limits<u32>::max())
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::EventSequenceExhausted;
    }
    // Every IF mutation in melonDS now funnels through SetIRQ/ClearIRQMask.
    // Replaying the emitted ordered operations must reproduce both banks.
    if (ExternalTimeWindowObserverFailed_ ||
        ExternalTimeWindowObservedIF_[0] != IF[0] ||
        ExternalTimeWindowObservedIF_[1] != IF[1] ||
        IE[0] != ieBefore[0] || IE[1] != ieBefore[1] ||
        IME[0] != imeBefore[0] || IME[1] != imeBefore[1] ||
        IF2 != if2Before || IE2 != ie2Before ||
        (CPUStop & ~(CPUStop_DMA9 | CPUStop_DMA7)) != nonDmaStopBefore)
    {
        (void)ifBefore;
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::UnrepresentableSideEffect;
    }
    // Find the real next scheduler event.  NextTarget() is intentionally not
    // used: it clamps to SysTimestamp+64 and cannot prove a causal horizon.
    u32 earliestEventID = Event_MAX;
    const u64 earliest = earliestScheduledEvent(&earliestEventID);
    if (earliest <= target)
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::ClosureDidNotConverge;
    }
    if (ExternalTimeWindowHaveFrontier_ &&
        earliest <= ExternalTimeWindowLastRunSafe_)
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::LateEvent;
    }

    u64 runSafe = finiteBound;
    if (earliest != std::numeric_limits<u64>::max())
    {
        // earliest > target, therefore earliest is nonzero and E-1 cannot
        // underflow.  The frontier is inclusive.
        const u64 beforeEarliest = earliest - 1;
        if (beforeEarliest < runSafe) runSafe = beforeEarliest;
    }
    if (runSafe < target)
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::FrontierRegressed;
    }
    ++ExternalTimeWindowProfile_.ClosureCount;
    const u64 grantedCycles = runSafe - target + 1;
    if (earliest == std::numeric_limits<u64>::max())
    {
        ++ExternalTimeWindowProfile_.NoEventCount;
        ++ExternalTimeWindowProfile_.FiniteBoundLimitedCount;
    }
    else if (earliest - 1 <= finiteBound)
    {
        ++ExternalTimeWindowProfile_.LimitingEventCount[earliestEventID];
        ExternalTimeWindowProfile_.GrantedCycles[earliestEventID] +=
            grantedCycles;
    }
    else
    {
        ++ExternalTimeWindowProfile_.FiniteBoundLimitedCount;
    }
    if (!ExternalTimeWindowHaveFrontier_ &&
        (ExternalTimeWindowCPUReached_[0] > runSafe ||
         ExternalTimeWindowCPUReached_[1] > runSafe))
    {
        // Enabling after a CPU already crossed an undispatched event cannot
        // retroactively make that execution causal.
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::CPUProgressBeyondRunSafe;
    }

    out.ProcessedThrough = target;
    out.RunSafeThrough = runSafe;
    out.LastEventSequence = ExternalTimeWindowEventSequence_;
    ExternalTimeWindowHaveFrontier_ = true;
    ExternalTimeWindowLastProcessed_ = target;
    ExternalTimeWindowLastRunSafe_ = runSafe;
    if (finishingBlockingMMIO)
    {
        ExternalBlockingMMIOBarrierActive_ = false;
        ExternalBlockingMMIOAccessClaimed_ = false;
        ExternalBlockingMMIOAccessComplete_ = false;
        ExternalBlockingMMIOBarrierTimestamp_ = 0;
        ExternalBlockingMMIORequest_ = {};
    }
    return ExternalTimeWindowResult::Success;
#endif
}

ExternalTimeWindowResult NDS::CloseAndQueryExternalTimeWindow(
    u64 finiteBound, u64 fpgaAuthoritativeEventMask,
    ExternalTimeWindow& out) noexcept
{
    return AdvanceAndCloseExternalTimeWindow(
        SysTimestamp, finiteBound, fpgaAuthoritativeEventMask, out);
}

ExternalTimeWindowResult NDS::AdvanceAndCloseExternalTimeWindowVerified(
    u64 closeThrough, u64 finiteBound,
    u64 fpgaAuthoritativeEventMask,
    const ExternalTimeWindowReplacement& replacement,
    ExternalTimeWindow& out) noexcept
{
    out = {};
#if !NDS4MISTER_EXTERNAL_TIME_WINDOW
    (void)closeThrough;
    (void)finiteBound;
    (void)fpgaAuthoritativeEventMask;
    (void)replacement;
    return ExternalTimeWindowResult::CapabilityDisabled;
#else
    if (ExternalTimeWindowFaulted_)
        return ExternalTimeWindowResult::ProtocolFaulted;
    if (!ExternalTimeWindowEnabled_)
        return ExternalTimeWindowResult::NotEnabled;

    const bool finishingBlockingMMIO =
        ExternalBlockingMMIOBarrierActive_;
    const auto reject = [&](ExternalTimeWindowResult result) noexcept {
        if (finishingBlockingMMIO)
            ExternalTimeWindowFaulted_ = true;
        return result;
    };
    if (replacement.Epoch == 0 || replacement.GrantSequence == 0)
        return reject(ExternalTimeWindowResult::InvalidExternalTimeWindowIdentity);

    if (!ExternalTimeWindowHaveVerifiedGrant_)
    {
        if (finishingBlockingMMIO || replacement.GrantSequence != 1 ||
            replacement.ReplacesGrantSequence != 0)
            return reject(ExternalTimeWindowResult::ExternalTimeWindowIdentityReplay);
    }
    else
    {
        if (replacement.Epoch != ExternalTimeWindowVerifiedEpoch_)
            return reject(ExternalTimeWindowResult::InvalidExternalTimeWindowIdentity);
        if (ExternalTimeWindowVerifiedGrantSequence_ ==
                std::numeric_limits<u32>::max() ||
            replacement.GrantSequence !=
                ExternalTimeWindowVerifiedGrantSequence_ + 1 ||
            replacement.ReplacesGrantSequence !=
                ExternalTimeWindowVerifiedGrantSequence_ ||
            replacement.VerifiedProducerFence <
                ExternalTimeWindowVerifiedProducerFence_)
            return reject(ExternalTimeWindowResult::ExternalTimeWindowIdentityReplay);
    }

    ExternalBlockingMMIORequest barrierRequest{};
    u64 completedBarrierTimestamp = 0;
    if (finishingBlockingMMIO)
    {
        barrierRequest = ExternalBlockingMMIORequest_;
        completedBarrierTimestamp = ExternalBlockingMMIOBarrierTimestamp_;
        if (!ExternalTimeWindowHaveVerifiedGrant_ ||
            replacement.Epoch != barrierRequest.Epoch ||
            replacement.ReplacesGrantSequence !=
                barrierRequest.ActiveGrantSequence ||
            replacement.VerifiedProducerFence !=
                barrierRequest.VerifiedProducerFence)
            return reject(
                ExternalTimeWindowResult::BlockingMMIOWindowIdentityMismatch);
    }

    ExternalTimeWindowVerifiedCloseActive_ = true;
    const ExternalTimeWindowResult result =
        AdvanceAndCloseExternalTimeWindow(
            closeThrough, finiteBound, fpgaAuthoritativeEventMask, out);
    ExternalTimeWindowVerifiedCloseActive_ = false;
    if (result != ExternalTimeWindowResult::Success)
        return result;

    ExternalTimeWindowHaveVerifiedGrant_ = true;
    ExternalTimeWindowVerifiedEpoch_ = replacement.Epoch;
    ExternalTimeWindowVerifiedGrantSequence_ = replacement.GrantSequence;
    ExternalTimeWindowVerifiedProducerFence_ =
        replacement.VerifiedProducerFence;
    out.Epoch = replacement.Epoch;
    out.GrantSequence = replacement.GrantSequence;
    out.ReplacesGrantSequence = replacement.ReplacesGrantSequence;
    out.VerifiedProducerFence = replacement.VerifiedProducerFence;
    out.ReplacesBlockingMMIO = finishingBlockingMMIO;
    if (finishingBlockingMMIO)
    {
        out.BarrierSourceSequence = barrierRequest.SourceSequence;
        out.BarrierSequence = barrierRequest.BarrierSequence;
        out.BarrierTimestamp = completedBarrierTimestamp;
    }
    return ExternalTimeWindowResult::Success;
#endif
}

ExternalTimeWindowResult NDS::CloseAndQueryExternalTimeWindowVerified(
    u64 finiteBound, u64 fpgaAuthoritativeEventMask,
    const ExternalTimeWindowReplacement& replacement,
    ExternalTimeWindow& out) noexcept
{
    return AdvanceAndCloseExternalTimeWindowVerified(
        SysTimestamp, finiteBound, fpgaAuthoritativeEventMask,
        replacement, out);
}

ExternalTimeWindowResult NDS::BeginExternalBlockingMMIOBarrier(
    const ExternalBlockingMMIORequest& request,
    u64& barrierTimestamp) noexcept
{
    barrierTimestamp = 0;
#if !NDS4MISTER_EXTERNAL_TIME_WINDOW
    (void)request;
    return ExternalTimeWindowResult::CapabilityDisabled;
#else
    if (ExternalTimeWindowFaulted_)
        return ExternalTimeWindowResult::ProtocolFaulted;
    if (!ExternalTimeWindowEnabled_)
        return ExternalTimeWindowResult::NotEnabled;
    if (!ExternalTimeWindowHaveFrontier_ ||
        !ExternalTimeWindowHaveVerifiedGrant_)
        return ExternalTimeWindowResult::NoActiveGrant;
    if (ExternalTimeWindowClosureActive_ ||
        ExternalARM9IFW1CActive_ || ExternalBlockingMMIOBarrierActive_ ||
        ExternalTimeWindowObserverFailed_ ||
        SysTimestamp != ExternalTimeWindowLastProcessed_ ||
        (ARM9Timestamp >> ARM9ClockShift) !=
            ExternalTimeWindowCPUReached_[0] ||
        ARM7Timestamp != ExternalTimeWindowCPUReached_[1])
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::BlockingMMIOBarrierStateMismatch;
    }

    // Barrier identities are exact and nonwrapping. Source sequence gaps are
    // legal because the source stream also carries nonbarrier operations;
    // barrier sequence gaps are not, since a skipped global stop could hide a
    // blocking access that changed HPS model state.
    if (request.Epoch == 0 || request.ActiveGrantSequence == 0 ||
        request.SourceSequence == 0 || request.BarrierSequence == 0)
        return ExternalTimeWindowResult::InvalidBlockingMMIOBarrierIdentity;
    if (request.CPU > 1 || request.Access > 2 ||
        request.ExecutionPC == std::numeric_limits<u32>::max() ||
        (!request.Write && request.WriteData != 0))
        return ExternalTimeWindowResult::InvalidBlockingMMIORequest;
    if (request.Epoch != ExternalTimeWindowVerifiedEpoch_ ||
        request.ActiveGrantSequence !=
            ExternalTimeWindowVerifiedGrantSequence_ ||
        request.ActiveProcessedThrough !=
            ExternalTimeWindowLastProcessed_ ||
        request.ActiveRunSafeThrough != ExternalTimeWindowLastRunSafe_ ||
        request.ActiveEventSequence != ExternalTimeWindowEventSequence_ ||
        request.VerifiedProducerFence !=
            ExternalTimeWindowVerifiedProducerFence_ ||
        request.VerifiedProducerFence < request.SourceSequence)
        return ExternalTimeWindowResult::BlockingMMIOWindowIdentityMismatch;
    if (!ExternalBlockingMMIOHaveIdentity_)
    {
        if (request.BarrierSequence != 1)
            return ExternalTimeWindowResult::BlockingMMIOBarrierReplay;
    }
    else
    {
        if (request.Epoch != ExternalBlockingMMIOEpoch_)
            return ExternalTimeWindowResult::InvalidBlockingMMIOBarrierIdentity;
        if (request.SourceSequence <=
                ExternalBlockingMMIOLastSourceSequence_ ||
            ExternalBlockingMMIOLastBarrierSequence_ ==
                std::numeric_limits<u32>::max() ||
            request.BarrierSequence !=
                ExternalBlockingMMIOLastBarrierSequence_ + 1)
            return ExternalTimeWindowResult::BlockingMMIOBarrierReplay;
    }
    if (ExternalTimeWindowHaveSourceSequence_ &&
        request.SourceSequence <= ExternalTimeWindowLastSourceSequence_)
        return ExternalTimeWindowResult::BlockingMMIOBarrierReplay;

    if (request.ARM9NormalizedTimestamp <
            ExternalTimeWindowCPUReached_[0] ||
        request.ARM7NormalizedTimestamp <
            ExternalTimeWindowCPUReached_[1])
        return ExternalTimeWindowResult::CPUProgressRegressed;
    if (request.ARM9NormalizedTimestamp >
            ExternalTimeWindowLastRunSafe_ ||
        request.ARM7NormalizedTimestamp >
            ExternalTimeWindowLastRunSafe_)
    {
        // The supplied values are the CPUs' already-effective times. Crossing
        // R is architectural uncertainty and cannot be repaired by retrying.
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::CPUProgressBeyondRunSafe;
    }
    const u64 maxNormalizedTimestamp =
        std::numeric_limits<u64>::max() >> ARM9ClockShift;
    if (request.ARM9NormalizedTimestamp > maxNormalizedTimestamp ||
        request.ARM7NormalizedTimestamp > maxNormalizedTimestamp)
        return ExternalTimeWindowResult::TimestampOverflow;

    const auto earliestScheduledEvent = [&]() noexcept {
        u64 earliest = std::numeric_limits<u64>::max();
        u32 mask = SchedListMask;
        for (u32 id = 0; id < Event_MAX && mask; ++id, mask >>= 1)
            if ((mask & 1u) && SchedList[id].Timestamp < earliest)
                earliest = SchedList[id].Timestamp;
        return earliest;
    };
    if (earliestScheduledEvent() <= ExternalTimeWindowLastRunSafe_)
    {
        // The grant promised no HPS-authoritative event through old R. A
        // newly discovered event in that interval invalidates the epoch.
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::LateEvent;
    }

    const u64 stoppedTimestamp = request.ARM9NormalizedTimestamp >
            request.ARM7NormalizedTimestamp
        ? request.ARM9NormalizedTimestamp
        : request.ARM7NormalizedTimestamp;
    const u64 barrier = ExternalTimeWindowLastProcessed_ > stoppedTimestamp
        ? ExternalTimeWindowLastProcessed_ : stoppedTimestamp;

    // Admission is the commit point. The lagging external CPU waits on its
    // bus request without retiring instructions until its effective time is
    // B=max(P,T9,T7). P may be one causal scheduler tick ahead of both
    // stopped CPUs; those events are already consumed, so rebasing to P is
    // safe. Truncating R before the ordinary closure makes B a legal exact
    // target inside the previously safe interval.
    ExternalTimeWindowCPUReached_[0] = barrier;
    ExternalTimeWindowCPUReached_[1] = barrier;
    ARM9Timestamp = barrier << ARM9ClockShift;
    ARM7Timestamp = barrier;
    ExternalTimeWindowLastRunSafe_ = barrier;

    ExternalTimeWindow closed;
    ExternalTimeWindowVerifiedCloseActive_ = true;
    const ExternalTimeWindowResult closeResult =
        AdvanceAndCloseExternalTimeWindow(barrier, barrier, 0, closed);
    ExternalTimeWindowVerifiedCloseActive_ = false;
    if (closeResult != ExternalTimeWindowResult::Success ||
        closed.ProcessedThrough != barrier ||
        closed.RunSafeThrough != barrier)
    {
        ExternalTimeWindowFaulted_ = true;
        return closeResult == ExternalTimeWindowResult::Success
            ? ExternalTimeWindowResult::BlockingMMIOBarrierStateMismatch
            : closeResult;
    }

    ExternalBlockingMMIOHaveIdentity_ = true;
    ExternalBlockingMMIOEpoch_ = request.Epoch;
    ExternalBlockingMMIOLastSourceSequence_ = request.SourceSequence;
    ExternalBlockingMMIOLastBarrierSequence_ = request.BarrierSequence;
    ExternalTimeWindowHaveSourceSequence_ = true;
    ExternalTimeWindowLastSourceSequence_ = request.SourceSequence;
    ExternalBlockingMMIOBarrierTimestamp_ = barrier;
    ExternalBlockingMMIORequest_ = request;
    ExternalBlockingMMIOBarrierActive_ = true;
    ExternalBlockingMMIOAccessClaimed_ = false;
    ExternalBlockingMMIOAccessComplete_ = false;
    ExternalTimeWindowObservedIF_[0] = IF[0];
    ExternalTimeWindowObservedIF_[1] = IF[1];
    ExternalTimeWindowObserverFailed_ = false;
    ExternalTimeWindowClosureActive_ = true;
    barrierTimestamp = barrier;
    return ExternalTimeWindowResult::Success;
#endif
}

ExternalTimeWindowResult NDS::ClaimExternalBlockingMMIOAccess(
    u32 cpu, bool write, u32 access, u32 address,
    u32 writeData, u32 executionPC) noexcept
{
#if !NDS4MISTER_EXTERNAL_TIME_WINDOW
    (void)cpu;
    (void)write;
    (void)access;
    (void)address;
    (void)writeData;
    (void)executionPC;
    return ExternalTimeWindowResult::CapabilityDisabled;
#else
    if (ExternalTimeWindowFaulted_)
        return ExternalTimeWindowResult::ProtocolFaulted;
    if (!ExternalTimeWindowEnabled_)
        return ExternalTimeWindowResult::NotEnabled;
    if (!ExternalBlockingMMIOBarrierActive_ ||
        !ExternalTimeWindowClosureActive_ ||
        SysTimestamp != ExternalBlockingMMIOBarrierTimestamp_)
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::BlockingMMIOBarrierStateMismatch;
    }
    if (ExternalBlockingMMIOAccessClaimed_)
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::BlockingMMIOAccessAlreadyClaimed;
    }
    const ExternalBlockingMMIORequest& expected =
        ExternalBlockingMMIORequest_;
    if (cpu != expected.CPU || write != expected.Write ||
        access != expected.Access || address != expected.Address ||
        writeData != expected.WriteData ||
        executionPC != expected.ExecutionPC)
    {
        // Admission already rebased both CPU clocks and truncated the active
        // grant. Executing any request other than the immutable descriptor is
        // therefore an epoch-fatal protocol violation, not a retryable miss.
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::BlockingMMIOAccessDescriptorMismatch;
    }
    ExternalBlockingMMIOAccessClaimed_ = true;
    ExternalBlockingMMIOAccessComplete_ = false;
    return ExternalTimeWindowResult::Success;
#endif
}

ExternalTimeWindowResult NDS::FinishExternalBlockingMMIOAccess(
    bool accessSucceeded) noexcept
{
#if !NDS4MISTER_EXTERNAL_TIME_WINDOW
    (void)accessSucceeded;
    return ExternalTimeWindowResult::CapabilityDisabled;
#else
    if (ExternalTimeWindowFaulted_)
        return ExternalTimeWindowResult::ProtocolFaulted;
    if (!ExternalTimeWindowEnabled_)
        return ExternalTimeWindowResult::NotEnabled;
    if (!ExternalBlockingMMIOBarrierActive_ ||
        !ExternalTimeWindowClosureActive_ ||
        !ExternalBlockingMMIOAccessClaimed_ ||
        ExternalBlockingMMIOAccessComplete_ ||
        SysTimestamp != ExternalBlockingMMIOBarrierTimestamp_)
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::BlockingMMIOBarrierStateMismatch;
    }
    if (!accessSucceeded || ExternalTimeWindowObserverFailed_)
    {
        ExternalTimeWindowFaulted_ = true;
        return ExternalTimeWindowResult::BlockingMMIOAccessFailed;
    }

    // Intentional state changes made by the one HPS MMIO are the new closure
    // baseline. Only additional scheduler/DMA work performed by final Close
    // must preserve these non-IRQ registers. IF remains checked against the
    // ordered transition observer that was active before the access began.
    ExternalBlockingMMIOIEAfterAccess_[0] = IE[0];
    ExternalBlockingMMIOIEAfterAccess_[1] = IE[1];
    ExternalBlockingMMIOIMEAfterAccess_[0] = IME[0];
    ExternalBlockingMMIOIMEAfterAccess_[1] = IME[1];
    ExternalBlockingMMIOIF2AfterAccess_ = IF2;
    ExternalBlockingMMIOIE2AfterAccess_ = IE2;
    ExternalBlockingMMIONonDMAStopAfterAccess_ =
        CPUStop & ~(CPUStop_DMA9 | CPUStop_DMA7);
    ExternalBlockingMMIOAccessComplete_ = true;
    return ExternalTimeWindowResult::Success;
#endif
}

ExternalTimeWindowResult NDS::ApplyExternalARM9IFW1C(
    u32 sourceSequence, u64 normalizedTimestamp,
    u32 address, u32 access, u32 writeData,
    u32 expectedFinalIF, bool expectedGXFIFOAsserted,
    ExternalARM9IFW1CResult& out) noexcept
{
    out = {};
#if !NDS4MISTER_EXTERNAL_TIME_WINDOW
    (void)sourceSequence;
    (void)normalizedTimestamp;
    (void)address;
    (void)access;
    (void)writeData;
    (void)expectedFinalIF;
    (void)expectedGXFIFOAsserted;
    return ExternalTimeWindowResult::CapabilityDisabled;
#else
    if (ExternalTimeWindowFaulted_)
        return ExternalTimeWindowResult::ProtocolFaulted;
    if (!ExternalTimeWindowEnabled_)
        return ExternalTimeWindowResult::NotEnabled;

    const auto fail = [&](ExternalTimeWindowResult result) noexcept {
        ExternalARM9IFW1CActive_ = false;
        ExternalARM9IFW1CFailed_ = true;
        ExternalTimeWindowFaulted_ = true;
        return result;
    };

    // This is a commit mirror, not another source of architectural time.  A
    // caller must first publish a real P/R grant and report the exact ARM9
    // commit timestamp reached inside it.  Reentrant use from a closure would
    // make the CPU write indistinguishable from scheduler-owned side effects.
    if (ExternalTimeWindowClosureActive_ ||
        ExternalARM9IFW1CActive_ ||
        ExternalTimeWindowObserverFailed_ ||
        !ExternalTimeWindowHaveFrontier_ ||
        normalizedTimestamp < ExternalTimeWindowLastProcessed_ ||
        normalizedTimestamp > ExternalTimeWindowLastRunSafe_ ||
        normalizedTimestamp != ExternalTimeWindowCPUReached_[0] ||
        (ARM9Timestamp >> ARM9ClockShift) != normalizedTimestamp)
        return fail(ExternalTimeWindowResult::ExternalIFWriteStateMismatch);

    // The seam intentionally cannot be generalized by its caller.  Any
    // subword/unaligned/other-register request poisons the active epoch rather
    // than silently acquiring posted-MMIO semantics it has not proved.
    if (sourceSequence == 0 || address != 0x04000214u || access != 2u)
        return fail(ExternalTimeWindowResult::InvalidExternalIFWrite);
    if ((ExternalTimeWindowHaveSourceSequence_ &&
         sourceSequence <= ExternalTimeWindowLastSourceSequence_) ||
        (ExternalARM9IFW1CHaveLast_ &&
         normalizedTimestamp < ExternalARM9IFW1CLastTimestamp_))
        return fail(ExternalTimeWindowResult::ExternalIFWriteReplay);

    constexpr u32 gxFIFOIRQMask = 1u << IRQ_GXFIFO;
    if (((expectedFinalIF & gxFIFOIRQMask) != 0) !=
        expectedGXFIFOAsserted)
        return fail(ExternalTimeWindowResult::ExternalIFWriteStateMismatch);

    u32 predictedFinalIF = IF[0] & ~writeData;
    if (expectedGXFIFOAsserted)
        predictedFinalIF |= gxFIFOIRQMask;
    else
        predictedFinalIF &= ~gxFIFOIRQMask;
    if (predictedFinalIF != expectedFinalIF)
        return fail(ExternalTimeWindowResult::ExternalIFWriteStateMismatch);

    // Validate the exact two model operations performed by the real ARM9
    // word handler: the requested W1C (unless its mask is zero), followed by
    // CheckFIFOIRQ's unconditional Set/Clear of bit 21.  RecordExternal...
    // consumes these transitions locally while this scope is active.
    ExternalARM9IFW1CActive_ = true;
    ExternalARM9IFW1CFailed_ = false;
    ExternalARM9IFW1CExpectedClearMask_ = writeData;
    ExternalARM9IFW1CExpectedGXFIFOSet_ = expectedGXFIFOAsserted;
    ExternalARM9IFW1CPhase_ = 0;
    ExternalARM9IFW1CExpectedPhases_ = writeData != 0 ? 2 : 1;

    ClearIRQMask(0, writeData);
    GPU.GPU3D.CheckFIFOIRQ();

    ExternalARM9IFW1CActive_ = false;
    if (ExternalARM9IFW1CFailed_ ||
        ExternalARM9IFW1CPhase_ != ExternalARM9IFW1CExpectedPhases_ ||
        IF[0] != expectedFinalIF ||
        (((IF[0] & gxFIFOIRQMask) != 0) != expectedGXFIFOAsserted))
        return fail(ExternalTimeWindowResult::ExternalIFWriteFailed);

    ExternalARM9IFW1CHaveLast_ = true;
    ExternalARM9IFW1CLastSourceSequence_ = sourceSequence;
    ExternalARM9IFW1CLastTimestamp_ = normalizedTimestamp;
    ExternalTimeWindowHaveSourceSequence_ = true;
    ExternalTimeWindowLastSourceSequence_ = sourceSequence;
    out.FinalIF = IF[0];
    out.GXFIFOAsserted = (IF[0] & gxFIFOIRQMask) != 0;
    return ExternalTimeWindowResult::Success;
#endif
}

bool NDS::SelfTestExternalTimeWindow()
{
#if !NDS4MISTER_EXTERNAL_TIME_WINDOW
    return false;
#else
    struct Collector
    {
        ExternalIRQTransition Events[16] {};
        unsigned Count = 0;
        bool Accept = true;
    };
    const auto sink = +[](const ExternalIRQTransition& transition,
                          void* userdata) noexcept -> bool {
        auto& collector = *static_cast<Collector*>(userdata);
        if (!collector.Accept || collector.Count >= 16) return false;
        collector.Events[collector.Count++] = transition;
        return true;
    };
    struct EqualTimestampProbe
    {
        NDS* System = nullptr;
        unsigned First = 0;
        unsigned Second = 0;
    };
    const auto equalFirst = +[](void* userdata, u32) {
        auto& probe = *static_cast<EqualTimestampProbe*>(userdata);
        ++probe.First;
        probe.System->SetIRQ(0, IRQ_VBlank);
        // The current event bit was cleared before this callback.  Scheduling
        // the same (earlier-scanned) ID at zero delay proves the closure loop
        // really rescans equal-timestamp work.
        probe.System->ScheduleEvent(Event_RTC, false, 0, 1, 0);
    };
    const auto equalSecond = +[](void* userdata, u32) {
        auto& probe = *static_cast<EqualTimestampProbe*>(userdata);
        ++probe.Second;
        probe.System->ClearIRQ(0, IRQ_VBlank);
    };
    const auto setOnly = +[](void* userdata, u32) {
        static_cast<NDS*>(userdata)->SetIRQ(1, IRQ_Timer0);
    };
    const auto noOp = +[](void*, u32) {};
    const auto countOnly = +[](void* userdata, u32) {
        ++*static_cast<unsigned*>(userdata);
    };

    auto ndsStorage = std::make_unique<NDS>();
    NDS& nds = *ndsStorage;
    auto alignedMainRAM = std::make_unique<u32[]>(0x00400000u / sizeof(u32));
    struct MainRAMRestore
    {
        NDS& System;
        u8* Original;
        ~MainRAMRestore() { System.MainRAM = Original; }
    } mainRAMRestore{nds, nds.MainRAM};
    nds.MainRAM = reinterpret_cast<u8*>(alignedMainRAM.get());
    nds.MainRAMMask = 0x003fffffu;
    Collector collector;
    nds.SetExternalIRQTransitionSink(sink, &collector);
    ExternalTimeWindow window;

    // A local-LCD epoch must never start or restart melonDS's LCD scheduler.
    // Apply a frame-wrap descriptor, close ETW, and prove both LCD event
    // sources remain absent. FPGA alone owns cadence, IRQ, and DMA here.
    nds.Reset();
    if (!nds.SetExternalLCDRendererEnabled(true) ||
        !nds.SetExternalTimeWindowEnabled(true) ||
        !nds.ApplyExternalLCDRendererPhase(
            2, 0, 0, 0, 0, 1, false, false) ||
        (nds.SchedListMask &
            ((1u << Event_LCD) | (1u << Event_DisplayFIFO))) ||
        nds.CloseAndQueryExternalTimeWindow(10000, 0, window) !=
            ExternalTimeWindowResult::Success ||
        (nds.SchedListMask &
            ((1u << Event_LCD) | (1u << Event_DisplayFIFO))))
        return false;

    // Output decimation may omit pixel drawing, but it must not omit the
    // architectural 3D VBlank that commits SWAP_BUFFERS and advances the
    // two-bank polygon RAM. Otherwise a later retained frame renders an old
    // bank (or no polygons at all) while replay continues into the wrong one.
    const auto initial3DBank = nds.GPU.GPU3D.CurRAMBank;
    nds.GPU.GPU3D.FlushRequest = 1;
    if (!nds.ApplyExternalLCDRendererPhase(
            0, 192, 192, 1, 1, 1, false, false) ||
        nds.GPU.GPU3D.FlushRequest != 0 ||
        nds.GPU.GPU3D.CurRAMBank == initial3DBank)
        return false;

    // Runtime opt-in is false even in a capable test build.
    nds.Reset();
    if (nds.CloseAndQueryExternalTimeWindow(1, 0, window) !=
            ExternalTimeWindowResult::NotEnabled)
        return false;

    // ETW is the production replacement for AdvanceExternalCPU, whose first
    // call historically bootstrapped GPU.StartFrame. Prove enabling a fresh
    // epoch now schedules LCD work exactly once instead of leaving only RTC.
    nds.Reset();
    if (nds.ExternalSchedulerStarted ||
        !nds.SetExternalTimeWindowEnabled(true) ||
        !nds.ExternalSchedulerStarted ||
        !(nds.SchedListMask & (1u << Event_LCD)))
        return false;
    // Model FinishFrame's publication marker at the current causal instant.
    // Closing it must immediately start the next frame and leave LCD work
    // scheduled; otherwise hardware publishes exactly one frame and stalls.
    nds.GPU.TotalScanlines = 263;
    if (nds.CloseAndQueryExternalTimeWindow(10000, 0, window) !=
            ExternalTimeWindowResult::Success ||
        nds.GPU.TotalScanlines != 0 ||
        !(nds.SchedListMask & (1u << Event_LCD)) ||
        nds.SchedList[Event_LCD].Timestamp <= nds.SysTimestamp)
        return false;

    const auto prepare = [&](u64 timestamp) {
        nds.SetExternalTimeWindowEnabled(false);
        nds.Reset();
        collector = {};
        nds.SetExternalIRQTransitionSink(sink, &collector);
        nds.SchedListMask = 0;
        nds.SysTimestamp = timestamp;
        nds.ARM9Timestamp = timestamp << nds.ARM9ClockShift;
        nds.ARM7Timestamp = timestamp;
        nds.ARM9Target = nds.ARM9Timestamp;
        nds.ARM7Target = nds.ARM7Timestamp;
        nds.CPUStop = 0;
        nds.IF[0] = nds.IF[1] = 0;
        nds.IE[0] = nds.IE[1] = 0;
        nds.IME[0] = nds.IME[1] = 0;
        nds.IF2 = nds.IE2 = 0;
        // The remaining cases install synthetic event sets. Suppress the
        // production bootstrap so each case stays isolated from real LCD.
        nds.ExternalSchedulerStarted = true;
        return nds.SetExternalTimeWindowEnabled(true);
    };
    const auto install = [&](u32 id, u64 timestamp, u32 funcId,
                             void* userdata,
                             std::initializer_list<EventFunc> funcs) {
        nds.RegisterEventFuncs(id, userdata, funcs);
        nds.SchedList[id].Timestamp = timestamp;
        nds.SchedList[id].FuncID = funcId;
        nds.SchedList[id].Param = 0;
        nds.SchedListMask |= 1u << id;
    };

    // With no pending event, the finite caller cap is the run horizon.
    if (!prepare(10) ||
        nds.CloseAndQueryExternalTimeWindow(20, 0, window) !=
            ExternalTimeWindowResult::Success ||
        window.ProcessedThrough != 10 || window.RunSafeThrough != 20 ||
        window.LastEventSequence != 0 ||
        nds.GetExternalTimeWindowProfile().ClosureCount != 1 ||
        nds.GetExternalTimeWindowProfile().FiniteBoundLimitedCount != 1 ||
        nds.GetExternalTimeWindowProfile().NoEventCount != 1)
        return false;
    ExternalTimeWindow rejected{1, 2, 3};
    if (nds.CloseAndQueryExternalTimeWindow(20, 1, rejected) !=
            ExternalTimeWindowResult::UnsupportedAuthoritativeEventMask ||
        rejected.ProcessedThrough != 0 || rejected.RunSafeThrough != 0 ||
        rejected.LastEventSequence != 0)
        return false;

    // A raw future event E creates an inclusive E-1 horizon.  The scheduler
    // remains processed only through the current causal target.
    if (!prepare(10)) return false;
    install(Event_RTC, 15, 0, nullptr, {noOp});
    if (nds.CloseAndQueryExternalTimeWindow(30, 0, window) !=
            ExternalTimeWindowResult::Success ||
        window.ProcessedThrough != 10 || window.RunSafeThrough != 14 ||
        nds.GetExternalTimeWindowProfile().ClosureCount != 1 ||
        nds.GetExternalTimeWindowProfile().LimitingEventCount[Event_RTC] != 1 ||
        nds.GetExternalTimeWindowProfile().GrantedCycles[Event_RTC] != 5)
        return false;
    if (!prepare(10)) return false;
    install(Event_RTC, 15, 0, nullptr, {noOp});
    if (nds.CloseAndQueryExternalTimeWindow(12, 0, window) !=
            ExternalTimeWindowResult::Success ||
        window.ProcessedThrough != 10 || window.RunSafeThrough != 12 ||
        nds.GetExternalTimeWindowProfile().FiniteBoundLimitedCount != 1 ||
        nds.GetExternalTimeWindowProfile().LimitingEventCount[Event_RTC] != 0)
        return false;

    // Successive windows cannot jump over their inclusive grant.  CPUs report
    // progress to R without running timers or callbacks; Close itself then
    // owns the exact R+1 event edge and records its IRQ in that transaction.
    if (!prepare(0)) return false;
    install(Event_RTC, 100, 0, &nds, {setOnly});
    if (nds.CloseAndQueryExternalTimeWindow(200, 0, window) !=
            ExternalTimeWindowResult::Success ||
        window.ProcessedThrough != 0 || window.RunSafeThrough != 99 ||
        collector.Count != 0 || nds.SysTimestamp != 0)
        return false;
    if (nds.ReportExternalTimeWindowCPUReached(0, 99) !=
            ExternalTimeWindowResult::Success ||
        nds.ReportExternalTimeWindowCPUReached(1, 99) !=
            ExternalTimeWindowResult::Success)
        return false;
    ExternalTimeWindow skipped{1, 2, 3};
    if (nds.AdvanceAndCloseExternalTimeWindow(1000, 1000, 0, skipped) !=
            ExternalTimeWindowResult::BoundarySkipped ||
        skipped.ProcessedThrough != 0 || skipped.RunSafeThrough != 0 ||
        skipped.LastEventSequence != 0 || collector.Count != 0 ||
        nds.SysTimestamp != 0)
        return false;
    if (nds.AdvanceAndCloseExternalTimeWindow(100, 200, 0, window) !=
            ExternalTimeWindowResult::Success ||
        window.ProcessedThrough != 100 || window.RunSafeThrough != 200 ||
        window.LastEventSequence != 1 || collector.Count != 1 ||
        collector.Events[0].Sequence != 1 ||
        collector.Events[0].Timestamp != 100 ||
        collector.Events[0].CPU != 1 || !collector.Events[0].Set ||
        collector.Events[0].Mask != (1u << IRQ_Timer0) ||
        nds.IF[1] != (1u << IRQ_Timer0))
        return false;

    // The legacy per-CPU helper used to run timers/scheduler callbacks before
    // a close had activated its observer. It is now rejected without moving
    // CPU or scheduler time, and the epoch becomes terminal.
    if (!prepare(0) ||
        nds.CloseAndQueryExternalTimeWindow(10, 0, window) !=
            ExternalTimeWindowResult::Success)
        return false;
    const u64 arm9BeforeLegacyAdvance = nds.ARM9Timestamp;
    if (nds.AdvanceExternalCPU(0, 1) != 0 || nds.SysTimestamp != 0 ||
        nds.ARM9Timestamp != arm9BeforeLegacyAdvance ||
        nds.AdvanceAndCloseExternalTimeWindow(1, 10, 0, rejected) !=
            ExternalTimeWindowResult::ProtocolFaulted)
        return false;

    // RunSystem snapshots its mask.  Prove a callback that reschedules the
    // same ID at T is also consumed, and that set/clear retain exact order and
    // one global sequence at the processed timestamp.
    if (!prepare(20)) return false;
    EqualTimestampProbe equal{&nds};
    install(Event_RTC, 20, 0, &equal, {equalFirst, equalSecond});
    if (nds.CloseAndQueryExternalTimeWindow(40, 0, window) !=
            ExternalTimeWindowResult::Success ||
        equal.First != 1 || equal.Second != 1 || collector.Count != 2 ||
        collector.Events[0].Sequence != 1 ||
        collector.Events[1].Sequence != 2 ||
        collector.Events[0].Timestamp != 20 ||
        collector.Events[1].Timestamp != 20 ||
        !collector.Events[0].Set || collector.Events[1].Set ||
        collector.Events[0].CPU != 0 || collector.Events[1].CPU != 0 ||
        collector.Events[0].Mask != (1u << IRQ_VBlank) ||
        collector.Events[1].Mask != (1u << IRQ_VBlank) ||
        window.ProcessedThrough != 20 || window.RunSafeThrough != 40 ||
        window.LastEventSequence != 2 || nds.IF[0] != 0)
        return false;

    // Both CPU DMA stop domains must reach a fixed point before publication.
    if (!prepare(30)) return false;
    auto* words = reinterpret_cast<u32*>(nds.MainRAM);
    for (u32 index = 0; index < 4; ++index)
    {
        words[(0x2000 / 4) + index] = 0x91000000u + index;
        words[(0x3000 / 4) + index] = 0;
        words[(0x4000 / 4) + index] = 0x71000000u + index;
        words[(0x5000 / 4) + index] = 0;
    }
    nds.CurCPU = 0;
    nds.ARM9Write32(0x040000b0, 0x02002000u);
    nds.ARM9Write32(0x040000b4, 0x02003000u);
    nds.ARM9Write32(0x040000b8, 0x84000004u);
    nds.CurCPU = 1;
    nds.ARM7Write32(0x040000b0, 0x02004000u);
    nds.ARM7Write32(0x040000b4, 0x02005000u);
    nds.ARM7Write32(0x040000b8, 0x84000004u);
    if ((nds.CPUStop & CPUStop_DMA9) == 0 ||
        (nds.CPUStop & CPUStop_DMA7) == 0 ||
        nds.CloseAndQueryExternalTimeWindow(35, 0, window) !=
            ExternalTimeWindowResult::Success ||
        (nds.CPUStop & (CPUStop_DMA9 | CPUStop_DMA7)) != 0)
        return false;
    for (u32 index = 0; index < 4; ++index)
        if (words[(0x3000 / 4) + index] != 0x91000000u + index ||
            words[(0x5000 / 4) + index] != 0x71000000u + index)
            return false;

    // A stop bit without a runnable DMA is never waved through.
    if (!prepare(40)) return false;
    nds.CPUStop = CPUStop_DMA9_0;
    if (nds.CloseAndQueryExternalTimeWindow(45, 0, window) !=
            ExternalTimeWindowResult::DMAClosureFailed)
        return false;

    // Bound, causality, wrap/sentinel and monotonic regressions all fail with
    // a zeroed output instead of manufacturing a horizon.
    if (!prepare(50)) return false;
    if (nds.CloseAndQueryExternalTimeWindow(49, 0, rejected) !=
            ExternalTimeWindowResult::BoundBeforeProcessed ||
        nds.CloseAndQueryExternalTimeWindow(
            std::numeric_limits<u64>::max(), 0, rejected) !=
            ExternalTimeWindowResult::InvalidFiniteBound)
        return false;
    if (!prepare(60)) return false;
    nds.ARM7Timestamp = 59;
    nds.ExternalTimeWindowCPUReached_[1] = 59;
    if (nds.CloseAndQueryExternalTimeWindow(70, 0, rejected) !=
            ExternalTimeWindowResult::CausalTargetNotReached)
        return false;
    if (!prepare(70) ||
        nds.CloseAndQueryExternalTimeWindow(80, 0, window) !=
            ExternalTimeWindowResult::Success)
        return false;
    if (nds.AdvanceAndCloseExternalTimeWindow(69, 80, 0, rejected) !=
            ExternalTimeWindowResult::FrontierRegressed)
        return false;

    // Once E-1 was granted, discovering a newly inserted event inside that
    // inclusive interval is epoch-fatal.
    if (!prepare(100)) return false;
    unsigned lateCallbackCount = 0;
    install(Event_RTC, 120, 0, &lateCallbackCount, {countOnly});
    if (nds.CloseAndQueryExternalTimeWindow(200, 0, window) !=
            ExternalTimeWindowResult::Success ||
        window.RunSafeThrough != 119)
        return false;
    if (nds.ReportExternalTimeWindowCPUReached(0, 119) !=
            ExternalTimeWindowResult::Success ||
        nds.ReportExternalTimeWindowCPUReached(1, 119) !=
            ExternalTimeWindowResult::Success)
        return false;
    nds.SchedList[Event_RTC].Timestamp = 110;
    if (nds.AdvanceAndCloseExternalTimeWindow(120, 200, 0, rejected) !=
            ExternalTimeWindowResult::LateEvent || lateCallbackCount != 0)
        return false;

    // On the first closure there is no prior grant to label an overdue event
    // "late", but it is still unsafe to execute at the current target and
    // stamp its IRQ effects with that later time.
    if (!prepare(200)) return false;
    unsigned overdueCallbackCount = 0;
    install(Event_RTC, 199, 0, &overdueCallbackCount, {countOnly});
    if (nds.CloseAndQueryExternalTimeWindow(210, 0, rejected) !=
            ExternalTimeWindowResult::EventBeforeClosureTarget ||
        overdueCallbackCount != 0)
        return false;

    // A successful published grant also commits the epoch identity. Runtime
    // disable must not silently discard P/R or restart the event sequence.
    if (!prepare(125) ||
        nds.CloseAndQueryExternalTimeWindow(129, 0, window) !=
            ExternalTimeWindowResult::Success ||
        nds.SetExternalTimeWindowEnabled(false) ||
        nds.SetExternalTimeWindowEnabled(true))
        return false;
    nds.Reset();
    nds.SetExternalIRQTransitionSink(sink, &collector);
    if (!nds.SetExternalTimeWindowEnabled(true))
        return false;
    nds.SetExternalTimeWindowEnabled(false);

    // Observer failure and sequence exhaustion are explicit terminal faults;
    // neither can yield a partially named window.
    if (!prepare(130)) return false;
    nds.SetExternalIRQTransitionSink(nullptr, nullptr);
    install(Event_RTC, 130, 0, &nds, {setOnly});
    if (nds.CloseAndQueryExternalTimeWindow(140, 0, rejected) !=
            ExternalTimeWindowResult::UnrepresentableSideEffect)
        return false;
    if (!nds.SetExternalTimeWindowEnabled(false) ||
        nds.SetExternalTimeWindowEnabled(true))
        return false;
    nds.Reset();
    nds.SetExternalIRQTransitionSink(sink, &collector);
    if (!nds.SetExternalTimeWindowEnabled(true))
        return false;
    nds.SetExternalTimeWindowEnabled(false);

    if (!prepare(150)) return false;
    nds.ExternalTimeWindowEventSequence_ =
        std::numeric_limits<u32>::max() - 1u;
    install(Event_RTC, 150, 0, &nds, {setOnly});
    if (nds.CloseAndQueryExternalTimeWindow(160, 0, rejected) !=
            ExternalTimeWindowResult::EventSequenceExhausted ||
        collector.Count != 1 ||
        collector.Events[0].Sequence != std::numeric_limits<u32>::max())
        return false;
    if (!nds.SetExternalTimeWindowEnabled(false) ||
        nds.SetExternalTimeWindowEnabled(true))
        return false;
    nds.Reset();
    nds.SetExternalIRQTransitionSink(sink, &collector);
    if (!nds.SetExternalTimeWindowEnabled(true))
        return false;

    // The FPGA-owned IF mirror remains inert until runtime opt-in, then
    // requires a published grant and exact reported ARM9 commit time.
    nds.SetExternalTimeWindowEnabled(false);
    nds.Reset();
    nds.SetExternalIRQTransitionSink(sink, &collector);
    nds.IF[0] = 1u << IRQ_VBlank;
    ExternalARM9IFW1CResult ifResult{0xffffffffu, true};
    if (nds.ApplyExternalARM9IFW1C(
            1, 0, 0x04000214u, 2, 1u << IRQ_VBlank,
            0, false, ifResult) != ExternalTimeWindowResult::NotEnabled ||
        nds.IF[0] != (1u << IRQ_VBlank) || ifResult.FinalIF != 0 ||
        ifResult.GXFIFOAsserted)
        return false;
    if (!nds.SetExternalTimeWindowEnabled(true) ||
        nds.ApplyExternalARM9IFW1C(
            1, 0, 0x04000214u, 2, 1u << IRQ_VBlank,
            0, false, ifResult) !=
            ExternalTimeWindowResult::ExternalIFWriteStateMismatch ||
        nds.ApplyExternalARM9IFW1C(
            2, 0, 0x04000214u, 2, 0, nds.IF[0], false, ifResult) !=
            ExternalTimeWindowResult::ProtocolFaulted)
        return false;

    // GXFIFO false: preserve an unrelated IF bit, consume exactly the word
    // W1C plus CheckFIFOIRQ clear, and emit no scheduler-owned ETW record.
    if (!prepare(200) ||
        nds.CloseAndQueryExternalTimeWindow(220, 0, window) !=
            ExternalTimeWindowResult::Success ||
        nds.ReportExternalTimeWindowCPUReached(0, 205) !=
            ExternalTimeWindowResult::Success)
        return false;
    constexpr u32 vblankMask = 1u << IRQ_VBlank;
    constexpr u32 timerMask = 1u << IRQ_Timer0;
    constexpr u32 gxFIFOIRQMask = 1u << IRQ_GXFIFO;
    nds.IF[0] = vblankMask | timerMask | gxFIFOIRQMask;
    nds.UpdateIRQ(0);
    nds.GPU.GPU3D.GXStat = 0;
    const unsigned falseCollectorCount = collector.Count;
    const u32 falseEventSequence = nds.ExternalTimeWindowEventSequence_;
    if (nds.ApplyExternalARM9IFW1C(
            10, 205, 0x04000214u, 2, vblankMask,
            timerMask, false, ifResult) !=
            ExternalTimeWindowResult::Success ||
        ifResult.FinalIF != timerMask || ifResult.GXFIFOAsserted ||
        nds.IF[0] != timerMask ||
        collector.Count != falseCollectorCount ||
        nds.ExternalTimeWindowEventSequence_ != falseEventSequence)
        return false;

    // GXFIFO true: sequence gaps are legal (the source stream can contain
    // other opcodes), but accepted source order is strictly increasing.  An
    // empty FIFO in mode 2 reasserts bit 21 after the W1C clears it.
    if (nds.ReportExternalTimeWindowCPUReached(0, 206) !=
            ExternalTimeWindowResult::Success)
        return false;
    nds.IF[0] = vblankMask | timerMask | gxFIFOIRQMask;
    nds.UpdateIRQ(0);
    nds.GPU.GPU3D.GXStat = 2u << 30;
    if (!nds.GPU.GPU3D.CmdFIFO.IsEmpty() ||
        nds.ApplyExternalARM9IFW1C(
            12, 206, 0x04000214u, 2,
            vblankMask | gxFIFOIRQMask,
            timerMask | gxFIFOIRQMask, true, ifResult) !=
            ExternalTimeWindowResult::Success ||
        ifResult.FinalIF != (timerMask | gxFIFOIRQMask) ||
        !ifResult.GXFIFOAsserted ||
        collector.Count != falseCollectorCount ||
        nds.ExternalTimeWindowEventSequence_ != falseEventSequence)
        return false;

    const u32 replayIF = nds.IF[0];
    if (nds.ApplyExternalARM9IFW1C(
            12, 206, 0x04000214u, 2, 0,
            replayIF, true, ifResult) !=
            ExternalTimeWindowResult::ExternalIFWriteReplay ||
        nds.IF[0] != replayIF || ifResult.FinalIF != 0 ||
        ifResult.GXFIFOAsserted ||
        nds.ApplyExternalARM9IFW1C(
            13, 206, 0x04000214u, 2, 0,
            replayIF, true, ifResult) !=
            ExternalTimeWindowResult::ProtocolFaulted ||
        !nds.SetExternalTimeWindowEnabled(false) ||
        nds.SetExternalTimeWindowEnabled(true))
        return false;

    // Reset is the sole recovery boundary and resets source ordering.  A
    // lower sequence after a newly accepted operation remains epoch-fatal.
    if (!prepare(230) ||
        nds.CloseAndQueryExternalTimeWindow(240, 0, window) !=
            ExternalTimeWindowResult::Success ||
        nds.ReportExternalTimeWindowCPUReached(0, 235) !=
            ExternalTimeWindowResult::Success)
        return false;
    nds.IF[0] = timerMask | gxFIFOIRQMask;
    nds.UpdateIRQ(0);
    nds.GPU.GPU3D.GXStat = 0;
    if (nds.ApplyExternalARM9IFW1C(
            12, 235, 0x04000214u, 2, gxFIFOIRQMask,
            timerMask, false, ifResult) !=
            ExternalTimeWindowResult::Success ||
        nds.ApplyExternalARM9IFW1C(
            11, 235, 0x04000214u, 2, 0,
            timerMask, false, ifResult) !=
            ExternalTimeWindowResult::ExternalIFWriteReplay)
        return false;

    // Caller/model disagreement about CheckFIFOIRQ is detected while running
    // the real side effect and poisons the epoch; Reset must recover it.
    if (!prepare(250) ||
        nds.CloseAndQueryExternalTimeWindow(260, 0, window) !=
            ExternalTimeWindowResult::Success ||
        nds.ReportExternalTimeWindowCPUReached(0, 255) !=
            ExternalTimeWindowResult::Success)
        return false;
    nds.IF[0] = vblankMask | gxFIFOIRQMask;
    nds.UpdateIRQ(0);
    nds.GPU.GPU3D.GXStat = 2u << 30;
    if (nds.ApplyExternalARM9IFW1C(
            20, 255, 0x04000214u, 2,
            vblankMask | gxFIFOIRQMask,
            0, false, ifResult) !=
            ExternalTimeWindowResult::ExternalIFWriteFailed ||
        nds.ApplyExternalARM9IFW1C(
            21, 255, 0x04000214u, 2, 0,
            gxFIFOIRQMask, true, ifResult) !=
            ExternalTimeWindowResult::ProtocolFaulted)
        return false;

    // Geometry and pre-apply final-state validation are also fail-closed and
    // must not mutate IF before the reset-required protocol fault.
    if (!prepare(270) ||
        nds.CloseAndQueryExternalTimeWindow(280, 0, window) !=
            ExternalTimeWindowResult::Success ||
        nds.ReportExternalTimeWindowCPUReached(0, 275) !=
            ExternalTimeWindowResult::Success)
        return false;
    nds.IF[0] = vblankMask | timerMask;
    nds.UpdateIRQ(0);
    const u32 invalidIF = nds.IF[0];
    if (nds.ApplyExternalARM9IFW1C(
            30, 275, 0x04000214u, 1, vblankMask,
            timerMask, false, ifResult) !=
            ExternalTimeWindowResult::InvalidExternalIFWrite ||
        nds.IF[0] != invalidIF)
        return false;
    if (!prepare(290) ||
        nds.CloseAndQueryExternalTimeWindow(300, 0, window) !=
            ExternalTimeWindowResult::Success ||
        nds.ReportExternalTimeWindowCPUReached(0, 295) !=
            ExternalTimeWindowResult::Success)
        return false;
    nds.IF[0] = vblankMask | timerMask;
    nds.UpdateIRQ(0);
    if (nds.ApplyExternalARM9IFW1C(
            31, 295, 0x04000214u, 2, vblankMask,
            0, false, ifResult) !=
            ExternalTimeWindowResult::ExternalIFWriteStateMismatch ||
        nds.IF[0] != (vblankMask | timerMask))
        return false;

    // The blocking-MMIO seam is runtime inert and only admits a request bound
    // to one verified active grant. Every field used below is immutable and
    // the execution claim must reproduce it exactly.
    nds.Reset();
    nds.SetExternalIRQTransitionSink(sink, &collector);
    u64 barrierTimestamp = 0xfeedfaceu;
    ExternalBlockingMMIORequest inertRequest{};
    if (nds.BeginExternalBlockingMMIOBarrier(
            inertRequest, barrierTimestamp) !=
            ExternalTimeWindowResult::NotEnabled ||
        barrierTimestamp != 0 ||
        !nds.SetExternalTimeWindowEnabled(true) ||
        nds.BeginExternalBlockingMMIOBarrier(
            inertRequest, barrierTimestamp) !=
            ExternalTimeWindowResult::NoActiveGrant ||
        barrierTimestamp != 0)
        return false;

    const auto makeRequest = [&](u32 epoch, u32 sourceSequence,
                                 u32 barrierSequence,
                                 u64 arm9Timestamp, u64 arm7Timestamp,
                                 u32 cpu, bool write, u32 access,
                                 u32 address, u32 writeData,
                                 u32 executionPC) {
        return ExternalBlockingMMIORequest{
            epoch,
            nds.ExternalTimeWindowVerifiedGrantSequence_,
            nds.ExternalTimeWindowLastProcessed_,
            nds.ExternalTimeWindowLastRunSafe_,
            nds.ExternalTimeWindowEventSequence_,
            sourceSequence,
            barrierSequence,
            nds.ExternalTimeWindowVerifiedProducerFence_,
            arm9Timestamp,
            arm7Timestamp,
            cpu,
            write,
            access,
            address,
            writeData,
            executionPC};
    };
    const auto claim = [&](const ExternalBlockingMMIORequest& request) {
        return nds.ClaimExternalBlockingMMIOAccess(
            request.CPU, request.Write, request.Access, request.Address,
            request.WriteData, request.ExecutionPC);
    };

    // Forward skew, exact active P/R/event/fence matching, equal-B callback
    // closure, and replacement echoes are all covered in one transaction.
    const ExternalTimeWindowReplacement grant7{7, 1, 0, 100};
    if (!prepare(300) ||
        nds.CloseAndQueryExternalTimeWindowVerified(
            400, 0, grant7, window) != ExternalTimeWindowResult::Success ||
        window.Epoch != 7 || window.GrantSequence != 1 ||
        window.ReplacesGrantSequence != 0 ||
        window.VerifiedProducerFence != 100 ||
        window.ReplacesBlockingMMIO)
        return false;
    // The verified producer has one global source stream.  Consume source 9
    // through the IF-W1C seam, then prove the blocking seam cannot reuse it.
    nds.IF[0] = vblankMask;
    nds.UpdateIRQ(0);
    nds.GPU.GPU3D.GXStat = 0;
    if (nds.ApplyExternalARM9IFW1C(
            9, 300, 0x04000214u, 2, vblankMask, 0, false, ifResult) !=
            ExternalTimeWindowResult::Success)
        return false;
    ExternalBlockingMMIORequest request = makeRequest(
        7, 10, 1, 340, 330, 0, false, 1,
        0x04000130u, 0, 0x02000040u);
    ExternalBlockingMMIORequest invalid = request;
    invalid.SourceSequence = 9;
    if (nds.BeginExternalBlockingMMIOBarrier(
            invalid, barrierTimestamp) !=
            ExternalTimeWindowResult::BlockingMMIOBarrierReplay)
        return false;
    invalid = request;
    invalid.Epoch = 0;
    if (nds.BeginExternalBlockingMMIOBarrier(
            invalid, barrierTimestamp) !=
            ExternalTimeWindowResult::InvalidBlockingMMIOBarrierIdentity)
        return false;
    invalid = request;
    invalid.BarrierSequence = 2;
    if (nds.BeginExternalBlockingMMIOBarrier(
            invalid, barrierTimestamp) !=
            ExternalTimeWindowResult::BlockingMMIOBarrierReplay)
        return false;
    invalid = request;
    invalid.ActiveProcessedThrough++;
    if (nds.BeginExternalBlockingMMIOBarrier(
            invalid, barrierTimestamp) !=
            ExternalTimeWindowResult::BlockingMMIOWindowIdentityMismatch)
        return false;
    invalid = request;
    invalid.VerifiedProducerFence--;
    if (nds.BeginExternalBlockingMMIOBarrier(
            invalid, barrierTimestamp) !=
            ExternalTimeWindowResult::BlockingMMIOWindowIdentityMismatch)
        return false;
    invalid = request;
    invalid.ARM9NormalizedTimestamp = 299;
    if (nds.BeginExternalBlockingMMIOBarrier(
            invalid, barrierTimestamp) !=
            ExternalTimeWindowResult::CPUProgressRegressed ||
        nds.BeginExternalBlockingMMIOBarrier(
            request, barrierTimestamp) !=
            ExternalTimeWindowResult::Success ||
        barrierTimestamp != 340 || nds.SysTimestamp != 340 ||
        (nds.ARM9Timestamp >> nds.ARM9ClockShift) != 340 ||
        nds.ARM7Timestamp != 340 || claim(request) !=
            ExternalTimeWindowResult::Success)
        return false;
    nds.IE[0] = vblankMask;
    nds.CurCPU = 0;
    nds.RegisterEventFuncs(Event_RTC, &nds, {setOnly});
    nds.ScheduleEvent(Event_RTC, false, 0, 0, 0);
    const ExternalTimeWindowReplacement replacement7{7, 2, 1, 100};
    if (nds.FinishExternalBlockingMMIOAccess(true) !=
            ExternalTimeWindowResult::Success ||
        nds.CloseAndQueryExternalTimeWindowVerified(
            400, 0, replacement7, window) !=
            ExternalTimeWindowResult::Success ||
        window.ProcessedThrough != 340 || window.RunSafeThrough != 400 ||
        window.LastEventSequence != 1 || window.Epoch != 7 ||
        window.GrantSequence != 2 || window.ReplacesGrantSequence != 1 ||
        window.VerifiedProducerFence != 100 ||
        !window.ReplacesBlockingMMIO ||
        window.BarrierSourceSequence != 10 ||
        window.BarrierSequence != 1 || window.BarrierTimestamp != 340 ||
        nds.IE[0] != vblankMask || collector.Count != 1 ||
        collector.Events[0].Timestamp != 340 ||
        collector.Events[0].CPU != 1 || !collector.Events[0].Set ||
        collector.Events[0].Mask != timerMask)
        return false;

    // Replaying the prior barrier and changing epoch are rejected before the
    // commit point. Reverse skew then completes under the next exact IDs.
    request = makeRequest(
        7, 12, 2, 350, 360, 1, true, 2,
        0x04000210u, vblankMask, 0x03800080u);
    invalid = request;
    invalid.SourceSequence = 10;
    invalid.BarrierSequence = 1;
    if (nds.BeginExternalBlockingMMIOBarrier(
            invalid, barrierTimestamp) !=
            ExternalTimeWindowResult::BlockingMMIOBarrierReplay)
        return false;
    invalid = request;
    invalid.Epoch = 8;
    if (nds.BeginExternalBlockingMMIOBarrier(
            invalid, barrierTimestamp) !=
            ExternalTimeWindowResult::BlockingMMIOWindowIdentityMismatch ||
        nds.BeginExternalBlockingMMIOBarrier(
            request, barrierTimestamp) !=
            ExternalTimeWindowResult::Success ||
        barrierTimestamp != 360 || claim(request) !=
            ExternalTimeWindowResult::Success)
        return false;
    nds.SetIRQ(0, IRQ_VBlank);
    const ExternalTimeWindowReplacement replacement7b{7, 3, 2, 100};
    if (nds.FinishExternalBlockingMMIOAccess(true) !=
            ExternalTimeWindowResult::Success ||
        nds.CloseAndQueryExternalTimeWindowVerified(
            420, 0, replacement7b, window) !=
            ExternalTimeWindowResult::Success ||
        window.ProcessedThrough != 360 || window.RunSafeThrough != 420 ||
        window.LastEventSequence != 2 || window.BarrierTimestamp != 360)
        return false;

    // A wrong next access cannot steal an admitted descriptor. Since B and R
    // have already changed, the mismatch is terminal until Reset.
    if (!prepare(500) ||
        nds.CloseAndQueryExternalTimeWindowVerified(
            520, 0, {9, 1, 0, 100}, window) !=
            ExternalTimeWindowResult::Success)
        return false;
    request = makeRequest(
        9, 20, 1, 510, 511, 0, false, 1,
        0x04000130u, 0, 0x02000100u);
    if (nds.BeginExternalBlockingMMIOBarrier(
            request, barrierTimestamp) !=
            ExternalTimeWindowResult::Success ||
        nds.ClaimExternalBlockingMMIOAccess(
            0, false, 1, 0x04000132u, 0, 0x02000100u) !=
            ExternalTimeWindowResult::BlockingMMIOAccessDescriptorMismatch ||
        claim(request) != ExternalTimeWindowResult::ProtocolFaulted)
        return false;

    // Missing, duplicate, and failed access completions remain reset-only.
    if (!prepare(600) ||
        nds.CloseAndQueryExternalTimeWindowVerified(
            620, 0, {10, 1, 0, 100}, window) !=
            ExternalTimeWindowResult::Success)
        return false;
    request = makeRequest(
        10, 30, 1, 610, 609, 0, false, 1,
        0x04000130u, 0, 0x02000200u);
    if (nds.BeginExternalBlockingMMIOBarrier(
            request, barrierTimestamp) !=
            ExternalTimeWindowResult::Success ||
        nds.CloseAndQueryExternalTimeWindowVerified(
            630, 0, {10, 2, 1, 100}, rejected) !=
            ExternalTimeWindowResult::BlockingMMIOAccessRequired)
        return false;

    // Once the exact access has completed, a replacement may not silently
    // attach a later producer prefix to the frozen barrier transaction.
    if (!prepare(625) ||
        nds.CloseAndQueryExternalTimeWindowVerified(
            645, 0, {11, 1, 0, 100}, window) !=
            ExternalTimeWindowResult::Success)
        return false;
    request = makeRequest(
        11, 31, 1, 635, 634, 0, false, 1,
        0x04000130u, 0, 0x02000280u);
    if (nds.BeginExternalBlockingMMIOBarrier(
            request, barrierTimestamp) !=
            ExternalTimeWindowResult::Success ||
        claim(request) != ExternalTimeWindowResult::Success ||
        nds.FinishExternalBlockingMMIOAccess(true) !=
            ExternalTimeWindowResult::Success ||
        nds.CloseAndQueryExternalTimeWindowVerified(
            650, 0, {11, 2, 1, 101}, rejected) !=
            ExternalTimeWindowResult::BlockingMMIOWindowIdentityMismatch)
        return false;
    if (!prepare(650) ||
        nds.CloseAndQueryExternalTimeWindowVerified(
            670, 0, {12, 1, 0, 100}, window) !=
            ExternalTimeWindowResult::Success)
        return false;
    request = makeRequest(
        12, 31, 1, 660, 659, 0, false, 1,
        0x04000130u, 0, 0x02000300u);
    if (nds.BeginExternalBlockingMMIOBarrier(
            request, barrierTimestamp) !=
            ExternalTimeWindowResult::Success ||
        claim(request) != ExternalTimeWindowResult::Success ||
        claim(request) !=
            ExternalTimeWindowResult::BlockingMMIOAccessAlreadyClaimed)
        return false;
    if (!prepare(700) ||
        nds.CloseAndQueryExternalTimeWindowVerified(
            720, 0, {13, 1, 0, 100}, window) !=
            ExternalTimeWindowResult::Success)
        return false;
    request = makeRequest(
        13, 40, 1, 710, 711, 0, false, 1,
        0x04000130u, 0, 0x02000400u);
    if (nds.BeginExternalBlockingMMIOBarrier(
            request, barrierTimestamp) !=
            ExternalTimeWindowResult::Success ||
        claim(request) != ExternalTimeWindowResult::Success ||
        nds.FinishExternalBlockingMMIOAccess(false) !=
            ExternalTimeWindowResult::BlockingMMIOAccessFailed)
        return false;

    // A scheduler event can be consumed at P while both external CPUs remain
    // stopped at P-1. The exact barrier is B=max(P,T9,T7), so this natural
    // one-tick lookahead must rebase both CPUs to P rather than fail as CPU
    // progress regression.
    if (!prepare(175))
        return false;
    install(Event_RTC, 176, 0, nullptr, {noOp});
    const auto ptestClose1 = nds.CloseAndQueryExternalTimeWindowVerified(
        820, 0, {15, 1, 0, 100}, window);
    if (ptestClose1 != ExternalTimeWindowResult::Success ||
        window.ProcessedThrough != 175 || window.RunSafeThrough != 175)
        return false;
    const auto ptestClose2 = nds.AdvanceAndCloseExternalTimeWindowVerified(
        176, 820, 0, {15, 2, 1, 100}, window);
    if (ptestClose2 != ExternalTimeWindowResult::Success ||
        window.ProcessedThrough != 176 ||
        (nds.ARM9Timestamp >> nds.ARM9ClockShift) != 175 ||
        nds.ARM7Timestamp != 175)
        return false;
    request = makeRequest(
        15, 50, 1, 175, 175, 1, true, 2,
        0x04000208u, 0x04000000u, 0x03800500u);
    const auto ptestBegin = nds.BeginExternalBlockingMMIOBarrier(
        request, barrierTimestamp);
    if (ptestBegin != ExternalTimeWindowResult::Success ||
        barrierTimestamp != 176 || nds.SysTimestamp != 176 ||
        (nds.ARM9Timestamp >> nds.ARM9ClockShift) != 176 ||
        nds.ARM7Timestamp != 176)
        return false;
    const auto ptestClaim = claim(request);
    const auto ptestFinish = nds.FinishExternalBlockingMMIOAccess(true);
    const auto ptestReplace = nds.CloseAndQueryExternalTimeWindowVerified(
        820, 0, {15, 3, 2, 100}, window);
    if (ptestClaim != ExternalTimeWindowResult::Success ||
        ptestFinish != ExternalTimeWindowResult::Success ||
        ptestReplace != ExternalTimeWindowResult::Success ||
        window.ProcessedThrough != 176 || window.BarrierTimestamp != 176)
        return false;

    // B must be representable for both clocks: reverse skew can overflow the
    // ARM9 rebase even when the ARM9-supplied timestamp itself is small.
    const u64 maxNormalized =
        std::numeric_limits<u64>::max() >> nds.ARM9ClockShift;
    if (!prepare(0) ||
        nds.CloseAndQueryExternalTimeWindowVerified(
            std::numeric_limits<u64>::max() - 1, 0,
            {14, 1, 0, 100}, window) !=
            ExternalTimeWindowResult::Success)
        return false;
    request = makeRequest(
        14, 50, 1, maxNormalized + 1, 0, 0, false, 1,
        0x04000130u, 0, 0x02000500u);
    if (nds.BeginExternalBlockingMMIOBarrier(
            request, barrierTimestamp) !=
            ExternalTimeWindowResult::TimestampOverflow)
        return false;
    request = makeRequest(
        14, 50, 1, 0, maxNormalized + 1, 1, false, 1,
        0x04000130u, 0, 0x03800500u);
    if (nds.BeginExternalBlockingMMIOBarrier(
            request, barrierTimestamp) !=
            ExternalTimeWindowResult::TimestampOverflow)
        return false;

    // Reset discards the exact descriptor and all verified identity state.
    if (!prepare(900) ||
        nds.CloseAndQueryExternalTimeWindowVerified(
            920, 0, {99, 1, 0, 100}, window) !=
            ExternalTimeWindowResult::Success)
        return false;
    request = makeRequest(
        99, 60, 1, 910, 912, 0, false, 1,
        0x04000130u, 0, 0x02000600u);
    if (nds.BeginExternalBlockingMMIOBarrier(
            request, barrierTimestamp) !=
            ExternalTimeWindowResult::Success ||
        claim(request) != ExternalTimeWindowResult::Success)
        return false;
    nds.Reset();
    if (nds.ExternalBlockingMMIOBarrierPending() ||
        nds.ClaimExternalBlockingMMIOAccess(
            request.CPU, request.Write, request.Access, request.Address,
            request.WriteData, request.ExecutionPC) !=
            ExternalTimeWindowResult::NotEnabled)
        return false;

    nds.Reset();
    nds.SetExternalIRQTransitionSink(sink, &collector);
    if (!nds.SetExternalTimeWindowEnabled(true))
        return false;

    return true;
#endif
}

u64 NDS::AdvanceExternalSystemToNextEvent(u64 bound)
{
#if NDS4MISTER_EXTERNAL_TIME_WINDOW
    if (ExternalTimeWindowEnabled_)
    {
        ExternalTimeWindowFaulted_ = true;
        return SysTimestamp;
    }
#endif
    u64 target = NextTarget();
    if (bound != 0 && target > bound) target = bound;
    const bool arm7Halted = ARM7.Halted == 1 && !HaltInterrupted(1);
    if (!arm7Halted && target > ARM7Timestamp) target = ARM7Timestamp;
    if (target <= SysTimestamp) return SysTimestamp;
    if ((ARM9Timestamp >> ARM9ClockShift) < target)
        ARM9Timestamp = target << ARM9ClockShift;
    if (ARM7Timestamp < target) ARM7Timestamp = target;
    RunSystem(target);
    // Run the geometry engine too. RunSystem alone fires scheduled events but
    // never executes GX commands, so CmdFIFO cannot drain, CmdStallQueue cannot
    // be refilled, and GXFIFOUnstall is never reached -- a caller waiting out a
    // geometry-FIFO stall would spin until its bound and give up every time.
    GPU.GPU3D.Run();
    return SysTimestamp;
}

u32 NDS::RunFrame()
{
#ifdef JIT_ENABLED
    if (EnableJIT)
        return RunFrame<CPUExecuteMode::JIT>();
    else
#endif
#ifdef GDBSTUB_ENABLED
    if (EnableGDBStub)
    {
        return RunFrame<CPUExecuteMode::InterpreterGDB>();
    } else
#endif
    {
        return RunFrame<CPUExecuteMode::Interpreter>();
    }
}

void NDS::Reschedule(u64 target)
{
    if (CurCPU == 0)
    {
        if (target < (ARM9Target >> ARM9ClockShift))
            ARM9Target = (target << ARM9ClockShift);
    }
    else
    {
        if (target < ARM7Target)
            ARM7Target = target;
    }
}

void NDS::RegisterEventFuncs(u32 id, void* that, const std::initializer_list<EventFunc>& funcs)
{
    SchedEvent& evt = SchedList[id];

    evt.That = that;
    assert(funcs.size() <= MaxEventFunctions);
    int i = 0;
    for (EventFunc func : funcs)
    {
        evt.Funcs[i++] = func;        
    }
}

void NDS::UnregisterEventFuncs(u32 id)
{
    SchedEvent& evt = SchedList[id];

    evt.That = nullptr;
    for (int i = 0; i < MaxEventFunctions; i++)
        evt.Funcs[i] = nullptr;
}

void NDS::ScheduleEvent(u32 id, bool periodic, s32 delay, u32 funcid, u32 param)
{
    if (SchedListMask & (1<<id))
    {
        Log(LogLevel::Debug, "!! EVENT %d ALREADY SCHEDULED\n", id);
        return; 
    }

    SchedEvent& evt = SchedList[id];

    if (periodic)
        evt.Timestamp += delay;
    else
    {
        if (CurCPU == 0)
            evt.Timestamp = (ARM9Timestamp >> ARM9ClockShift) + delay;
        else
            evt.Timestamp = ARM7Timestamp + delay;
    }

    evt.FuncID = funcid;
    evt.Param = param;

    SchedListMask |= (1<<id);

    Reschedule(evt.Timestamp);
}

void NDS::CancelEvent(u32 id)
{
    SchedListMask &= ~(1<<id);
}


void NDS::TouchScreen(u16 x, u16 y)
{
    SPI.GetTSC()->SetTouchCoords(x, y);
}

void NDS::ReleaseScreen()
{
    SPI.GetTSC()->SetTouchCoords(0x000, 0xFFF);
}


void NDS::CheckKeyIRQ(u32 cpu, u32 oldkey, u32 newkey)
{
    u16 cnt = KeyCnt[cpu];
    if (!(cnt & (1<<14))) // IRQ disabled
        return;

    u32 mask = (cnt & 0x03FF);
    oldkey &= mask;
    newkey &= mask;

    bool oldmatch, newmatch;
    if (cnt & (1<<15))
    {
        // logical AND

        oldmatch = (oldkey == 0);
        newmatch = (newkey == 0);
    }
    else
    {
        // logical OR

        oldmatch = (oldkey != mask);
        newmatch = (newkey != mask);
    }

    if ((!oldmatch) && newmatch)
        SetIRQ(cpu, IRQ_Keypad);
}

void NDS::SetKeyMask(u32 mask)
{
    u32 key_lo = mask & 0x3FF;
    u32 key_hi = (mask >> 10) & 0x3;

    u32 oldkey = KeyInput;
    KeyInput &= 0xFFFCFC00;
    KeyInput |= key_lo | (key_hi << 16);

    CheckKeyIRQ(0, oldkey, KeyInput);
    CheckKeyIRQ(1, oldkey, KeyInput);
}

bool NDS::IsLidClosed() const
{
    if (KeyInput & (1<<23)) return true;
    return false;
}

void NDS::SetLidClosed(bool closed)
{
    if (closed)
    {
        KeyInput |= (1<<23);
    }
    else
    {
        KeyInput &= ~(1<<23);
        SetIRQ(1, IRQ_LidOpen);
    }
}

/*int ImportSRAM(u8* data, u32 length)
{
    return NDSCart::ImportSRAM(data, length);
}*/


void NDS::Halt()
{
    Log(LogLevel::Info, "Halt()\n");
    Running = false;
}


void NDS::SetExMemCnt(u32 cpu, u16 val, u16 mask)
{
    val &= mask;

    if (cpu == 0)
    {
        u16 oldval = ExMemCnt[0];

        // DSi has one extra bit (access rights for second cart slot)
        u16 rwmask = (ConsoleType == 1) ? 0x8CFF : 0x88FF;

        // bit13/14 are read-only
        ExMemCnt[0] = (ExMemCnt[0] & (~mask | 0x6000)) | (val & rwmask);
        ExMemCnt[1] = (ExMemCnt[0] & 0xFF80) | (ExMemCnt[1] & 0x007F);
        u16 diff = oldval ^ ExMemCnt[0];

        if (diff & 0xFF)
            SetGBASlotTimings();

        if (diff & (1<<11))
            NDSCartSlots[0]->SetCPUSelect((ExMemCnt[0] >> 11) & 0x1);

        if (ConsoleType == 1)
        {
            if (diff & (1<<10))
                NDSCartSlots[1]->SetCPUSelect((ExMemCnt[0] >> 10) & 0x1);
        }
    }
    else
    {
        if (!(mask & 0xFF))
            return;

        u16 oldval = ExMemCnt[1];
        ExMemCnt[1] = (ExMemCnt[1] & 0xFF80) | (val & 0x007F);
        u16 diff = oldval ^ ExMemCnt[1];

        if (diff & 0xFF)
            SetGBASlotTimings();
    }
}


void NDS::MapSharedWRAM(u8 val)
{
    if (val == WRAMCnt)
        return;

    JIT.Memory.RemapSWRAM();

    WRAMCnt = val;

    switch (WRAMCnt & 0x3)
    {
    case 0:
        SWRAM_ARM9.Mem = &SharedWRAM[0];
        SWRAM_ARM9.Mask = 0x7FFF;
        SWRAM_ARM7.Mem = NULL;
        SWRAM_ARM7.Mask = 0;
        break;

    case 1:
        SWRAM_ARM9.Mem = &SharedWRAM[0x4000];
        SWRAM_ARM9.Mask = 0x3FFF;
        SWRAM_ARM7.Mem = &SharedWRAM[0];
        SWRAM_ARM7.Mask = 0x3FFF;
        break;

    case 2:
        SWRAM_ARM9.Mem = &SharedWRAM[0];
        SWRAM_ARM9.Mask = 0x3FFF;
        SWRAM_ARM7.Mem = &SharedWRAM[0x4000];
        SWRAM_ARM7.Mask = 0x3FFF;
        break;

    case 3:
        SWRAM_ARM9.Mem = NULL;
        SWRAM_ARM9.Mask = 0;
        SWRAM_ARM7.Mem = &SharedWRAM[0];
        SWRAM_ARM7.Mask = 0x7FFF;
        break;
    }
}

void NDS::ReplaceWRAMBacking(u8* shared, u8* arm7)
{
    const u8 mapping = WRAMCnt;
    SharedWRAM = shared;
    ARM7WRAM = arm7;
    WRAMCnt = 0xff;
    MapSharedWRAM(mapping);
}


void NDS::UpdateWifiTimings()
{
    if (PowerControl7 & 0x0002)
    {
        const int ntimings[4] = {10, 8, 6, 18};
        u16 val = WifiWaitCnt;

        SetARM7RegionTimings(0x04800, 0x04808, Mem7_Wifi0, 16, ntimings[val & 0x3], (val & 0x4) ? 4 : 6);
        SetARM7RegionTimings(0x04808, 0x04810, Mem7_Wifi1, 16, ntimings[(val>>3) & 0x3], (val & 0x20) ? 4 : 10);
    }
    else
    {
        SetARM7RegionTimings(0x04800, 0x04808, Mem7_Wifi0, 32, 1, 1);
        SetARM7RegionTimings(0x04808, 0x04810, Mem7_Wifi1, 32, 1, 1);
    }
}

void NDS::SetWifiWaitCnt(u16 val)
{
    if (WifiWaitCnt == val) return;

    WifiWaitCnt = val;
    UpdateWifiTimings();
}

void NDS::SetGBASlotTimings()
{
    const int ntimings[4] = {10, 8, 6, 18};
    const u16 openbus[4] = {0xFE08, 0x0000, 0x0000, 0xFFFF};

    u16 curcpu = (ExMemCnt[0] >> 7) & 0x1;
    u16 curcnt = ExMemCnt[curcpu];
    int ramN = ntimings[curcnt & 0x3];
    int romN = ntimings[(curcnt>>2) & 0x3];
    int romS = (curcnt & 0x10) ? 4 : 6;

    // GBA slot timings only apply on the selected side

    if (curcpu == 0)
    {
        SetARM9RegionTimings(0x08000, 0x0A000, Mem9_GBAROM, 16, romN, romS);
        SetARM9RegionTimings(0x0A000, 0x0B000, Mem9_GBARAM, 8, ramN, ramN);

        SetARM7RegionTimings(0x08000, 0x0A000, 0, 32, 1, 1);
        SetARM7RegionTimings(0x0A000, 0x0B000, 0, 32, 1, 1);
    }
    else
    {
        SetARM9RegionTimings(0x08000, 0x0A000, 0, 32, 1, 1);
        SetARM9RegionTimings(0x0A000, 0x0B000, 0, 32, 1, 1);

        SetARM7RegionTimings(0x08000, 0x0A000, Mem7_GBAROM, 16, romN, romS);
        SetARM7RegionTimings(0x0A000, 0x0B000, Mem7_GBARAM, 8, ramN, ramN);
    }

    // this open-bus implementation is a rough way of simulating the way values
    // lingering on the bus decay after a while, which is visible at higher waitstates
    // for example, the Cartridge Construction Kit relies on this to determine that
    // the GBA slot is empty

    GBACartSlot.SetOpenBusDecay(openbus[(curcnt>>2) & 0x3]);
}


void NDS::UpdateIRQ(u32 cpu)
{
    ARM& arm = cpu ? (ARM&)ARM7 : (ARM&)ARM9;

    if (IME[cpu] & 0x1)
    {
        arm.IRQ = !!(IE[cpu] & IF[cpu]);
        if ((ConsoleType == 1) && cpu)
            arm.IRQ |= !!(IE2 & IF2);
    }
    else
    {
        arm.IRQ = 0;
    }
}

void NDS::SetIRQ(u32 cpu, u32 irq)
{
    const u32 mask = 1u << irq;
    IF[cpu] |= mask;
    RecordExternalIRQTransition(cpu, true, mask);
    if (ExternalIRQSink)
        ExternalIRQSink(cpu, mask, ExternalIRQSinkUserdata);
    UpdateIRQ(cpu);

    if ((cpu == 1) && (CPUStop & CPUStop_Sleep))
    {
        if (IE[1] & (1 << irq))
        {
            CPUStop &= ~CPUStop_Sleep;
            CPUStop |= CPUStop_Wakeup;
            GPU.Restart3DFrame();
        }
    }
}

void NDS::ClearIRQ(u32 cpu, u32 irq)
{
    ClearIRQMask(cpu, 1u << irq);
}

void NDS::ClearIRQMask(u32 cpu, u32 mask)
{
    IF[cpu] &= ~mask;
    if (mask != 0)
        RecordExternalIRQTransition(cpu, false, mask);
    UpdateIRQ(cpu);
}

void NDS::RecordExternalIRQTransition(u32 cpu, bool set, u32 mask) noexcept
{
#if NDS4MISTER_EXTERNAL_TIME_WINDOW
    if (ExternalARM9IFW1CActive_)
    {
        constexpr u32 gxFIFOIRQMask = 1u << IRQ_GXFIFO;
        bool matches = false;
        if (ExternalARM9IFW1CExpectedClearMask_ != 0 &&
            ExternalARM9IFW1CPhase_ == 0)
        {
            matches = cpu == 0 && !set &&
                      mask == ExternalARM9IFW1CExpectedClearMask_;
        }
        else
        {
            const u8 gxPhase =
                ExternalARM9IFW1CExpectedClearMask_ != 0 ? 1 : 0;
            if (ExternalARM9IFW1CPhase_ == gxPhase)
                matches = cpu == 0 &&
                          set == ExternalARM9IFW1CExpectedGXFIFOSet_ &&
                          mask == gxFIFOIRQMask;
        }

        if (!matches ||
            ExternalARM9IFW1CPhase_ >=
                ExternalARM9IFW1CExpectedPhases_)
        {
            ExternalARM9IFW1CFailed_ = true;
            ExternalTimeWindowFaulted_ = true;
            return;
        }
        ++ExternalARM9IFW1CPhase_;
        return;
    }
    if (!ExternalTimeWindowEnabled_)
        return;
    if (!ExternalTimeWindowClosureActive_)
    {
        // Never emit an unassociated global stream. An IF mutation outside an
        // explicit closure has no atomic P/R transaction and poisons the epoch.
        ExternalTimeWindowFaulted_ = true;
        return;
    }
    if (cpu > 1 || mask == 0 ||
        ExternalTimeWindowEventSequence_ ==
            std::numeric_limits<u32>::max())
    {
        ExternalTimeWindowFaulted_ = true;
        return;
    }

    const ExternalIRQTransition transition{
        ++ExternalTimeWindowEventSequence_, SysTimestamp, cpu, mask, set};
    if (set)
        ExternalTimeWindowObservedIF_[cpu] |= mask;
    else
        ExternalTimeWindowObservedIF_[cpu] &= ~mask;
    if (!ExternalIRQTransitionSink_ ||
        !ExternalIRQTransitionSink_(
            transition, ExternalIRQTransitionSinkUserdata_))
    {
        ExternalTimeWindowObserverFailed_ = true;
        ExternalTimeWindowFaulted_ = true;
    }
#else
    (void)cpu;
    (void)set;
    (void)mask;
#endif
}

void NDS::SetIRQ2(u32 irq)
{
    IF2 |= (1 << irq);
    UpdateIRQ(1);
}

void NDS::ClearIRQ2(u32 irq)
{
    IF2 &= ~(1 << irq);
    UpdateIRQ(1);
}

bool NDS::HaltInterrupted(u32 cpu) const
{
    if (cpu == 0)
    {
        if (!(IME[0] & 0x1))
            return false;
    }

    if (IF[cpu] & IE[cpu])
        return true;

    if ((ConsoleType == 1) && cpu && (IF2 & IE2))
        return true;

    return false;
}

void NDS::StopCPU(u32 cpu, u32 mask)
{
    if (cpu)
    {
        CPUStop |= (mask << 16);
        ARM7.Halt(2);
    }
    else
    {
        CPUStop |= mask;
        ARM9.Halt(2);
    }
}

void NDS::ResumeCPU(u32 cpu, u32 mask)
{
    if (cpu) mask <<= 16;
    CPUStop &= ~mask;
}

void NDS::GXFIFOStall()
{
    if (CPUStop & CPUStop_GXStall) return;

    CPUStop |= CPUStop_GXStall;

    if (CurCPU == 1) ARM9.Halt(2);
    else
    {
        DMAs[0].StallIfRunning();
        DMAs[1].StallIfRunning();
        DMAs[2].StallIfRunning();
        DMAs[3].StallIfRunning();
        if (ConsoleType == 1)
        {
            auto& dsi = dynamic_cast<melonDS::DSi&>(*this);
            dsi.StallNDMAs();
        }
    }
}

void NDS::GXFIFOUnstall()
{
    CPUStop &= ~CPUStop_GXStall;
}

void NDS::EnterSleepMode()
{
    if (CPUStop & CPUStop_Sleep) return;

    CPUStop |= CPUStop_Sleep;
    ARM7.Halt(2);
}

u32 NDS::GetPC(u32 cpu) const
{
    return cpu ? ARM7.R[15] : ARM9.R[15];
}

u64 NDS::GetSysClockCycles(int num)
{
    u64 ret;

    if (num == 0 || num == 2)
    {
        if (CurCPU == 0)
            ret = ARM9Timestamp >> ARM9ClockShift;
        else
            ret = ARM7Timestamp;

        if (num == 2) ret -= FrameStartTimestamp;
    }
    else if (num == 1)
    {
        ret = LastSysClockCycles;
        LastSysClockCycles = 0;

        if (CurCPU == 0)
            LastSysClockCycles = ARM9Timestamp >> ARM9ClockShift;
        else
            LastSysClockCycles = ARM7Timestamp;
    }

    return ret;
}

void NDS::NocashPrint(u32 ncpu, u32 addr, bool appendNewline)
{
    // addr: debug string

    ARM* cpu = ncpu ? (ARM*)&ARM7 : (ARM*)&ARM9;
    u8 (NDS::*readfn)(u32) = ncpu ? &NDS::ARM7Read8 : &NDS::ARM9Read8;

    char output[1024];
    int ptr = 0;

    for (int i = 0; i < 120 && ptr < 1023; )
    {
        char ch = (this->*readfn)(addr++);
        i++;

        if (ch == '%')
        {
            char cmd[16]; int j;
            for (j = 0; j < 15; )
            {
                char ch2 = (this->*readfn)(addr++);
                i++;
                if (i >= 120) break;
                if (ch2 == '%') break;
                cmd[j++] = ch2;
            }
            cmd[j] = '\0';

            char subs[64];

            if (cmd[0] == 'r')
            {
                if      (!strcmp(cmd, "r0")) snprintf(subs, sizeof(subs), "%08X", cpu->R[0]);
                else if (!strcmp(cmd, "r1")) snprintf(subs, sizeof(subs), "%08X", cpu->R[1]);
                else if (!strcmp(cmd, "r2")) snprintf(subs, sizeof(subs), "%08X", cpu->R[2]);
                else if (!strcmp(cmd, "r3")) snprintf(subs, sizeof(subs), "%08X", cpu->R[3]);
                else if (!strcmp(cmd, "r4")) snprintf(subs, sizeof(subs), "%08X", cpu->R[4]);
                else if (!strcmp(cmd, "r5")) snprintf(subs, sizeof(subs), "%08X", cpu->R[5]);
                else if (!strcmp(cmd, "r6")) snprintf(subs, sizeof(subs), "%08X", cpu->R[6]);
                else if (!strcmp(cmd, "r7")) snprintf(subs, sizeof(subs), "%08X", cpu->R[7]);
                else if (!strcmp(cmd, "r8")) snprintf(subs, sizeof(subs), "%08X", cpu->R[8]);
                else if (!strcmp(cmd, "r9")) snprintf(subs, sizeof(subs), "%08X", cpu->R[9]);
                else if (!strcmp(cmd, "r10")) snprintf(subs, sizeof(subs), "%08X", cpu->R[10]);
                else if (!strcmp(cmd, "r11")) snprintf(subs, sizeof(subs), "%08X", cpu->R[11]);
                else if (!strcmp(cmd, "r12")) snprintf(subs, sizeof(subs), "%08X", cpu->R[12]);
                else if (!strcmp(cmd, "r13")) snprintf(subs, sizeof(subs), "%08X", cpu->R[13]);
                else if (!strcmp(cmd, "r14")) snprintf(subs, sizeof(subs), "%08X", cpu->R[14]);
                else if (!strcmp(cmd, "r15")) snprintf(subs, sizeof(subs), "%08X", cpu->R[15]);
            }
            else
            {
                if      (!strcmp(cmd, "sp")) snprintf(subs, sizeof(subs), "%08X", cpu->R[13]);
                else if (!strcmp(cmd, "lr")) snprintf(subs, sizeof(subs), "%08X", cpu->R[14]);
                else if (!strcmp(cmd, "pc")) snprintf(subs, sizeof(subs), "%08X", cpu->R[15]);
                else if (!strcmp(cmd, "frame")) snprintf(subs, sizeof(subs), "%u", NumFrames);
                else if (!strcmp(cmd, "scanline")) snprintf(subs, sizeof(subs), "%u", GPU.VCount);
                else if (!strcmp(cmd, "totalclks")) snprintf(subs, sizeof(subs), "%" PRIu64, GetSysClockCycles(0));
                else if (!strcmp(cmd, "lastclks")) snprintf(subs, sizeof(subs), "%" PRIu64, GetSysClockCycles(1));
                else if (!strcmp(cmd, "zeroclks"))
                {
                    snprintf(subs, sizeof(subs), "%s", "");
                    GetSysClockCycles(1);
                }
            }

            int slen = strnlen(subs, sizeof(subs));
            if ((ptr+slen) > 1023) slen = 1023-ptr;
            strncpy(&output[ptr], subs, slen);
            ptr += slen;
        }
        else
        {
            output[ptr++] = ch;
            if (ch == '\0') break;
        }
    }

    output[ptr] = '\0';
    Log(LogLevel::Debug, appendNewline ? "%s\n" : "%s", output);
}

void NDS::MonitorARM9Jump(u32 addr)
{
    // checkme: can the entrypoint addr be THUMB?
    // also TODO: make it work in DSi mode

    if ((!RunningGame) && NDSCartSlot.GetCart())
    {
        const NDSHeader& header = NDSCartSlot.GetCart()->GetHeader();
        if (addr == header.ARM9EntryAddress)
        {
            Log(LogLevel::Info, "Game is now booting\n");
            RunningGame = true;
        }
    }
}



void NDS::HandleTimerOverflow(u32 tid)
{
    Timer* timer = &Timers[tid];

    timer->Counter += (timer->Reload << 10);
    if (timer->Cnt & (1<<6))
        SetIRQ(tid >> 2, IRQ_Timer0 + (tid & 0x3));

    if ((tid & 0x3) == 3)
        return;

    for (;;)
    {
        tid++;

        timer = &Timers[tid];

        if ((timer->Cnt & 0x84) != 0x84)
            break;

        timer->Counter += (1 << 10);
        if (!(timer->Counter >> 26))
            break;

        timer->Counter = timer->Reload << 10;
        if (timer->Cnt & (1<<6))
            SetIRQ(tid >> 2, IRQ_Timer0 + (tid & 0x3));

        if ((tid & 0x3) == 3)
            break;
    }
}

void NDS::RunTimer(u32 tid, s32 cycles)
{
    Timer* timer = &Timers[tid];

    timer->Counter += (cycles << timer->CycleShift);
    while (timer->Counter >> 26)
    {
        timer->Counter -= (1 << 26);
        HandleTimerOverflow(tid);
    }
}

void NDS::RunTimers(u32 cpu)
{
    u32 timermask = TimerCheckMask[cpu];
    s32 cycles;

    if (cpu == 0)
        cycles = (ARM9Timestamp >> ARM9ClockShift) - TimerTimestamp[0];
    else
        cycles = ARM7Timestamp - TimerTimestamp[1];

    if (timermask & 0x1) RunTimer((cpu<<2)+0, cycles);
    if (timermask & 0x2) RunTimer((cpu<<2)+1, cycles);
    if (timermask & 0x4) RunTimer((cpu<<2)+2, cycles);
    if (timermask & 0x8) RunTimer((cpu<<2)+3, cycles);

    TimerTimestamp[cpu] += cycles;
}

const s32 TimerPrescaler[4] = {0, 6, 8, 10};

u16 NDS::TimerGetCounter(u32 timer)
{
    RunTimers(timer>>2);
    u32 ret = Timers[timer].Counter;

    return ret >> 10;
}

void NDS::TimerStart(u32 id, u16 cnt)
{
    Timer* timer = &Timers[id];
    u16 curstart = timer->Cnt & (1<<7);
    u16 newstart = cnt & (1<<7);

    RunTimers(id>>2);

    timer->Cnt = cnt;
    timer->CycleShift = 10 - TimerPrescaler[cnt & 0x03];

    if ((!curstart) && newstart)
    {
        timer->Counter = timer->Reload << 10;
    }

    if ((cnt & 0x84) == 0x80)
        TimerCheckMask[id>>2] |= 0x01 << (id&0x3);
    else
        TimerCheckMask[id>>2] &= ~(0x01 << (id&0x3));
}



bool NDS::DMAsInMode(u32 cpu, u32 mode) const
{
    cpu <<= 2;
    if (DMAs[cpu+0].IsInMode(mode)) return true;
    if (DMAs[cpu+1].IsInMode(mode)) return true;
    if (DMAs[cpu+2].IsInMode(mode)) return true;
    if (DMAs[cpu+3].IsInMode(mode)) return true;

    return false;
}

bool NDS::DMAsRunning(u32 cpu) const
{
    cpu <<= 2;
    if (DMAs[cpu+0].IsRunning()) return true;
    if (DMAs[cpu+1].IsRunning()) return true;
    if (DMAs[cpu+2].IsRunning()) return true;
    if (DMAs[cpu+3].IsRunning()) return true;

    return false;
}

void NDS::CheckDMAs(u32 cpu, u32 mode)
{
    cpu <<= 2;
    DMAs[cpu+0].StartIfNeeded(mode);
    DMAs[cpu+1].StartIfNeeded(mode);
    DMAs[cpu+2].StartIfNeeded(mode);
    DMAs[cpu+3].StartIfNeeded(mode);
}

void NDS::StopDMAs(u32 cpu, u32 mode)
{
    cpu <<= 2;
    DMAs[cpu+0].StopIfNeeded(mode);
    DMAs[cpu+1].StopIfNeeded(mode);
    DMAs[cpu+2].StopIfNeeded(mode);
    DMAs[cpu+3].StopIfNeeded(mode);
}



void NDS::DivDone(u32 param)
{
    DivCnt &= ~0xC000;

    switch (DivCnt & 0x0003)
    {
    case 0x0000:
        {
            s32 num = (s32)DivNumerator[0];
            s32 den = (s32)DivDenominator[0];
            if (den == 0)
            {
                DivQuotient[0] = (num<0) ? 1:-1;
                DivQuotient[1] = (num<0) ? -1:0;
                *(s64*)&DivRemainder[0] = num;
            }
            else if (num == -0x80000000 && den == -1)
            {
                *(s64*)&DivQuotient[0] = 0x80000000;
            }
            else
            {
                *(s64*)&DivQuotient[0] = (s64)(num / den);
                *(s64*)&DivRemainder[0] = (s64)(num % den);
            }
        }
        break;

    case 0x0001:
    case 0x0003:
        {
            s64 num = *(s64*)&DivNumerator[0];
            s32 den = (s32)DivDenominator[0];
            if (den == 0)
            {
                *(s64*)&DivQuotient[0] = (num<0) ? 1:-1;
                *(s64*)&DivRemainder[0] = num;
            }
            else if (num == -0x8000000000000000 && den == -1)
            {
                *(s64*)&DivQuotient[0] = 0x8000000000000000;
                *(s64*)&DivRemainder[0] = 0;
            }
            else
            {
                *(s64*)&DivQuotient[0] = (s64)(num / den);
                *(s64*)&DivRemainder[0] = (s64)(num % den);
            }
        }
        break;

    case 0x0002:
        {
            s64 num = *(s64*)&DivNumerator[0];
            s64 den = *(s64*)&DivDenominator[0];
            if (den == 0)
            {
                *(s64*)&DivQuotient[0] = (num<0) ? 1:-1;
                *(s64*)&DivRemainder[0] = num;
            }
            else if (num == -0x8000000000000000 && den == -1)
            {
                *(s64*)&DivQuotient[0] = 0x8000000000000000;
                *(s64*)&DivRemainder[0] = 0;
            }
            else
            {
                *(s64*)&DivQuotient[0] = (s64)(num / den);
                *(s64*)&DivRemainder[0] = (s64)(num % den);
            }
        }
        break;
    }

    if ((DivDenominator[0] | DivDenominator[1]) == 0)
        DivCnt |= 0x4000;
}

void NDS::StartDiv()
{
    CancelEvent(Event_Div);
    DivCnt |= 0x8000;
    ScheduleEvent(Event_Div, false, ((DivCnt&0x3)==0) ? 18:34, 0, 0);
}

// http://stackoverflow.com/questions/1100090/looking-for-an-efficient-integer-square-root-algorithm-for-arm-thumb2
void NDS::SqrtDone(u32 param)
{
    u64 val;
    u32 res = 0;
    u64 rem = 0;
    u32 prod = 0;
    u32 nbits, topshift;

    SqrtCnt &= ~0x8000;

    if (SqrtCnt & 0x0001)
    {
        val = *(u64*)&SqrtVal[0];
        nbits = 32;
        topshift = 62;
    }
    else
    {
        val = (u64)SqrtVal[0]; // 32bit
        nbits = 16;
        topshift = 30;
    }

    for (u32 i = 0; i < nbits; i++)
    {
        rem = (rem << 2) + ((val >> topshift) & 0x3);
        val <<= 2;
        res <<= 1;

        prod = (res << 1) + 1;
        if (rem >= prod)
        {
            rem -= prod;
            res++;
        }
    }

    SqrtRes = res;
}

void NDS::StartSqrt()
{
    CancelEvent(Event_Sqrt);
    SqrtCnt |= 0x8000;
    ScheduleEvent(Event_Sqrt, false, 13, 0, 0);
}



void NDS::debug(u32 param)
{
    Log(LogLevel::Debug, "ARM9 PC=%08X LR=%08X %08X\n", ARM9.R[15], ARM9.R[14], ARM9.R_IRQ[1]);
    Log(LogLevel::Debug, "ARM7 PC=%08X LR=%08X %08X\n", ARM7.R[15], ARM7.R[14], ARM7.R_IRQ[1]);

    Log(LogLevel::Debug, "ARM9 IME=%08X IE=%08X IF=%08X\n", IME[0], IE[0], IF[0]);
    Log(LogLevel::Debug, "ARM7 IME=%08X IE=%08X IF=%08X IE2=%04X IF2=%04X\n", IME[1], IE[1], IF[1], IE2, IF2);

    //for (int i = 0; i < 9; i++)
    //    printf("VRAM %c: %02X\n", 'A'+i, GPU->VRAMCNT[i]);
return;
    Platform::FileHandle* shit = Platform::OpenFile("debug/dragonball.bin", FileMode::Write);
    Platform::FileWrite(ARM9.ITCM, 0x8000, 1, shit);
    for (u32 i = 0x02000000; i < 0x02400000; i+=4)
    {
        u32 val = NDS::ARM7Read32(i);
        Platform::FileWrite(&val, 4, 1, shit);
    }
    for (u32 i = 0x037F0000; i < 0x03810000; i+=4)
    {
        u32 val = NDS::ARM7Read32(i);
        Platform::FileWrite(&val, 4, 1, shit);
    }
    for (u32 i = 0x06000000; i < 0x06040000; i+=4)
    {
        u32 val = NDS::ARM7Read32(i);
        Platform::FileWrite(&val, 4, 1, shit);
    }
    Platform::CloseFile(shit);

    /*FILE*
    shit = fopen("debug/bowser9.bin", "wb");
    fwrite(ARM9.ITCM, 0x8000, 1, shit);
    for (u32 i = 0x02000000; i < 0x04000000; i+=4)
    {
        u32 val = ARM9Read32(i);
        fwrite(&val, 4, 1, shit);
    }
    fclose(shit);
    shit = fopen("debug/bowser7.bin", "wb");
    for (u32 i = 0x02000000; i < 0x04000000; i+=4)
    {
        u32 val = ARM7Read32(i);
        fwrite(&val, 4, 1, shit);
    }
    fclose(shit);*/
}



u8 NDS::ARM9Read8(u32 addr)
{
    if ((addr & 0xFFFFF000) == 0xFFFF0000)
    {
        return *(u8*)&ARM9BIOS[addr & 0xFFF];
    }

    switch (addr & 0xFF000000)
    {
    case 0x02000000:
        return *(u8*)&MainRAM[addr & MainRAMMask];

    case 0x03000000:
        if (SWRAM_ARM9.Mem)
        {
            return *(u8*)&SWRAM_ARM9.Mem[addr & SWRAM_ARM9.Mask];
        }
        else
        {
            return 0;
        }

    case 0x04000000:
        // Specifically want to call the NDS version, not a subclass
        return NDS::ARM9IORead8(addr);

    case 0x05000000:
        if (!(PowerControl9 & ((addr & 0x400) ? (1<<9) : (1<<1)))) return 0;
        return GPU.ReadPalette<u8>(addr);

    case 0x06000000:
        switch (addr & 0x00E00000)
        {
        case 0x00000000: GPU.SyncVRAM_ABG(addr, false); return GPU.ReadVRAM_ABG<u8>(addr);
        case 0x00200000: GPU.SyncVRAM_BBG(addr, false); return GPU.ReadVRAM_BBG<u8>(addr);
        case 0x00400000: GPU.SyncVRAM_AOBJ(addr, false); return GPU.ReadVRAM_AOBJ<u8>(addr);
        case 0x00600000: GPU.SyncVRAM_BOBJ(addr, false); return GPU.ReadVRAM_BOBJ<u8>(addr);
        default:         GPU.SyncVRAM_LCDC(addr, false); return GPU.ReadVRAM_LCDC<u8>(addr);
        }

    case 0x07000000:
        if (!(PowerControl9 & ((addr & 0x400) ? (1<<9) : (1<<1)))) return 0;
        return GPU.ReadOAM<u8>(addr);

    case 0x08000000:
    case 0x09000000:
        if (ExMemCnt[0] & (1<<7)) return 0x00; // deselected CPU is 00h-filled
        if (addr & 0x1) return GBACartSlot.ROMRead(addr-1) >> 8;
        return GBACartSlot.ROMRead(addr) & 0xFF;

    case 0x0A000000:
        if (ExMemCnt[0] & (1<<7)) return 0x00; // deselected CPU is 00h-filled
        return GBACartSlot.SRAMRead(addr);
    }

    Log(LogLevel::Debug, "unknown arm9 read8 %08X\n", addr);
    return 0;
}

u16 NDS::ARM9Read16(u32 addr)
{
    addr &= ~0x1;

    if ((addr & 0xFFFFF000) == 0xFFFF0000)
    {
        return *(u16*)&ARM9BIOS[addr & 0xFFF];
    }

    switch (addr & 0xFF000000)
    {
    case 0x02000000:
        return *(u16*)&MainRAM[addr & MainRAMMask];

    case 0x03000000:
        if (SWRAM_ARM9.Mem)
        {
            return *(u16*)&SWRAM_ARM9.Mem[addr & SWRAM_ARM9.Mask];
        }
        else
        {
            return 0;
        }

    case 0x04000000:
        return NDS::ARM9IORead16(addr);

    case 0x05000000:
        if (!(PowerControl9 & ((addr & 0x400) ? (1<<9) : (1<<1)))) return 0;
        return GPU.ReadPalette<u16>(addr);

    case 0x06000000:
        switch (addr & 0x00E00000)
        {
        case 0x00000000: GPU.SyncVRAM_ABG(addr, false); return GPU.ReadVRAM_ABG<u16>(addr);
        case 0x00200000: GPU.SyncVRAM_BBG(addr, false); return GPU.ReadVRAM_BBG<u16>(addr);
        case 0x00400000: GPU.SyncVRAM_AOBJ(addr, false); return GPU.ReadVRAM_AOBJ<u16>(addr);
        case 0x00600000: GPU.SyncVRAM_BOBJ(addr, false); return GPU.ReadVRAM_BOBJ<u16>(addr);
        default:         GPU.SyncVRAM_LCDC(addr, false); return GPU.ReadVRAM_LCDC<u16>(addr);
        }

    case 0x07000000:
        if (!(PowerControl9 & ((addr & 0x400) ? (1<<9) : (1<<1)))) return 0;
        return GPU.ReadOAM<u16>(addr);

    case 0x08000000:
    case 0x09000000:
        if (ExMemCnt[0] & (1<<7)) return 0x0000; // deselected CPU is 00h-filled
        return GBACartSlot.ROMRead(addr);

    case 0x0A000000:
        if (ExMemCnt[0] & (1<<7)) return 0x0000; // deselected CPU is 00h-filled
        return GBACartSlot.SRAMRead(addr) |
              (GBACartSlot.SRAMRead(addr+1) << 8);
    }

    //if (addr) Log(LogLevel::Warn, "unknown arm9 read16 %08X %08X\n", addr, ARM9.R[15]);
    return 0;
}

u32 NDS::ARM9Read32(u32 addr)
{
    addr &= ~0x3;

    if ((addr & 0xFFFFF000) == 0xFFFF0000)
    {
        return *(u32*)&ARM9BIOS[addr & 0xFFF];
    }

    switch (addr & 0xFF000000)
    {
    case 0x02000000:
        return *(u32*)&MainRAM[addr & MainRAMMask];

    case 0x03000000:
        if (SWRAM_ARM9.Mem)
        {
            return *(u32*)&SWRAM_ARM9.Mem[addr & SWRAM_ARM9.Mask];
        }
        else
        {
            return 0;
        }

    case 0x04000000:
        return NDS::ARM9IORead32(addr);

    case 0x05000000:
        if (!(PowerControl9 & ((addr & 0x400) ? (1<<9) : (1<<1)))) return 0;
        return GPU.ReadPalette<u32>(addr);

    case 0x06000000:
        switch (addr & 0x00E00000)
        {
        case 0x00000000: GPU.SyncVRAM_ABG(addr, false); return GPU.ReadVRAM_ABG<u32>(addr);
        case 0x00200000: GPU.SyncVRAM_BBG(addr, false); return GPU.ReadVRAM_BBG<u32>(addr);
        case 0x00400000: GPU.SyncVRAM_AOBJ(addr, false); return GPU.ReadVRAM_AOBJ<u32>(addr);
        case 0x00600000: GPU.SyncVRAM_BOBJ(addr, false); return GPU.ReadVRAM_BOBJ<u32>(addr);
        default:         GPU.SyncVRAM_LCDC(addr, false); return GPU.ReadVRAM_LCDC<u32>(addr);
        }

    case 0x07000000:
        if (!(PowerControl9 & ((addr & 0x400) ? (1<<9) : (1<<1)))) return 0;
        return GPU.ReadOAM<u32>(addr & 0x7FF);

    case 0x08000000:
    case 0x09000000:
        if (ExMemCnt[0] & (1<<7)) return 0x00000000; // deselected CPU is 00h-filled
        return GBACartSlot.ROMRead(addr) |
              (GBACartSlot.ROMRead(addr+2) << 16);

    case 0x0A000000:
        if (ExMemCnt[0] & (1<<7)) return 0x00000000; // deselected CPU is 00h-filled
        return GBACartSlot.SRAMRead(addr) |
              (GBACartSlot.SRAMRead(addr+1) << 8) |
              (GBACartSlot.SRAMRead(addr+2) << 16) |
              (GBACartSlot.SRAMRead(addr+3) << 24);
    }

    //Log(LogLevel::Warn, "unknown arm9 read32 %08X | %08X %08X\n", addr, ARM9.R[15], ARM9.R[12]);
    return 0;
}

void NDS::ARM9Write8(u32 addr, u8 val)
{
    switch (addr & 0xFF000000)
    {
    case 0x02000000:
        JIT.CheckAndInvalidate<0, ARMJIT_Memory::memregion_MainRAM>(addr);
        *(u8*)&MainRAM[addr & MainRAMMask] = val;
        return;

    case 0x03000000:
        if (SWRAM_ARM9.Mem)
        {
            JIT.CheckAndInvalidate<0, ARMJIT_Memory::memregion_SharedWRAM>(addr);
            *(u8*)&SWRAM_ARM9.Mem[addr & SWRAM_ARM9.Mask] = val;
        }
        return;

    case 0x04000000:
        NDS::ARM9IOWrite8(addr, val);
        return;

    case 0x05000000:
    case 0x06000000:
    case 0x07000000:
        return;

    case 0x08000000:
    case 0x09000000:
        return;

    case 0x0A000000:
        if (ExMemCnt[0] & (1<<7)) return; // deselected CPU, skip the write
        GBACartSlot.SRAMWrite(addr, val);
        return;
    }

    Log(LogLevel::Debug, "unknown arm9 write8 %08X %02X\n", addr, val);
}

void NDS::ARM9Write16(u32 addr, u16 val)
{
    addr &= ~0x1;

    switch (addr & 0xFF000000)
    {
    case 0x02000000:
        JIT.CheckAndInvalidate<0, ARMJIT_Memory::memregion_MainRAM>(addr);
        *(u16*)&MainRAM[addr & MainRAMMask] = val;
        return;

    case 0x03000000:
        if (SWRAM_ARM9.Mem)
        {
            JIT.CheckAndInvalidate<0, ARMJIT_Memory::memregion_SharedWRAM>(addr);
            *(u16*)&SWRAM_ARM9.Mem[addr & SWRAM_ARM9.Mask] = val;
        }
        return;

    case 0x04000000:
        NDS::ARM9IOWrite16(addr, val);
        return;

    case 0x05000000:
        if (!(PowerControl9 & ((addr & 0x400) ? (1<<9) : (1<<1)))) return;
        GPU.WritePalette<u16>(addr, val);
        return;

    case 0x06000000:
        JIT.CheckAndInvalidate<0, ARMJIT_Memory::memregion_VRAM>(addr);
        switch (addr & 0x00E00000)
        {
        case 0x00000000: GPU.SyncVRAM_ABG(addr, true); GPU.WriteVRAM_ABG<u16>(addr, val); return;
        case 0x00200000: GPU.SyncVRAM_BBG(addr, true); GPU.WriteVRAM_BBG<u16>(addr, val); return;
        case 0x00400000: GPU.SyncVRAM_AOBJ(addr, true); GPU.WriteVRAM_AOBJ<u16>(addr, val); return;
        case 0x00600000: GPU.SyncVRAM_BOBJ(addr, true); GPU.WriteVRAM_BOBJ<u16>(addr, val); return;
        default: GPU.SyncVRAM_LCDC(addr, true); GPU.WriteVRAM_LCDC<u16>(addr, val); return;
        }

    case 0x07000000:
        if (!(PowerControl9 & ((addr & 0x400) ? (1<<9) : (1<<1)))) return;
        GPU.WriteOAM<u16>(addr, val);
        return;

    case 0x08000000:
    case 0x09000000:
        if (ExMemCnt[0] & (1<<7)) return; // deselected CPU, skip the write
        GBACartSlot.ROMWrite(addr, val);
        return;

    case 0x0A000000:
        if (ExMemCnt[0] & (1<<7)) return; // deselected CPU, skip the write
        GBACartSlot.SRAMWrite(addr, val & 0xFF);
        GBACartSlot.SRAMWrite(addr+1, val >> 8);
        return;
    }

    //if (addr) Log(LogLevel::Warn, "unknown arm9 write16 %08X %04X\n", addr, val);
}

void NDS::ARM9Write32(u32 addr, u32 val)
{
    addr &= ~0x3;

    switch (addr & 0xFF000000)
    {
    case 0x02000000:
        JIT.CheckAndInvalidate<0, ARMJIT_Memory::memregion_MainRAM>(addr);
        *(u32*)&MainRAM[addr & MainRAMMask] = val;
        return ;

    case 0x03000000:
        if (SWRAM_ARM9.Mem)
        {
            JIT.CheckAndInvalidate<0, ARMJIT_Memory::memregion_SharedWRAM>(addr);
            *(u32*)&SWRAM_ARM9.Mem[addr & SWRAM_ARM9.Mask] = val;
        }
        return;

    case 0x04000000:
        NDS::ARM9IOWrite32(addr, val);
        return;

    case 0x05000000:
        if (!(PowerControl9 & ((addr & 0x400) ? (1<<9) : (1<<1)))) return;
        GPU.WritePalette(addr, val);
        return;

    case 0x06000000:
        JIT.CheckAndInvalidate<0, ARMJIT_Memory::memregion_VRAM>(addr);
        switch (addr & 0x00E00000)
        {
        case 0x00000000: GPU.SyncVRAM_ABG(addr, true); GPU.WriteVRAM_ABG<u32>(addr, val); return;
        case 0x00200000: GPU.SyncVRAM_BBG(addr, true); GPU.WriteVRAM_BBG<u32>(addr, val); return;
        case 0x00400000: GPU.SyncVRAM_AOBJ(addr, true); GPU.WriteVRAM_AOBJ<u32>(addr, val); return;
        case 0x00600000: GPU.SyncVRAM_BOBJ(addr, true); GPU.WriteVRAM_BOBJ<u32>(addr, val); return;
        default: GPU.SyncVRAM_LCDC(addr, true); GPU.WriteVRAM_LCDC<u32>(addr, val); return;
        }

    case 0x07000000:
        if (!(PowerControl9 & ((addr & 0x400) ? (1<<9) : (1<<1)))) return;
        GPU.WriteOAM<u32>(addr, val);
        return;

    case 0x08000000:
    case 0x09000000:
        if (ExMemCnt[0] & (1<<7)) return; // deselected CPU, skip the write
        GBACartSlot.ROMWrite(addr, val & 0xFFFF);
        GBACartSlot.ROMWrite(addr+2, val >> 16);
        return;

    case 0x0A000000:
        if (ExMemCnt[0] & (1<<7)) return; // deselected CPU, skip the write
        GBACartSlot.SRAMWrite(addr, val & 0xFF);
        GBACartSlot.SRAMWrite(addr+1, (val >> 8) & 0xFF);
        GBACartSlot.SRAMWrite(addr+2, (val >> 16) & 0xFF);
        GBACartSlot.SRAMWrite(addr+3, val >> 24);
        return;
    }

    //Log(LogLevel::Warn, "unknown arm9 write32 %08X %08X | %08X\n", addr, val, ARM9.R[15]);
}

bool NDS::ARM9GetMemRegion(u32 addr, bool write, MemRegion* region)
{
    switch (addr & 0xFF000000)
    {
    case 0x02000000:
        region->Mem = MainRAM;
        region->Mask = MainRAMMask;
        return true;

    case 0x03000000:
        if (SWRAM_ARM9.Mem)
        {
            region->Mem = SWRAM_ARM9.Mem;
            region->Mask = SWRAM_ARM9.Mask;
            return true;
        }
        break;
    }

    if ((addr & 0xFFFFF000) == 0xFFFF0000 && !write)
    {
        region->Mem = &ARM9BIOS[0];
        region->Mask = 0xFFF;
        return true;
    }

    region->Mem = NULL;
    return false;
}



u8 NDS::ARM7Read8(u32 addr)
{
    if (addr < 0x00004000)
    {
        // TODO: check the boundary? is it 4000 or higher on regular DS?
        if (ARM7.R[15] >= 0x00004000)
            return 0xFF;
        if (addr < ARM7BIOSProt && ARM7.R[15] >= ARM7BIOSProt)
            return 0xFF;

        return *(u8*)&ARM7BIOS[addr];
    }

    switch (addr & 0xFF800000)
    {
    case 0x02000000:
    case 0x02800000:
        return *(u8*)&MainRAM[addr & MainRAMMask];

    case 0x03000000:
        if (SWRAM_ARM7.Mem)
        {
            return *(u8*)&SWRAM_ARM7.Mem[addr & SWRAM_ARM7.Mask];
        }
        else
        {
            return *(u8*)&ARM7WRAM[addr & (ARM7WRAMSize - 1)];
        }

    case 0x03800000:
        return *(u8*)&ARM7WRAM[addr & (ARM7WRAMSize - 1)];

    case 0x04000000:
        return NDS::ARM7IORead8(addr);

    case 0x04800000:
        if (addr < 0x04810000)
        {
            if (!(PowerControl7 & (1<<1))) return 0;
            if (addr & 0x1) return Wifi.Read(addr-1) >> 8;
            return Wifi.Read(addr) & 0xFF;
        }
        break;

    case 0x06000000:
    case 0x06800000:
        return GPU.ReadVRAM_ARM7<u8>(addr);

    case 0x08000000:
    case 0x08800000:
    case 0x09000000:
    case 0x09800000:
        if (!(ExMemCnt[0] & (1<<7))) return 0x00; // deselected CPU is 00h-filled
        if (addr & 0x1) return GBACartSlot.ROMRead(addr-1) >> 8;
        return GBACartSlot.ROMRead(addr) & 0xFF;

    case 0x0A000000:
    case 0x0A800000:
        if (!(ExMemCnt[0] & (1<<7))) return 0x00; // deselected CPU is 00h-filled
        return GBACartSlot.SRAMRead(addr);
    }

    Log(LogLevel::Debug, "unknown arm7 read8 %08X %08X %08X/%08X\n", addr, ARM7.R[15], ARM7.R[0], ARM7.R[1]);
    return 0;
}

u16 NDS::ARM7Read16(u32 addr)
{
    addr &= ~0x1;

    if (addr < 0x00004000)
    {
        if (ARM7.R[15] >= 0x00004000)
            return 0xFFFF;
        if (addr < ARM7BIOSProt && ARM7.R[15] >= ARM7BIOSProt)
            return 0xFFFF;

        return *(u16*)&ARM7BIOS[addr];
    }

    switch (addr & 0xFF800000)
    {
    case 0x02000000:
    case 0x02800000:
        return *(u16*)&MainRAM[addr & MainRAMMask];

    case 0x03000000:
        if (SWRAM_ARM7.Mem)
        {
            return *(u16*)&SWRAM_ARM7.Mem[addr & SWRAM_ARM7.Mask];
        }
        else
        {
            return *(u16*)&ARM7WRAM[addr & (ARM7WRAMSize - 1)];
        }

    case 0x03800000:
        return *(u16*)&ARM7WRAM[addr & (ARM7WRAMSize - 1)];

    case 0x04000000:
        return NDS::ARM7IORead16(addr);

    case 0x04800000:
        if (addr < 0x04810000)
        {
            if (!(PowerControl7 & (1<<1))) return 0;
            return Wifi.Read(addr);
        }
        break;

    case 0x06000000:
    case 0x06800000:
        return GPU.ReadVRAM_ARM7<u16>(addr);

    case 0x08000000:
    case 0x08800000:
    case 0x09000000:
    case 0x09800000:
        if (!(ExMemCnt[0] & (1<<7))) return 0x0000; // deselected CPU is 00h-filled
        return GBACartSlot.ROMRead(addr);

    case 0x0A000000:
    case 0x0A800000:
        if (!(ExMemCnt[0] & (1<<7))) return 0x0000; // deselected CPU is 00h-filled
        return GBACartSlot.SRAMRead(addr) |
              (GBACartSlot.SRAMRead(addr+1) << 8);
    }

    Log(LogLevel::Debug, "unknown arm7 read16 %08X %08X\n", addr, ARM7.R[15]);
    return 0;
}

u32 NDS::ARM7Read32(u32 addr)
{
    addr &= ~0x3;

    if (addr < 0x00004000)
    {
        if (ARM7.R[15] >= 0x00004000)
            return 0xFFFFFFFF;
        if (addr < ARM7BIOSProt && ARM7.R[15] >= ARM7BIOSProt)
            return 0xFFFFFFFF;

        return *(u32*)&ARM7BIOS[addr];
    }

    switch (addr & 0xFF800000)
    {
    case 0x02000000:
    case 0x02800000:
        return *(u32*)&MainRAM[addr & MainRAMMask];

    case 0x03000000:
        if (SWRAM_ARM7.Mem)
        {
            return *(u32*)&SWRAM_ARM7.Mem[addr & SWRAM_ARM7.Mask];
        }
        else
        {
            return *(u32*)&ARM7WRAM[addr & (ARM7WRAMSize - 1)];
        }

    case 0x03800000:
        return *(u32*)&ARM7WRAM[addr & (ARM7WRAMSize - 1)];

    case 0x04000000:
        return NDS::ARM7IORead32(addr);

    case 0x04800000:
        if (addr < 0x04810000)
        {
            if (!(PowerControl7 & (1<<1))) return 0;
            return Wifi.Read(addr) | (Wifi.Read(addr+2) << 16);
        }
        break;

    case 0x06000000:
    case 0x06800000:
        return GPU.ReadVRAM_ARM7<u32>(addr);

    case 0x08000000:
    case 0x08800000:
    case 0x09000000:
    case 0x09800000:
        if (!(ExMemCnt[0] & (1<<7))) return 0x00000000; // deselected CPU is 00h-filled
        return GBACartSlot.ROMRead(addr) |
              (GBACartSlot.ROMRead(addr+2) << 16);

    case 0x0A000000:
    case 0x0A800000:
        if (!(ExMemCnt[0] & (1<<7))) return 0x00000000; // deselected CPU is 00h-filled
        return GBACartSlot.SRAMRead(addr) |
              (GBACartSlot.SRAMRead(addr+1) << 8) |
              (GBACartSlot.SRAMRead(addr+2) << 16) |
              (GBACartSlot.SRAMRead(addr+3) << 24);
    }

    //Log(LogLevel::Warn, "unknown arm7 read32 %08X | %08X\n", addr, ARM7.R[15]);
    return 0;
}

void NDS::ARM7Write8(u32 addr, u8 val)
{
    switch (addr & 0xFF800000)
    {
    case 0x02000000:
    case 0x02800000:
        JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_MainRAM>(addr);
        *(u8*)&MainRAM[addr & MainRAMMask] = val;
        return;

    case 0x03000000:
        if (SWRAM_ARM7.Mem)
        {
            JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_SharedWRAM>(addr);
            *(u8*)&SWRAM_ARM7.Mem[addr & SWRAM_ARM7.Mask] = val;
            return;
        }
        else
        {
            JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_WRAM7>(addr);
            *(u8*)&ARM7WRAM[addr & (ARM7WRAMSize - 1)] = val;
            return;
        }

    case 0x03800000:
        JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_WRAM7>(addr);
        *(u8*)&ARM7WRAM[addr & (ARM7WRAMSize - 1)] = val;
        return;

    case 0x04000000:
        NDS::ARM7IOWrite8(addr, val);
        return;

    case 0x06000000:
    case 0x06800000:
        JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_VWRAM>(addr);
        GPU.WriteVRAM_ARM7<u8>(addr, val);
        return;

    case 0x08000000:
    case 0x08800000:
    case 0x09000000:
    case 0x09800000:
        return;

    case 0x0A000000:
    case 0x0A800000:
        if (!(ExMemCnt[0] & (1<<7))) return; // deselected CPU, skip the write
        GBACartSlot.SRAMWrite(addr, val);
        return;
    }

    //if (ARM7.R[15] > 0x00002F30) // ARM7 BIOS bug
    if (addr >= 0x01000000)
        Log(LogLevel::Debug, "unknown arm7 write8 %08X %02X @ %08X\n", addr, val, ARM7.R[15]);
}

void NDS::ARM7Write16(u32 addr, u16 val)
{
    addr &= ~0x1;

    switch (addr & 0xFF800000)
    {
    case 0x02000000:
    case 0x02800000:
        JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_MainRAM>(addr);
        *(u16*)&MainRAM[addr & MainRAMMask] = val;
        return;

    case 0x03000000:
        if (SWRAM_ARM7.Mem)
        {
            JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_SharedWRAM>(addr);
            *(u16*)&SWRAM_ARM7.Mem[addr & SWRAM_ARM7.Mask] = val;
            return;
        }
        else
        {
            JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_WRAM7>(addr);
            *(u16*)&ARM7WRAM[addr & (ARM7WRAMSize - 1)] = val;
            return;
        }

    case 0x03800000:
        JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_WRAM7>(addr);
        *(u16*)&ARM7WRAM[addr & (ARM7WRAMSize - 1)] = val;
        return;

    case 0x04000000:
        NDS::ARM7IOWrite16(addr, val);
        return;

    case 0x04800000:
        if (addr < 0x04810000)
        {
            if (!(PowerControl7 & (1<<1))) return;
            Wifi.Write(addr, val);
            return;
        }
        break;

    case 0x06000000:
    case 0x06800000:
        JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_VWRAM>(addr);
        GPU.WriteVRAM_ARM7<u16>(addr, val);
        return;

    case 0x08000000:
    case 0x08800000:
    case 0x09000000:
    case 0x09800000:
        if (!(ExMemCnt[0] & (1<<7))) return; // deselected CPU, skip the write
        GBACartSlot.ROMWrite(addr, val);
        return;

    case 0x0A000000:
    case 0x0A800000:
        if (!(ExMemCnt[0] & (1<<7))) return; // deselected CPU, skip the write
        GBACartSlot.SRAMWrite(addr, val & 0xFF);
        GBACartSlot.SRAMWrite(addr+1, val >> 8);
        return;
    }

    if (addr >= 0x01000000)
        Log(LogLevel::Debug, "unknown arm7 write16 %08X %04X @ %08X\n", addr, val, ARM7.R[15]);
}

void NDS::ARM7Write32(u32 addr, u32 val)
{
    addr &= ~0x3;

    switch (addr & 0xFF800000)
    {
    case 0x02000000:
    case 0x02800000:
        JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_MainRAM>(addr);
        *(u32*)&MainRAM[addr & MainRAMMask] = val;
        return;

    case 0x03000000:
        if (SWRAM_ARM7.Mem)
        {
            JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_SharedWRAM>(addr);
            *(u32*)&SWRAM_ARM7.Mem[addr & SWRAM_ARM7.Mask] = val;
            return;
        }
        else
        {
            JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_WRAM7>(addr);
            *(u32*)&ARM7WRAM[addr & (ARM7WRAMSize - 1)] = val;
            return;
        }

    case 0x03800000:
        JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_WRAM7>(addr);
        *(u32*)&ARM7WRAM[addr & (ARM7WRAMSize - 1)] = val;
        return;

    case 0x04000000:
        NDS::ARM7IOWrite32(addr, val);
        return;

    case 0x04800000:
        if (addr < 0x04810000)
        {
            if (!(PowerControl7 & (1<<1))) return;
            Wifi.Write(addr, val & 0xFFFF);
            Wifi.Write(addr+2, val >> 16);
            return;
        }
        break;

    case 0x06000000:
    case 0x06800000:
        JIT.CheckAndInvalidate<1, ARMJIT_Memory::memregion_VWRAM>(addr);
        GPU.WriteVRAM_ARM7<u32>(addr, val);
        return;

    case 0x08000000:
    case 0x08800000:
    case 0x09000000:
    case 0x09800000:
        if (!(ExMemCnt[0] & (1<<7))) return; // deselected CPU, skip the write
        GBACartSlot.ROMWrite(addr, val & 0xFFFF);
        GBACartSlot.ROMWrite(addr+2, val >> 16);
        return;

    case 0x0A000000:
    case 0x0A800000:
        if (!(ExMemCnt[0] & (1<<7))) return; // deselected CPU, skip the write
        GBACartSlot.SRAMWrite(addr, val & 0xFF);
        GBACartSlot.SRAMWrite(addr+1, (val >> 8) & 0xFF);
        GBACartSlot.SRAMWrite(addr+2, (val >> 16) & 0xFF);
        GBACartSlot.SRAMWrite(addr+3, val >> 24);
        return;
    }

    if (addr >= 0x01000000)
        Log(LogLevel::Debug, "unknown arm7 write32 %08X %08X @ %08X\n", addr, val, ARM7.R[15]);
}

bool NDS::ARM7GetMemRegion(u32 addr, bool write, MemRegion* region)
{
    switch (addr & 0xFF800000)
    {
    case 0x02000000:
    case 0x02800000:
        region->Mem = MainRAM;
        region->Mask = MainRAMMask;
        return true;

    case 0x03000000:
        // note on this, and why we can only cover it in one particular case:
        // it is typical for games to map all shared WRAM to the ARM7
        // then access all the WRAM as one contiguous block starting at 0x037F8000
        // this case needs a bit of a hack to cover
        // it's not really worth bothering anyway
        if (!SWRAM_ARM7.Mem)
        {
            region->Mem = ARM7WRAM;
            region->Mask = ARM7WRAMSize-1;
            return true;
        }
        break;

    case 0x03800000:
        region->Mem = ARM7WRAM;
        region->Mask = ARM7WRAMSize-1;
        return true;
    }

    // BIOS. ARM7 PC has to be within range.
    if (addr < 0x00004000 && !write)
    {
        if (ARM7.R[15] < 0x4000 && (addr >= ARM7BIOSProt || ARM7.R[15] < ARM7BIOSProt))
        {
            region->Mem = &ARM7BIOS[0];
            region->Mask = 0x3FFF;
            return true;
        }
    }

    region->Mem = NULL;
    return false;
}




#define CASE_READ8_16BIT(addr, val) \
    case (addr): return (val) & 0xFF; \
    case (addr+1): return (val) >> 8;

#define CASE_READ8_32BIT(addr, val) \
    case (addr): return (val) & 0xFF; \
    case (addr+1): return ((val) >> 8) & 0xFF; \
    case (addr+2): return ((val) >> 16) & 0xFF; \
    case (addr+3): return (val) >> 24;

u8 NDS::ARM9IORead8(u32 addr)
{
    switch (addr)
    {
    case 0x04000004: return GPU.DispStat[0] & 0xFF;
    case 0x04000005: return GPU.DispStat[0] >> 8;
    case 0x04000006: return GPU.VCount & 0xFF;
    case 0x04000007: return GPU.VCount >> 8;

    case 0x04000064:
    case 0x04000065:
    case 0x04000066:
    case 0x04000067:
    case 0x0400006C:
    case 0x0400006D:
    case 0x0400106C:
    case 0x0400106D: return GPU.Read8(addr);

    case 0x04000130: LagFrameFlag = false; return KeyInput & 0xFF;
    case 0x04000131: LagFrameFlag = false; return (KeyInput >> 8) & 0xFF;
    case 0x04000132: return KeyCnt[0] & 0xFF;
    case 0x04000133: return KeyCnt[0] >> 8;

    case 0x04000180: return IPCSync9 & 0xFF;
    case 0x04000181: return IPCSync9 >> 8;

    case 0x040001A0: return NDSCartSlots[0]->ReadSPICnt(0) & 0xFF;
    case 0x040001A1: return NDSCartSlots[0]->ReadSPICnt(0) >> 8;
    case 0x040001A2: return NDSCartSlots[0]->ReadSPIData(0);
    case 0x040001A4: return NDSCartSlots[0]->ReadROMCnt(0) & 0xFF;
    case 0x040001A5: return (NDSCartSlots[0]->ReadROMCnt(0) >> 8) & 0xFF;
    case 0x040001A6: return (NDSCartSlots[0]->ReadROMCnt(0) >> 16) & 0xFF;
    case 0x040001A7: return NDSCartSlots[0]->ReadROMCnt(0) >> 24;

    case 0x04000208: return IME[0];

    case 0x04000240: return GPU.VRAMCNT[0];
    case 0x04000241: return GPU.VRAMCNT[1];
    case 0x04000242: return GPU.VRAMCNT[2];
    case 0x04000243: return GPU.VRAMCNT[3];
    case 0x04000244: return GPU.VRAMCNT[4];
    case 0x04000245: return GPU.VRAMCNT[5];
    case 0x04000246: return GPU.VRAMCNT[6];
    case 0x04000247: return WRAMCnt;
    case 0x04000248: return GPU.VRAMCNT[7];
    case 0x04000249: return GPU.VRAMCNT[8];

    CASE_READ8_16BIT(0x04000280, DivCnt)
    CASE_READ8_32BIT(0x04000290, DivNumerator[0])
    CASE_READ8_32BIT(0x04000294, DivNumerator[1])
    CASE_READ8_32BIT(0x04000298, DivDenominator[0])
    CASE_READ8_32BIT(0x0400029C, DivDenominator[1])
    CASE_READ8_32BIT(0x040002A0, DivQuotient[0])
    CASE_READ8_32BIT(0x040002A4, DivQuotient[1])
    CASE_READ8_32BIT(0x040002A8, DivRemainder[0])
    CASE_READ8_32BIT(0x040002AC, DivRemainder[1])

    CASE_READ8_16BIT(0x040002B0, SqrtCnt)
    CASE_READ8_32BIT(0x040002B4, SqrtRes)
    CASE_READ8_32BIT(0x040002B8, SqrtVal[0])
    CASE_READ8_32BIT(0x040002BC, SqrtVal[1])

    case 0x04000300: return PostFlag9;
    }

    if (addr >= 0x04000000 && addr < 0x04000060)
    {
        return GPU.GPU2D_A.Read8(addr);
    }
    if (addr >= 0x04001000 && addr < 0x04001060)
    {
        return GPU.GPU2D_B.Read8(addr);
    }
    if (addr >= 0x04000320 && addr < 0x040006A4)
    {
        return GPU.GPU3D.Read8(addr);
    }
    // NO$GBA debug register "Emulation ID"
    if(addr >= 0x04FFFA00 && addr < 0x04FFFA10)
    {
        // FIX: GBATek says this should be padded with spaces
        static char const emuID[16] = "melonDS " MELONDS_VERSION_BASE;
        auto idx = addr - 0x04FFFA00;
        return (u8)(emuID[idx]);
    }

    if ((addr & 0xFFFFF000) != 0x04004000)
        Log(LogLevel::Debug, "unknown ARM9 IO read8 %08X %08X\n", addr, ARM9.R[15]);
    return 0;
}

u16 NDS::ARM9IORead16(u32 addr)
{
    switch (addr)
    {
    case 0x04000004: return GPU.DispStat[0];
    case 0x04000006: return GPU.VCount;

    case 0x04000060: return GPU.GPU3D.Read16(addr);
    case 0x04000064:
    case 0x04000066:
    case 0x0400006C:
    case 0x0400106C: return GPU.Read16(addr);

    case 0x040000B8: return DMAs[0].Cnt & 0xFFFF;
    case 0x040000BA: return DMAs[0].Cnt >> 16;
    case 0x040000C4: return DMAs[1].Cnt & 0xFFFF;
    case 0x040000C6: return DMAs[1].Cnt >> 16;
    case 0x040000D0: return DMAs[2].Cnt & 0xFFFF;
    case 0x040000D2: return DMAs[2].Cnt >> 16;
    case 0x040000DC: return DMAs[3].Cnt & 0xFFFF;
    case 0x040000DE: return DMAs[3].Cnt >> 16;

    case 0x040000E0: return ((u16*)DMA9Fill)[0];
    case 0x040000E2: return ((u16*)DMA9Fill)[1];
    case 0x040000E4: return ((u16*)DMA9Fill)[2];
    case 0x040000E6: return ((u16*)DMA9Fill)[3];
    case 0x040000E8: return ((u16*)DMA9Fill)[4];
    case 0x040000EA: return ((u16*)DMA9Fill)[5];
    case 0x040000EC: return ((u16*)DMA9Fill)[6];
    case 0x040000EE: return ((u16*)DMA9Fill)[7];

    case 0x04000100: return TimerGetCounter(0);
    case 0x04000102: return Timers[0].Cnt;
    case 0x04000104: return TimerGetCounter(1);
    case 0x04000106: return Timers[1].Cnt;
    case 0x04000108: return TimerGetCounter(2);
    case 0x0400010A: return Timers[2].Cnt;
    case 0x0400010C: return TimerGetCounter(3);
    case 0x0400010E: return Timers[3].Cnt;

    case 0x04000130: LagFrameFlag = false; return KeyInput & 0xFFFF;
    case 0x04000132: return KeyCnt[0];

    case 0x04000180: return IPCSync9;
    case 0x04000184:
        {
            u16 val = IPCFIFOCnt9;
            if (IPCFIFO9.IsEmpty())     val |= 0x0001;
            else if (IPCFIFO9.IsFull()) val |= 0x0002;
            if (IPCFIFO7.IsEmpty())     val |= 0x0100;
            else if (IPCFIFO7.IsFull()) val |= 0x0200;
            return val;
        }

    case 0x040001A0: return NDSCartSlots[0]->ReadSPICnt(0);
    case 0x040001A2: return NDSCartSlots[0]->ReadSPIData(0);
    case 0x040001A4: return NDSCartSlots[0]->ReadROMCnt(0) & 0xFFFF;
    case 0x040001A6: return NDSCartSlots[0]->ReadROMCnt(0) >> 16;

    case 0x04000204: return ExMemCnt[0];
    case 0x04000208: return IME[0];
    case 0x04000210: return IE[0] & 0xFFFF;
    case 0x04000212: return IE[0] >> 16;
    case 0x04000214: return IF[0] & 0xFFFF;
    case 0x04000216: return IF[0] >> 16;

    case 0x04000240: return GPU.VRAMCNT[0] | (GPU.VRAMCNT[1] << 8);
    case 0x04000242: return GPU.VRAMCNT[2] | (GPU.VRAMCNT[3] << 8);
    case 0x04000244: return GPU.VRAMCNT[4] | (GPU.VRAMCNT[5] << 8);
    case 0x04000246: return GPU.VRAMCNT[6] | (WRAMCnt << 8);
    case 0x04000248: return GPU.VRAMCNT[7] | (GPU.VRAMCNT[8] << 8);

    case 0x04000280: return DivCnt;
    case 0x04000290: return DivNumerator[0] & 0xFFFF;
    case 0x04000292: return DivNumerator[0] >> 16;
    case 0x04000294: return DivNumerator[1] & 0xFFFF;
    case 0x04000296: return DivNumerator[1] >> 16;
    case 0x04000298: return DivDenominator[0] & 0xFFFF;
    case 0x0400029A: return DivDenominator[0] >> 16;
    case 0x0400029C: return DivDenominator[1] & 0xFFFF;
    case 0x0400029E: return DivDenominator[1] >> 16;
    case 0x040002A0: return DivQuotient[0] & 0xFFFF;
    case 0x040002A2: return DivQuotient[0] >> 16;
    case 0x040002A4: return DivQuotient[1] & 0xFFFF;
    case 0x040002A6: return DivQuotient[1] >> 16;
    case 0x040002A8: return DivRemainder[0] & 0xFFFF;
    case 0x040002AA: return DivRemainder[0] >> 16;
    case 0x040002AC: return DivRemainder[1] & 0xFFFF;
    case 0x040002AE: return DivRemainder[1] >> 16;

    case 0x040002B0: return SqrtCnt;
    case 0x040002B4: return SqrtRes & 0xFFFF;
    case 0x040002B6: return SqrtRes >> 16;
    case 0x040002B8: return SqrtVal[0] & 0xFFFF;
    case 0x040002BA: return SqrtVal[0] >> 16;
    case 0x040002BC: return SqrtVal[1] & 0xFFFF;
    case 0x040002BE: return SqrtVal[1] >> 16;

    case 0x04000300: return PostFlag9;
    case 0x04000304: return PowerControl9;

    case 0x04004000:
    case 0x04004004:
    case 0x04004010:
        // shut up logging for DSi registers
        return 0;
    }

    if ((addr >= 0x04000000 && addr < 0x04000060) || (addr == 0x0400006C))
    {
        return GPU.GPU2D_A.Read16(addr);
    }
    if ((addr >= 0x04001000 && addr < 0x04001060) || (addr == 0x0400106C))
    {
        return GPU.GPU2D_B.Read16(addr);
    }
    if (addr >= 0x04000320 && addr < 0x040006A4)
    {
        return GPU.GPU3D.Read16(addr);
    }

    if ((addr & 0xFFFFF000) != 0x04004000)
        Log(LogLevel::Debug, "unknown ARM9 IO read16 %08X %08X\n", addr, ARM9.R[15]);
    return 0;
}

u32 NDS::ARM9IORead32(u32 addr)
{
    switch (addr)
    {
    case 0x04000004: return GPU.DispStat[0] | (GPU.VCount << 16);

    case 0x04000060: return GPU.GPU3D.Read32(addr);
    case 0x04000064:
    case 0x0400006C:
    case 0x0400106C: return GPU.Read32(addr);

    case 0x040000B0: return DMAs[0].SrcAddr;
    case 0x040000B4: return DMAs[0].DstAddr;
    case 0x040000B8: return DMAs[0].Cnt;
    case 0x040000BC: return DMAs[1].SrcAddr;
    case 0x040000C0: return DMAs[1].DstAddr;
    case 0x040000C4: return DMAs[1].Cnt;
    case 0x040000C8: return DMAs[2].SrcAddr;
    case 0x040000CC: return DMAs[2].DstAddr;
    case 0x040000D0: return DMAs[2].Cnt;
    case 0x040000D4: return DMAs[3].SrcAddr;
    case 0x040000D8: return DMAs[3].DstAddr;
    case 0x040000DC: return DMAs[3].Cnt;

    case 0x040000E0: return DMA9Fill[0];
    case 0x040000E4: return DMA9Fill[1];
    case 0x040000E8: return DMA9Fill[2];
    case 0x040000EC: return DMA9Fill[3];

    case 0x040000F4: return 0; // ???? Golden Sun Dark Dawn keeps reading this

    case 0x04000100: return TimerGetCounter(0) | (Timers[0].Cnt << 16);
    case 0x04000104: return TimerGetCounter(1) | (Timers[1].Cnt << 16);
    case 0x04000108: return TimerGetCounter(2) | (Timers[2].Cnt << 16);
    case 0x0400010C: return TimerGetCounter(3) | (Timers[3].Cnt << 16);

    case 0x04000130: LagFrameFlag = false; return (KeyInput & 0xFFFF) | (KeyCnt[0] << 16);

    case 0x04000180: return IPCSync9;
    case 0x04000184: return NDS::ARM9IORead16(addr);

    case 0x040001A0: return NDSCartSlots[0]->ReadSPICnt(0) | (NDSCartSlots[0]->ReadSPIData(0) << 16);
    case 0x040001A4: return NDSCartSlots[0]->ReadROMCnt(0);

    case 0x04000208: return IME[0];
    case 0x04000210: return IE[0];
    case 0x04000214: return IF[0];

    case 0x04000240: return GPU.VRAMCNT[0] | (GPU.VRAMCNT[1] << 8) | (GPU.VRAMCNT[2] << 16) | (GPU.VRAMCNT[3] << 24);
    case 0x04000244: return GPU.VRAMCNT[4] | (GPU.VRAMCNT[5] << 8) | (GPU.VRAMCNT[6] << 16) | (WRAMCnt << 24);
    case 0x04000248: return GPU.VRAMCNT[7] | (GPU.VRAMCNT[8] << 8);

    case 0x04000280: return DivCnt;
    case 0x04000290: return DivNumerator[0];
    case 0x04000294: return DivNumerator[1];
    case 0x04000298: return DivDenominator[0];
    case 0x0400029C: return DivDenominator[1];
    case 0x040002A0: return DivQuotient[0];
    case 0x040002A4: return DivQuotient[1];
    case 0x040002A8: return DivRemainder[0];
    case 0x040002AC: return DivRemainder[1];

    case 0x040002B0: return SqrtCnt;
    case 0x040002B4: return SqrtRes;
    case 0x040002B8: return SqrtVal[0];
    case 0x040002BC: return SqrtVal[1];

    case 0x04000300: return PostFlag9;
    case 0x04000304: return PowerControl9;

    case 0x04100000:
        if (IPCFIFOCnt9 & 0x8000)
        {
            u32 ret;
            if (IPCFIFO7.IsEmpty())
            {
                IPCFIFOCnt9 |= 0x4000;
                ret = IPCFIFO7.Peek();
            }
            else
            {
                ret = IPCFIFO7.Read();

                if (IPCFIFO7.IsEmpty() && (IPCFIFOCnt7 & 0x0004))
                    SetIRQ(1, IRQ_IPCSendDone);
            }
            return ret;
        }
        else
            return IPCFIFO7.Peek();

    case 0x04100010:
        return NDSCartSlots[0]->ReadROMData(0);

    case 0x04004000:
    case 0x04004004:
    case 0x04004010:
        // shut up logging for DSi registers
        return 0;

    // NO$GBA debug register "Clock Cycles"
    // Since it's a 64 bit reg. the CPU will access it in two parts:
    case 0x04FFFA20: return (u32)(GetSysClockCycles(0) & 0xFFFFFFFF);
    case 0x04FFFA24: return (u32)(GetSysClockCycles(0) >> 32);
    }

    if ((addr >= 0x04000000 && addr < 0x04000060) || (addr == 0x0400006C))
    {
        return GPU.GPU2D_A.Read32(addr);
    }
    if ((addr >= 0x04001000 && addr < 0x04001060) || (addr == 0x0400106C))
    {
        return GPU.GPU2D_B.Read32(addr);
    }
    if (addr >= 0x04000320 && addr < 0x040006A4)
    {
        return GPU.GPU3D.Read32(addr);
    }

    if ((addr & 0xFFFFF000) != 0x04004000)
        Log(LogLevel::Debug, "unknown ARM9 IO read32 %08X %08X\n", addr, ARM9.R[15]);
    return 0;
}

void NDS::ARM9IOWrite8(u32 addr, u8 val)
{
    switch (addr)
    {
    case 0x04000004: GPU.SetDispStat(0, val, 0x00FF); return;
    case 0x04000005: GPU.SetDispStat(0, val << 8, 0xFF00); return;
    case 0x04000006: GPU.SetVCount(val, 0x00FF); return;
    case 0x04000007: GPU.SetVCount(val << 8, 0xFF00); return;

    case 0x04000060:
    case 0x04000061: GPU.GPU3D.Write8(addr, val); return;
    case 0x04000064:
    case 0x04000065:
    case 0x04000066:
    case 0x04000067:
    case 0x04000068:
    case 0x04000069:
    case 0x0400006A:
    case 0x0400006B:
    case 0x0400006C:
    case 0x0400006D:
    case 0x0400106C:
    case 0x0400106D: GPU.Write8(addr, val); return;

    case 0x04000132:
        KeyCnt[0] = (KeyCnt[0] & 0xFF00) | val;
        return;
    case 0x04000133:
        KeyCnt[0] = (KeyCnt[0] & 0x00FF) | (val << 8);
        return;

    case 0x04000181:
        IPCSync7 &= 0xFFF0;
        IPCSync7 |= (val & 0x0F);
        IPCSync9 &= 0xB0FF;
        IPCSync9 |= ((val & 0x4F) << 8);
        if ((val & 0x20) && (IPCSync7 & 0x4000))
        {
            SetIRQ(1, IRQ_IPCSync);
        }
        return;

    case 0x04000188:
        NDS::ARM9IOWrite32(addr, val | (val << 8) | (val << 16) | (val << 24));
        return;

    case 0x040001A0:
        NDSCartSlots[0]->WriteSPICnt(0, val, 0x00FF);
        return;
    case 0x040001A1:
        NDSCartSlots[0]->WriteSPICnt(0, val << 8, 0xFF00);
        return;
    case 0x040001A2:
        NDSCartSlots[0]->WriteSPIData(0, val);
        return;

    case 0x040001A4:
        NDSCartSlots[0]->WriteROMCnt(0, val, 0x000000FF);
        return;
    case 0x040001A5:
        NDSCartSlots[0]->WriteROMCnt(0, val << 8, 0x0000FF00);
        return;
    case 0x040001A6:
        NDSCartSlots[0]->WriteROMCnt(0, val << 16, 0x00FF0000);
        return;
    case 0x040001A7:
        NDSCartSlots[0]->WriteROMCnt(0, val << 24, 0xFF000000);
        return;

    case 0x040001A8: NDSCartSlots[0]->WriteROMCommand(0, 0, val); return;
    case 0x040001A9: NDSCartSlots[0]->WriteROMCommand(0, 1, val); return;
    case 0x040001AA: NDSCartSlots[0]->WriteROMCommand(0, 2, val); return;
    case 0x040001AB: NDSCartSlots[0]->WriteROMCommand(0, 3, val); return;
    case 0x040001AC: NDSCartSlots[0]->WriteROMCommand(0, 4, val); return;
    case 0x040001AD: NDSCartSlots[0]->WriteROMCommand(0, 5, val); return;
    case 0x040001AE: NDSCartSlots[0]->WriteROMCommand(0, 6, val); return;
    case 0x040001AF: NDSCartSlots[0]->WriteROMCommand(0, 7, val); return;

    case 0x04000208: IME[0] = val & 0x1; UpdateIRQ(0); return;

    case 0x04000240: GPU.MapVRAM_AB(0, val); return;
    case 0x04000241: GPU.MapVRAM_AB(1, val); return;
    case 0x04000242: GPU.MapVRAM_CD(2, val); return;
    case 0x04000243: GPU.MapVRAM_CD(3, val); return;
    case 0x04000244: GPU.MapVRAM_E(4, val); return;
    case 0x04000245: GPU.MapVRAM_FG(5, val); return;
    case 0x04000246: GPU.MapVRAM_FG(6, val); return;
    case 0x04000247: MapSharedWRAM(val); return;
    case 0x04000248: GPU.MapVRAM_H(7, val); return;
    case 0x04000249: GPU.MapVRAM_I(8, val); return;

    case 0x04000300:
        if (PostFlag9 & 0x01) val |= 0x01;
        PostFlag9 = val & 0x03;
        return;

    // NO$GBA debug register "Char Out"
        case 0x04FFFA1C: Log(LogLevel::Debug, "%c", char(val)); return;
    }

    if (addr >= 0x04000000 && addr < 0x04000060)
    {
        GPU.GPU2D_A.Write8(addr, val);
        return;
    }
    if (addr >= 0x04001000 && addr < 0x04001060)
    {
        GPU.GPU2D_B.Write8(addr, val);
        return;
    }
    if (addr >= 0x04000320 && addr < 0x040006A4)
    {
        GPU.GPU3D.Write8(addr, val);
        return;
    }

    Log(LogLevel::Debug, "unknown ARM9 IO write8 %08X %02X %08X\n", addr, val, ARM9.R[15]);
}

void NDS::ARM9IOWrite16(u32 addr, u16 val)
{
    switch (addr)
    {
    case 0x04000004: GPU.SetDispStat(0, val, 0xFFFF); return;
    case 0x04000006: GPU.SetVCount(val, 0xFFFF); return;

    case 0x04000060: GPU.GPU3D.Write16(addr, val); return;
    case 0x04000064:
    case 0x04000066:
    case 0x04000068:
    case 0x0400006A:
    case 0x0400006C:
    case 0x0400106C: GPU.Write16(addr, val); return;

    case 0x040000B8: DMAs[0].WriteCnt((DMAs[0].Cnt & 0xFFFF0000) | val); return;
    case 0x040000BA: DMAs[0].WriteCnt((DMAs[0].Cnt & 0x0000FFFF) | (val << 16)); return;
    case 0x040000C4: DMAs[1].WriteCnt((DMAs[1].Cnt & 0xFFFF0000) | val); return;
    case 0x040000C6: DMAs[1].WriteCnt((DMAs[1].Cnt & 0x0000FFFF) | (val << 16)); return;
    case 0x040000D0: DMAs[2].WriteCnt((DMAs[2].Cnt & 0xFFFF0000) | val); return;
    case 0x040000D2: DMAs[2].WriteCnt((DMAs[2].Cnt & 0x0000FFFF) | (val << 16)); return;
    case 0x040000DC: DMAs[3].WriteCnt((DMAs[3].Cnt & 0xFFFF0000) | val); return;
    case 0x040000DE: DMAs[3].WriteCnt((DMAs[3].Cnt & 0x0000FFFF) | (val << 16)); return;

    case 0x040000E0: DMA9Fill[0] = (DMA9Fill[0] & 0xFFFF0000) | val; return;
    case 0x040000E2: DMA9Fill[0] = (DMA9Fill[0] & 0x0000FFFF) | (val << 16); return;
    case 0x040000E4: DMA9Fill[1] = (DMA9Fill[1] & 0xFFFF0000) | val; return;
    case 0x040000E6: DMA9Fill[1] = (DMA9Fill[1] & 0x0000FFFF) | (val << 16); return;
    case 0x040000E8: DMA9Fill[2] = (DMA9Fill[2] & 0xFFFF0000) | val; return;
    case 0x040000EA: DMA9Fill[2] = (DMA9Fill[2] & 0x0000FFFF) | (val << 16); return;
    case 0x040000EC: DMA9Fill[3] = (DMA9Fill[3] & 0xFFFF0000) | val; return;
    case 0x040000EE: DMA9Fill[3] = (DMA9Fill[3] & 0x0000FFFF) | (val << 16); return;

    case 0x04000100: Timers[0].Reload = val; return;
    case 0x04000102: TimerStart(0, val); return;
    case 0x04000104: Timers[1].Reload = val; return;
    case 0x04000106: TimerStart(1, val); return;
    case 0x04000108: Timers[2].Reload = val; return;
    case 0x0400010A: TimerStart(2, val); return;
    case 0x0400010C: Timers[3].Reload = val; return;
    case 0x0400010E: TimerStart(3, val); return;

    case 0x04000132:
        KeyCnt[0] = val;
        return;

    case 0x04000180:
        IPCSync7 &= 0xFFF0;
        IPCSync7 |= ((val & 0x0F00) >> 8);
        IPCSync9 &= 0xB0FF;
        IPCSync9 |= (val & 0x4F00);
        if ((val & 0x2000) && (IPCSync7 & 0x4000))
        {
            SetIRQ(1, IRQ_IPCSync);
        }
        return;

    case 0x04000184:
        if (val & 0x0008)
            IPCFIFO9.Clear();
        if ((val & 0x0004) && (!(IPCFIFOCnt9 & 0x0004)) && IPCFIFO9.IsEmpty())
            SetIRQ(0, IRQ_IPCSendDone);
        if ((val & 0x0400) && (!(IPCFIFOCnt9 & 0x0400)) && (!IPCFIFO7.IsEmpty()))
            SetIRQ(0, IRQ_IPCRecv);
        if (val & 0x4000)
            IPCFIFOCnt9 &= ~0x4000;
        IPCFIFOCnt9 = (val & 0x8404) | (IPCFIFOCnt9 & 0x4000);
        return;

    case 0x04000188:
        NDS::ARM9IOWrite32(addr, val | (val << 16));
        return;

    case 0x040001A0:
        NDSCartSlots[0]->WriteSPICnt(0, val, 0xFFFF);
        return;
    case 0x040001A2:
        NDSCartSlots[0]->WriteSPIData(0, val & 0xFF);
        return;

    case 0x040001A4:
        NDSCartSlots[0]->WriteROMCnt(0, val, 0x0000FFFF);
        return;
    case 0x040001A6:
        NDSCartSlots[0]->WriteROMCnt(0, val << 16, 0xFFFF0000);
        return;

    case 0x040001A8:
        NDSCartSlots[0]->WriteROMCommand(0, 0, val & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(0, 1, val >> 8);
        return;
    case 0x040001AA:
        NDSCartSlots[0]->WriteROMCommand(0, 2, val & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(0, 3, val >> 8);
        return;
    case 0x040001AC:
        NDSCartSlots[0]->WriteROMCommand(0, 4, val & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(0, 5, val >> 8);
        return;
    case 0x040001AE:
        NDSCartSlots[0]->WriteROMCommand(0, 6, val & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(0, 7, val >> 8);
        return;

    case 0x040001B8:
        NDSCartSlots[0]->WriteKey2Seed0(0, (u64)val << 32, 0x7F00000000ULL);
        return;
    case 0x040001BA:
        NDSCartSlots[0]->WriteKey2Seed1(0, (u64)val << 32, 0x7F00000000ULL);
        return;

    case 0x04000204:
        SetExMemCnt(0, val, 0xFFFF);
        return;

    case 0x04000208: IME[0] = val & 0x1; UpdateIRQ(0); return;
    case 0x04000210: IE[0] = (IE[0] & 0xFFFF0000) | val; UpdateIRQ(0); return;
    case 0x04000212: IE[0] = (IE[0] & 0x0000FFFF) | (val << 16); UpdateIRQ(0); return;
    // TODO: what happens when writing to IF this way??
    case 0x04000214: ClearIRQMask(0, val); GPU.GPU3D.CheckFIFOIRQ(); return;
    case 0x04000216: ClearIRQMask(0, val<<16); GPU.GPU3D.CheckFIFOIRQ(); return;

    case 0x04000240:
        GPU.MapVRAM_AB(0, val & 0xFF);
        GPU.MapVRAM_AB(1, val >> 8);
        return;
    case 0x04000242:
        GPU.MapVRAM_CD(2, val & 0xFF);
        GPU.MapVRAM_CD(3, val >> 8);
        return;
    case 0x04000244:
        GPU.MapVRAM_E(4, val & 0xFF);
        GPU.MapVRAM_FG(5, val >> 8);
        return;
    case 0x04000246:
        GPU.MapVRAM_FG(6, val & 0xFF);
        MapSharedWRAM(val >> 8);
        return;
    case 0x04000248:
        GPU.MapVRAM_H(7, val & 0xFF);
        GPU.MapVRAM_I(8, val >> 8);
        return;

    case 0x04000280: DivCnt = val; StartDiv(); return;

    case 0x040002B0: SqrtCnt = val; StartSqrt(); return;

    case 0x04000300:
        if (PostFlag9 & 0x01) val |= 0x01;
        PostFlag9 = val & 0x03;
        return;

    case 0x04000304:
        PowerControl9 = val & 0x820F;
        GPU.SetPowerCnt(PowerControl9);
        return;
    }

    if (addr >= 0x04000000 && addr < 0x04000060)
    {
        GPU.GPU2D_A.Write16(addr, val);
        return;
    }
    if (addr >= 0x04001000 && addr < 0x04001060)
    {
        GPU.GPU2D_B.Write16(addr, val);
        return;
    }
    if (addr >= 0x04000320 && addr < 0x040006A4)
    {
        GPU.GPU3D.Write16(addr, val);
        return;
    }

    Log(LogLevel::Debug, "unknown ARM9 IO write16 %08X %04X %08X\n", addr, val, ARM9.R[15]);
}

void NDS::ARM9IOWrite32(u32 addr, u32 val)
{
    switch (addr)
    {
    case 0x04000004:
        GPU.SetDispStat(0, val & 0xFFFF, 0xFFFF);
        GPU.SetVCount(val >> 16, 0xFFFF);
        return;

    case 0x04000060: GPU.GPU3D.Write32(addr, val); return;
    case 0x04000064:
    case 0x04000068:
    case 0x0400006C:
    case 0x0400106C: GPU.Write32(addr, val); return;

    case 0x040000B0: DMAs[0].SrcAddr = val; return;
    case 0x040000B4: DMAs[0].DstAddr = val; return;
    case 0x040000B8: DMAs[0].WriteCnt(val); return;
    case 0x040000BC: DMAs[1].SrcAddr = val; return;
    case 0x040000C0: DMAs[1].DstAddr = val; return;
    case 0x040000C4: DMAs[1].WriteCnt(val); return;
    case 0x040000C8: DMAs[2].SrcAddr = val; return;
    case 0x040000CC: DMAs[2].DstAddr = val; return;
    case 0x040000D0: DMAs[2].WriteCnt(val); return;
    case 0x040000D4: DMAs[3].SrcAddr = val; return;
    case 0x040000D8: DMAs[3].DstAddr = val; return;
    case 0x040000DC: DMAs[3].WriteCnt(val); return;

    case 0x040000E0: DMA9Fill[0] = val; return;
    case 0x040000E4: DMA9Fill[1] = val; return;
    case 0x040000E8: DMA9Fill[2] = val; return;
    case 0x040000EC: DMA9Fill[3] = val; return;

    case 0x04000100:
        Timers[0].Reload = val & 0xFFFF;
        TimerStart(0, val>>16);
        return;
    case 0x04000104:
        Timers[1].Reload = val & 0xFFFF;
        TimerStart(1, val>>16);
        return;
    case 0x04000108:
        Timers[2].Reload = val & 0xFFFF;
        TimerStart(2, val>>16);
        return;
    case 0x0400010C:
        Timers[3].Reload = val & 0xFFFF;
        TimerStart(3, val>>16);
        return;

    case 0x04000130:
        KeyCnt[0] = val >> 16;
        return;

    case 0x04000180:
    case 0x04000184:
        NDS::ARM9IOWrite16(addr, val);
        return;
    case 0x04000188:
        if (IPCFIFOCnt9 & 0x8000)
        {
            if (IPCFIFO9.IsFull())
                IPCFIFOCnt9 |= 0x4000;
            else
            {
                bool wasempty = IPCFIFO9.IsEmpty();
                IPCFIFO9.Write(val);
                if ((IPCFIFOCnt7 & 0x0400) && wasempty)
                    SetIRQ(1, IRQ_IPCRecv);
            }
        }
        return;

    case 0x040001A0:
        NDSCartSlots[0]->WriteSPICnt(0, val & 0xFFFF, 0xFFFF);
        NDSCartSlots[0]->WriteSPIData(0, (val >> 16) & 0xFF);
        return;
    case 0x040001A4:
        NDSCartSlots[0]->WriteROMCnt(0, val, 0xFFFFFFFF);
        return;

    case 0x040001A8:
        NDSCartSlots[0]->WriteROMCommand(0, 0, val & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(0, 1, (val >> 8) & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(0, 2, (val >> 16) & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(0, 3, val >> 24);
        return;
    case 0x040001AC:
        NDSCartSlots[0]->WriteROMCommand(0, 4, val & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(0, 5, (val >> 8) & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(0, 6, (val >> 16) & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(0, 7, val >> 24);
        return;

    case 0x040001B0:
        NDSCartSlots[0]->WriteKey2Seed0(0, (u64)val, 0x00FFFFFFFFULL);
        return;
    case 0x040001B4:
        NDSCartSlots[0]->WriteKey2Seed1(0, (u64)val, 0x00FFFFFFFFULL);
        return;

    case 0x04000208: IME[0] = val & 0x1; UpdateIRQ(0); return;
    case 0x04000210: IE[0] = val; UpdateIRQ(0); return;
    case 0x04000214: ClearIRQMask(0, val); GPU.GPU3D.CheckFIFOIRQ(); return;

    case 0x04000240:
        GPU.MapVRAM_AB(0, val & 0xFF);
        GPU.MapVRAM_AB(1, (val >> 8) & 0xFF);
        GPU.MapVRAM_CD(2, (val >> 16) & 0xFF);
        GPU.MapVRAM_CD(3, val >> 24);
        return;
    case 0x04000244:
        GPU.MapVRAM_E(4, val & 0xFF);
        GPU.MapVRAM_FG(5, (val >> 8) & 0xFF);
        GPU.MapVRAM_FG(6, (val >> 16) & 0xFF);
        MapSharedWRAM(val >> 24);
        return;
    case 0x04000248:
        GPU.MapVRAM_H(7, val & 0xFF);
        GPU.MapVRAM_I(8, (val >> 8) & 0xFF);
        return;

    case 0x04000280: DivCnt = val; StartDiv(); return;

    case 0x040002B0: SqrtCnt = val; StartSqrt(); return;

    case 0x04000290: DivNumerator[0] = val; StartDiv(); return;
    case 0x04000294: DivNumerator[1] = val; StartDiv(); return;
    case 0x04000298: DivDenominator[0] = val; StartDiv(); return;
    case 0x0400029C: DivDenominator[1] = val; StartDiv(); return;

    case 0x040002B8: SqrtVal[0] = val; StartSqrt(); return;
    case 0x040002BC: SqrtVal[1] = val; StartSqrt(); return;

    case 0x04000304:
        PowerControl9 = val & 0x820F;
        GPU.SetPowerCnt(PowerControl9);
        return;

    case 0x04100010:
        NDSCartSlots[0]->WriteROMData(0, val, 0xFFFFFFFF);
        return;

    // NO$GBA debug register "String Out (raw)"
    case 0x04FFFA10:
        {
            char output[1024] = { 0 };
            char ch = '.';
            for (size_t i = 0; i < 1023 && ch != '\0'; i++)
            {
                ch = NDS::ARM9Read8(val + i);
                output[i] = ch;
            }
            Log(LogLevel::Debug, "%s", output);
            return;
        }

    // NO$GBA debug registers "String Out (with parameters)" and "String Out (with parameters, plus linefeed)"
    case 0x04FFFA14:
    case 0x04FFFA18:
        {
            NocashPrint(0, val, 0x04FFFA18 == addr);

            return;
        }

    // NO$GBA debug register "Char Out"
        case 0x04FFFA1C: Log(LogLevel::Debug, "%c", val & 0xFF); return;
    }

    if (addr >= 0x04000000 && addr < 0x04000060)
    {
        GPU.GPU2D_A.Write32(addr, val);
        return;
    }
    if (addr >= 0x04001000 && addr < 0x04001060)
    {
        GPU.GPU2D_B.Write32(addr, val);
        return;
    }
    if (addr >= 0x04000320 && addr < 0x040006A4)
    {
        GPU.GPU3D.Write32(addr, val);
        return;
    }

    Log(LogLevel::Debug, "unknown ARM9 IO write32 %08X %08X %08X\n", addr, val, ARM9.R[15]);
}


u8 NDS::ARM7IORead8(u32 addr)
{
    switch (addr)
    {
    case 0x04000004: return GPU.DispStat[1] & 0xFF;
    case 0x04000005: return GPU.DispStat[1] >> 8;
    case 0x04000006: return GPU.VCount & 0xFF;
    case 0x04000007: return GPU.VCount >> 8;

    case 0x04000130: return KeyInput & 0xFF;
    case 0x04000131: return (KeyInput >> 8) & 0xFF;
    case 0x04000132: return KeyCnt[1] & 0xFF;
    case 0x04000133: return KeyCnt[1] >> 8;
    case 0x04000134: return RCnt & 0xFF;
    case 0x04000135: return RCnt >> 8;
    case 0x04000136: return (KeyInput >> 16) & 0xFF;
    case 0x04000137: return KeyInput >> 24;

    case 0x04000138: return RTC.Read() & 0xFF;

    case 0x04000180: return IPCSync7 & 0xFF;
    case 0x04000181: return IPCSync7 >> 8;

    case 0x040001A0: return NDSCartSlots[0]->ReadSPICnt(1) & 0xFF;
    case 0x040001A1: return NDSCartSlots[0]->ReadSPICnt(1) >> 8;
    case 0x040001A2: return NDSCartSlots[0]->ReadSPIData(1);
    case 0x040001A4: return NDSCartSlots[0]->ReadROMCnt(1) & 0xFF;
    case 0x040001A5: return (NDSCartSlots[0]->ReadROMCnt(1) >> 8) & 0xFF;
    case 0x040001A6: return (NDSCartSlots[0]->ReadROMCnt(1) >> 16) & 0xFF;
    case 0x040001A7: return NDSCartSlots[0]->ReadROMCnt(1) >> 24;

    case 0x040001C2: return SPI.ReadData();

    case 0x04000208: return IME[1];

    case 0x04000240: return GPU.VRAMSTAT;
    case 0x04000241: return WRAMCnt;

    case 0x04000300: return PostFlag7;
    case 0x04000304: return PowerControl7;
    }

    if (addr >= 0x04000400 && addr < 0x04000520)
    {
        return SPU.Read8(addr);
    }

    if ((addr & 0xFFFFF000) != 0x04004000)
        Log(LogLevel::Debug, "unknown ARM7 IO read8 %08X %08X\n", addr, ARM7.R[15]);
    return 0;
}

u16 NDS::ARM7IORead16(u32 addr)
{
    switch (addr)
    {
    case 0x04000004: return GPU.DispStat[1];
    case 0x04000006: return GPU.VCount;

    case 0x040000B8: return DMAs[4].Cnt & 0xFFFF;
    case 0x040000BA: return DMAs[4].Cnt >> 16;
    case 0x040000C4: return DMAs[5].Cnt & 0xFFFF;
    case 0x040000C6: return DMAs[5].Cnt >> 16;
    case 0x040000D0: return DMAs[6].Cnt & 0xFFFF;
    case 0x040000D2: return DMAs[6].Cnt >> 16;
    case 0x040000DC: return DMAs[7].Cnt & 0xFFFF;
    case 0x040000DE: return DMAs[7].Cnt >> 16;

    case 0x04000100: return TimerGetCounter(4);
    case 0x04000102: return Timers[4].Cnt;
    case 0x04000104: return TimerGetCounter(5);
    case 0x04000106: return Timers[5].Cnt;
    case 0x04000108: return TimerGetCounter(6);
    case 0x0400010A: return Timers[6].Cnt;
    case 0x0400010C: return TimerGetCounter(7);
    case 0x0400010E: return Timers[7].Cnt;

    case 0x04000130: return KeyInput & 0xFFFF;
    case 0x04000132: return KeyCnt[1];
    case 0x04000134: return RCnt;
    case 0x04000136: return KeyInput >> 16;

    case 0x04000138: return RTC.Read();

    case 0x04000180: return IPCSync7;
    case 0x04000184:
        {
            u16 val = IPCFIFOCnt7;
            if (IPCFIFO7.IsEmpty())     val |= 0x0001;
            else if (IPCFIFO7.IsFull()) val |= 0x0002;
            if (IPCFIFO9.IsEmpty())     val |= 0x0100;
            else if (IPCFIFO9.IsFull()) val |= 0x0200;
            return val;
        }

    case 0x040001A0: return NDSCartSlots[0]->ReadSPICnt(1);
    case 0x040001A2: return NDSCartSlots[0]->ReadSPIData(1);
    case 0x040001A4: return NDSCartSlots[0]->ReadROMCnt(1) & 0xFFFF;
    case 0x040001A6: return NDSCartSlots[0]->ReadROMCnt(1) >> 16;

    case 0x040001C0: return SPI.ReadCnt();
    case 0x040001C2: return SPI.ReadData();

    case 0x04000204: return ExMemCnt[1];
    case 0x04000206:
        if (!(PowerControl7 & (1<<1))) return 0;
        return WifiWaitCnt;

    case 0x04000208: return IME[1];
    case 0x04000210: return IE[1] & 0xFFFF;
    case 0x04000212: return IE[1] >> 16;

    case 0x04000300: return PostFlag7;
    case 0x04000304: return PowerControl7;
    case 0x04000308: return ARM7BIOSProt;
    }

    if (addr >= 0x04000400 && addr < 0x04000520)
    {
        return SPU.Read16(addr);
    }

    if ((addr & 0xFFFFF000) != 0x04004000)
        Log(LogLevel::Debug, "unknown ARM7 IO read16 %08X %08X\n", addr, ARM7.R[15]);
    return 0;
}

u32 NDS::ARM7IORead32(u32 addr)
{
    switch (addr)
    {
    case 0x04000004: return GPU.DispStat[1] | (GPU.VCount << 16);

    case 0x040000B0: return DMAs[4].SrcAddr;
    case 0x040000B4: return DMAs[4].DstAddr;
    case 0x040000B8: return DMAs[4].Cnt;
    case 0x040000BC: return DMAs[5].SrcAddr;
    case 0x040000C0: return DMAs[5].DstAddr;
    case 0x040000C4: return DMAs[5].Cnt;
    case 0x040000C8: return DMAs[6].SrcAddr;
    case 0x040000CC: return DMAs[6].DstAddr;
    case 0x040000D0: return DMAs[6].Cnt;
    case 0x040000D4: return DMAs[7].SrcAddr;
    case 0x040000D8: return DMAs[7].DstAddr;
    case 0x040000DC: return DMAs[7].Cnt;

    case 0x04000100: return TimerGetCounter(4) | (Timers[4].Cnt << 16);
    case 0x04000104: return TimerGetCounter(5) | (Timers[5].Cnt << 16);
    case 0x04000108: return TimerGetCounter(6) | (Timers[6].Cnt << 16);
    case 0x0400010C: return TimerGetCounter(7) | (Timers[7].Cnt << 16);

    case 0x04000130: return (KeyInput & 0xFFFF) | (KeyCnt[1] << 16);
    case 0x04000134: return RCnt | (KeyInput & 0xFFFF0000);
    case 0x04000138: return RTC.Read();

    case 0x04000180: return IPCSync7;
    case 0x04000184: return NDS::ARM7IORead16(addr);

    case 0x040001A0: return NDSCartSlots[0]->ReadSPICnt(1) | (NDSCartSlots[0]->ReadSPIData(1) << 16);
    case 0x040001A4: return NDSCartSlots[0]->ReadROMCnt(1);

    case 0x040001C0:
        return SPI.ReadCnt() | (SPI.ReadData() << 16);

    case 0x04000208: return IME[1];
    case 0x04000210: return IE[1];
    case 0x04000214: return IF[1];

    case 0x04000304: return PowerControl7;
    case 0x04000308: return ARM7BIOSProt;

    case 0x04100000:
        if (IPCFIFOCnt7 & 0x8000)
        {
            u32 ret;
            if (IPCFIFO9.IsEmpty())
            {
                IPCFIFOCnt7 |= 0x4000;
                ret = IPCFIFO9.Peek();
            }
            else
            {
                ret = IPCFIFO9.Read();

                if (IPCFIFO9.IsEmpty() && (IPCFIFOCnt9 & 0x0004))
                    SetIRQ(0, IRQ_IPCSendDone);
            }
            return ret;
        }
        else
            return IPCFIFO9.Peek();

    case 0x04100010:
        return NDSCartSlots[0]->ReadROMData(1);
    }

    if (addr >= 0x04000400 && addr < 0x04000520)
    {
        return SPU.Read32(addr);
    }

    if ((addr & 0xFFFFF000) != 0x04004000)
        Log(LogLevel::Debug, "unknown ARM7 IO read32 %08X %08X\n", addr, ARM7.R[15]);
    return 0;
}

void NDS::ARM7IOWrite8(u32 addr, u8 val)
{
    switch (addr)
    {
    case 0x04000004: GPU.SetDispStat(1, val, 0x00FF); return;
    case 0x04000005: GPU.SetDispStat(1, val << 8, 0xFF00); return;
    case 0x04000006: GPU.SetVCount(val, 0x00FF); return;
    case 0x04000007: GPU.SetVCount(val << 8, 0xFF00); return;

    case 0x04000132:
        KeyCnt[1] = (KeyCnt[1] & 0xFF00) | val;
        return;
    case 0x04000133:
        KeyCnt[1] = (KeyCnt[1] & 0x00FF) | (val << 8);
        return;
    case 0x04000134:
        RCnt = (RCnt & 0xFF00) | val;
        return;
    case 0x04000135:
        RCnt = (RCnt & 0x00FF) | (val << 8);
        return;

    case 0x04000138: RTC.Write(val, true); return;

    case 0x04000181:
        IPCSync9 &= 0xFFF0;
        IPCSync9 |= (val & 0x0F);
        IPCSync7 &= 0xB0FF;
        IPCSync7 |= ((val & 0x4F) << 8);
        if ((val & 0x20) && (IPCSync9 & 0x4000))
        {
            SetIRQ(0, IRQ_IPCSync);
        }
        return;

    case 0x04000188:
        NDS::ARM7IOWrite32(addr, val | (val << 8) | (val << 16) | (val << 24));
        return;

    case 0x040001A0:
        NDSCartSlots[0]->WriteSPICnt(1, val, 0x00FF);
        return;
    case 0x040001A1:
        NDSCartSlots[0]->WriteSPICnt(1, val << 8, 0xFF00);
        return;
    case 0x040001A2:
        NDSCartSlots[0]->WriteSPIData(1, val);
        return;

    case 0x040001A4:
        NDSCartSlots[0]->WriteROMCnt(1, val, 0x000000FF);
        return;
    case 0x040001A5:
        NDSCartSlots[0]->WriteROMCnt(1, val << 8, 0x0000FF00);
        return;
    case 0x040001A6:
        NDSCartSlots[0]->WriteROMCnt(1, val << 16, 0x00FF0000);
        return;
    case 0x040001A7:
        NDSCartSlots[0]->WriteROMCnt(1, val << 24, 0xFF000000);
        return;

    case 0x040001A8: NDSCartSlots[0]->WriteROMCommand(1, 0, val); return;
    case 0x040001A9: NDSCartSlots[0]->WriteROMCommand(1, 1, val); return;
    case 0x040001AA: NDSCartSlots[0]->WriteROMCommand(1, 2, val); return;
    case 0x040001AB: NDSCartSlots[0]->WriteROMCommand(1, 3, val); return;
    case 0x040001AC: NDSCartSlots[0]->WriteROMCommand(1, 4, val); return;
    case 0x040001AD: NDSCartSlots[0]->WriteROMCommand(1, 5, val); return;
    case 0x040001AE: NDSCartSlots[0]->WriteROMCommand(1, 6, val); return;
    case 0x040001AF: NDSCartSlots[0]->WriteROMCommand(1, 7, val); return;

    case 0x040001C2:
        SPI.WriteData(val);
        return;

    case 0x04000208: IME[1] = val & 0x1; UpdateIRQ(1); return;

    case 0x04000300:
        if (ARM7.R[15] >= 0x4000)
            return;
        if (!(PostFlag7 & 0x01))
            PostFlag7 = val & 0x01;
        return;

    case 0x04000301:
        val &= 0xC0;
        if      (val == 0x40) Stop(StopReason::GBAModeNotSupported);
        else if (val == 0x80) ARM7.Halt(1);
        else if (val == 0xC0) EnterSleepMode();
        return;
    }

    if (addr >= 0x04000400 && addr < 0x04000520)
    {
        SPU.Write8(addr, val);
        return;
    }

    Log(LogLevel::Debug, "unknown ARM7 IO write8 %08X %02X %08X\n", addr, val, ARM7.R[15]);
}

void NDS::ARM7IOWrite16(u32 addr, u16 val)
{
    switch (addr)
    {
    case 0x04000004: GPU.SetDispStat(1, val, 0xFFFF); return;
    case 0x04000006: GPU.SetVCount(val, 0xFFFF); return;

    case 0x040000B8: DMAs[4].WriteCnt((DMAs[4].Cnt & 0xFFFF0000) | val); return;
    case 0x040000BA: DMAs[4].WriteCnt((DMAs[4].Cnt & 0x0000FFFF) | (val << 16)); return;
    case 0x040000C4: DMAs[5].WriteCnt((DMAs[5].Cnt & 0xFFFF0000) | val); return;
    case 0x040000C6: DMAs[5].WriteCnt((DMAs[5].Cnt & 0x0000FFFF) | (val << 16)); return;
    case 0x040000D0: DMAs[6].WriteCnt((DMAs[6].Cnt & 0xFFFF0000) | val); return;
    case 0x040000D2: DMAs[6].WriteCnt((DMAs[6].Cnt & 0x0000FFFF) | (val << 16)); return;
    case 0x040000DC: DMAs[7].WriteCnt((DMAs[7].Cnt & 0xFFFF0000) | val); return;
    case 0x040000DE: DMAs[7].WriteCnt((DMAs[7].Cnt & 0x0000FFFF) | (val << 16)); return;

    case 0x04000100: Timers[4].Reload = val; return;
    case 0x04000102: TimerStart(4, val); return;
    case 0x04000104: Timers[5].Reload = val; return;
    case 0x04000106: TimerStart(5, val); return;
    case 0x04000108: Timers[6].Reload = val; return;
    case 0x0400010A: TimerStart(6, val); return;
    case 0x0400010C: Timers[7].Reload = val; return;
    case 0x0400010E: TimerStart(7, val); return;

    case 0x04000132: KeyCnt[1] = val; return;
    case 0x04000134: RCnt = val; return;

    case 0x04000138: RTC.Write(val, false); return;

    case 0x04000180:
        IPCSync9 &= 0xFFF0;
        IPCSync9 |= ((val & 0x0F00) >> 8);
        IPCSync7 &= 0xB0FF;
        IPCSync7 |= (val & 0x4F00);
        if ((val & 0x2000) && (IPCSync9 & 0x4000))
        {
            SetIRQ(0, IRQ_IPCSync);
        }
        return;

    case 0x04000184:
        if (val & 0x0008)
            IPCFIFO7.Clear();
        if ((val & 0x0004) && (!(IPCFIFOCnt7 & 0x0004)) && IPCFIFO7.IsEmpty())
            SetIRQ(1, IRQ_IPCSendDone);
        if ((val & 0x0400) && (!(IPCFIFOCnt7 & 0x0400)) && (!IPCFIFO9.IsEmpty()))
            SetIRQ(1, IRQ_IPCRecv);
        if (val & 0x4000)
            IPCFIFOCnt7 &= ~0x4000;
        IPCFIFOCnt7 = (val & 0x8404) | (IPCFIFOCnt7 & 0x4000);
        return;

    case 0x04000188:
        NDS::ARM7IOWrite32(addr, val | (val << 16));
        return;

    case 0x040001A0:
        NDSCartSlots[0]->WriteSPICnt(1, val, 0xFFFF);
        return;
    case 0x040001A2:
        NDSCartSlots[0]->WriteSPIData(1, val & 0xFF);
        return;

    case 0x040001A4:
        NDSCartSlots[0]->WriteROMCnt(1, val, 0x0000FFFF);
        return;
    case 0x040001A6:
        NDSCartSlots[0]->WriteROMCnt(1, val << 16, 0xFFFF0000);
        return;

    case 0x040001A8:
        NDSCartSlots[0]->WriteROMCommand(1, 0, val & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(1, 1, val >> 8);
        return;
    case 0x040001AA:
        NDSCartSlots[0]->WriteROMCommand(1, 2, val & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(1, 3, val >> 8);
        return;
    case 0x040001AC:
        NDSCartSlots[0]->WriteROMCommand(1, 4, val & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(1, 5, val >> 8);
        return;
    case 0x040001AE:
        NDSCartSlots[0]->WriteROMCommand(1, 6, val & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(1, 7, val >> 8);
        return;

    case 0x040001B8:
        NDSCartSlots[0]->WriteKey2Seed0(1, (u64)val << 32, 0x7F00000000ULL);
        return;
    case 0x040001BA:
        NDSCartSlots[0]->WriteKey2Seed1(1, (u64)val << 32, 0x7F00000000ULL);
        return;

    case 0x040001C0:
        SPI.WriteCnt(val);
        return;
    case 0x040001C2:
        SPI.WriteData(val & 0xFF);
        return;

    case 0x04000204:
        SetExMemCnt(1, val, 0xFFFF);
        return;

    case 0x04000206:
        if (!(PowerControl7 & (1<<1))) return;
        SetWifiWaitCnt(val);
        return;

    case 0x04000208: IME[1] = val & 0x1; UpdateIRQ(1); return;
    case 0x04000210: IE[1] = (IE[1] & 0xFFFF0000) | val; UpdateIRQ(1); return;
    case 0x04000212: IE[1] = (IE[1] & 0x0000FFFF) | (val << 16); UpdateIRQ(1); return;
    // TODO: what happens when writing to IF this way??

    case 0x04000300:
        if (ARM7.R[15] >= 0x4000)
            return;
        if (!(PostFlag7 & 0x01))
            PostFlag7 = val & 0x01;
        return;

    case 0x04000304:
        {
            u16 change = PowerControl7 ^ val;
            PowerControl7 = val & 0x0003;
            SPU.SetPowerCnt(val & 0x0001);
            Wifi.SetPowerCnt(val & 0x0002);
            if (change & 0x0002) UpdateWifiTimings();
        }
        return;

    case 0x04000308:
        if (ARM7BIOSProt == 0)
            ARM7BIOSProt = val & 0xFFFE;
        return;
    }

    if (addr >= 0x04000400 && addr < 0x04000520)
    {
        SPU.Write16(addr, val);
        return;
    }

    Log(LogLevel::Debug, "unknown ARM7 IO write16 %08X %04X %08X\n", addr, val, ARM7.R[15]);
}

void NDS::ARM7IOWrite32(u32 addr, u32 val)
{
    switch (addr)
    {
    case 0x04000004:
        GPU.SetDispStat(1, val & 0xFFFF, 0xFFFF);
        GPU.SetVCount(val >> 16, 0xFFFF);
        return;

    case 0x040000B0: DMAs[4].SrcAddr = val; return;
    case 0x040000B4: DMAs[4].DstAddr = val; return;
    case 0x040000B8: DMAs[4].WriteCnt(val); return;
    case 0x040000BC: DMAs[5].SrcAddr = val; return;
    case 0x040000C0: DMAs[5].DstAddr = val; return;
    case 0x040000C4: DMAs[5].WriteCnt(val); return;
    case 0x040000C8: DMAs[6].SrcAddr = val; return;
    case 0x040000CC: DMAs[6].DstAddr = val; return;
    case 0x040000D0: DMAs[6].WriteCnt(val); return;
    case 0x040000D4: DMAs[7].SrcAddr = val; return;
    case 0x040000D8: DMAs[7].DstAddr = val; return;
    case 0x040000DC: DMAs[7].WriteCnt(val); return;

    case 0x04000100:
        Timers[4].Reload = val & 0xFFFF;
        TimerStart(4, val>>16);
        return;
    case 0x04000104:
        Timers[5].Reload = val & 0xFFFF;
        TimerStart(5, val>>16);
        return;
    case 0x04000108:
        Timers[6].Reload = val & 0xFFFF;
        TimerStart(6, val>>16);
        return;
    case 0x0400010C:
        Timers[7].Reload = val & 0xFFFF;
        TimerStart(7, val>>16);
        return;

    case 0x04000130: KeyCnt[1] = val >> 16; return;
    case 0x04000134: RCnt = val & 0xFFFF; return;
    case 0x04000138: RTC.Write(val & 0xFFFF, false); return;

    case 0x04000180:
    case 0x04000184:
        NDS::ARM7IOWrite16(addr, val);
        return;
    case 0x04000188:
        if (IPCFIFOCnt7 & 0x8000)
        {
            if (IPCFIFO7.IsFull())
                IPCFIFOCnt7 |= 0x4000;
            else
            {
                bool wasempty = IPCFIFO7.IsEmpty();
                IPCFIFO7.Write(val);
                if ((IPCFIFOCnt9 & 0x0400) && wasempty)
                    SetIRQ(0, IRQ_IPCRecv);
            }
        }
        return;

    case 0x040001A0:
        NDSCartSlots[0]->WriteSPICnt(1, val & 0xFFFF, 0xFFFF);
        NDSCartSlots[0]->WriteSPIData(1, (val >> 16) & 0xFF);
        return;
    case 0x040001A4:
        NDSCartSlots[0]->WriteROMCnt(1, val, 0xFFFFFFFF);
        return;

    case 0x040001A8:
        NDSCartSlots[0]->WriteROMCommand(1, 0, val & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(1, 1, (val >> 8) & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(1, 2, (val >> 16) & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(1, 3, val >> 24);
        return;
    case 0x040001AC:
        NDSCartSlots[0]->WriteROMCommand(1, 4, val & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(1, 5, (val >> 8) & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(1, 6, (val >> 16) & 0xFF);
        NDSCartSlots[0]->WriteROMCommand(1, 7, val >> 24);
        return;

    case 0x040001B0:
        NDSCartSlots[0]->WriteKey2Seed0(1, (u64)val, 0x00FFFFFFFFULL);
        return;
    case 0x040001B4:
        NDSCartSlots[0]->WriteKey2Seed1(1, (u64)val, 0x00FFFFFFFFULL);
        return;

    case 0x040001C0:
        SPI.WriteCnt(val & 0xFFFF);
        SPI.WriteData((val >> 16) & 0xFF);
        return;

    case 0x04000208: IME[1] = val & 0x1; UpdateIRQ(1); return;
    case 0x04000210: IE[1] = val; UpdateIRQ(1); return;
    case 0x04000214: ClearIRQMask(1, val); return;

    case 0x04000304:
        {
            u16 change = PowerControl7 ^ val;
            PowerControl7 = val & 0x0003;
            SPU.SetPowerCnt(val & 0x0001);
            Wifi.SetPowerCnt(val & 0x0002);
            if (change & 0x0002) UpdateWifiTimings();
        }
        return;

    case 0x04000308:
        if (ARM7BIOSProt == 0)
            ARM7BIOSProt = val & 0xFFFE;
        return;

    case 0x04100010:
        NDSCartSlots[0]->WriteROMData(1, val, 0xFFFFFFFF);
        return;
    }

    if (addr >= 0x04000400 && addr < 0x04000520)
    {
        SPU.Write32(addr, val);
        return;
    }

    Log(LogLevel::Debug, "unknown ARM7 IO write32 %08X %08X %08X\n", addr, val, ARM7.R[15]);
}

}
