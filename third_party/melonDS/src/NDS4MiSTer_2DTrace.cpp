#include "NDS4MiSTer_2DTrace.h"

#include "GPU.h"
#include "NDS.h"

#include <cstring>
#include <memory>

namespace melonDS::NDS4MiSTer
{
bool Trace2DActive = false;
thread_local bool Trace2DThreadSuppressed = false;

namespace
{

Trace2DSink TraceSink = nullptr;
void* TraceUserdata = nullptr;
CompositeLineSink LineSink = nullptr;
void* LineUserdata = nullptr;
bool LineBypass = false;
OutputLineSink OutputSink = nullptr;
void* OutputUserdata = nullptr;
VBlankSink VBlankObserver = nullptr;
void* VBlankUserdata = nullptr;
PreDrawScrollSink PreDrawScrollObserver = nullptr;
void* PreDrawScrollUserdata = nullptr;

struct TraceMemoryShadow
{
    u8 Palette[2 * 1024] {};
    u8 OAM[2 * 1024] {};
    u8 VRAM[656 * 1024] {};
    u8 FlatAOBJ[256 * 1024] {};
    u8 FlatBOBJ[128 * 1024] {};
    u32 ABGExtPal[4] {};
    u32 AOBJExtPal {};
    u32 BBGExtPal[4] {};
    u32 BOBJExtPal {};
    bool ExtPalMapInitialized {};
    bool MemoryInitialized {};
};

std::unique_ptr<TraceMemoryShadow> MemoryShadow;

void EmitRaw(const void* data, size_t size) noexcept
{
    TraceSink(data, size, TraceUserdata);
}

u64 HashBytes(const u8* data, size_t size) noexcept
{
    u64 hash=1469598103934665603ULL;
    for (size_t i=0;i<size;i++) { hash^=data[i]; hash*=1099511628211ULL; }
    return hash;
}

void EmitMemoryDelta(u32 frame, u16 line, Trace2DMemoryRegion region,
    u32 offset, const u8* data, u8* shadow, u32 size) noexcept
{
    if (std::memcmp(data, shadow, size) == 0)
        return;

    Trace2DMemoryDeltaHeader header {
        {static_cast<u16>(Trace2DRecordType::MemoryDelta),
         static_cast<u16>(sizeof(Trace2DMemoryDeltaHeader) + size)},
        frame,
        line,
        static_cast<u8>(region),
        0,
        offset,
    };
    EmitRaw(&header, sizeof(header));
    EmitRaw(data, size);
    std::memcpy(shadow, data, size);
}

void FillEngine(Trace2DEngine& out, const GPU2D& in) noexcept
{
    out.DispCnt = in.DispCnt;
    out.LayerEnable = in.LayerEnable;
    out.OBJEnable = in.OBJEnable;
    out.ForcedBlank = in.ForcedBlank;
    out.Reserved0 = 0;
    std::memcpy(out.BGCnt, in.BGCnt, sizeof(out.BGCnt));
    std::memcpy(out.BGXPos, in.BGXPos, sizeof(out.BGXPos));
    std::memcpy(out.BGYPos, in.BGYPos, sizeof(out.BGYPos));
    std::memcpy(out.BGXRef, in.BGXRef, sizeof(out.BGXRef));
    std::memcpy(out.BGYRef, in.BGYRef, sizeof(out.BGYRef));
    std::memcpy(out.BGRotA, in.BGRotA, sizeof(out.BGRotA));
    std::memcpy(out.BGRotB, in.BGRotB, sizeof(out.BGRotB));
    std::memcpy(out.BGRotC, in.BGRotC, sizeof(out.BGRotC));
    std::memcpy(out.BGRotD, in.BGRotD, sizeof(out.BGRotD));
    std::memcpy(out.Win0Coords, in.Win0Coords, sizeof(out.Win0Coords));
    std::memcpy(out.Win1Coords, in.Win1Coords, sizeof(out.Win1Coords));
    std::memcpy(out.WinCnt, in.WinCnt, sizeof(out.WinCnt));
    out.Win0Active = in.Win0Active;
    out.Win1Active = in.Win1Active;
    std::memcpy(out.BGMosaicSize, in.BGMosaicSize, sizeof(out.BGMosaicSize));
    std::memcpy(out.OBJMosaicSize, in.OBJMosaicSize, sizeof(out.OBJMosaicSize));
    out.BlendCnt = in.BlendCnt;
    out.BlendAlpha = in.BlendAlpha;
    out.EVA = in.EVA;
    out.EVB = in.EVB;
    out.EVY = in.EVY;
    out.Reserved1 = 0;
}

} // namespace

Trace2DFileHeader MakeTrace2DFileHeader() noexcept
{
    return Trace2DFileHeader {
        Trace2DMagic,
        Trace2DVersion,
        static_cast<u16>(sizeof(Trace2DFileHeader)),
        0,
        0,
    };
}

void SetTrace2DSink(Trace2DSink sink, void* userdata) noexcept
{
    TraceSink = sink;
    TraceUserdata = userdata;
    Trace2DActive = sink != nullptr;
    MemoryShadow = sink ? std::make_unique<TraceMemoryShadow>() : nullptr;
}

void SetCompositeLineSink(CompositeLineSink sink, void* userdata) noexcept
{
    LineSink = sink;
    LineUserdata = userdata;
}

void SetCompositeLineBypass(bool enabled) noexcept
{
    LineBypass = enabled;
}

void SetOutputLineSink(OutputLineSink sink, void* userdata) noexcept
{
    OutputSink = sink;
    OutputUserdata = userdata;
}

void SetVBlankSink(VBlankSink sink, void* userdata) noexcept
{
    VBlankObserver = sink;
    VBlankUserdata = userdata;
}

void SetPreDrawScrollSink(PreDrawScrollSink sink, void* userdata) noexcept
{
    PreDrawScrollObserver = sink;
    PreDrawScrollUserdata = userdata;
}

bool CompositeLineEnabled() noexcept { return LineSink != nullptr && !Trace2DThreadSuppressed; }
bool CompositeLineBypassEnabled() noexcept
{
    return LineBypass && LineSink != nullptr && !Trace2DThreadSuppressed;
}

void EmitCompositeLine(u32 frame, u16 line, u8 engine, bool screenSwap,
    const u32* top, const u32* second, const u8* windowMask,
    u16 blendCnt, u8 eva, u8 evb, u8 evy, u8 displayMode,
    u16 masterBrightness) noexcept
{
    CompositeLineSink sink=LineSink;
    if(sink&&!Trace2DThreadSuppressed)
        sink(frame,line,engine,screenSwap,top,second,windowMask,blendCnt,eva,
             evb,evy,displayMode,masterBrightness,LineUserdata);
}

void EmitOutputLine(u32 frame, u16 line, const u32* top, const u32* bottom) noexcept
{
    OutputLineSink sink=OutputSink;
    if(sink&&!Trace2DThreadSuppressed) sink(frame,line,top,bottom,OutputUserdata);
}

void EmitVBlank(u32 frame) noexcept
{
    VBlankSink sink = VBlankObserver;
    if (sink && !Trace2DThreadSuppressed)
        sink(frame, VBlankUserdata);
}

void EmitPreDrawScroll(u32 frame, u16 line, u16 bg1hofs, u16 bg2hofs) noexcept
{
    PreDrawScrollSink sink = PreDrawScrollObserver;
    if (sink && !Trace2DThreadSuppressed)
        sink(frame, line, bg1hofs, bg2hofs, PreDrawScrollUserdata);
}

void EmitTrace2DScanline(GPU& gpu, u32 line) noexcept
{
    if (Trace2DThreadSuppressed) return;
    Trace2DSink sink = TraceSink;
    if (sink == nullptr) {
        return;
    }
    (void)line;

    const u32 frame = gpu.NDS.NumFrames;
    const u16 scanline = gpu.VCount;
    TraceMemoryShadow& shadow = *MemoryShadow;
    const bool initialMemorySnapshot = !shadow.MemoryInitialized;

    Trace2DOBJBufferHashPacket objhash {
        {static_cast<u16>(Trace2DRecordType::OBJBufferHash), static_cast<u16>(sizeof(Trace2DOBJBufferHashPacket))},
        frame, scanline, 0, {},
    };
    if (gpu.GetRenderer().GetOBJBufferHashes(objhash.Hashes)) EmitRaw(&objhash, sizeof(objhash));
    if (frame >= 312 && frame <= 314)
    {
        Trace2DOBJInputHashPacket inputhash {
            {static_cast<u16>(Trace2DRecordType::OBJInputHash), static_cast<u16>(sizeof(Trace2DOBJInputHashPacket))},
            frame, scanline, 0,
            HashBytes(gpu.OAM, 1024), HashBytes(gpu.OAM + 1024, 1024),
            HashBytes(gpu.VRAMFlat_AOBJ, sizeof(gpu.VRAMFlat_AOBJ)),
            HashBytes(gpu.VRAMFlat_BOBJ, sizeof(gpu.VRAMFlat_BOBJ)),
        };
        EmitRaw(&inputhash, sizeof(inputhash));
    }

    Trace2DInternal2DLatchPacket latch {
        {static_cast<u16>(Trace2DRecordType::Internal2DLatch), static_cast<u16>(sizeof(Trace2DInternal2DLatchPacket))},
        frame, scanline, 0, {},
    };
    const GPU2D* engines[2] = {&gpu.GPU2D_A, &gpu.GPU2D_B};
    for (int i=0; i<2; i++) {
        std::memcpy(latch.Engine[i].BGXRefInternal, engines[i]->BGXRefInternal, sizeof(latch.Engine[i].BGXRefInternal));
        std::memcpy(latch.Engine[i].BGYRefInternal, engines[i]->BGYRefInternal, sizeof(latch.Engine[i].BGYRefInternal));
        latch.Engine[i].BGMosaicY=engines[i]->BGMosaicY; latch.Engine[i].BGMosaicYMax=engines[i]->BGMosaicYMax;
        latch.Engine[i].OBJMosaicY=engines[i]->OBJMosaicY;
        latch.Engine[i].Flags=(engines[i]->BGMosaicLatch?1:0)|(engines[i]->OBJMosaicLatch?2:0);
        latch.Engine[i].BGMosaicLine=engines[i]->BGMosaicLine; latch.Engine[i].OBJMosaicLine=engines[i]->OBJMosaicLine;
    }
    EmitRaw(&latch, sizeof(latch));

    for (u32 chunk = 0; chunk < 4; chunk++)
    {
        if (initialMemorySnapshot || (gpu.PaletteDirty & (1U << chunk)))
            EmitMemoryDelta(frame, scanline, Trace2DMemoryRegion::Palette,
                chunk * VRAMDirtyGranularity, gpu.Palette + chunk * VRAMDirtyGranularity,
                shadow.Palette + chunk * VRAMDirtyGranularity, VRAMDirtyGranularity);
    }
    for (u32 chunk = 0; chunk < 2; chunk++)
    {
        if (initialMemorySnapshot || (gpu.OAMDirty & (1U << chunk)))
            EmitMemoryDelta(frame, scanline, Trace2DMemoryRegion::OAM,
                chunk * 1024, gpu.OAM + chunk * 1024, shadow.OAM + chunk * 1024, 1024);
    }

    static constexpr u32 BankSizes[9] = {
        128 * 1024, 128 * 1024, 128 * 1024, 128 * 1024,
        64 * 1024, 16 * 1024, 16 * 1024, 32 * 1024, 16 * 1024,
    };
    u32 shadowOffset = 0;
    for (u32 bank = 0; bank < 9; bank++)
    {
        for (u32 chunk = 0; chunk < BankSizes[bank] / VRAMDirtyGranularity; chunk++)
        {
            if (initialMemorySnapshot || gpu.VRAMDirty[bank][chunk])
                EmitMemoryDelta(frame, scanline,
                    static_cast<Trace2DMemoryRegion>(static_cast<u8>(Trace2DMemoryRegion::VRAMA) + bank),
                    chunk * VRAMDirtyGranularity,
                    gpu.VRAM[bank] + chunk * VRAMDirtyGranularity,
                    shadow.VRAM + shadowOffset + chunk * VRAMDirtyGranularity,
                    VRAMDirtyGranularity);
        }
        shadowOffset += BankSizes[bank];
    }
    shadow.MemoryInitialized = true;
    for (u32 chunk=0;chunk<sizeof(shadow.FlatAOBJ)/VRAMDirtyGranularity;chunk++)
        if (initialMemorySnapshot || gpu.NDS4MiSTerTraceDirtyFlatAOBJ[chunk])
            EmitMemoryDelta(frame,scanline,Trace2DMemoryRegion::FlatAOBJ,chunk*VRAMDirtyGranularity,
                gpu.VRAMFlat_AOBJ+chunk*VRAMDirtyGranularity,shadow.FlatAOBJ+chunk*VRAMDirtyGranularity,VRAMDirtyGranularity);
    for (u32 chunk=0;chunk<sizeof(shadow.FlatBOBJ)/VRAMDirtyGranularity;chunk++)
        if (initialMemorySnapshot || gpu.NDS4MiSTerTraceDirtyFlatBOBJ[chunk])
            EmitMemoryDelta(frame,scanline,Trace2DMemoryRegion::FlatBOBJ,chunk*VRAMDirtyGranularity,
                gpu.VRAMFlat_BOBJ+chunk*VRAMDirtyGranularity,shadow.FlatBOBJ+chunk*VRAMDirtyGranularity,VRAMDirtyGranularity);
    gpu.NDS4MiSTerTraceDirtyFlatAOBJ.Clear(); gpu.NDS4MiSTerTraceDirtyFlatBOBJ.Clear();

    if (!shadow.ExtPalMapInitialized
        || std::memcmp(shadow.ABGExtPal, gpu.VRAMMap_ABGExtPal, sizeof(shadow.ABGExtPal)) != 0
        || shadow.AOBJExtPal != gpu.VRAMMap_AOBJExtPal
        || std::memcmp(shadow.BBGExtPal, gpu.VRAMMap_BBGExtPal, sizeof(shadow.BBGExtPal)) != 0
        || shadow.BOBJExtPal != gpu.VRAMMap_BOBJExtPal)
    {
        Trace2DExtendedPaletteMapPacket mapping {
            {static_cast<u16>(Trace2DRecordType::ExtendedPaletteMap),
             static_cast<u16>(sizeof(Trace2DExtendedPaletteMapPacket))},
            frame,
            scanline,
            0,
            {},
            gpu.VRAMMap_AOBJExtPal,
            {},
            gpu.VRAMMap_BOBJExtPal,
        };
        std::memcpy(mapping.ABG, gpu.VRAMMap_ABGExtPal, sizeof(mapping.ABG));
        std::memcpy(mapping.BBG, gpu.VRAMMap_BBGExtPal, sizeof(mapping.BBG));
        EmitRaw(&mapping, sizeof(mapping));
        std::memcpy(shadow.ABGExtPal, mapping.ABG, sizeof(shadow.ABGExtPal));
        shadow.AOBJExtPal = mapping.AOBJ;
        std::memcpy(shadow.BBGExtPal, mapping.BBG, sizeof(shadow.BBGExtPal));
        shadow.BOBJExtPal = mapping.BOBJ;
        shadow.ExtPalMapInitialized = true;
    }

#if !NDS4MISTER_NO_VIDEO_RENDER && !NDS4MISTER_NO_3D_RENDER
    if ((gpu.GPU2D_A.DispCnt & (1U << 3)) && (gpu.GPU2D_A.LayerEnable & 1U))
    {
        const u32* pixels = gpu.GetRenderer().Get3DScanline(scanline);
        if (pixels != nullptr)
        {
            constexpr u16 PixelCount = 256;
            Trace2DRenderer3DHeader header {
                {static_cast<u16>(Trace2DRecordType::Renderer3DScanline),
                 static_cast<u16>(sizeof(Trace2DRenderer3DHeader) + PixelCount * sizeof(u32))},
                frame,
                scanline,
                PixelCount,
            };
            EmitRaw(&header, sizeof(header));
            EmitRaw(pixels, PixelCount * sizeof(u32));
        }
    }
#endif

    Trace2DScanlinePacket packet {};
    packet.Frame = frame;
    packet.Line = gpu.VCount;
    packet.VCount = gpu.VCount;
    packet.ScreensEnabled = gpu.ScreensEnabled ? 1 : 0;
    packet.ScreenSwap = gpu.ScreenSwap ? 1 : 0;
    packet.CaptureEnable = gpu.CaptureEnable ? 1 : 0;
    packet.MasterBrightnessA = gpu.MasterBrightnessA;
    packet.MasterBrightnessB = gpu.MasterBrightnessB;
    std::memcpy(packet.VRAMCNT, gpu.VRAMCNT, sizeof(packet.VRAMCNT));
    std::memcpy(packet.VRAMMapABG, gpu.VRAMMap_ABG, sizeof(packet.VRAMMapABG));
    std::memcpy(packet.VRAMMapAOBJ, gpu.VRAMMap_AOBJ, sizeof(packet.VRAMMapAOBJ));
    std::memcpy(packet.VRAMMapBBG, gpu.VRAMMap_BBG, sizeof(packet.VRAMMapBBG));
    std::memcpy(packet.VRAMMapBOBJ, gpu.VRAMMap_BOBJ, sizeof(packet.VRAMMapBOBJ));
    packet.OAMDirty = gpu.OAMDirty;
    packet.PaletteDirty = gpu.PaletteDirty;
    FillEngine(packet.Engine[0], gpu.GPU2D_A);
    FillEngine(packet.Engine[1], gpu.GPU2D_B);

    const Trace2DRecordHeader record {
        static_cast<u16>(Trace2DRecordType::Scanline),
        static_cast<u16>(sizeof(Trace2DRecordHeader) + sizeof(packet)),
    };
    EmitRaw(&record, sizeof(record));
    EmitRaw(&packet, sizeof(packet));
}

void EmitTrace3DCommand(u32 frame, u64 timestamp, u8 command, u32 parameter) noexcept
{
    if (TraceSink == nullptr)
        return;
    const Trace2DGeometryCommandPacket packet {
        {static_cast<u16>(Trace2DRecordType::GeometryCommand),
         static_cast<u16>(sizeof(Trace2DGeometryCommandPacket))},
        frame,
        timestamp,
        command,
        {},
        parameter,
    };
    EmitRaw(&packet, sizeof(packet));
}

void EmitTrace3DFrame(u32 frame, u64 timestamp, u32 vertices, u32 polygons, u32 flushAttributes) noexcept
{
    if (TraceSink == nullptr)
        return;
    const Trace2DGeometryFramePacket packet {
        {static_cast<u16>(Trace2DRecordType::GeometryFrame),
         static_cast<u16>(sizeof(Trace2DGeometryFramePacket))},
        frame,
        timestamp,
        vertices,
        polygons,
        flushAttributes,
    };
    EmitRaw(&packet, sizeof(packet));
}

void EmitTrace3DRegister(u32 frame, u64 timestamp, u32 address, u32 value, u8 width) noexcept
{
    if (!TraceSink) return;
    const Trace2DGeometryRegisterPacket packet {
        {static_cast<u16>(Trace2DRecordType::GeometryRegister),
         static_cast<u16>(sizeof(Trace2DGeometryRegisterPacket))},
        frame, timestamp, address, value, width, {0, 0, 0},
    };
    EmitRaw(&packet, sizeof(packet));
}

void EmitTraceFramebufferScanline(u32 frame, u16 line, const u32* top, const u32* bottom) noexcept
{
    if (!TraceSink) return;
    Trace2DFramebufferScanlinePacket packet {
        {static_cast<u16>(Trace2DRecordType::FramebufferScanline),
         static_cast<u16>(sizeof(Trace2DFramebufferScanlinePacket))},
        frame, line, 256, {}, {},
    };
    std::memcpy(packet.Top, top, sizeof(packet.Top));
    std::memcpy(packet.Bottom, bottom, sizeof(packet.Bottom));
    EmitRaw(&packet, sizeof(packet));
}

} // namespace melonDS::NDS4MiSTer
