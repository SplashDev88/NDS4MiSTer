#include "melonds/MelonDsBackend.h"
#include "replay/Arm7SoundMmioTrace.h"
#include "replay/ConsumedCreditAckDdrProducer.h"
#include "replay/ConsumedCreditAckMappedDdrMemory.h"
#include "replay/ExternalTimeWindowDdrBridge.h"
#include "replay/ExternalTimeWindowLwControl.h"
#include "replay/ExternalTimeWindowRuntime.h"
#include "replay/LayerRecord.h"
#include "replay/SoundPersistentEpoch.h"
#include "replay/StandaloneBoot.h"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <csignal>
#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include <fcntl.h>
#if defined(__linux__)
#include <linux/input.h>
#endif
#include <sched.h>
#include <sys/mman.h>
#if defined(__linux__) && defined(__arm__)
#include <ucontext.h>
#endif
#include <unistd.h>

#if defined(__linux__) && defined(__arm__)
namespace {
[[noreturn]] void writeArithmeticFault(
    const char* prefix,
    std::uintptr_t pc,
    std::uintptr_t lr,
    std::uintptr_t sp,
    int code) noexcept {
    char line[192];
    std::size_t length = 0;
    const auto appendText = [&](const char* text) {
        while (*text && length < sizeof(line)) line[length++] = *text++;
    };
    const auto appendHex32 = [&](std::uintptr_t value) {
        static constexpr char digits[] = "0123456789abcdef";
        appendText("0x");
        // Bounds-check every digit. This ran unchecked and could write eight
        // bytes past the end of `line`, which is how the SIGFPE handler ended
        // up reporting "stack smashing detected" instead of the arithmetic
        // fault it was invoked to describe.
        for (unsigned shift = 28; ; shift -= 4) {
            if (length < sizeof(line))
                line[length++] = digits[(value >> shift) & 0xfu];
            if (shift == 0) break;
        }
    };
    appendText(prefix);
    appendText(" pc=");
    appendHex32(pc);
    appendText(" lr=");
    appendHex32(lr);
    appendText(" sp=");
    appendHex32(sp);
    appendText(" code=");
    appendHex32(static_cast<std::uint32_t>(code));
    // Same hazard: unchecked, this writes one past the end whenever the
    // message exactly fills the buffer.
    if (length < sizeof(line)) line[length++] = '\n';
    else line[sizeof(line) - 1] = '\n';
    const ssize_t written = ::write(STDERR_FILENO, line, length);
    (void)written;
    ::_exit(128 + SIGFPE);
}

void arithmeticFaultSignal(int, siginfo_t* info, void* context) noexcept {
    const auto* ucontext = static_cast<const ucontext_t*>(context);
    writeArithmeticFault(
        "NDS4MISTER_SIGFPE_V1",
        ucontext ? ucontext->uc_mcontext.arm_pc : 0,
        ucontext ? ucontext->uc_mcontext.arm_lr : 0,
        ucontext ? ucontext->uc_mcontext.arm_sp : 0,
        info ? info->si_code : 0);
}

void installArithmeticFaultDiagnostic() {
    struct sigaction action {};
    action.sa_sigaction = arithmeticFaultSignal;
    action.sa_flags = SA_SIGINFO | SA_RESETHAND;
    if (sigfillset(&action.sa_mask) != 0 ||
        sigaction(SIGFPE, &action, nullptr) != 0)
        throw std::runtime_error(
            std::string("install SIGFPE diagnostic: ") +
            std::strerror(errno));
}
}

// Cortex-A9 integer division is implemented by libgcc helpers. Their
// divide-by-zero paths tail-branch to this weak EABI hook, preserving the
// original caller in LR. Override it in responder diagnostics so a crash
// identifies the exact optimized call site rather than libc's raise().
extern "C" __attribute__((noinline, noipa, used, noreturn))
int __aeabi_idiv0(int) {
    std::uintptr_t sp = 0;
    asm volatile("mov %0, sp" : "=r"(sp));
    const auto caller = reinterpret_cast<std::uintptr_t>(
        __builtin_extract_return_addr(__builtin_return_address(0)));
    writeArithmeticFault(
        "NDS4MISTER_IDIV0_V1", caller, caller, sp, 0);
}

// The 64-bit EABI helpers use a separate weak hook. This is especially
// relevant to the DS geometry clipper, whose interpolation numerator is s64.
extern "C" __attribute__((noinline, noipa, used, noreturn))
long long __aeabi_ldiv0(long long) {
    std::uintptr_t sp = 0;
    asm volatile("mov %0, sp" : "=r"(sp));
    const auto caller = reinterpret_cast<std::uintptr_t>(
        __builtin_extract_return_addr(__builtin_return_address(0)));
    writeArithmeticFault(
        "NDS4MISTER_LDIV0_V1", caller, caller, sp, 0);
}
#endif

namespace {
constexpr std::uint32_t kMagic = 0x4f53444e;
constexpr std::uintptr_t kDefaultPhysical = 0x2c000000;
constexpr std::uintptr_t kExternalTimeWindowPhysical = 0x2c0e0000;
constexpr std::size_t kExternalTimeWindowGroupCount = 64u;
constexpr std::size_t kExternalTimeWindowHeaderWords = 8u;
constexpr std::size_t kExternalTimeWindowBarrierReplacementWordOffset =
    kExternalTimeWindowHeaderWords +
    kExternalTimeWindowGroupCount *
        nds4mister::ExternalTimeWindowDdrProducer::kWordsPerGroup;
constexpr nds4mister::ExternalTimeWindowDdrLayout
    kExternalTimeWindowLayout{
        kExternalTimeWindowGroupCount,
        kExternalTimeWindowHeaderWords,
        0u,
        1u,
        kExternalTimeWindowBarrierReplacementWordOffset};
constexpr std::size_t kExternalTimeWindowBytes =
    (kExternalTimeWindowBarrierReplacementWordOffset +
     kExternalTimeWindowGroupCount *
         nds4mister::ExternalTimeWindowDdrProducer::
             kWordsPerBarrierReplacement) * sizeof(std::uint64_t);
static_assert((kExternalTimeWindowPhysical & 7u) == 0);
static_assert(kExternalTimeWindowBarrierReplacementWordOffset == 1352u);
static_assert(kExternalTimeWindowBytes == 15424u);
// HPS lightweight bridge aperture. All three HPS bridges are already out of
// reset on MiSTer (rstmgr brgmodrst reads 0), so this is reachable without any
// preloader change. Word offsets match nds_hps_oracle_mailbox_lw.
constexpr std::uintptr_t kLwBridgePhysical = 0xff200000;
constexpr unsigned kLwRegStatus  = 0; // r {31:1 sequence, 0 pending}
constexpr unsigned kLwRegAddress = 1;
constexpr unsigned kLwRegWData   = 2;
constexpr unsigned kLwRegControl = 3;
constexpr unsigned kLwRegCycles  = 4;
constexpr unsigned kLwRegFence   = 5;
constexpr unsigned kLwRegRData   = 6; // w
constexpr unsigned kLwRegFlags   = 7; // w -- completes the transaction
constexpr unsigned kLwRegProducer = 8; // r posted commit sequence
constexpr unsigned kLwRegConsumer = 9; // rw consumed sequence
constexpr unsigned kLwRegDoorbell = 10; // r work/error/session status
constexpr unsigned kLwRegAbi      = 11; // r transport identity
constexpr unsigned kLwRegSession  = 12; // rw nonzero HPS session claim
// r272's preserved FPGA-audio diagnostic overlay owns words 13..22. Keep the
// transport extension above that window so the accepted sound top forwards it.
constexpr unsigned kLwRegCaps     = 23; // r exact transport capabilities
constexpr unsigned kLwRegArm      = 24; // rw same-cookie session arm
constexpr unsigned kLwRegFenceEpoch = 25; // r saved mailbox fence epoch
constexpr unsigned kLwRegReverseConsumer = 26; // r FPGA reverse-ring frontier
constexpr std::uint32_t kLwAbiMagic = 0x4e445332u;
constexpr std::uint32_t kLwCapVramPosted = 1u << 0;
constexpr std::uint32_t kLwCapGxPosted = 1u << 1;
constexpr std::uint32_t kLwCapEpochCommit = 1u << 2;
constexpr std::uint32_t kLwCapTwoPhaseSession = 1u << 3;
constexpr std::uint32_t kLwCapTimeIrqReverse = 1u << 4;
// Bit 5 proves that PRODUCER is the largest contiguous verified posted-write
// frontier.  It predates the blocking external-time-window transport and must
// not be reinterpreted as sufficient permission for that larger protocol.
constexpr std::uint32_t kLwCapVerifiedPostedProducer = 1u << 5;
// A production blocking ETW candidate must advertise this independent bit in
// addition to verified posting.  Requiring both makes an old bit-5-only core
// fail closed instead of accidentally enabling the new DDR/BRRP ABI.
constexpr std::uint32_t kLwCapBlockingExternalTimeWindow = 1u << 6;
constexpr std::uint32_t kLwCapLocalLcd = 1u << 7;
constexpr std::uint32_t kLwExternalTimeWindowCaps =
    kLwCapVerifiedPostedProducer | kLwCapBlockingExternalTimeWindow;
constexpr std::uint32_t kLwRequiredBaseCaps =
    kLwCapVramPosted | kLwCapEpochCommit | kLwCapTwoPhaseSession;
constexpr std::size_t kLwRegisterBytes =
    (kLwRegFenceEpoch + 1u) * sizeof(std::uint32_t);
constexpr std::size_t kLwReverseRegisterBytes =
    (kLwRegReverseConsumer + 1u) * sizeof(std::uint32_t);
constexpr std::size_t kLwExternalTimeWindowRegisterBytes =
    nds4mister::ExternalTimeWindowLwControl::kRequiredWords *
    sizeof(std::uint32_t);
constexpr unsigned kLwRegLcdMagic = 63;
constexpr unsigned kLwRegLcdStatus = 64;
constexpr unsigned kLwRegLcdProducer = 65;
constexpr unsigned kLwRegLcdHeadSequence = 66;
constexpr unsigned kLwRegLcdHeadTimestampLo = 67;
constexpr unsigned kLwRegLcdHeadTimestampHi = 68;
constexpr unsigned kLwRegLcdHeadMeta = 69;
constexpr unsigned kLwRegLcdHeadDispstat = 70;
constexpr unsigned kLwRegLcdHeadFrame = 71;
constexpr unsigned kLwRegLcdDropped = 72;
constexpr unsigned kLwRegLcdAckSequence = 73;
constexpr unsigned kLwRegLcdAckCommit = 74;
constexpr std::size_t kLwLocalLcdRegisterBytes =
    (kLwRegLcdAckCommit + 1u) * sizeof(std::uint32_t);
constexpr std::uint32_t kLwLcdMagic = 0x4c434451u;
constexpr std::uint32_t kLwLcdAckMagic = 0x4c41434bu;
constexpr std::size_t kLcdDrainBatch = 64u;
constexpr std::uint32_t kLwDoorbellIrq = 1u << 0;
constexpr std::uint32_t kLwDoorbellError = 1u << 1;
constexpr std::uint32_t kLwDoorbellMailbox = 1u << 2;
constexpr std::uint32_t kLwDoorbellPosted = 1u << 3;
constexpr std::uint32_t kLwDoorbellSessionRequired = 1u << 4;

enum class LwMailboxDecision {
    Idle,
    AwaitRelease,
    Service,
    Fault,
};

constexpr LwMailboxDecision classifyLwMailboxStatus(
    std::uint32_t status,
    std::uint32_t completed,
    bool responsePublished,
    bool doorbellAdvertised)
{
    if ((status & 1u) == 0)
        return doorbellAdvertised
            ? LwMailboxDecision::Fault
            : LwMailboxDecision::Idle;
    const std::uint32_t sequence = status >> 1;
    if (sequence == 0)
        return LwMailboxDecision::Fault;
    if (responsePublished && sequence == completed)
        return LwMailboxDecision::AwaitRelease;
    const std::uint32_t expected = completed + 1u;
    if (expected == 0 || expected > 0x7fffffffu || sequence != expected)
        return LwMailboxDecision::Fault;
    return LwMailboxDecision::Service;
}

constexpr bool lwTransportProtocolSelfTest()
{
    return kLwRegisterBytes == 104u &&
        kLwLocalLcdRegisterBytes == 300u &&
        kLwCapLocalLcd == (1u << 7) &&
        classifyLwMailboxStatus(0, 0, false, false) ==
            LwMailboxDecision::Idle &&
        classifyLwMailboxStatus(0, 0, false, true) ==
            LwMailboxDecision::Fault &&
        classifyLwMailboxStatus((1u << 1) | 1u, 0, false, true) ==
            LwMailboxDecision::Service &&
        classifyLwMailboxStatus((1u << 1) | 1u, 1, true, true) ==
            LwMailboxDecision::AwaitRelease &&
        classifyLwMailboxStatus((2u << 1) | 1u, 1, true, true) ==
            LwMailboxDecision::Service &&
        // After a transport-session reset the HPS resets completed to zero;
        // a restarted FPGA sequence one must therefore be serviced again.
        classifyLwMailboxStatus((1u << 1) | 1u, 0, false, true) ==
            LwMailboxDecision::Service &&
        classifyLwMailboxStatus((1u << 1) | 1u, 1, false, true) ==
            LwMailboxDecision::Fault &&
        classifyLwMailboxStatus((3u << 1) | 1u, 1, true, true) ==
            LwMailboxDecision::Fault &&
        classifyLwMailboxStatus(1u, 0, false, true) ==
            LwMailboxDecision::Fault;
}
static_assert(lwTransportProtocolSelfTest());

class LcdEventQueueConsumer {
public:
    using Apply = std::function<bool(
        const nds4mister::ExternalLCDPhase&, bool, bool, std::string&)>;
    using Drop = std::function<void()>;
    using Ack = std::function<bool(std::uint32_t, std::string&)>;

    LcdEventQueueConsumer(
        volatile std::uint32_t* words, Apply apply, Drop drop,
        Ack ack = {})
        : words_(words), apply_(std::move(apply)),
          drop_(std::move(drop)), ack_(std::move(ack)) {}

    static bool cleanBeforeArm(
        volatile std::uint32_t* words, std::string& error)
    {
        if (words[kLwRegLcdMagic] != kLwLcdMagic) {
            error = "local LCD queue identity mismatch";
            return false;
        }
        if (words[kLwRegLcdStatus] != (1u << 16) ||
            words[kLwRegLcdProducer] != 0 ||
            words[kLwRegLcdHeadSequence] != 0 ||
            words[kLwRegLcdHeadTimestampLo] != 0 ||
            words[kLwRegLcdHeadTimestampHi] != 0 ||
            words[kLwRegLcdHeadMeta] != 0 ||
            words[kLwRegLcdHeadDispstat] != 0 ||
            words[kLwRegLcdHeadFrame] != 0 ||
            words[kLwRegLcdDropped] != 0 ||
            words[kLwRegLcdAckSequence] != 0 ||
            words[kLwRegLcdAckCommit] != 0) {
            error = "local LCD queue was not in its exact clean pre-arm state";
            return false;
        }
        return true;
    }

    bool beginSession(std::string& error)
    {
        if (words_[kLwRegLcdMagic] != kLwLcdMagic) {
            error = "local LCD queue identity changed at session arm";
            return false;
        }
        const auto status = words_[kLwRegLcdStatus];
        if (!validStatus(status, true, error) ||
            words_[kLwRegLcdDropped] != 0 ||
            words_[kLwRegLcdAckSequence] != 0) {
            if (error.empty())
                error = "local LCD queue did not start a clean epoch";
            return false;
        }
        active_ = true;
        recovering_ = false;
        completedFrameReady_ = false;
        consumerSequence_ = 0;
        observedDropped_ = 0;
        lastProducer_ = words_[kLwRegLcdProducer];
        haveProducer_ = lastProducer_ != 0;
        dropEvidence_ = false;
        haveLatest_ = false;
        haveTimestamp_ = false;
        expected_ = {};
        expected_.sequence = 1;
        expected_.kind = nds4mister::ExternalLCDPhaseKind::ScanlineStart;
        return true;
    }

    bool poll(std::size_t limit, std::uint64_t ceiling,
              std::size_t& drained, std::string& error)
    {
        drained = 0;
        if (!active_) {
            error = "local LCD queue session is not active";
            return false;
        }
        while (drained < limit) {
            if (words_[kLwRegLcdMagic] != kLwLcdMagic) {
                error = "local LCD queue identity changed during the epoch";
                return false;
            }
            const auto status = words_[kLwRegLcdStatus];
            if (!validStatus(status, true, error))
                return false;
            const auto producer = words_[kLwRegLcdProducer];
            if ((haveProducer_ && producer == 0) ||
                producer < lastProducer_ ||
                (lastProducer_ == UINT32_MAX && producer != lastProducer_)) {
                error = "local LCD producer sequence regressed, wrapped, or reset";
                return false;
            }
            if (producer != 0)
                haveProducer_ = true;
            lastProducer_ = producer;

            const auto dropped = words_[kLwRegLcdDropped];
            if (dropped < observedDropped_) {
                error = "local LCD dropped counter regressed";
                return false;
            }
            if (dropped != observedDropped_) {
                observedDropped_ = dropped;
                dropEvidence_ = true;
                enterRecovery();
            }
            const auto level = status & 0xffffu;
            if (level == 0)
                return true;

            nds4mister::ExternalLCDPhase phase;
            if (!readStableHead(phase, error))
                return error.empty();
            if (phase.timestamp > ceiling)
                return true;
            if (phase.sequence == 0 ||
                phase.sequence <= consumerSequence_) {
                error = "local LCD queue replayed or regressed a sequence";
                return false;
            }
            if (phase.sequence > producer) {
                error = "local LCD head exceeded the advertised producer";
                return false;
            }
            if (!validShape(phase)) {
                error = "local LCD queue descriptor shape is invalid";
                return false;
            }
            if (haveTimestamp_ && phase.timestamp <= lastTimestamp_) {
                error = "local LCD queue timestamp did not advance";
                return false;
            }
            if (!recovering_ && !matchesExpected(phase)) {
                if (!dropEvidence_) {
                    error = "local LCD queue sequence/cadence gap without a recorded drop";
                    return false;
                }
                enterRecovery();
            }

            const bool resync = recovering_ &&
                phase.kind == nds4mister::ExternalLCDPhaseKind::FrameWrap &&
                phase.line == 0;
            const bool render = !recovering_ || resync;
            if (!apply_(phase, render, resync, error)) {
                if (error.empty())
                    error = "local LCD renderer phase apply failed";
                return false;
            }
            latest_ = phase;
            haveLatest_ = true;
            if (!acknowledge(phase.sequence, error))
                return false;

            consumerSequence_ = phase.sequence;
            lastTimestamp_ = phase.timestamp;
            haveTimestamp_ = true;
            if (resync) {
                recovering_ = false;
                dropEvidence_ = false;
                advanceExpected(phase);
            } else if (!recovering_) {
                if (phase.kind ==
                    nds4mister::ExternalLCDPhaseKind::FrameWrap)
                    completedFrameReady_ = true;
                advanceExpected(phase);
            }
            ++drained;
            // The capture buffers are single-frame storage. Return at a
            // coherent wrap so the caller publishes before any next-frame
            // HBlank overwrites line zero. The 64-record limit still drains a
            // complete hardware queue when no publication boundary occurs.
            if (completedFrameReady_)
                return true;
        }
        return true;
    }

    bool drainThrough(std::uint64_t timestamp, std::string& error)
    {
        const auto deadline =
            std::chrono::steady_clock::now() + std::chrono::seconds(1);
        for (;;) {
            if (!recovering_ && expected_.timestamp > timestamp)
                return true;
            if (completedFrameReady_ && expected_.timestamp <= timestamp) {
                // An exact MMIO barrier can require phases from the next
                // frame before the outer loop can publish the completed one.
                // Drop that frame before its single-frame capture storage is
                // overwritten. Cadence remains continuous, and publication
                // resumes only at the next coherent wrap.
                completedFrameReady_ = false;
                if (drop_)
                    drop_();
            }
            std::size_t drained = 0;
            if (!poll(kLcdDrainBatch, timestamp, drained, error))
                return false;
            if (!recovering_ && expected_.timestamp > timestamp)
                return true;
            if (recovering_ && drained == 0) {
                error = "local LCD drop removed exact MMIO history before the requested timestamp";
                return false;
            }
            if (drained != 0)
                continue;
            if (std::chrono::steady_clock::now() >= deadline) {
                error = "local LCD queue did not publish through the requested timestamp";
                return false;
            }
            sched_yield();
        }
    }

    bool completedFrameReady() const noexcept
    {
        return completedFrameReady_;
    }
    void retireCompletedFrame() noexcept { completedFrameReady_ = false; }
    bool recovering() const noexcept { return recovering_; }
    std::uint32_t consumerSequence() const noexcept
    {
        return consumerSequence_;
    }

    bool exactAccess(
        const nds4mister::ExternalBlockingMMIORequest& request,
        nds4mister::ExternalBlockingMMIOOverrideResult& result,
        std::string& error) const
    {
        result = {};
        if (request.access > 2)
            return true;
        const std::uint64_t first = request.address;
        const std::uint64_t width = std::uint64_t{1} << request.access;
        const std::uint64_t last = first + width - 1u;
        if (first > 0x04000007u || last < 0x04000004u)
            return true;
        if (first < 0x04000004u || last > 0x04000007u ||
            (first & (width - 1u)) != 0) {
            error = "local LCD exact access crossed or misaligned its register word";
            return false;
        }
        if (!haveLatest_) {
            error = "local LCD exact access has no drained FPGA snapshot";
            return false;
        }
        result.handled = true;
        if (request.write)
            return true;
        const std::uint32_t packed =
            (request.arm9 ? latest_.dispstat9 : latest_.dispstat7) |
            (static_cast<std::uint32_t>(latest_.vcount) << 16);
        const auto shift =
            static_cast<unsigned>((first - 0x04000004u) * 8u);
        const std::uint32_t mask = request.access == 0
            ? 0xffu : request.access == 1 ? 0xffffu : UINT32_MAX;
        result.readData = (packed >> shift) & mask;
        return true;
    }

private:
    static bool validShape(const nds4mister::ExternalLCDPhase& phase)
    {
        return phase.line <= 262 && phase.vcount <= 511 &&
            (phase.kind != nds4mister::ExternalLCDPhaseKind::FrameWrap ||
             phase.line == 0);
    }

    static bool validStatus(
        std::uint32_t status, bool requireEnabled, std::string& error)
    {
        const auto level = status & 0xffffu;
        const bool empty = (status & (1u << 16)) != 0;
        const bool full = (status & (1u << 17)) != 0;
        const bool enabled = (status & (1u << 30)) != 0;
        const bool fault = (status & (1u << 31)) != 0;
        if (fault || level > 64 || empty != (level == 0) ||
            full != (level == 64) || enabled != requireEnabled) {
            error = fault
                ? "local LCD queue reported a protocol fault"
                : "local LCD queue status is inconsistent or changed epoch";
            return false;
        }
        return true;
    }

    bool readStableHead(
        nds4mister::ExternalLCDPhase& phase, std::string& error) const
    {
        const auto sequence1 = words_[kLwRegLcdHeadSequence];
        const auto timestampLo = words_[kLwRegLcdHeadTimestampLo];
        const auto timestampHi = words_[kLwRegLcdHeadTimestampHi];
        const auto meta = words_[kLwRegLcdHeadMeta];
        const auto dispstat = words_[kLwRegLcdHeadDispstat];
        const auto frame = words_[kLwRegLcdHeadFrame];
        __sync_synchronize();
        const auto sequence2 = words_[kLwRegLcdHeadSequence];
        const auto status = words_[kLwRegLcdStatus];
        if (!validStatus(status, true, error))
            return false;
        if (sequence1 == 0 || sequence1 != sequence2) {
            error.clear();
            return false;
        }
        if ((meta & 0xfff00000u) != 0) {
            error = "local LCD queue descriptor reserved bits are nonzero";
            return false;
        }
        phase.sequence = sequence1;
        phase.timestamp =
            (static_cast<std::uint64_t>(timestampHi) << 32) | timestampLo;
        phase.kind = static_cast<nds4mister::ExternalLCDPhaseKind>(
            (meta >> 18) & 3u);
        phase.line = static_cast<std::uint16_t>(meta & 0x1ffu);
        phase.vcount = static_cast<std::uint16_t>((meta >> 9) & 0x1ffu);
        phase.dispstat9 = static_cast<std::uint16_t>(dispstat);
        phase.dispstat7 = static_cast<std::uint16_t>(dispstat >> 16);
        phase.frameSequence = frame;
        return true;
    }

    bool matchesExpected(const nds4mister::ExternalLCDPhase& phase) const
    {
        return phase.sequence == expected_.sequence &&
            phase.timestamp == expected_.timestamp &&
            phase.kind == expected_.kind && phase.line == expected_.line &&
            phase.frameSequence == expected_.frameSequence;
    }

    void advanceExpected(const nds4mister::ExternalLCDPhase& phase)
    {
        expected_ = phase;
        expected_.sequence = phase.sequence + 1u;
        if (expected_.sequence == 0)
            throw std::runtime_error(
                "local LCD queue sequence space exhausted");
        if (phase.kind == nds4mister::ExternalLCDPhaseKind::HBlank) {
            expected_.timestamp += 546u;
            if (phase.line == 262) {
                expected_.kind =
                    nds4mister::ExternalLCDPhaseKind::FrameWrap;
                expected_.line = 0;
                ++expected_.frameSequence;
            } else {
                expected_.kind =
                    nds4mister::ExternalLCDPhaseKind::ScanlineStart;
                ++expected_.line;
            }
        } else {
            expected_.timestamp += 1584u;
            expected_.kind = nds4mister::ExternalLCDPhaseKind::HBlank;
        }
    }

    void enterRecovery()
    {
        if (recovering_)
            return;
        recovering_ = true;
        completedFrameReady_ = false;
        if (drop_)
            drop_();
    }

    bool acknowledge(std::uint32_t sequence, std::string& error)
    {
        if (ack_)
            return ack_(sequence, error);
        words_[kLwRegLcdAckSequence] = sequence;
        __sync_synchronize();
        words_[kLwRegLcdAckCommit] = kLwLcdAckMagic;
        __sync_synchronize();
        for (unsigned retry = 0; retry < 1024; ++retry) {
            const auto status = words_[kLwRegLcdStatus];
            if ((status & (1u << 31)) != 0) {
                error = "local LCD queue rejected its head ACK";
                return false;
            }
            if (words_[kLwRegLcdAckSequence] == sequence)
                return true;
            sched_yield();
        }
        error = "local LCD queue ACK readback timeout";
        return false;
    }

    volatile std::uint32_t* words_ = nullptr;
    Apply apply_;
    Drop drop_;
    Ack ack_;
    bool active_ = false;
    bool recovering_ = false;
    bool completedFrameReady_ = false;
    bool haveTimestamp_ = false;
    bool haveProducer_ = false;
    bool dropEvidence_ = false;
    bool haveLatest_ = false;
    std::uint32_t consumerSequence_ = 0;
    std::uint32_t observedDropped_ = 0;
    std::uint32_t lastProducer_ = 0;
    std::uint64_t lastTimestamp_ = 0;
    nds4mister::ExternalLCDPhase expected_{};
    nds4mister::ExternalLCDPhase latest_{};
};

enum class LcdQueueArmDecision {
    AwaitEnable,
    Ready,
    Fault,
};

constexpr LcdQueueArmDecision classifyLcdQueueArmState(
    std::uint32_t status, std::uint32_t dropped,
    std::uint32_t consumer)
{
    if (dropped != 0 || consumer != 0)
        return LcdQueueArmDecision::Fault;
    if (status == (1u << 16))
        return LcdQueueArmDecision::AwaitEnable;
    const auto level = status & 0xffffu;
    const bool empty = (status & (1u << 16)) != 0;
    const bool full = (status & (1u << 17)) != 0;
    const bool enabled = (status & (1u << 30)) != 0;
    const bool fault = (status & (1u << 31)) != 0;
    return !fault && enabled && level <= 64 &&
            empty == (level == 0) && full == (level == 64)
        ? LcdQueueArmDecision::Ready
        : LcdQueueArmDecision::Fault;
}

static_assert(classifyLcdQueueArmState(1u << 16, 0, 0) ==
              LcdQueueArmDecision::AwaitEnable);
static_assert(classifyLcdQueueArmState((1u << 30) | (1u << 16), 0, 0) ==
              LcdQueueArmDecision::Ready);
static_assert(classifyLcdQueueArmState((1u << 30) | 1u, 0, 0) ==
              LcdQueueArmDecision::Ready);
static_assert(classifyLcdQueueArmState(1u << 16, 1, 0) ==
              LcdQueueArmDecision::Fault);
static_assert(classifyLcdQueueArmState((1u << 30) | (1u << 16), 0, 1) ==
              LcdQueueArmDecision::Fault);
static_assert(classifyLcdQueueArmState((1u << 30) | (1u << 16) | 1u, 0, 0) ==
              LcdQueueArmDecision::Fault);

bool lcdEventQueueConsumerSelfTest()
{
    using Kind = nds4mister::ExternalLCDPhaseKind;
    using Phase = nds4mister::ExternalLCDPhase;
    using Request = nds4mister::ExternalBlockingMMIORequest;
    using Override = nds4mister::ExternalBlockingMMIOOverrideResult;

    std::array<std::uint32_t, kLwRegLcdAckCommit + 1u> clean{};
    clean[kLwRegLcdMagic] = kLwLcdMagic;
    clean[kLwRegLcdStatus] = 1u << 16;
    std::string error;
    if (!LcdEventQueueConsumer::cleanBeforeArm(clean.data(), error))
        return false;
    clean[kLwRegLcdProducer] = 1;
    if (LcdEventQueueConsumer::cleanBeforeArm(clean.data(), error))
        return false;

    const auto encode = [](std::array<std::uint32_t,
                           kLwRegLcdAckCommit + 1u>& words,
                           const Phase& phase) {
        words[kLwRegLcdHeadSequence] = phase.sequence;
        words[kLwRegLcdHeadTimestampLo] =
            static_cast<std::uint32_t>(phase.timestamp);
        words[kLwRegLcdHeadTimestampHi] =
            static_cast<std::uint32_t>(phase.timestamp >> 32);
        words[kLwRegLcdHeadMeta] = phase.line |
            (static_cast<std::uint32_t>(phase.vcount) << 9) |
            (static_cast<std::uint32_t>(phase.kind) << 18);
        words[kLwRegLcdHeadDispstat] = phase.dispstat9 |
            (static_cast<std::uint32_t>(phase.dispstat7) << 16);
        words[kLwRegLcdHeadFrame] = phase.frameSequence;
    };

    std::array<std::uint32_t, kLwRegLcdAckCommit + 1u> words{};
    const std::vector<Phase> phases{
        {1, 0, Kind::ScanlineStart, 0, 0, 0x1200, 0xab00, 0},
        {2, 1584, Kind::HBlank, 0, 7, 0x1234, 0xabcd, 0},
        {3, 2130, Kind::ScanlineStart, 1, 1, 0x1200, 0xab00, 0},
    };
    std::size_t index = 0;
    const auto load = [&] {
        const auto level = phases.size() - index;
        words[kLwRegLcdMagic] = kLwLcdMagic;
        words[kLwRegLcdStatus] = (1u << 30) |
            (level == 0 ? (1u << 16) : 0u) |
            static_cast<std::uint32_t>(level);
        words[kLwRegLcdProducer] = phases.back().sequence;
        if (level != 0)
            encode(words, phases[index]);
    };
    std::vector<std::uint32_t> applied;
    load();
    LcdEventQueueConsumer consumer(
        words.data(),
        [&](const Phase& phase, bool render, bool resync,
            std::string&) {
            if (!render || resync)
                return false;
            applied.push_back(phase.sequence);
            return true;
        },
        [] {},
        [&](std::uint32_t sequence, std::string&) {
            if (index >= phases.size() ||
                phases[index].sequence != sequence)
                return false;
            words[kLwRegLcdAckSequence] = sequence;
            ++index;
            load();
            return true;
        });
    if (!consumer.beginSession(error) ||
        !consumer.drainThrough(1584, error) ||
        consumer.consumerSequence() != 2 ||
        applied != std::vector<std::uint32_t>({1, 2}))
        return false;

    Override result;
    Request request;
    request.arm9 = true;
    request.address = 0x04000004u;
    request.access = 2;
    if (!consumer.exactAccess(request, result, error) || !result.handled ||
        result.readData != 0x00071234u)
        return false;
    request.arm9 = false;
    request.address = 0x04000005u;
    request.access = 0;
    if (!consumer.exactAccess(request, result, error) ||
        result.readData != 0xabu)
        return false;
    request.address = 0x04000006u;
    request.access = 1;
    if (!consumer.exactAccess(request, result, error) ||
        result.readData != 7u)
        return false;
    request.write = true;
    request.address = 0x04000004u;
    if (!consumer.exactAccess(request, result, error) ||
        !result.handled || result.readData != 0)
        return false;

    // If an inclusive exact-access drain crosses a frame wrap, the completed
    // frame must be dropped before the next frame overwrites its capture
    // storage. Build one exact cadence plus the following HBlank to exercise
    // that policy without a new test harness.
    std::vector<Phase> framePhases;
    std::uint32_t frameSequence = 0;
    std::uint32_t framePhaseSequence = 1;
    std::uint64_t frameTimestamp = 0;
    for (std::uint16_t line = 0; line <= 262; ++line) {
        framePhases.push_back({
            framePhaseSequence++, frameTimestamp, Kind::ScanlineStart,
            line, line, 0, 0, frameSequence});
        frameTimestamp += 1584;
        framePhases.push_back({
            framePhaseSequence++, frameTimestamp, Kind::HBlank,
            line, line, 0, 0, frameSequence});
        frameTimestamp += 546;
    }
    ++frameSequence;
    framePhases.push_back({
        framePhaseSequence++, frameTimestamp, Kind::FrameWrap,
        0, 0, 0, 0, frameSequence});
    frameTimestamp += 1584;
    framePhases.push_back({
        framePhaseSequence++, frameTimestamp, Kind::HBlank,
        0, 0, 0, 0, frameSequence});
    std::array<std::uint32_t, kLwRegLcdAckCommit + 1u> frameWords{};
    std::size_t frameIndex = 0;
    const auto loadFrame = [&] {
        frameWords[kLwRegLcdMagic] = kLwLcdMagic;
        frameWords[kLwRegLcdStatus] = (1u << 30) |
            (frameIndex == framePhases.size() ? (1u << 16) : 1u);
        frameWords[kLwRegLcdProducer] = framePhases.back().sequence;
        if (frameIndex != framePhases.size())
            encode(frameWords, framePhases[frameIndex]);
    };
    unsigned frameDrops = 0;
    loadFrame();
    LcdEventQueueConsumer frameConsumer(
        frameWords.data(),
        [](const Phase&, bool render, bool resync, std::string&) {
            return render && !resync;
        },
        [&] { ++frameDrops; },
        [&](std::uint32_t sequence, std::string&) {
            if (frameIndex >= framePhases.size() ||
                framePhases[frameIndex].sequence != sequence)
                return false;
            frameWords[kLwRegLcdAckSequence] = sequence;
            ++frameIndex;
            loadFrame();
            return true;
        });
    if (!frameConsumer.beginSession(error) ||
        !frameConsumer.drainThrough(framePhases.back().timestamp, error) ||
        frameConsumer.consumerSequence() != framePhases.back().sequence ||
        frameConsumer.completedFrameReady() || frameDrops != 1)
        return false;

    // One observed drop authorizes one recovery only. Resynchronize at the
    // next frame wrap, then reject a later gap when DROPPED did not advance.
    std::array<std::uint32_t, kLwRegLcdAckCommit + 1u> gapWords{};
    const std::vector<Phase> gapPhases{
        {1, 0, Kind::ScanlineStart, 0, 0, 0, 0, 0},
        {527, 560190, Kind::FrameWrap, 0, 0, 0, 0, 1},
        {529, 562320, Kind::ScanlineStart, 1, 1, 0, 0, 1},
    };
    std::size_t gapIndex = 0;
    const auto loadGap = [&] {
        const auto level = gapPhases.size() - gapIndex;
        gapWords[kLwRegLcdMagic] = kLwLcdMagic;
        gapWords[kLwRegLcdStatus] = (1u << 30) |
            (level == 0 ? (1u << 16) : 0u) |
            static_cast<std::uint32_t>(level);
        gapWords[kLwRegLcdProducer] = gapPhases.back().sequence;
        if (level != 0)
            encode(gapWords, gapPhases[gapIndex]);
    };
    unsigned drops = 0;
    std::vector<std::uint32_t> rendered;
    loadGap();
    LcdEventQueueConsumer gapConsumer(
        gapWords.data(),
        [&](const Phase& phase, bool render, bool resync,
            std::string&) {
            if (render)
                rendered.push_back(phase.sequence);
            return !render || resync;
        },
        [&] { ++drops; },
        [&](std::uint32_t sequence, std::string&) {
            if (gapPhases[gapIndex].sequence != sequence)
                return false;
            gapWords[kLwRegLcdAckSequence] = sequence;
            ++gapIndex;
            loadGap();
            return true;
        });
    if (!gapConsumer.beginSession(error))
        return false;
    gapWords[kLwRegLcdDropped] = 1;
    std::size_t drained = 0;
    if (!gapConsumer.poll(2, UINT64_MAX, drained, error) || drained != 2 ||
        gapConsumer.recovering() || drops != 1 ||
        rendered != std::vector<std::uint32_t>({527}))
        return false;
    if (gapConsumer.poll(1, UINT64_MAX, drained, error) ||
        error.find("without a recorded drop") == std::string::npos)
        return false;

    // Identity and producer continuity are epoch checks on every poll.
    gapWords[kLwRegLcdMagic] = 0;
    if (gapConsumer.poll(1, UINT64_MAX, drained, error) ||
        error.find("identity changed") == std::string::npos)
        return false;
    gapWords[kLwRegLcdMagic] = kLwLcdMagic;
    gapWords[kLwRegLcdProducer] = 0;
    if (gapConsumer.poll(1, UINT64_MAX, drained, error) ||
        error.find("producer sequence") == std::string::npos)
        return false;
    return true;
}

constexpr bool postedDrainWithinAdvertisedFrontier(
    std::uint32_t advertised,
    std::uint32_t consumed,
    std::uint32_t target)
{
    return advertised >= consumed &&
        advertised - consumed < nds4mister::kPostedWriteRingEntries &&
        target >= consumed && target <= advertised;
}
static_assert(postedDrainWithinAdvertisedFrontier(0, 0, 0));
static_assert(postedDrainWithinAdvertisedFrontier(7, 5, 5));
static_assert(postedDrainWithinAdvertisedFrontier(7, 5, 7));
static_assert(!postedDrainWithinAdvertisedFrontier(7, 5, 8));
static_assert(!postedDrainWithinAdvertisedFrontier(7, 5, 4));
static_assert(!postedDrainWithinAdvertisedFrontier(4, 5, 5));

constexpr bool externalTimeWindowPostedStateIsZero(
    std::uint32_t requestedRawFence,
    std::uint32_t advertisedProducer,
    std::uint32_t deviceConsumer,
    std::uint32_t localConsumer,
    std::uint32_t lastPublishedConsumer)
{
    return requestedRawFence == 0 && advertisedProducer == 0 &&
        deviceConsumer == 0 && localConsumer == 0 &&
        lastPublishedConsumer == 0;
}
static_assert(externalTimeWindowPostedStateIsZero(0, 0, 0, 0, 0));
static_assert(!externalTimeWindowPostedStateIsZero(1, 0, 0, 0, 0));
static_assert(!externalTimeWindowPostedStateIsZero(0, 1, 0, 0, 0));
static_assert(!externalTimeWindowPostedStateIsZero(0, 0, 1, 0, 0));
static_assert(!externalTimeWindowPostedStateIsZero(0, 0, 0, 1, 0));
static_assert(!externalTimeWindowPostedStateIsZero(0, 0, 0, 0, 1));
constexpr std::size_t kCompactPixels = 512u * 192u;
constexpr std::size_t kCompactFrameBytes = kCompactPixels * sizeof(std::uint16_t);
constexpr std::size_t kCompactMapBytes = 3u * nds4mister::kLayerSlotBytes;
constexpr std::uint64_t kFramePeriodNanoseconds = 16715200;
constexpr std::uint64_t kNanosecondsPerSecond = 1000000000;
constexpr std::uint32_t kAudioSampleRate = 48000;
constexpr std::uint32_t canonicalizeExecutionPc(
    std::uint32_t pc, bool arm9)
{
    // r112 proves the dedicated execute-PC path reaches HPS, but the retired
    // diagnostic mux still contaminates only its top nibble in hardware.
    // All normal DS execution regions fit in the low 28 bits. ARM9's high
    // BIOS is the sole exception and is unambiguous from 0x0fffxxxx.
    const std::uint32_t low28 = pc & 0x0fffffffu;
    return arm9 && (low28 & 0x0fff0000u) == 0x0fff0000u
        ? low28 | 0xf0000000u
        : low28;
}
constexpr std::uint32_t decodeExecutionPc(
    std::uint32_t payload, bool readNotWrite, bool encoded, bool arm9)
{
    return readNotWrite && encoded
        ? canonicalizeExecutionPc(
              payload ^ (arm9 ? 0x40000000u : 0x80000000u), arm9)
        : payload;
}
static_assert(
    decodeExecutionPc(0x42068a3cu, true, true, true) == 0x02068a3cu);
static_assert(
    decodeExecutionPc(0x82380000u, true, true, false) == 0x02380000u);
static_assert(
    decodeExecutionPc(0x8200100cu, true, true, true) == 0x0200100cu);
static_assert(
    decodeExecutionPc(0xd2022914u, true, true, true) == 0x02022914u);
static_assert(
    decodeExecutionPc(0x8fff06f4u, true, true, true) == 0xffff06f4u);
static_assert(
    decodeExecutionPc(0xf37fe920u, true, true, false) == 0x037fe920u);
static_assert(
    decodeExecutionPc(0x000001abu, false, true, true) == 0x000001abu);
constexpr bool shouldTriggerBadPc(bool timingOnly,
                                  bool validPc,
                                  bool invalidExternalAddress,
                                  bool addressOnly)
{
    // Packed FPGA diagnostic words intentionally replace the live PC on
    // timing-only heartbeats. They must remain in the flight recorder, but
    // cannot themselves be treated as corrupt execution. A real bus request
    // with an invalid PC, or any invalid external address, is actionable.
    return (!addressOnly && !timingOnly && !validPc) ||
           invalidExternalAddress;
}
static_assert(!shouldTriggerBadPc(true, false, false, false));
static_assert(shouldTriggerBadPc(false, false, false, false));
static_assert(shouldTriggerBadPc(false, true, true, false));
static_assert(!shouldTriggerBadPc(false, false, false, true));
static_assert(shouldTriggerBadPc(false, true, true, true));
volatile std::sig_atomic_t running = 1;

void stop(int) { running = 0; }

class RuntimeProfiler {
public:
    explicit RuntimeProfiler(std::uint64_t intervalSeconds,
                             bool announce = true)
        : enabled_(intervalSeconds != 0),
          intervalNanoseconds_(intervalSeconds * kNanosecondsPerSecond) {
        if (!enabled_) return;
        lastWallNanoseconds_ = wallNanoseconds();
        lastCpuNanoseconds_ = processCpuNanoseconds();
        if (announce) {
            std::cerr << "NDS4MISTER_PROFILE_V1 enabled interval_seconds="
                      << intervalSeconds
                      << " posted_sample_period=192..319"
                      << " mailbox_sample_period=48..79"
                      << " input_sample_period=192..319"
                      << " idle_yield_sample_period=48..79\n"
                      << std::flush;
        }
    }

    bool enabled() const { return enabled_; }

    std::uint64_t timestampNanoseconds() const {
        return wallNanoseconds();
    }

    void noteLoop() {
        if (enabled_) ++interval_.mainLoops;
    }

    void noteIdleDrain(std::size_t drained) {
        if (!enabled_) return;
        ++interval_.idleDrainCalls;
        interval_.idleDrainedEntries += drained;
    }

    bool beginIdleYield() {
        if (!enabled_) return false;
        ++interval_.idleYields;
        return countdownSample(
            idleYieldCountdown_, idleYieldRandom_, 48, 0x1fu);
    }

    void finishIdleYield(std::uint64_t nanoseconds) {
        ++interval_.sampledIdleYields;
        interval_.idleYieldNanoseconds += nanoseconds;
    }

    bool beginInput() {
        if (!enabled_) return false;
        ++interval_.inputCalls;
        return countdownSample(
            inputCountdown_, inputRandom_, 192, 0x7fu);
    }

    void finishInput(std::uint64_t nanoseconds) {
        ++interval_.sampledInputs;
        interval_.inputNanoseconds += nanoseconds;
    }

    bool beginPosted(std::uint32_t cycles) {
        if (!enabled_) return false;
        ++interval_.postedEntries;
        interval_.postedCycles += cycles;
        if (cycles == 0) ++interval_.postedZeroCycles;
        return countdownSample(
            postedCountdown_, postedRandom_, 192, 0x7fu);
    }

    void finishPosted(std::uint64_t advanceNanoseconds,
                      std::uint64_t busNanoseconds,
                      std::uint64_t publishCheckNanoseconds) {
        ++interval_.sampledPosted;
        interval_.postedAdvanceNanoseconds += advanceNanoseconds;
        interval_.postedBusNanoseconds += busNanoseconds;
        interval_.postedPublishCheckNanoseconds += publishCheckNanoseconds;
    }

    bool beginMailbox(std::uint32_t address,
                      std::uint32_t control,
                      std::uint32_t cycles) {
        if (!enabled_) return false;
        ++interval_.mailboxRequests;
        interval_.mailboxCycles += cycles;
        if (cycles == 0) ++interval_.mailboxZeroCycles;
        if (address == 0xffffffffu) ++interval_.mailboxTiming;
        else {
            if (control & 1u) ++interval_.mailboxReads;
            else ++interval_.mailboxWrites;
            ++interval_.mailboxRegions[address >> 24];
            if ((address & 0xfffff000u) == 0x04000000u) {
                const auto offset = address & 0xfffu;
                ++interval_.primaryIoCount[offset];
                if (control & 1u) ++interval_.primaryIoReadCount[offset];
                if (control & 8u) ++interval_.primaryIoArm9Count[offset];
            }
        }
        if (control & 8u) ++interval_.mailboxArm9;
        else ++interval_.mailboxArm7;
        return countdownSample(
            mailboxCountdown_, mailboxRandom_, 48, 0x1fu);
    }

    void finishMailbox(std::uint64_t fenceNanoseconds,
                       std::uint64_t inputNanoseconds,
                       std::uint64_t advanceNanoseconds,
                       std::uint64_t busNanoseconds,
                       std::uint64_t publishCheckNanoseconds,
                       std::uint64_t responseNanoseconds,
                       std::uint64_t totalNanoseconds) {
        ++interval_.sampledMailbox;
        interval_.mailboxFenceNanoseconds += fenceNanoseconds;
        interval_.mailboxInputNanoseconds += inputNanoseconds;
        interval_.mailboxAdvanceNanoseconds += advanceNanoseconds;
        interval_.mailboxBusNanoseconds += busNanoseconds;
        interval_.mailboxPublishCheckNanoseconds += publishCheckNanoseconds;
        interval_.mailboxResponseNanoseconds += responseNanoseconds;
        interval_.mailboxTotalNanoseconds += totalNanoseconds;
    }

    void recordPublication(std::uint32_t audioFrames,
                           std::uint64_t audioReadNanoseconds,
                           std::uint64_t audioNormalizeNanoseconds,
                           std::uint64_t framePaceNanoseconds,
                           std::uint64_t publishNanoseconds) {
        if (!enabled_) return;
        ++interval_.publishedFrames;
        interval_.publishedAudioFrames += audioFrames;
        interval_.audioReadNanoseconds += audioReadNanoseconds;
        interval_.audioNormalizeNanoseconds += audioNormalizeNanoseconds;
        interval_.framePaceNanoseconds += framePaceNanoseconds;
        interval_.publicationNanoseconds += publishNanoseconds;
    }

    void recordSchedulerSleep(std::uint64_t nanoseconds) {
        if (!enabled_) return;
        ++interval_.schedulerSleeps;
        interval_.schedulerSleepNanoseconds += nanoseconds;
    }

    void maybeReport(std::uint32_t consumerSequence,
                     std::uint32_t completedGeneration,
                     std::uint64_t publishedTotal,
                     bool force = false,
                     bool emit = true) {
        if (!enabled_) return;
        const auto nowWall = wallNanoseconds();
        if (!force &&
            nowWall - lastWallNanoseconds_ < intervalNanoseconds_)
            return;
        const auto nowCpu = processCpuNanoseconds();
        const auto wallDelta = nowWall - lastWallNanoseconds_;
        const auto cpuDelta = nowCpu >= lastCpuNanoseconds_
            ? nowCpu - lastCpuNanoseconds_ : 0;
        const auto& p = interval_;
        if (emit) {
            std::cerr
                << "NDS4MISTER_PROFILE_V1"
                << " wall_ns=" << wallDelta
                << " cpu_ns=" << cpuDelta
                << " consumer=" << consumerSequence
                << " completed_generation=" << completedGeneration
                << " published_total=" << publishedTotal
                << " main_loops=" << p.mainLoops
                << " idle_drain_calls=" << p.idleDrainCalls
                << " idle_drained_entries=" << p.idleDrainedEntries
                << " idle_yields=" << p.idleYields
                << " sampled_idle_yields=" << p.sampledIdleYields
                << " idle_yield_ns=" << p.idleYieldNanoseconds
                << " posted_entries=" << p.postedEntries
                << " posted_zero_cycles=" << p.postedZeroCycles
                << " posted_cycles=" << p.postedCycles
                << " sampled_posted=" << p.sampledPosted
                << " posted_advance_ns=" << p.postedAdvanceNanoseconds
                << " posted_bus_ns=" << p.postedBusNanoseconds
                << " posted_publish_check_ns="
                << p.postedPublishCheckNanoseconds
                << " mailbox_requests=" << p.mailboxRequests
                << " mailbox_timing=" << p.mailboxTiming
                << " mailbox_reads=" << p.mailboxReads
                << " mailbox_writes=" << p.mailboxWrites
                << " mailbox_arm9=" << p.mailboxArm9
                << " mailbox_arm7=" << p.mailboxArm7
                << " mailbox_zero_cycles=" << p.mailboxZeroCycles
                << " mailbox_cycles=" << p.mailboxCycles
                << " sampled_mailbox=" << p.sampledMailbox
                << " mailbox_fence_ns=" << p.mailboxFenceNanoseconds
                << " mailbox_input_ns=" << p.mailboxInputNanoseconds
                << " mailbox_advance_ns=" << p.mailboxAdvanceNanoseconds
                << " mailbox_bus_ns=" << p.mailboxBusNanoseconds
                << " mailbox_publish_check_ns="
                << p.mailboxPublishCheckNanoseconds
                << " mailbox_response_ns=" << p.mailboxResponseNanoseconds
                << " mailbox_total_ns=" << p.mailboxTotalNanoseconds
                << " input_calls=" << p.inputCalls
                << " sampled_inputs=" << p.sampledInputs
                << " input_ns=" << p.inputNanoseconds
                << " scheduler_sleeps=" << p.schedulerSleeps
                << " scheduler_sleep_ns=" << p.schedulerSleepNanoseconds
                << " published_frames=" << p.publishedFrames
                << " published_audio_frames=" << p.publishedAudioFrames
                << " audio_read_ns=" << p.audioReadNanoseconds
                << " audio_normalize_ns=" << p.audioNormalizeNanoseconds
                << " frame_pace_ns=" << p.framePaceNanoseconds
                << " publication_ns=" << p.publicationNanoseconds
                << "\n" << std::flush;

            // The remaining hybrid bottleneck is serialized external I/O.
            // Keep an exact, allocation-free histogram for the primary DS I/O
            // page so each hardware run identifies the next subsystem to move
            // into RTL instead of relying on a high-overhead request trace.
            std::array<std::uint16_t, 16> topOffsets{};
            std::array<std::uint32_t, 16> topCounts{};
            for (std::uint32_t offset = 0;
                 offset < p.primaryIoCount.size(); ++offset) {
                const auto count = p.primaryIoCount[offset];
                if (!count) continue;
                for (std::size_t rank = 0; rank < topCounts.size(); ++rank) {
                    if (count < topCounts[rank] ||
                        (count == topCounts[rank] &&
                         offset >= topOffsets[rank]))
                        continue;
                    for (std::size_t move = topCounts.size() - 1;
                         move > rank; --move) {
                        topCounts[move] = topCounts[move - 1];
                        topOffsets[move] = topOffsets[move - 1];
                    }
                    topCounts[rank] = count;
                    topOffsets[rank] = static_cast<std::uint16_t>(offset);
                    break;
                }
            }
            std::cerr
                << "NDS4MISTER_IO_PROFILE_V1"
                << " mailbox=" << p.mailboxRequests
                << " timing=" << p.mailboxTiming
                << " region04=" << p.mailboxRegions[0x04]
                << " region06=" << p.mailboxRegions[0x06];
            for (std::size_t rank = 0; rank < topCounts.size(); ++rank) {
                if (!topCounts[rank]) break;
                const auto offset = topOffsets[rank];
                std::cerr
                    << " rank" << rank << "=0x" << std::hex
                    << (0x04000000u + offset) << std::dec
                    << ':' << topCounts[rank]
                    << ':' << p.primaryIoReadCount[offset]
                    << ':' << p.primaryIoArm9Count[offset];
            }
            std::cerr << "\n" << std::flush;
        }
        interval_ = {};
        lastWallNanoseconds_ = nowWall;
        lastCpuNanoseconds_ = nowCpu;
    }

    static bool selfTest() {
        RuntimeProfiler disabled(0, false);
        if (disabled.enabled() || disabled.beginPosted(1) ||
            disabled.beginMailbox(0, 0, 0) || disabled.beginInput())
            return false;

        RuntimeProfiler profiler(1, false);
        if (!profiler.enabled()) return false;
        bool postedSample = false;
        for (unsigned index = 0; index < 256; ++index)
            postedSample = profiler.beginPosted(index == 0 ? 0 : 3);
        if (!postedSample || profiler.interval_.postedEntries != 256 ||
            profiler.interval_.postedZeroCycles != 1 ||
            profiler.interval_.postedCycles != 765)
            return false;
        profiler.finishPosted(11, 13, 17);

        bool mailboxSample = false;
        for (unsigned index = 0; index < 64; ++index)
            mailboxSample = profiler.beginMailbox(
                index == 0 ? 0xffffffffu : 0x04000000u,
                index & 1u ? 0x9u : 0u, index == 1 ? 0 : 5);
        if (!mailboxSample || profiler.interval_.mailboxRequests != 64 ||
            profiler.interval_.mailboxTiming != 1 ||
            profiler.interval_.mailboxReads != 32 ||
            profiler.interval_.mailboxWrites != 31 ||
            profiler.interval_.mailboxArm9 != 32 ||
            profiler.interval_.mailboxArm7 != 32 ||
            profiler.interval_.mailboxZeroCycles != 1 ||
            profiler.interval_.mailboxRegions[0x04] != 63 ||
            profiler.interval_.primaryIoCount[0] != 63 ||
            profiler.interval_.primaryIoReadCount[0] != 32 ||
            profiler.interval_.primaryIoArm9Count[0] != 32)
            return false;
        profiler.finishMailbox(19, 23, 29, 31, 37, 41, 181);

        bool inputSample = false;
        for (unsigned index = 0; index < 256; ++index)
            inputSample = profiler.beginInput();
        if (!inputSample) return false;
        profiler.finishInput(43);
        profiler.recordPublication(803, 47, 53, 59, 61);
        profiler.recordSchedulerSleep(67);
        const bool countersCorrect =
               profiler.interval_.sampledPosted == 1 &&
               profiler.interval_.postedAdvanceNanoseconds == 11 &&
               profiler.interval_.postedBusNanoseconds == 13 &&
               profiler.interval_.postedPublishCheckNanoseconds == 17 &&
               profiler.interval_.sampledMailbox == 1 &&
               profiler.interval_.mailboxResponseNanoseconds == 41 &&
               profiler.interval_.mailboxTotalNanoseconds == 181 &&
               profiler.interval_.sampledInputs == 1 &&
               profiler.interval_.inputNanoseconds == 43 &&
               profiler.interval_.publishedFrames == 1 &&
               profiler.interval_.publishedAudioFrames == 803 &&
               profiler.interval_.audioNormalizeNanoseconds == 53 &&
               profiler.interval_.framePaceNanoseconds == 59 &&
               profiler.interval_.publicationNanoseconds == 61 &&
               profiler.interval_.schedulerSleepNanoseconds == 67;
        if (!countersCorrect) return false;
        // Emit the same records used on hardware so the responder gate can
        // validate the profile ABI and exact top-address formatting too.
        profiler.maybeReport(7, 11, 13, true, true);
        if (profiler.interval_.postedEntries != 0 ||
            profiler.interval_.mailboxRequests != 0 ||
            profiler.interval_.mailboxRegions[0x04] != 0 ||
            profiler.interval_.primaryIoCount[0] != 0 ||
            profiler.interval_.inputCalls != 0 ||
            profiler.interval_.publishedFrames != 0)
            return false;
        profiler.beginInput();
        return profiler.interval_.inputCalls == 1;
    }

private:
    struct Counters {
        std::uint64_t mainLoops = 0;
        std::uint64_t idleDrainCalls = 0;
        std::uint64_t idleDrainedEntries = 0;
        std::uint64_t idleYields = 0;
        std::uint64_t sampledIdleYields = 0;
        std::uint64_t idleYieldNanoseconds = 0;
        std::uint64_t inputCalls = 0;
        std::uint64_t sampledInputs = 0;
        std::uint64_t inputNanoseconds = 0;
        std::uint64_t postedEntries = 0;
        std::uint64_t postedZeroCycles = 0;
        std::uint64_t postedCycles = 0;
        std::uint64_t sampledPosted = 0;
        std::uint64_t postedAdvanceNanoseconds = 0;
        std::uint64_t postedBusNanoseconds = 0;
        std::uint64_t postedPublishCheckNanoseconds = 0;
        std::uint64_t mailboxRequests = 0;
        std::uint64_t mailboxTiming = 0;
        std::uint64_t mailboxReads = 0;
        std::uint64_t mailboxWrites = 0;
        std::uint64_t mailboxArm9 = 0;
        std::uint64_t mailboxArm7 = 0;
        std::uint64_t mailboxZeroCycles = 0;
        std::uint64_t mailboxCycles = 0;
        std::array<std::uint64_t, 256> mailboxRegions{};
        std::array<std::uint32_t, 4096> primaryIoCount{};
        std::array<std::uint32_t, 4096> primaryIoReadCount{};
        std::array<std::uint32_t, 4096> primaryIoArm9Count{};
        std::uint64_t sampledMailbox = 0;
        std::uint64_t mailboxFenceNanoseconds = 0;
        std::uint64_t mailboxInputNanoseconds = 0;
        std::uint64_t mailboxAdvanceNanoseconds = 0;
        std::uint64_t mailboxBusNanoseconds = 0;
        std::uint64_t mailboxPublishCheckNanoseconds = 0;
        std::uint64_t mailboxResponseNanoseconds = 0;
        std::uint64_t mailboxTotalNanoseconds = 0;
        std::uint64_t schedulerSleeps = 0;
        std::uint64_t schedulerSleepNanoseconds = 0;
        std::uint64_t publishedFrames = 0;
        std::uint64_t publishedAudioFrames = 0;
        std::uint64_t audioReadNanoseconds = 0;
        std::uint64_t audioNormalizeNanoseconds = 0;
        std::uint64_t framePaceNanoseconds = 0;
        std::uint64_t publicationNanoseconds = 0;
    };

    static std::uint64_t wallNanoseconds() {
        return static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count());
    }

    static std::uint64_t processCpuNanoseconds() {
#if defined(__linux__) && defined(CLOCK_PROCESS_CPUTIME_ID)
        timespec value{};
        if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0) {
            return static_cast<std::uint64_t>(value.tv_sec) *
                       kNanosecondsPerSecond +
                   static_cast<std::uint64_t>(value.tv_nsec);
        }
#endif
        const auto ticks = std::clock();
        if (ticks == static_cast<std::clock_t>(-1)) return 0;
        return static_cast<std::uint64_t>(
            static_cast<long double>(ticks) * kNanosecondsPerSecond /
            CLOCKS_PER_SEC);
    }

    static bool countdownSample(std::uint32_t& countdown,
                                std::uint32_t& randomState,
                                std::uint32_t base,
                                std::uint32_t mask) {
        if (--countdown != 0) return false;
        randomState = randomState * 1664525u + 1013904223u;
        countdown = base + ((randomState >> 16) & mask);
        return true;
    }

    bool enabled_ = false;
    std::uint64_t intervalNanoseconds_ = 0;
    std::uint64_t lastWallNanoseconds_ = 0;
    std::uint64_t lastCpuNanoseconds_ = 0;
    std::uint32_t idleYieldCountdown_ = 64;
    std::uint32_t inputCountdown_ = 256;
    std::uint32_t postedCountdown_ = 256;
    std::uint32_t mailboxCountdown_ = 64;
    std::uint32_t idleYieldRandom_ = 0x9e3779b9u;
    std::uint32_t inputRandom_ = 0x243f6a88u;
    std::uint32_t postedRandom_ = 0xb7e15162u;
    std::uint32_t mailboxRandom_ = 0x8aed2a6bu;
    Counters interval_{};
};

struct PostedWriteEntry {
    std::uint32_t sequence = 0;
    std::uint32_t address = 0;
    std::uint32_t data = 0;
    std::uint32_t cycles = 0;
    std::uint32_t control = 0;
    // NDS IF bits 0..24 for the exact tagged ETW ARM9 IF opcode. Legacy
    // VRAM/GX entries require this field to remain zero.
    std::uint32_t auxiliary = 0;
    std::uint64_t externalTargetTimestamp = 0;
    bool externalArm9If = false;
};

constexpr std::uint32_t kPostedAuxExternalArm9If = 1u << 27;
constexpr std::uint32_t kPostedAuxExternalReserved = 3u << 25;
constexpr std::uint32_t kPostedAuxExternalFinalIf = (1u << 25) - 1u;

// Simulator-first description of the future HPS->FPGA consumed-credit ABI.
// No live responder path instantiates this ledger. The integration hook belongs
// after advance_external_cycles() and the associated bus operation return, not
// at FPGA mailbox launch, posted-ring admission, or posted commit.
enum class ConsumedCreditKind : std::uint32_t {
    Posted = 0,
    Mailbox = 1,
    Halt = 2,
    IrqSet = 3,
};

struct ConsumedCreditAckRecord {
    std::uint32_t epoch = 0;
    std::uint32_t sequence = 0;
    bool arm9 = false;
    std::uint32_t cycles = 0;
    ConsumedCreditKind kind = ConsumedCreditKind::Posted;
    std::uint32_t sourceId = 0;
};

class ConsumedCreditAckLedger {
public:
    explicit ConsumedCreditAckLedger(std::size_t capacity)
        : capacity_(capacity) {
        if (capacity_ == 0)
            throw std::invalid_argument(
                "consumed-credit ACK capacity must be nonzero");
    }

    bool beginEpoch(std::uint32_t epoch, bool transportQuiescent) {
        // A busy transport is ordinary backpressure. Epoch zero or reusing the
        // current nonzero epoch is ambiguous and poisons this instance.
        if (!transportQuiescent || !queue_.empty()) return false;
        if (fault_ || exhausted_ || epoch == 0 ||
            (active_ && epoch == epoch_)) {
            fault_ = true;
            active_ = false;
            return false;
        }
        epoch_ = epoch;
        nextSequence_ = 1;
        active_ = true;
        exhausted_ = false;
        return true;
    }

    template <typename Advance, typename Apply>
    bool consume(
        bool arm9,
        std::uint32_t cycles,
        ConsumedCreditKind kind,
        std::uint32_t sourceId,
        Advance&& advance,
        Apply&& apply) {
        // Reserve transport capacity before changing emulator state. If the
        // ACK stream stalls, neither elapsed time nor the associated bus effect
        // may be consumed speculatively.
        if (!active_ || fault_ || exhausted_ ||
            queue_.size() >= capacity_)
            return false;
        if (kind == ConsumedCreditKind::IrqSet &&
            (cycles != 0 || sourceId == 0)) {
            fault_ = true;
            active_ = false;
            return false;
        }
        advance();
        apply();
        queue_.push_back({
            epoch_, nextSequence_, arm9, cycles, kind, sourceId});
        if (nextSequence_ == 0xffffffffu)
            exhausted_ = true;
        else
            ++nextSequence_;
        return true;
    }

    bool pop(ConsumedCreditAckRecord& record) {
        if (queue_.empty()) return false;
        record = queue_.front();
        queue_.erase(queue_.begin());
        return true;
    }

    // Deterministic wrap test only. A live epoch always starts at sequence one.
    void seedNextSequenceForSelfTest(std::uint32_t sequence) {
        if (!active_ || !queue_.empty() || sequence == 0)
            throw std::logic_error("invalid consumed-credit sequence seed");
        nextSequence_ = sequence;
    }

    std::size_t pending() const { return queue_.size(); }
    bool faulted() const { return fault_; }
    bool exhausted() const { return exhausted_; }

private:
    std::size_t capacity_;
    std::vector<ConsumedCreditAckRecord> queue_;
    std::uint32_t epoch_ = 0;
    std::uint32_t nextSequence_ = 1;
    bool active_ = false;
    bool exhausted_ = false;
    bool fault_ = false;
};

class PostedWriteRingConsumer {
public:
    enum class ApplyDisposition {
        Commit,
        Retry,
    };

    enum class DrainResult {
        Empty,
        Retried,
        Committed,
    };

    explicit PostedWriteRingConsumer(
        volatile std::uint32_t* words,
        bool allowGxWrites = false,
        bool allowExternalArm9IfWrites = false)
        : words_(words), allowGxWrites_(allowGxWrites),
          allowExternalArm9IfWrites_(allowExternalArm9IfWrites) {}

    void initialize(
        std::uint32_t sessionEpoch = 0,
        std::uint32_t capabilities = kLwRequiredBaseCaps) {
        for (std::size_t index = 0;
             index < nds4mister::kPostedWriteRingBytes /
                         sizeof(std::uint32_t);
             ++index)
            words_[index] = 0;
        words_[0] = nds4mister::kPostedWriteRingMagic;
        words_[1] = nds4mister::kPostedWriteRingVersion;
        words_[2] = 0;
        words_[3] = nds4mister::kPostedWriteRingEntries;
        words_[4] = sessionEpoch;
        words_[5] = ~sessionEpoch;
        words_[6] = capabilities;
        __sync_synchronize();
        if (words_[0] != nds4mister::kPostedWriteRingMagic ||
            words_[1] != nds4mister::kPostedWriteRingVersion ||
            words_[2] != 0 ||
            words_[3] != nds4mister::kPostedWriteRingEntries ||
            words_[4] != sessionEpoch ||
            words_[5] != ~sessionEpoch ||
            words_[6] != capabilities)
            throw std::runtime_error(
                "posted-write ring initialization readback mismatch");
        consumerSequence_ = 0;
        sessionEpoch_ = sessionEpoch;
        capabilities_ = capabilities;
    }

    // Deterministic near-wrap regression hook. Live startup always calls only
    // initialize(), so a production session still begins at sequence zero.
    void seedConsumerSequenceForSelfTest(std::uint32_t sequence) {
        consumerSequence_ = sequence;
        words_[2] = sequence;
        __sync_synchronize();
    }

    template <typename Apply>
    DrainResult tryDrainOneRetryable(Apply&& apply) {
        constexpr std::size_t headerWords =
            nds4mister::kPostedWriteRingHeaderBytes / sizeof(std::uint32_t);
        constexpr std::size_t entryWords =
            nds4mister::kPostedWriteEntryBytes / sizeof(std::uint32_t);
        const std::uint32_t expected = consumerSequence_ + 1u;
        // Sequence zero is also the uncommitted marker. Until a larger ABI
        // adds a session generation, wrapping here must terminate before any
        // entry fields are read or applied.
        if (expected == 0)
            throw std::runtime_error(
                "posted-write sequence exhausted before reserved zero");
        const std::size_t slot =
            consumerSequence_ & (nds4mister::kPostedWriteRingEntries - 1u);
        const std::size_t base = headerWords + slot * entryWords;
        const std::uint32_t commit = words_[base + 4u];
        if (commit != expected) return DrainResult::Empty;
        __sync_synchronize();

        PostedWriteEntry entry;
        entry.sequence = commit;
        const std::uint32_t rawAddress = words_[base + 0u];
        entry.data = words_[base + 1u];
        const std::uint32_t rawCycles = words_[base + 2u];
        const std::uint32_t serializedControl = words_[base + 3u];
        entry.control = serializedControl & 0xfu;
        const std::uint32_t rawAuxiliary = serializedControl >> 4;
        const bool externalArm9IfTag =
            (rawAuxiliary & kPostedAuxExternalArm9If) != 0;
        const bool externalArm9IfTagWellFormed = externalArm9IfTag &&
            (rawAuxiliary & kPostedAuxExternalReserved) == 0;
        if (externalArm9IfTag) {
            entry.address = 0x04000214u;
            entry.cycles = 0;
            entry.auxiliary =
                rawAuxiliary & kPostedAuxExternalFinalIf;
            entry.externalTargetTimestamp =
                (static_cast<std::uint64_t>(rawCycles) << 32) |
                rawAddress;
            entry.externalArm9If = externalArm9IfTagWellFormed;
        } else {
            entry.address = rawAddress;
            entry.cycles = rawCycles;
            entry.auxiliary = rawAuxiliary;
        }
        const std::uint32_t commitUpper = words_[base + 5u];
        __sync_synchronize();
        if (words_[base + 4u] != expected ||
            commitUpper != sessionEpoch_)
            throw std::runtime_error("posted-write entry changed during read");
        const bool provenVramHalfword =
            entry.control == 0xau &&
            entry.auxiliary == 0 &&
            (entry.address & 0xfffff000u) == 0x0600c000u;
        const bool enabledGxWord =
            allowGxWrites_ &&
            entry.control == 0xcu &&
            entry.auxiliary == 0 &&
            (entry.address & 3u) == 0 &&
            entry.address >= 0x04000400u &&
            entry.address <= 0x040005c8u;
        const bool enabledExternalArm9IfWord =
            allowExternalArm9IfWrites_ &&
            (capabilities_ & kLwExternalTimeWindowCaps) ==
                kLwExternalTimeWindowCaps &&
            entry.externalArm9If &&
            entry.control == 0xcu &&
            entry.address == 0x04000214u;
        if (!provenVramHalfword && !enabledGxWord &&
            !enabledExternalArm9IfWord)
            throw std::runtime_error(
                "posted-write entry escaped enabled VRAM/GX/ETW-IF scope");

        // A retryable callback must return Retry before changing model state.
        // In that case this consumer leaves both the entry commit and public
        // consumer credit untouched, so the same entry can be attempted after
        // downstream capacity becomes available. A Commit callback owns the
        // apply exactly once before this method retires the entry below.
        const auto disposition = apply(entry);
        if (disposition == ApplyDisposition::Retry)
            return DrainResult::Retried;
        if (disposition != ApplyDisposition::Commit)
            throw std::runtime_error(
                "posted-write callback returned invalid disposition");

        // Clear the commit marker before publishing consumer progress. The
        // FPGA may reuse the slot as soon as it observes words_[2].
        words_[base + 4u] = 0;
        __sync_synchronize();
        consumerSequence_ = expected;
        words_[2] = consumerSequence_;
        __sync_synchronize();
        return DrainResult::Committed;
    }

    // Compatibility path for existing consumers whose callback always
    // applies synchronously. Its observable behavior is unchanged: false
    // means no committed entry was available, and true means one entry was
    // applied, cleared, and credited.
    template <typename Apply>
    bool tryDrainOne(Apply&& apply) {
        return tryDrainOneRetryable(
                   [&](const PostedWriteEntry& entry) {
                       apply(entry);
                       return ApplyDisposition::Commit;
                   }) == DrainResult::Committed;
    }

    template <typename Apply>
    std::size_t drainAvailable(std::size_t limit, Apply&& apply) {
        std::size_t drained = 0;
        while (drained < limit && tryDrainOne(apply))
            ++drained;
        return drained;
    }

    template <typename Apply>
    std::size_t drainTo(std::uint32_t target, Apply&& apply) {
        if (target == 0 && consumerSequence_ != 0)
            throw std::runtime_error(
                "posted-write fence attempted sequence-zero wrap");
        const auto distance = target - consumerSequence_;
        if (distance >= nds4mister::kPostedWriteRingEntries)
            throw std::runtime_error("posted-write fence is outside ring window");
        if (distance == 0) return 0;
        const auto deadline =
            std::chrono::steady_clock::now() + std::chrono::seconds(1);
        std::size_t drained = 0;
        while (consumerSequence_ != target) {
            if (tryDrainOne(apply)) {
                ++drained;
                continue;
            }
            if (std::chrono::steady_clock::now() >= deadline)
                throw std::runtime_error(
                    "posted-write fence references an uncommitted entry");
            sched_yield();
        }
        return drained;
    }

    std::uint32_t consumerSequence() const { return consumerSequence_; }

private:
    volatile std::uint32_t* words_;
    bool allowGxWrites_ = false;
    bool allowExternalArm9IfWrites_ = false;
    std::uint32_t consumerSequence_ = 0;
    std::uint32_t sessionEpoch_ = 0;
    std::uint32_t capabilities_ = 0;
};

template <typename ReportCPUReached, typename ApplyW1C>
void applyExternalArm9IfPostedEntry(
    const PostedWriteEntry& entry,
    ReportCPUReached&& reportCPUReached,
    ApplyW1C&& applyW1C)
{
    if (!entry.externalArm9If || entry.sequence == 0 ||
        entry.address != 0x04000214u || entry.control != 0xcu ||
        (entry.auxiliary & ~kPostedAuxExternalFinalIf) != 0)
        throw std::runtime_error(
            "invalid decoded external ARM9 IF posted entry");

    std::string error;
    if (!reportCPUReached(entry.externalTargetTimestamp, error))
        throw std::runtime_error(
            "external ARM9 IF progress report failed: " + error);

    nds4mister::ExternalARM9IFW1CResult result;
    const bool expectedGXFIFO =
        (entry.auxiliary & (1u << 21)) != 0;
    if (!applyW1C(
            entry.sequence, entry.externalTargetTimestamp,
            entry.address, 2u, entry.data, entry.auxiliary,
            expectedGXFIFO, result, error))
        throw std::runtime_error(
            "external ARM9 IF model apply failed: " + error);
    if (result.finalIF != entry.auxiliary ||
        result.gxFIFOAsserted != expectedGXFIFO)
        throw std::runtime_error(
            "external ARM9 IF model result mismatched posted proof");
}

std::uint32_t expectedLwCapabilities(
    bool gxPostedWrites,
    bool timeIrqReverse = false,
    bool externalTimeWindow = false,
    bool localLcd = false) {
    return kLwRequiredBaseCaps |
        (gxPostedWrites ? kLwCapGxPosted : 0u) |
        (timeIrqReverse ? kLwCapTimeIrqReverse : 0u) |
        (externalTimeWindow ? kLwExternalTimeWindowCaps : 0u) |
        (localLcd ? kLwCapLocalLcd : 0u);
}

void requireOwnedLwSession(
    volatile std::uint32_t* lwWords,
    std::uint32_t sessionCookie,
    std::uint32_t expectedCapabilities);

struct CountedTransactionBoundary {
    nds4mister::ConsumedCreditAck ack;
    std::uint32_t requiredPostedSource = 0;
    nds4mister::ConsumedCreditAckIrqBoundary irq;
};

CountedTransactionBoundary makeMailboxCountedBoundary(
    bool arm9,
    std::uint32_t elapsedCycles,
    std::uint32_t generation,
    std::uint32_t requiredPostedSource,
    bool timingOnly,
    bool readNotWrite,
    unsigned access,
    std::uint32_t address,
    std::uint32_t writeData) {
    CountedTransactionBoundary boundary{
        {arm9, elapsedCycles,
         nds4mister::ConsumedCreditAckKind::Mailbox, generation},
        requiredPostedSource,
        {}};
    const auto wordAddress = address & ~std::uint32_t{3};
    const bool irqWord = wordAddress == 0x04000208u ||
        wordAddress == 0x04000210u || wordAddress == 0x04000214u;
    const bool aligned = access <= 2u &&
        (access != 1u || (address & 1u) == 0) &&
        (access != 2u || (address & 3u) == 0);
    if (!timingOnly && irqWord && aligned) {
        boundary.irq.enabled = true;
        boundary.irq.readNotWrite = readNotWrite;
        boundary.irq.access = static_cast<std::uint8_t>(access);
        boundary.irq.address = address;
        boundary.irq.payload = readNotWrite ? 0u : writeData;
    }
    return boundary;
}

nds4mister::ConsumedCreditAckIrqMasks takeIrqSetMasks(
    nds4mister::MelonDsBackend& backend) {
    const auto capture = backend.take_irq_set_capture();
    return {capture.arm9_mask, capture.arm7_mask};
}

const char* publishResultName(
    nds4mister::ConsumedCreditAckPublishResult result) {
    using Result = nds4mister::ConsumedCreditAckPublishResult;
    switch (result) {
    case Result::Published: return "published";
    case Result::Backpressured: return "backpressured";
    case Result::SessionNotReady: return "session-not-ready";
    case Result::OrderingBlocked: return "ordering-blocked";
    case Result::Exhausted: return "sequence-exhausted";
    case Result::Fault: return "transport-fault";
    }
    return "unknown";
}

template <typename Advance, typename Apply, typename Capture, typename Retry>
nds4mister::ConsumedCreditAckDdrReceipt
publishCountedTransactionWithRetry(
    nds4mister::ConsumedCreditAckDdrProducer& producer,
    CountedTransactionBoundary& boundary,
    Advance&& advance,
    Apply&& apply,
    Capture&& capture,
    Retry&& retry) {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(1);
    for (;;) {
        nds4mister::ConsumedCreditAckDdrReceipt receipt;
        const auto result = producer.publishTransaction(
            boundary.ack, boundary.requiredPostedSource, boundary.irq,
            advance, apply, capture, receipt);
        if (result ==
            nds4mister::ConsumedCreditAckPublishResult::Published)
            return receipt;
        if (result ==
                nds4mister::ConsumedCreditAckPublishResult::Fault ||
            result ==
                nds4mister::ConsumedCreditAckPublishResult::Exhausted ||
            result ==
                nds4mister::ConsumedCreditAckPublishResult::OrderingBlocked ||
            std::chrono::steady_clock::now() >= deadline ||
            !retry(result))
            throw std::runtime_error(
                std::string("reverse counted transaction ") +
                publishResultName(result));
        // The producer proves capacity/session state before invoking either
        // callback. Retrying these results therefore cannot replay a model
        // advance, bus access, DMA completion, or input update.
    }
}

void waitReverseSessionReady(
    nds4mister::ConsumedCreditAckDdrProducer& producer,
    volatile std::uint32_t* lwWords,
    std::uint32_t sessionCookie,
    std::uint32_t expectedCapabilities) {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(1);
    std::uint64_t spins = 0;
    while (!producer.sessionReady()) {
        if (!producer.active())
            throw std::runtime_error(
                "reverse counted transport session fault");
        if ((++spins & 0xfffu) == 0) {
            requireOwnedLwSession(
                lwWords, sessionCookie, expectedCapabilities);
            if (std::chrono::steady_clock::now() >= deadline)
                throw std::runtime_error(
                    "reverse counted transport startup timeout");
            sched_yield();
        }
    }
    requireOwnedLwSession(
        lwWords, sessionCookie, expectedCapabilities);
    if (producer.producerSequence() != 0 ||
        lwWords[kLwRegReverseConsumer] != 0)
        throw std::runtime_error(
            "reverse counted transport did not start at sequence zero");
}

void validateReverseFrontier(
    std::uint32_t frontier,
    std::uint32_t& previous,
    const nds4mister::ConsumedCreditAckDdrProducer& producer) {
    if (frontier < previous || frontier > producer.producerSequence())
        throw std::runtime_error(
            "reverse counted transport LW frontier is invalid");
    previous = frontier;
}

void waitReverseReceipt(
    nds4mister::ConsumedCreditAckDdrProducer& producer,
    const nds4mister::ConsumedCreditAckDdrReceipt& receipt,
    volatile std::uint32_t* lwWords,
    std::uint32_t sessionCookie,
    std::uint32_t expectedCapabilities,
    std::uint32_t& previousFrontier) {
    const auto deadline =
        std::chrono::steady_clock::now() + std::chrono::seconds(1);
    std::uint64_t spins = 0;
    for (;;) {
        // skmp's low-latency path: busy-loop one uncached H2F-LW register.
        // The LW value is only a doorbell/frontier; acceptance still requires
        // the epoch/descriptor/consumer validation in consumedThrough().
        const auto frontier = lwWords[kLwRegReverseConsumer];
        validateReverseFrontier(frontier, previousFrontier, producer);
        if (frontier >= receipt.finalSequence &&
            producer.consumedThrough(receipt))
            return;
        if ((++spins & 0xfffu) == 0) {
            requireOwnedLwSession(
                lwWords, sessionCookie, expectedCapabilities);
            if (std::chrono::steady_clock::now() >= deadline)
                throw std::runtime_error(
                    "reverse counted transport receipt timeout");
            sched_yield();
        }
    }
}

void requireCleanLwStartupBeforeDeviceWrite(
    volatile std::uint32_t* lwWords,
    std::uint32_t expectedCapabilities)
{
    if (lwWords[kLwRegAbi] != kLwAbiMagic)
        throw std::runtime_error(
            "LW mailbox ABI mismatch (wrong core or responder)");
    if (lwWords[kLwRegCaps] != expectedCapabilities)
        throw std::runtime_error(
            "LW mailbox capability mismatch (GX/core/responder disagreement)");
    if ((expectedCapabilities & kLwCapLocalLcd) != 0) {
        std::string lcdError;
        if (!LcdEventQueueConsumer::cleanBeforeArm(lwWords, lcdError))
            throw std::runtime_error(lcdError);
    }
    if (lwWords[kLwRegSession] != 0 || lwWords[kLwRegArm] != 0)
        throw std::runtime_error(
            "LW mailbox session already owned; reload core before responder");
    const std::uint32_t cleanDoorbell =
        kLwDoorbellIrq | kLwDoorbellSessionRequired;
    if (lwWords[kLwRegStatus] != 0 ||
        lwWords[kLwRegProducer] != 0 ||
        lwWords[kLwRegConsumer] != 0 ||
        lwWords[kLwRegDoorbell] != cleanDoorbell)
        throw std::runtime_error(
            "LW mailbox did not enter a clean session-required state");
}

void requireClaimedLwSession(
    volatile std::uint32_t* lwWords,
    std::uint32_t sessionCookie,
    std::uint32_t expectedCapabilities)
{
    const std::uint32_t cleanDoorbell =
        kLwDoorbellIrq | kLwDoorbellSessionRequired;
    if (sessionCookie == 0 ||
        lwWords[kLwRegAbi] != kLwAbiMagic ||
        lwWords[kLwRegCaps] != expectedCapabilities ||
        lwWords[kLwRegSession] != sessionCookie ||
        lwWords[kLwRegArm] != 0 ||
        lwWords[kLwRegStatus] != 0 ||
        lwWords[kLwRegProducer] != 0 ||
        lwWords[kLwRegConsumer] != 0 ||
        lwWords[kLwRegDoorbell] != cleanDoorbell)
        throw std::runtime_error(
            "LW transport claim changed before session arm");
    if ((expectedCapabilities & kLwCapLocalLcd) != 0) {
        std::string lcdError;
        if (!LcdEventQueueConsumer::cleanBeforeArm(lwWords, lcdError))
            throw std::runtime_error(lcdError);
    }
}

void requireOwnedLwSession(
    volatile std::uint32_t* lwWords,
    std::uint32_t sessionCookie,
    std::uint32_t expectedCapabilities)
{
    if (sessionCookie == 0 ||
        lwWords[kLwRegAbi] != kLwAbiMagic ||
        lwWords[kLwRegCaps] != expectedCapabilities ||
        lwWords[kLwRegSession] != sessionCookie ||
        lwWords[kLwRegArm] != sessionCookie)
        throw std::runtime_error(
            "LW transport session ownership changed; core reload required");
}

void publishAdvancedLwConsumerAck(
    volatile std::uint32_t* lwWords,
    std::uint32_t consumed,
    std::uint32_t& lastPublished,
    std::uint32_t sessionCookie,
    std::uint32_t expectedCapabilities)
{
    // Most calls arrive with no new posted-write credit. Avoid four uncached
    // LW-bridge ownership reads on that no-op path; every real ACK retains the
    // complete ownership, producer-window, barrier, and readback checks.
    if (consumed == lastPublished) return;
    requireOwnedLwSession(
        lwWords, sessionCookie, expectedCapabilities);
    const std::uint32_t advertised = lwWords[kLwRegProducer];
    if (consumed > advertised)
        throw std::runtime_error(
            "LW consumer sequence exceeded advertised producer");
    lwWords[kLwRegConsumer] = consumed;
    __sync_synchronize();
    bool observed = false;
    for (unsigned retry = 0; retry < 1024; ++retry) {
        if (lwWords[kLwRegConsumer] == consumed) {
            observed = true;
            break;
        }
        sched_yield();
    }
    if (!observed)
        throw std::runtime_error("LW consumer ACK readback timeout");
    lastPublished = consumed;
}

bool lwConsumerAckFastPathSelfTest() {
    constexpr std::uint32_t cookie = 0x12345678u;
    const std::uint32_t capabilities = expectedLwCapabilities(true);
    std::array<std::uint32_t, kLwRegFenceEpoch + 1u> storage{};
    auto* regs = reinterpret_cast<volatile std::uint32_t*>(storage.data());
    std::uint32_t lastPublished = 0;

    // A no-op ACK must touch no LW ownership state. A changed sequence must
    // still fail closed while that same state is invalid.
    publishAdvancedLwConsumerAck(
        regs, 0, lastPublished, cookie, capabilities);
    try {
        publishAdvancedLwConsumerAck(
            regs, 1, lastPublished, cookie, capabilities);
        return false;
    } catch (const std::runtime_error& error) {
        if (std::strstr(error.what(), "ownership changed") == nullptr)
            return false;
    }

    storage[kLwRegAbi] = kLwAbiMagic;
    storage[kLwRegCaps] = capabilities;
    storage[kLwRegSession] = cookie;
    storage[kLwRegArm] = cookie;
    storage[kLwRegProducer] = 2;
    publishAdvancedLwConsumerAck(
        regs, 1, lastPublished, cookie, capabilities);
    if (lastPublished != 1 || storage[kLwRegConsumer] != 1)
        return false;

    // Once an ACK is current, even poisoned ownership must remain an exact
    // no-op. The next real ACK must observe and reject that poison.
    storage[kLwRegSession] ^= 1u;
    const auto beforeNoOp = storage;
    publishAdvancedLwConsumerAck(
        regs, 1, lastPublished, cookie, capabilities);
    if (storage != beforeNoOp) return false;
    try {
        publishAdvancedLwConsumerAck(
            regs, 2, lastPublished, cookie, capabilities);
        return false;
    } catch (const std::runtime_error& error) {
        if (std::strstr(error.what(), "ownership changed") == nullptr)
            return false;
    }
    if (lastPublished != 1 || storage[kLwRegConsumer] != 1)
        return false;

    storage[kLwRegSession] = cookie;
    storage[kLwRegProducer] = 1;
    try {
        publishAdvancedLwConsumerAck(
            regs, 2, lastPublished, cookie, capabilities);
        return false;
    } catch (const std::runtime_error& error) {
        if (std::strstr(error.what(), "exceeded advertised producer") ==
            nullptr)
            return false;
    }
    if (lastPublished != 1 || storage[kLwRegConsumer] != 1)
        return false;
    storage[kLwRegProducer] = 2;
    publishAdvancedLwConsumerAck(
        regs, 2, lastPublished, cookie, capabilities);
    return lastPublished == 2 && storage[kLwRegConsumer] == 2;
}

void claimCleanLwSession(
    volatile std::uint32_t* lwWords,
    std::uint32_t sessionCookie,
    std::uint32_t expectedCapabilities)
{
    if (sessionCookie == 0)
        throw std::runtime_error("LW mailbox session cookie must be nonzero");
    requireCleanLwStartupBeforeDeviceWrite(lwWords, expectedCapabilities);
    lwWords[kLwRegSession] = sessionCookie;
    __sync_synchronize();
    requireClaimedLwSession(
        lwWords, sessionCookie, expectedCapabilities);
}

template <typename InitializeRing, typename ArmSession>
void initializePostedRingAndArmLwSession(
    volatile std::uint32_t* lwWords,
    std::uint32_t sessionCookie,
    std::uint32_t expectedCapabilities,
    InitializeRing&& initializeRing,
    ArmSession&& armSession)
{
    // SESSION claim is the exclusive ownership boundary. It remains disarmed,
    // so the FPGA cannot admit CPU traffic while surviving DDR is initialized.
    requireClaimedLwSession(
        lwWords, sessionCookie, expectedCapabilities);
    initializeRing();
    requireClaimedLwSession(
        lwWords, sessionCookie, expectedCapabilities);
    armSession();
    __sync_synchronize();
    requireOwnedLwSession(
        lwWords, sessionCookie, expectedCapabilities);
    if (lwWords[kLwRegStatus] != 0 ||
        lwWords[kLwRegProducer] != 0 ||
        lwWords[kLwRegConsumer] != 0 ||
        lwWords[kLwRegDoorbell] != 0)
        throw std::runtime_error(
            "LW mailbox did not become clean and ready after session arm");
}

bool lwPostedRingStartupSelfTest() {
    constexpr std::size_t ringWordCount =
        nds4mister::kPostedWriteRingBytes / sizeof(std::uint32_t);
    constexpr std::uint32_t canary = 0xa5a55a5au;
    constexpr std::uint32_t cookie = 0x12345678u;
    const std::uint32_t capabilities = expectedLwCapabilities(true);
    std::vector<std::uint32_t> ringWords(ringWordCount, canary);
    std::array<std::uint32_t, kLwRegFenceEpoch + 1u> lwWords{};
    auto* ring = reinterpret_cast<volatile std::uint32_t*>(ringWords.data());
    auto* regs = reinterpret_cast<volatile std::uint32_t*>(lwWords.data());
    PostedWriteRingConsumer consumer(ring, true);

    const auto reset = [&] {
        std::fill(ringWords.begin(), ringWords.end(), canary);
        lwWords.fill(0);
        lwWords[kLwRegAbi] = kLwAbiMagic;
        lwWords[kLwRegCaps] = capabilities;
        lwWords[kLwRegDoorbell] =
            kLwDoorbellIrq | kLwDoorbellSessionRequired;
    };
    const auto ringUntouched = [&] {
        return std::all_of(ringWords.begin(), ringWords.end(),
                           [](std::uint32_t word) { return word == canary; });
    };
    const auto mustRejectBeforeDeviceWrite = [&](const char* expected) {
        try {
            claimCleanLwSession(regs, cookie, capabilities);
        } catch (const std::runtime_error& error) {
            return std::strstr(error.what(), expected) != nullptr &&
                ringUntouched();
        }
        return false;
    };

    reset();
    lwWords[kLwRegAbi] ^= 1u;
    if (!mustRejectBeforeDeviceWrite("ABI mismatch")) return false;
    reset();
    lwWords[kLwRegCaps] ^= kLwCapGxPosted;
    if (!mustRejectBeforeDeviceWrite("capability mismatch")) return false;
    reset();
    lwWords[kLwRegSession] = 0x87654321u;
    if (!mustRejectBeforeDeviceWrite("session already owned")) return false;
    reset();
    lwWords[kLwRegDoorbell] |= kLwDoorbellMailbox;
    if (!mustRejectBeforeDeviceWrite("clean session-required")) return false;
    reset();
    lwWords[kLwRegProducer] = 1;
    lwWords[kLwRegConsumer] = 1;
    if (!mustRejectBeforeDeviceWrite("clean session-required")) return false;

    reset();
    claimCleanLwSession(regs, cookie, capabilities);
    if (!ringUntouched() || lwWords[kLwRegSession] != cookie ||
        lwWords[kLwRegArm] != 0 || lwWords[kLwRegDoorbell] != 0x11u)
        return false;
    unsigned initializeCalls = 0;
    unsigned armCalls = 0;
    initializePostedRingAndArmLwSession(
        regs, cookie, capabilities,
        [&] {
            ++initializeCalls;
            consumer.initialize(cookie, capabilities);
        },
        [&] {
            ++armCalls;
            lwWords[kLwRegArm] = cookie;
            lwWords[kLwRegDoorbell] = 0;
        });
    if (initializeCalls != 1 || armCalls != 1 ||
        ringWords[0] != nds4mister::kPostedWriteRingMagic ||
        ringWords[1] != nds4mister::kPostedWriteRingVersion ||
        ringWords[2] != 0 ||
        ringWords[3] != nds4mister::kPostedWriteRingEntries ||
        ringWords[4] != cookie || ringWords[5] != ~cookie ||
        ringWords[6] != capabilities)
        return false;
    requireOwnedLwSession(regs, cookie, capabilities);

    // A new responder cannot claim or clear the live session.
    try {
        claimCleanLwSession(regs, 0x87654321u, capabilities);
        return false;
    } catch (const std::runtime_error& error) {
        if (std::strstr(error.what(), "session already owned") == nullptr)
            return false;
    }

    // Reset/ownership changing during ring initialization must prevent ARM.
    reset();
    claimCleanLwSession(regs, cookie, capabilities);
    initializeCalls = 0;
    armCalls = 0;
    try {
        initializePostedRingAndArmLwSession(
            regs, cookie, capabilities,
            [&] {
                ++initializeCalls;
                consumer.initialize(cookie, capabilities);
                lwWords[kLwRegSession] = 0x87654321u;
            },
            [&] { ++armCalls; });
    } catch (const std::runtime_error& error) {
        return initializeCalls == 1 && armCalls == 0 &&
            std::strstr(error.what(), "claim changed") != nullptr;
    }
    return false;
}

bool timeIrqReverseResponderSelfTest() {
    using nds4mister::ConsumedCreditAckDdrLayout;
    using nds4mister::ConsumedCreditAckDdrProducer;
    using nds4mister::ConsumedCreditAckKind;
    using nds4mister::ConsumedCreditAckMappedDdrMemory;
    using nds4mister::ConsumedCreditAckPublishResult;

    if (expectedLwCapabilities(false) != kLwRequiredBaseCaps ||
        expectedLwCapabilities(true) !=
            (kLwRequiredBaseCaps | kLwCapGxPosted) ||
        expectedLwCapabilities(false, true) !=
            (kLwRequiredBaseCaps | kLwCapTimeIrqReverse) ||
        expectedLwCapabilities(false, false, true) !=
            (kLwRequiredBaseCaps | kLwExternalTimeWindowCaps) ||
        expectedLwCapabilities(true, true, true) !=
            (kLwRequiredBaseCaps | kLwCapGxPosted |
             kLwCapTimeIrqReverse | kLwExternalTimeWindowCaps))
        return false;

    const auto exact = [&](std::uint32_t address, unsigned access,
                           bool timingOnly = false) {
        return makeMailboxCountedBoundary(
            true, 7, 1, 0, timingOnly, true, access, address, 0)
            .irq.enabled;
    };
    if (!exact(0x04000208u, 2) || !exact(0x04000209u, 0) ||
        !exact(0x0400020au, 1) || !exact(0x04000213u, 0) ||
        !exact(0x04000216u, 1) ||
        exact(0x04000209u, 1) || exact(0x0400020au, 2) ||
        exact(0x0400020cu, 2) || exact(0x04000218u, 2) ||
        exact(0x04000208u, 2, true))
        return false;

    constexpr std::uint32_t cookie = 0x13579bdfu;
    constexpr std::size_t entryCount = 8;
    constexpr std::size_t headerWords = 8;
    std::vector<std::uint64_t> ringWords(
        headerWords + entryCount * 3u, 0);
    ConsumedCreditAckMappedDdrMemory memory(
        ringWords.data(), ringWords.size() * sizeof(ringWords[0]));
    ConsumedCreditAckDdrProducer producer(
        memory, ConsumedCreditAckDdrLayout{
            entryCount, headerWords, 0, 1});
    if (!producer.beginSession(cookie, true)) return false;

    std::array<std::uint32_t, kLwRegReverseConsumer + 1u> lwWords{};
    lwWords[kLwRegAbi] = kLwAbiMagic;
    lwWords[kLwRegCaps] = expectedLwCapabilities(false, true);
    lwWords[kLwRegSession] = cookie;
    lwWords[kLwRegArm] = cookie;
    ringWords[0] = static_cast<std::uint64_t>(cookie) << 32;
    waitReverseSessionReady(
        producer, lwWords.data(), cookie, lwWords[kLwRegCaps]);

    CountedTransactionBoundary posted{
        {true, 3, ConsumedCreditAckKind::Posted, 1}, 0, {}};
    unsigned postedAdvance = 0;
    unsigned postedApply = 0;
    unsigned postedCapture = 0;
    const auto postedReceipt = publishCountedTransactionWithRetry(
        producer, posted,
        [&] { ++postedAdvance; },
        [&] {
            ++postedApply;
            return 0u;
        },
        [&] {
            ++postedCapture;
            return postedCapture == 1
                ? nds4mister::ConsumedCreditAckIrqMasks{1, 2}
                : nds4mister::ConsumedCreditAckIrqMasks{4, 8};
        },
        [](ConsumedCreditAckPublishResult) { return false; });
    if (postedReceipt.baseSequence != 1 ||
        postedReceipt.finalSequence != 5 || postedAdvance != 1 ||
        postedApply != 1 || postedCapture != 2 ||
        producer.lastPostedSource() != 1)
        return false;

    auto mailbox = makeMailboxCountedBoundary(
        false, 11, 9, 1, false, true, 0, 0x04000217u, 0);
    unsigned mailboxAdvance = 0;
    unsigned mailboxApply = 0;
    unsigned mailboxCapture = 0;
    unsigned retries = 0;
    const auto mailboxReceipt = publishCountedTransactionWithRetry(
        producer, mailbox,
        [&] { ++mailboxAdvance; },
        [&] {
            ++mailboxApply;
            return 0x89abcdefu;
        },
        [&] {
            ++mailboxCapture;
            return nds4mister::ConsumedCreditAckIrqMasks{};
        },
        [&](ConsumedCreditAckPublishResult result) {
            if (result != ConsumedCreditAckPublishResult::Backpressured ||
                retries++ != 0 || mailboxAdvance != 0 ||
                mailboxApply != 0 || mailboxCapture != 0)
                return false;
            ringWords[0] =
                (static_cast<std::uint64_t>(cookie) << 32) | 5u;
            lwWords[kLwRegReverseConsumer] = 5;
            return true;
        });
    if (mailboxReceipt.baseSequence != 6 ||
        mailboxReceipt.finalSequence != 6 || retries != 1 ||
        mailboxAdvance != 1 || mailboxApply != 1 ||
        mailboxCapture != 2)
        return false;

    constexpr std::size_t mailboxCommitWord =
        headerWords + ((6u - 1u) & (entryCount - 1u)) * 3u + 2u;
    if (static_cast<std::uint32_t>(ringWords[mailboxCommitWord]) != 6u ||
        static_cast<std::uint32_t>(
            ringWords[mailboxCommitWord] >> 32) != 0x89abcdefu)
        return false;

    ringWords[0] =
        (static_cast<std::uint64_t>(cookie) << 32) | 6u;
    lwWords[kLwRegReverseConsumer] = 6;
    std::uint32_t previousFrontier = 5;
    waitReverseReceipt(
        producer, mailboxReceipt, lwWords.data(), cookie,
        lwWords[kLwRegCaps], previousFrontier);
    return previousFrontier == 6;
}

bool externalTimeWindowProductionPrerequisitesSelfTest() {
    using nds4mister::ConsumedCreditAckMappedDdrMemory;
    using nds4mister::ExternalTimeWindowDdrLayout;
    using nds4mister::ExternalTimeWindowDdrProducer;
    using nds4mister::ExternalTimeWindowDdrProducerFault;

    const std::uint32_t expected =
        expectedLwCapabilities(false, false, true);
    if (kLwCapVerifiedPostedProducer != (1u << 5) ||
        kLwCapBlockingExternalTimeWindow != (1u << 6) ||
        expected != (kLwRequiredBaseCaps |
                     kLwCapVerifiedPostedProducer |
                     kLwCapBlockingExternalTimeWindow))
        return false;

    // Either historical single bit must fail the exact startup preflight. This
    // is the guard that prevents an old verified-posted core from being treated
    // as a blocking-ETW core, or a new blocking bit from bypassing verification.
    const auto rejectsIncompleteCapabilities =
        [&](std::uint32_t incompleteCapabilities) {
            std::array<std::uint32_t, kLwRegReverseConsumer + 1u> words{};
            words[kLwRegAbi] = kLwAbiMagic;
            words[kLwRegCaps] = incompleteCapabilities;
            words[kLwRegDoorbell] =
                kLwDoorbellIrq | kLwDoorbellSessionRequired;
            try {
                requireCleanLwStartupBeforeDeviceWrite(
                    words.data(), expected);
            } catch (const std::runtime_error& error) {
                return std::strstr(error.what(), "capability mismatch") !=
                    nullptr;
            }
            return false;
        };
    if (!rejectsIncompleteCapabilities(
            kLwRequiredBaseCaps | kLwCapVerifiedPostedProducer) ||
        !rejectsIncompleteCapabilities(
            kLwRequiredBaseCaps | kLwCapBlockingExternalTimeWindow))
        return false;

    constexpr std::size_t mappedWords =
        kExternalTimeWindowBytes / sizeof(std::uint64_t);
    std::vector<std::uint64_t> mappedStorage(mappedWords);
    ConsumedCreditAckMappedDdrMemory mappedMemory(
        mappedStorage.data(), kExternalTimeWindowBytes);
    ExternalTimeWindowDdrProducer exactProducer(
        mappedMemory, kExternalTimeWindowLayout);
    if (exactProducer.fault() != ExternalTimeWindowDdrProducerFault::None ||
        exactProducer.requiredWords() != mappedWords)
        return false;

    // The former ordinary-only layout must no longer match the production
    // mapping contract, even though it remains a valid legacy producer layout.
    ExternalTimeWindowDdrProducer oldLayoutProducer(
        mappedMemory, ExternalTimeWindowDdrLayout{
            kExternalTimeWindowGroupCount,
            kExternalTimeWindowHeaderWords,
            0u,
            1u,
            0u});
    if (oldLayoutProducer.fault() !=
            ExternalTimeWindowDdrProducerFault::None ||
        oldLayoutProducer.requiredWords() == mappedWords)
        return false;

    // Conversely, the exact BRRP layout cannot be installed over the old
    // 10,816-byte mapping.
    std::vector<std::uint64_t> oldStorage(
        kExternalTimeWindowBarrierReplacementWordOffset);
    ConsumedCreditAckMappedDdrMemory oldMemory(
        oldStorage.data(), oldStorage.size() * sizeof(oldStorage[0]));
    ExternalTimeWindowDdrProducer undersizedProducer(
        oldMemory, kExternalTimeWindowLayout);
    return undersizedProducer.fault() ==
        ExternalTimeWindowDdrProducerFault::InvalidLayout;
}

template <typename DrainDma, typename WriteGx, typename DrainStall>
bool applyPostedGxWriteInOrder(
    DrainDma&& drainDma,
    WriteGx&& writeGx,
    DrainStall&& drainStall)
{
    // Elapsed-cycle advancement may trigger a repeating GXFIFO DMA. Drain it
    // before the direct CPU word touches melonDS's stateful packed-command
    // decoder, then preserve r268's post-write DMA-completion boundary before
    // consumer credit can release the ring slot.
    if (drainDma() < 0) return false;
    if (!writeGx()) return false;
    if (drainDma() < 0) return false;
    drainStall();
    return true;
}

bool postedGxWriteOrderingSelfTest() {
    std::vector<unsigned> order;
    unsigned drains = 0;
    if (!applyPostedGxWriteInOrder(
            [&] { order.push_back(++drains == 1 ? 1u : 3u); return 0; },
            [&] { order.push_back(2); return true; },
            [&] { order.push_back(4); }) ||
        order != std::vector<unsigned>({1, 2, 3, 4}))
        return false;

    bool writeRan = false;
    if (applyPostedGxWriteInOrder(
            [] { return -1; },
            [&] { writeRan = true; return true; },
            [] {}) || writeRan)
        return false;

    bool stallRan = false;
    drains = 0;
    if (applyPostedGxWriteInOrder(
            [&] { return ++drains == 2 ? -1 : 0; },
            [] { return true; },
            [&] { stallRan = true; }) || stallRan)
        return false;
    return true;
}

static_assert((nds4mister::kPostedWriteRingEntries &
               (nds4mister::kPostedWriteRingEntries - 1u)) == 0);
static_assert(nds4mister::kPostedWriteRingHeaderBytes %
                  sizeof(std::uint32_t) == 0);
static_assert(nds4mister::kPostedWriteEntryBytes %
                  sizeof(std::uint32_t) == 0);

class InputSourceArbiter {
public:
    template <typename PollLocal>
    std::uint32_t select(
        std::uint64_t publishedInput, PollLocal&& pollLocal) {
        const bool publishedValid =
            static_cast<std::uint32_t>(publishedInput >> 32) ==
            nds4mister::kCompactInputMagic;
        if (!publishedValid) {
            validPublishedCalls_ = 0;
            return pollLocal();
        }

        if (++validPublishedCalls_ == kLocalMaintenancePeriod) {
            validPublishedCalls_ = 0;
            (void)pollLocal();
        }
        return nds4mister::mister_joystick_to_ds_key_mask(
            static_cast<std::uint32_t>(publishedInput));
    }

    static constexpr std::uint32_t kLocalMaintenancePeriod = 64;

private:
    std::uint32_t validPublishedCalls_ = 0;
};

class MailboxInputPacer {
public:
    bool shouldService(std::uint32_t address, unsigned access,
        bool readNotWrite, unsigned period) {
        const std::uint64_t bytes = access == 0 ? 1u : access == 1 ? 2u : 4u;
        const std::uint64_t end =
            static_cast<std::uint64_t>(address) + bytes - 1u;
        const bool keyRegisterRead = readNotWrite &&
            ((address <= 0x04000131u && end >= 0x04000130u) ||
             (address <= 0x04000137u && end >= 0x04000136u));
        if (first_ || keyRegisterRead) {
            first_ = false;
            sinceService_ = 0;
            return true;
        }
        if (++sinceService_ < period) return false;
        sinceService_ = 0;
        return true;
    }

    static constexpr unsigned kDefaultPeriod = 16;
    static constexpr unsigned kLeanPeriod = 64;

private:
    unsigned sinceService_ = 0;
    bool first_ = true;
};

class LocalInput {
public:
    LocalInput() {
#if defined(__linux__)
        const char* configured = std::getenv("NDS4MISTER_INPUT");
        path_ = configured ? configured : "/dev/input/event0";
        openDevice();
#endif
    }
    ~LocalInput() {
        if (fd_ >= 0) close(fd_);
    }
    std::uint32_t poll() {
#if defined(__linux__)
        if (fd_ < 0 && std::chrono::steady_clock::now() >= nextOpen_)
            openDevice();
        input_event event{};
        ssize_t count = -1;
        while (fd_ >= 0 &&
               (count = read(fd_, &event, sizeof(event))) ==
                   static_cast<ssize_t>(sizeof(event))) {
            if (event.type == EV_KEY) set(event.code, event.value != 0);
            else if (event.type == EV_ABS) axis(event.code, event.value);
        }
        if (fd_ >= 0 && count < 0 && errno != EAGAIN &&
            errno != EWOULDBLOCK && errno != EINTR) {
            std::cerr << "input device lost: " << path_
                      << " error=" << std::strerror(errno) << "\n";
            close(fd_);
            fd_ = -1;
            mask_ = 0x0fffu;
            nextOpen_ =
                std::chrono::steady_clock::now() + std::chrono::seconds(1);
        }
#endif
        return mask_;
    }

private:
#if defined(__linux__)
    void openDevice() {
        fd_ = open(path_.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        std::cout << "input device=" << path_ << " fd=" << fd_;
        if (fd_ < 0) {
            std::cout << " error=" << std::strerror(errno);
            nextOpen_ =
                std::chrono::steady_clock::now() + std::chrono::seconds(1);
        }
        std::cout << "\n" << std::flush;
    }
#endif
    void button(unsigned bit, bool pressed) {
        if (pressed) mask_ &= ~(1u << bit);
        else mask_ |= 1u << bit;
    }
    void set(unsigned code, bool pressed) {
#if defined(__linux__)
        switch (code) {
        case KEY_X: case BTN_EAST: button(0, pressed); break;
        case KEY_Z: case BTN_SOUTH: button(1, pressed); break;
        case KEY_RIGHTSHIFT: case BTN_SELECT: button(2, pressed); break;
        case KEY_ENTER: case BTN_START: button(3, pressed); break;
        case KEY_RIGHT: case BTN_DPAD_RIGHT: button(4, pressed); break;
        case KEY_LEFT: case BTN_DPAD_LEFT: button(5, pressed); break;
        case KEY_UP: case BTN_DPAD_UP: button(6, pressed); break;
        case KEY_DOWN: case BTN_DPAD_DOWN: button(7, pressed); break;
        case KEY_S: case BTN_TR: button(8, pressed); break;
        case KEY_A: case BTN_TL: button(9, pressed); break;
        case KEY_W: case BTN_NORTH: button(10, pressed); break;
        case KEY_Q: case BTN_WEST: button(11, pressed); break;
        }
#else
        (void)code;
        (void)pressed;
#endif
    }
    void axis(unsigned code, int value) {
#if defined(__linux__)
        if (code == ABS_X || code == ABS_HAT0X) {
            button(4, value > 12000);
            button(5, value < -12000);
        }
        if (code == ABS_Y || code == ABS_HAT0Y) {
            button(7, value > 12000);
            button(6, value < -12000);
        }
#else
        (void)code;
        (void)value;
#endif
    }

    int fd_ = -1;
    std::uint32_t mask_ = 0x0fffu;
#if defined(__linux__)
    std::string path_;
    std::chrono::steady_clock::time_point nextOpen_{};
#endif
};

class PacedAudio {
public:
    std::uint32_t normalize(const std::int16_t* source,
                            std::uint32_t sourceFrames,
                            std::int16_t* destination) {
        if (!sourceFrames) return 0;
        frameRemainder_ += kAudioSampleRate * kFramePeriodNanoseconds;
        const auto targetFrames = static_cast<std::uint32_t>(
            frameRemainder_ / kNanosecondsPerSecond);
        frameRemainder_ %= kNanosecondsPerSecond;
        if (!targetFrames || targetFrames > 1024) return 0;

        // The externally clocked renderer currently yields about 751 SPU
        // frames for each video publication. The FPGA consumes audio at a
        // fixed 48 kHz while video is paced at the DS frame period, so
        // publishing the short block creates a repeatable silence gap. Stretch
        // each source block to the exact 802/803-frame cadence with linear
        // interpolation. Mapping output positions across [0, sourceFrames)
        // preserves every input frame and keeps consecutive blocks adjacent.
        for (std::uint32_t output = 0; output < targetFrames; ++output) {
            const std::uint64_t position =
                static_cast<std::uint64_t>(output) * sourceFrames;
            const auto first = static_cast<std::uint32_t>(
                position / targetFrames);
            const auto fraction = static_cast<std::uint32_t>(
                position % targetFrames);
            const auto second = std::min(first + 1, sourceFrames - 1);
            for (unsigned channel = 0; channel < 2; ++channel) {
                const std::int64_t a = source[first * 2u + channel];
                const std::int64_t b = source[second * 2u + channel];
                destination[output * 2u + channel] =
                    static_cast<std::int16_t>(
                        (a * (targetFrames - fraction) + b * fraction) /
                        targetFrames);
            }
        }
        return targetFrames;
    }

private:
    std::uint64_t frameRemainder_ = 0;
};

class HpsAudioPublicationSource {
public:
    explicit HpsAudioPublicationSource(bool fpgaOffload)
        : fpgaOffload_(fpgaOffload)
    {
    }

    template <typename Reader>
    int read(Reader&& reader)
    {
        if (fpgaOffload_)
            return 0;
        ++readCalls_;
        const int frames = reader();
        if (frames > 0)
            readFrames_ += static_cast<std::uint32_t>(frames);
        return frames;
    }

    void recordPublished(std::uint32_t frames)
    {
        publishedFrames_ += frames;
    }

    std::uint64_t readCalls() const { return readCalls_; }
    std::uint64_t readFrames() const { return readFrames_; }
    std::uint64_t publishedFrames() const { return publishedFrames_; }

    static bool selfTest()
    {
        unsigned callbackCalls = 0;
        HpsAudioPublicationSource offload(true);
        if (offload.read([&] {
                ++callbackCalls;
                return 17;
            }) != 0 ||
            callbackCalls != 0 ||
            offload.readCalls() != 0 ||
            offload.readFrames() != 0)
            return false;
        offload.recordPublished(0);
        if (offload.publishedFrames() != 0)
            return false;

        HpsAudioPublicationSource normal(false);
        if (normal.read([&] {
                ++callbackCalls;
                return 17;
            }) != 17 ||
            callbackCalls != 1 ||
            normal.readCalls() != 1 ||
            normal.readFrames() != 17)
            return false;
        normal.recordPublished(19);
        return normal.publishedFrames() == 19;
    }

private:
    bool fpgaOffload_ = false;
    std::uint64_t readCalls_ = 0;
    std::uint64_t readFrames_ = 0;
    std::uint64_t publishedFrames_ = 0;
};

std::uint16_t rgb555(std::uint32_t color) {
    return static_cast<std::uint16_t>(((color >> 1) & 0x1fu) |
        ((color >> 4) & 0x03e0u) | ((color >> 7) & 0x7c00u));
}

struct CompactCapture {
    std::array<std::uint16_t, kCompactPixels> pixels{};
    std::array<bool, 192> lines{};
    bool frameReady = false;
    bool incomplete = false;
    std::uint64_t sequence = 0;
    std::uint64_t overruns = 0;

    static void receive(melonDS::u32 frame, melonDS::u16 line,
        const melonDS::u32* top, const melonDS::u32* bottom, void* userdata) {
        auto& self = *static_cast<CompactCapture*>(userdata);
        if (line >= 192) return;
        self.lines[line] = true;
        for (unsigned x = 0; x < 256; ++x) {
            self.pixels[line * 512u + x] = rgb555(top[x]);
            self.pixels[line * 512u + 256u + x] = rgb555(bottom[x]);
        }
        if (line != 191) return;
        for (bool present : self.lines) {
            if (!present) {
                self.incomplete = true;
                self.lines.fill(false);
                return;
            }
        }
        if (self.frameReady) ++self.overruns;
        self.frameReady = true;
        self.sequence = frame;
        self.lines.fill(false);
    }
};

struct LayerCapture {
    std::array<std::vector<nds4mister::LayerRecord>, 2> records{
        std::vector<nds4mister::LayerRecord>(nds4mister::kLayerFrameRecords),
        std::vector<nds4mister::LayerRecord>(nds4mister::kLayerFrameRecords)};
    unsigned recordIndex = 0;
    std::array<bool, 384> lines{};
    std::array<bool, 384> fallback{};
    std::array<std::uint8_t, 384> physicalScreen{};
    bool frameReady = false;
    bool incomplete = false;
    std::uint64_t sequence = 0;
    std::uint64_t overruns = 0;

    static void receive(melonDS::u32 frame, melonDS::u16 line,
        melonDS::u8 engine, bool screenSwap, const melonDS::u32* top,
        const melonDS::u32* second, const melonDS::u8* windowMask,
        melonDS::u16 blendCnt, melonDS::u8 eva, melonDS::u8 evb,
        melonDS::u8 evy, melonDS::u8 displayMode,
        melonDS::u16 masterBrightness, void* userdata) {
        auto& self = *static_cast<LayerCapture*>(userdata);
        (void)frame;
        if (line >= 192 || engine >= 2) return;
        const unsigned state = line * 2u + engine;
        self.lines[state] = true;
        const unsigned screen = engine ^ (screenSwap ? 0u : 1u);
        self.physicalScreen[state] = static_cast<std::uint8_t>(screen);
        self.fallback[state] =
            displayMode != 1 || ((masterBrightness >> 14) & 3) != 0;
        for (unsigned x = 0; x < 256; ++x) {
            auto& out =
                self.records[self.recordIndex][line * 512u + screen * 256u + x];
            out = {};
            out.pixels[0] = top[x];
            out.pixels[1] = second[x];
            out.ranks[0] = 0x10;
            out.valid = 0x03;
            out.blendCnt = blendCnt;
            out.eva = eva;
            out.evb = evb;
            out.evy = evy;
            out.flags = (windowMask[x] & 0x20) ? 1u : 0u;
            out.setTag(static_cast<std::uint16_t>(screen * 256u + x), line);
        }
    }

    void fillFinal(unsigned line, unsigned screen, const melonDS::u32* pixels) {
        for (unsigned x = 0; x < 256; ++x) {
            auto& out =
                records[recordIndex][line * 512u + screen * 256u + x];
            out = {};
            out.pixels[0] = pixels[x] & 0x00ffffffu;
            out.valid = 1;
            out.setTag(static_cast<std::uint16_t>(screen * 256u + x), line);
        }
    }

    static void receiveOutput(melonDS::u32 frame, melonDS::u16 line,
        const melonDS::u32* top, const melonDS::u32* bottom, void* userdata) {
        auto& self = *static_cast<LayerCapture*>(userdata);
        if (line >= 192) return;
        const unsigned a = line * 2u, b = a + 1u;
        if (!self.lines[a] || !self.lines[b]) {
            self.fillFinal(line, 0, top);
            self.fillFinal(line, 1, bottom);
            self.lines[a] = self.lines[b] = true;
        } else {
            if (self.fallback[a]) {
                const unsigned screen = self.physicalScreen[a];
                self.fillFinal(line, screen, screen ? bottom : top);
            }
            if (self.fallback[b]) {
                const unsigned screen = self.physicalScreen[b];
                self.fillFinal(line, screen, screen ? bottom : top);
            }
        }
        if (line != 191) return;
        for (bool present : self.lines)
            if (!present) self.incomplete = true;
        if (self.frameReady) ++self.overruns;
        self.frameReady = true;
        self.sequence = frame;
        self.lines.fill(false);
        self.fallback.fill(false);
    }
};

class CompactPublisher {
public:
    explicit CompactPublisher(void* mapping) : mapping_(mapping) {}
    ~CompactPublisher() {
        if (layerWorker_.joinable()) {
            {
                std::lock_guard<std::mutex> lock(layerMutex_);
                layerStopping_ = true;
            }
            layerCv_.notify_all();
            layerWorker_.join();
        }
    }

    volatile const std::uint64_t* inputWord() const {
        return reinterpret_cast<volatile const std::uint64_t*>(
            static_cast<const std::byte*>(mapping_) +
            sizeof(nds4mister::LayerPublication));
    }

    void publish(const CompactCapture& capture, const std::int16_t* audio,
        std::uint32_t audioFrames) {
        generation_ += 2;
        activeSlot_ ^= 1u;
        const auto sequence = nextSequence(capture.sequence);
        nds4mister::LayerPublication header{
            nds4mister::kLayerPublicationMagic, 2,
            sizeof(nds4mister::LayerPublication), generation_ | 1u,
            activeSlot_, kCompactFrameBytes, sizeof(std::uint16_t),
            kCompactPixels, sequence, generation_ | 1u, audioFrames};
        std::memcpy(mapping_, &header, sizeof(header));
        __sync_synchronize();
        auto* destination = static_cast<std::byte*>(mapping_) +
            nds4mister::kLayerSlotBytes * (activeSlot_ + 1u);
        std::memcpy(destination, capture.pixels.data(), kCompactFrameBytes);
        if (audioFrames)
            std::memcpy(destination + kCompactFrameBytes, audio,
                        audioFrames * 2u * sizeof(std::int16_t));
        __sync_synchronize();
        header.generation = generation_;
        header.generationCheck = generation_;
        std::memcpy(mapping_, &header, sizeof(header));
        __sync_synchronize();
        ++published_;
    }

    void publish(const LayerCapture& capture, const std::int16_t* audio,
        std::uint32_t audioFrames) {
        if (!layerWorker_.joinable())
            layerWorker_ = std::thread([this] { layerWorkerLoop(); });
        std::unique_lock<std::mutex> lock(layerMutex_);
        layerCv_.wait(lock, [this] { return !layerPending_ && !layerBusy_; });
        layerRecords_ = capture.records[capture.recordIndex].data();
        layerSequence_ = nextSequence(capture.sequence);
        layerAudioFrames_ = audioFrames;
        if (audioFrames)
            std::memcpy(layerAudio_.data(), audio,
                        audioFrames * 2u * sizeof(std::int16_t));
        layerPending_ = true;
        lock.unlock();
        layerCv_.notify_all();
    }

    void drainLayer() {
        if (!layerWorker_.joinable()) return;
        std::unique_lock<std::mutex> lock(layerMutex_);
        layerCv_.wait(lock, [this] { return !layerPending_ && !layerBusy_; });
    }

    std::uint64_t published() const { return published_; }

private:
    std::uint64_t nextSequence(std::uint64_t captured) {
        if (captured > publishedSequence_) publishedSequence_ = captured;
        else ++publishedSequence_;
        return publishedSequence_;
    }

    void publishLayerNow(const nds4mister::LayerRecord* records,
        std::uint64_t sequence, const std::int16_t* audio,
        std::uint32_t audioFrames) {
        generation_ += 2;
        activeSlot_ ^= 1u;
        nds4mister::LayerPublication header{
            nds4mister::kLayerPublicationMagic, 1,
            sizeof(nds4mister::LayerPublication), generation_ | 1u,
            activeSlot_, nds4mister::kLayerFrameBytes,
            sizeof(nds4mister::LayerRecord), nds4mister::kLayerFrameRecords,
            sequence, generation_ | 1u, audioFrames};
        std::memcpy(mapping_, &header, sizeof(header));
        __sync_synchronize();
        auto* destination = static_cast<std::byte*>(mapping_) +
            nds4mister::kLayerSlotBytes * (activeSlot_ + 1u);
        std::memcpy(destination, records,
                    nds4mister::kLayerFrameBytes);
        if (audioFrames)
            std::memcpy(destination + nds4mister::kLayerFrameBytes, audio,
                        audioFrames * 2u * sizeof(std::int16_t));
        __sync_synchronize();
        header.generation = generation_;
        header.generationCheck = generation_;
        std::memcpy(mapping_, &header, sizeof(header));
        __sync_synchronize();
        ++published_;
    }

    void layerWorkerLoop() {
        for (;;) {
            const nds4mister::LayerRecord* records;
            const std::int16_t* audio;
            std::uint64_t sequence;
            std::uint32_t audioFrames;
            {
                std::unique_lock<std::mutex> lock(layerMutex_);
                layerCv_.wait(lock, [this] {
                    return layerPending_ || layerStopping_;
                });
                if (!layerPending_ && layerStopping_) return;
                records = layerRecords_;
                sequence = layerSequence_;
                audio = layerAudio_.data();
                audioFrames = layerAudioFrames_;
                layerPending_ = false;
                layerBusy_ = true;
            }
            publishLayerNow(records, sequence, audio, audioFrames);
            {
                std::lock_guard<std::mutex> lock(layerMutex_);
                layerBusy_ = false;
            }
            layerCv_.notify_all();
        }
    }

    void* mapping_;
    std::uint64_t generation_ = 0;
    std::uint64_t published_ = 0;
    std::uint64_t publishedSequence_ = 0;
    std::uint32_t activeSlot_ = 1;
    std::thread layerWorker_;
    std::mutex layerMutex_;
    std::condition_variable layerCv_;
    const nds4mister::LayerRecord* layerRecords_ = nullptr;
    std::array<std::int16_t, 2048> layerAudio_{};
    std::uint64_t layerSequence_ = 0;
    std::uint32_t layerAudioFrames_ = 0;
    bool layerPending_ = false;
    bool layerBusy_ = false;
    bool layerStopping_ = false;
};

bool publicationSelfTest() {
    std::vector<std::byte> memory(kCompactMapBytes);
    CompactPublisher publisher(memory.data());
    CompactCapture capture;
    capture.sequence = 0x123456789abcdef0ULL;
    for (std::size_t index = 0; index < capture.pixels.size(); ++index)
        capture.pixels[index] = static_cast<std::uint16_t>(index ^ 0x5a5au);
    std::array<std::int16_t, 10> audio{
        -1, 1, -2, 2, -3, 3, -4, 4, -5, 5};
    publisher.publish(capture, audio.data(), 5);

    const auto* header =
        reinterpret_cast<const nds4mister::LayerPublication*>(memory.data());
    if (header->magic != nds4mister::kLayerPublicationMagic ||
        header->abi != 2 || header->headerBytes != sizeof(*header) ||
        header->generation != 2 || header->generationCheck != 2 ||
        header->activeSlot != 0 || header->frameBytes != kCompactFrameBytes ||
        header->recordBytes != sizeof(std::uint16_t) ||
        header->recordCount != kCompactPixels ||
        header->frameSequence != capture.sequence || header->reserved != 5)
        return false;
    const auto* slot = memory.data() + nds4mister::kLayerSlotBytes;
    if (std::memcmp(slot, capture.pixels.data(), kCompactFrameBytes) != 0)
        return false;
    if (std::memcmp(slot + kCompactFrameBytes, audio.data(),
                    audio.size() * sizeof(audio[0])) != 0)
        return false;

    // Externally clocked melonDS currently reports the same NumFrames value
    // on consecutive output callbacks. The publication sequence must still
    // advance or the FPGA correctly treats every later frame as a duplicate.
    publisher.publish(capture, audio.data(), 5);
    if (header->generation != 4 || header->generationCheck != 4 ||
        header->frameSequence != capture.sequence + 1)
        return false;

    std::array<std::int16_t, 2048> source{}, normalized{};
    for (unsigned frame = 0; frame < 751; ++frame) {
        source[frame * 2] = static_cast<std::int16_t>(frame * 17);
        source[frame * 2 + 1] = static_cast<std::int16_t>(-frame * 17);
    }
    PacedAudio paced;
    const auto first = paced.normalize(source.data(), 751, normalized.data());
    const auto second = paced.normalize(source.data(), 751, normalized.data());
    const auto third = paced.normalize(source.data(), 751, normalized.data());
    const auto fourth = paced.normalize(source.data(), 751, normalized.data());
    return first == 802 && second == 802 && third == 802 &&
        fourth == 803 &&
        normalized[0] == source[0] && normalized[1] == source[1] &&
        paced.normalize(source.data(), 0, normalized.data()) == 0;
}

bool postedWriteRingSelfTest() {
    constexpr std::size_t headerWords =
        nds4mister::kPostedWriteRingHeaderBytes / sizeof(std::uint32_t);
    constexpr std::size_t entryWords =
        nds4mister::kPostedWriteEntryBytes / sizeof(std::uint32_t);
    const auto publish = [](
        volatile std::uint32_t* ringWords,
        std::uint32_t sequence,
        std::uint32_t address,
        std::uint32_t data,
        std::uint32_t cycles,
        std::uint32_t control) {
        constexpr std::size_t publishHeaderWords =
            nds4mister::kPostedWriteRingHeaderBytes /
            sizeof(std::uint32_t);
        constexpr std::size_t publishEntryWords =
            nds4mister::kPostedWriteEntryBytes /
            sizeof(std::uint32_t);
        const std::size_t slot =
            (sequence - 1u) & (nds4mister::kPostedWriteRingEntries - 1u);
        const std::size_t base =
            publishHeaderWords + slot * publishEntryWords;
        ringWords[base + 0u] = address;
        ringWords[base + 1u] = data;
        ringWords[base + 2u] = cycles;
        ringWords[base + 3u] = control;
        ringWords[base + 5u] = 0;
        __sync_synchronize();
        ringWords[base + 4u] = sequence;
        __sync_synchronize();
    };

    std::vector<std::uint32_t> memory(
        nds4mister::kPostedWriteRingBytes / sizeof(std::uint32_t));
    auto* words = reinterpret_cast<volatile std::uint32_t*>(memory.data());
    // No software option means exactly the legacy VRAM-only whitelist.
    PostedWriteRingConsumer consumer(words);
    consumer.initialize();
    if (words[0] != nds4mister::kPostedWriteRingMagic ||
        words[1] != nds4mister::kPostedWriteRingVersion ||
        words[2] != 0 ||
        words[3] != nds4mister::kPostedWriteRingEntries)
        return false;

    publish(words, 1, 0x0600c000u, 0x1111u, 17u, 0xau);
    publish(words, 2, 0x0600c002u, 0x2222u, 19u, 0xau);
    publish(words, 3, 0x0600c004u, 0x3333u, 23u, 0xau);

    std::vector<PostedWriteEntry> applied;
    const auto apply = [&](const PostedWriteEntry& entry) {
        applied.push_back(entry);
    };
    if (consumer.drainTo(0, apply) != 0 || !applied.empty() ||
        consumer.consumerSequence() != 0 || words[2] != 0)
        return false;
    if (consumer.drainTo(2, apply) != 2 || applied.size() != 2 ||
        applied[0].sequence != 1 || applied[0].address != 0x0600c000u ||
        applied[0].data != 0x1111u || applied[0].cycles != 17u ||
        applied[1].sequence != 2 || applied[1].address != 0x0600c002u ||
        words[2] != 2)
        return false;
    // LW visibility race regression: sequence 3 is already atomically present
    // in DDR, but an LW PRODUCER snapshot of 2 must cap consumption/ACK at 2.
    // The unadvertised commit must remain intact for the next doorbell pass.
    const std::size_t third = headerWords + 2u * entryWords;
    if (consumer.consumerSequence() != 2 || words[third + 4u] != 3)
        return false;
    if (consumer.drainAvailable(8, apply) != 1 || applied.size() != 3 ||
        applied[2].sequence != 3 || applied[2].data != 0x3333u ||
        consumer.consumerSequence() != 3 || words[2] != 3)
        return false;

    // Data without the sequence word is not committed and must never be
    // consumed speculatively.
    const std::size_t fourth = headerWords + 3u * entryWords;
    words[fourth + 0u] = 0x0600c006u;
    words[fourth + 1u] = 0x4444u;
    words[fourth + 2u] = 29u;
    words[fourth + 3u] = 0xau;
    if (consumer.drainAvailable(8, apply) != 0 || applied.size() != 3 ||
        consumer.consumerSequence() != 3)
        return false;

    // A downstream queue may be temporarily full after this DDR entry is
    // visible. Retrying must leave the commit and consumer credit intact, and
    // the eventual successful attempt must apply and retire the entry exactly
    // once. A later idle probe must not replay the callback.
    std::vector<std::uint32_t> retryMemory(
        nds4mister::kPostedWriteRingBytes / sizeof(std::uint32_t));
    auto* retryWords =
        reinterpret_cast<volatile std::uint32_t*>(retryMemory.data());
    PostedWriteRingConsumer retryConsumer(retryWords);
    retryConsumer.initialize();
    publish(retryWords, 1, 0x0600c000u, 0x5a5au, 31u, 0xau);
    std::size_t retryAttempts = 0;
    std::size_t retryApplies = 0;
    const auto retryApply = [&](const PostedWriteEntry& entry) {
        ++retryAttempts;
        if (retryAttempts <= 2)
            return PostedWriteRingConsumer::ApplyDisposition::Retry;
        if (entry.sequence != 1 || entry.address != 0x0600c000u ||
            entry.data != 0x5a5au || entry.cycles != 31u)
            throw std::runtime_error("retryable posted entry changed");
        ++retryApplies;
        return PostedWriteRingConsumer::ApplyDisposition::Commit;
    };
    const auto retryBase = headerWords;
    if (retryConsumer.tryDrainOneRetryable(retryApply) !=
            PostedWriteRingConsumer::DrainResult::Retried ||
        retryAttempts != 1 || retryApplies != 0 ||
        retryConsumer.consumerSequence() != 0 || retryWords[2] != 0 ||
        retryWords[retryBase + 4u] != 1)
        return false;
    if (retryConsumer.tryDrainOneRetryable(retryApply) !=
            PostedWriteRingConsumer::DrainResult::Retried ||
        retryAttempts != 2 || retryApplies != 0 ||
        retryConsumer.consumerSequence() != 0 || retryWords[2] != 0 ||
        retryWords[retryBase + 4u] != 1)
        return false;
    if (retryConsumer.tryDrainOneRetryable(retryApply) !=
            PostedWriteRingConsumer::DrainResult::Committed ||
        retryAttempts != 3 || retryApplies != 1 ||
        retryConsumer.consumerSequence() != 1 || retryWords[2] != 1 ||
        retryWords[retryBase + 4u] != 0)
        return false;
    if (retryConsumer.tryDrainOneRetryable(retryApply) !=
            PostedWriteRingConsumer::DrainResult::Empty ||
        retryAttempts != 3 || retryApplies != 1 ||
        retryConsumer.consumerSequence() != 1 || retryWords[2] != 1 ||
        retryWords[retryBase + 4u] != 0)
        return false;

    const auto rejected = [&](bool allowGxWrites,
                              bool allowExternalArm9IfWrites,
                              std::uint32_t capabilities,
                              std::uint32_t address,
                              std::uint32_t serializedControl) {
        std::vector<std::uint32_t> rejectedMemory(
            nds4mister::kPostedWriteRingBytes / sizeof(std::uint32_t));
        auto* rejectedWords = reinterpret_cast<volatile std::uint32_t*>(
            rejectedMemory.data());
        PostedWriteRingConsumer rejectedConsumer(
            rejectedWords, allowGxWrites, allowExternalArm9IfWrites);
        rejectedConsumer.initialize(0, capabilities);
        publish(
            rejectedWords, 1, address, 0xa5a55a5au, 37u,
            serializedControl);
        bool callbackRan = false;
        try {
            rejectedConsumer.drainAvailable(
                1, [&](const PostedWriteEntry&) { callbackRan = true; });
        } catch (const std::runtime_error&) {
            return !callbackRan &&
                rejectedConsumer.consumerSequence() == 0 &&
                rejectedWords[2] == 0 &&
                rejectedWords[headerWords + 4u] == 1;
        }
        return false;
    };

    // The default configuration must reject even an otherwise valid GX word.
    // With the option enabled, only the two inclusive aligned endpoints and
    // aligned words between them are legal; nearby/narrow/ARM7/read traffic
    // remains fail-closed.
    const auto gxCaps = expectedLwCapabilities(true);
    const auto etwCaps = expectedLwCapabilities(false, false, true);
    const auto verifiedPostedOnlyCaps =
        kLwRequiredBaseCaps | kLwCapVerifiedPostedProducer;
    const auto blockingEtwOnlyCaps =
        kLwRequiredBaseCaps | kLwCapBlockingExternalTimeWindow;
    if (!rejected(false, false, kLwRequiredBaseCaps,
                  0x04000400u, 0xcu) ||
        !rejected(true, false, gxCaps, 0x040003fcu, 0xcu) ||
        !rejected(true, false, gxCaps, 0x040005ccu, 0xcu) ||
        !rejected(true, false, gxCaps, 0x04000402u, 0xcu) ||
        !rejected(true, false, gxCaps, 0x04000400u, 0xau) ||
        !rejected(true, false, gxCaps, 0x04000400u, 0x4u) ||
        !rejected(true, false, gxCaps, 0x04000400u, 0xdu) ||
        // Auxiliary bits are reserved for the exact ETW IF opcode. They must
        // never alter the meaning of an existing VRAM or GX entry.
        !rejected(false, false, kLwRequiredBaseCaps,
                  0x0600c000u, (0x80u << 4) | 0xau) ||
        !rejected(true, false, gxCaps,
                  0x04000400u, (0x80u << 4) | 0xcu) ||
        // Both the software opt-in and negotiated capability are mandatory.
        !rejected(false, false, etwCaps,
                  0x000000cdu,
                  ((kPostedAuxExternalArm9If | 0x200080u) << 4) |
                      0xcu) ||
        !rejected(false, true, kLwRequiredBaseCaps,
                  0x000000cdu,
                  ((kPostedAuxExternalArm9If | 0x200080u) << 4) |
                      0xcu) ||
        !rejected(false, true, verifiedPostedOnlyCaps,
                  0x000000cdu,
                  ((kPostedAuxExternalArm9If | 0x200080u) << 4) |
                      0xcu) ||
        !rejected(false, true, blockingEtwOnlyCaps,
                  0x000000cdu,
                  ((kPostedAuxExternalArm9If | 0x200080u) << 4) |
                      0xcu) ||
        // Missing tag and reserved tag bits both fail closed.
        !rejected(false, true, etwCaps,
                  0x000000cdu, (0x200080u << 4) | 0xcu) ||
        !rejected(false, true, etwCaps,
                  0x000000cdu,
                  ((kPostedAuxExternalArm9If | (1u << 26) |
                    0x200080u) << 4) | 0xcu) ||
        !rejected(false, true, etwCaps,
                  0x000000cdu,
                  ((kPostedAuxExternalArm9If | 0x200080u) << 4) |
                      0xau) ||
        !rejected(false, true, etwCaps,
                  0x000000cdu,
                  ((kPostedAuxExternalArm9If | 0x200080u) << 4) |
                      0xdu))
        return false;

    // The exact default-off ETW opcode preserves the fixed 24-byte ring ABI:
    // the existing control word carries its low-four-bit bus control plus the
    // FPGA-predicted final ARM9 IF in the otherwise reserved high 28 bits.
    std::vector<std::uint32_t> etwMemory(
        nds4mister::kPostedWriteRingBytes / sizeof(std::uint32_t));
    auto* etwWords =
        reinterpret_cast<volatile std::uint32_t*>(etwMemory.data());
    PostedWriteRingConsumer etwConsumer(etwWords, false, true);
    etwConsumer.initialize(0, etwCaps);
    publish(
        etwWords, 1, 0x12345678u, 0x00200000u, 0x9abcdef0u,
        ((kPostedAuxExternalArm9If | 0x00200080u) << 4) | 0xcu);
    std::vector<PostedWriteEntry> etwApplied;
    if (etwConsumer.drainTo(
            1, [&](const PostedWriteEntry& entry) {
                etwApplied.push_back(entry);
            }) != 1 ||
        etwApplied.size() != 1 ||
        etwApplied[0].sequence != 1 ||
        etwApplied[0].address != 0x04000214u ||
        etwApplied[0].data != 0x00200000u ||
        etwApplied[0].cycles != 0 ||
        etwApplied[0].control != 0xcu ||
        etwApplied[0].auxiliary != 0x00200080u ||
        etwApplied[0].externalTargetTimestamp !=
            0x9abcdef012345678ULL ||
        !etwApplied[0].externalArm9If ||
        etwConsumer.consumerSequence() != 1 || etwWords[2] != 1)
        return false;

    unsigned etwApplyPhase = 0;
    applyExternalArm9IfPostedEntry(
        etwApplied[0],
        [&](std::uint64_t target, std::string&) {
            if (etwApplyPhase != 0 ||
                target != 0x9abcdef012345678ULL)
                return false;
            etwApplyPhase = 1;
            return true;
        },
        [&](std::uint32_t sourceSequence,
            std::uint64_t target,
            std::uint32_t address,
            std::uint32_t access,
            std::uint32_t writeData,
            std::uint32_t expectedFinalIF,
            bool expectedGXFIFO,
            nds4mister::ExternalARM9IFW1CResult& result,
            std::string&) {
            if (etwApplyPhase != 1 || sourceSequence != 1 ||
                target != 0x9abcdef012345678ULL ||
                address != 0x04000214u || access != 2u ||
                writeData != 0x00200000u ||
                expectedFinalIF != 0x00200080u || !expectedGXFIFO)
                return false;
            etwApplyPhase = 2;
            result = {expectedFinalIF, expectedGXFIFO};
            return true;
        });
    if (etwApplyPhase != 2) return false;

    // A reported/model result mismatch is terminal and cannot be credited as
    // a consumed entry. This exercises the final glue check independently of
    // melonDS's own stricter internal validation.
    bool mismatchedResultRejected = false;
    try {
        applyExternalArm9IfPostedEntry(
            etwApplied[0],
            [](std::uint64_t, std::string&) { return true; },
            [](std::uint32_t, std::uint64_t, std::uint32_t,
               std::uint32_t, std::uint32_t, std::uint32_t,
               bool, nds4mister::ExternalARM9IFW1CResult& result,
               std::string&) {
                result = {0, false};
                return true;
            });
    } catch (const std::runtime_error& error) {
        mismatchedResultRejected =
            std::strstr(error.what(), "mismatched posted proof") != nullptr;
    }
    if (!mismatchedResultRejected) return false;

    std::vector<std::uint32_t> gxMemory(
        nds4mister::kPostedWriteRingBytes / sizeof(std::uint32_t));
    auto* gxWords =
        reinterpret_cast<volatile std::uint32_t*>(gxMemory.data());
    PostedWriteRingConsumer gxConsumer(gxWords, true);
    gxConsumer.initialize(0, expectedLwCapabilities(true));
    publish(gxWords, 1, 0x0600c000u, 0x11112222u, 41u, 0xau);
    publish(gxWords, 2, 0x04000400u, 0x33334444u, 43u, 0xcu);
    publish(gxWords, 3, 0x040005c8u, 0x55556666u, 47u, 0xcu);
    std::vector<PostedWriteEntry> ordered;
    if (gxConsumer.drainTo(
            3, [&](const PostedWriteEntry& entry) {
                ordered.push_back(entry);
            }) != 3 ||
        ordered.size() != 3 ||
        ordered[0].sequence != 1 ||
        ordered[0].address != 0x0600c000u ||
        ordered[0].data != 0x11112222u ||
        ordered[0].cycles != 41u ||
        ordered[0].control != 0xau ||
        ordered[1].sequence != 2 ||
        ordered[1].address != 0x04000400u ||
        ordered[1].data != 0x33334444u ||
        ordered[1].cycles != 43u ||
        ordered[1].control != 0xcu ||
        ordered[2].sequence != 3 ||
        ordered[2].address != 0x040005c8u ||
        ordered[2].data != 0x55556666u ||
        ordered[2].cycles != 47u ||
        ordered[2].control != 0xcu ||
        gxConsumer.consumerSequence() != 3 ||
        gxWords[2] != 3)
        return false;

    // ABI-v2 commit words bind every entry to the claimed LW session. A stale
    // entry with the expected numeric sequence but the wrong epoch must fail
    // before its callback, commit clear, or consumer-credit publication.
    constexpr std::uint32_t epoch = 0x11223344u;
    std::vector<std::uint32_t> epochMemory(
        nds4mister::kPostedWriteRingBytes / sizeof(std::uint32_t));
    auto* epochWords =
        reinterpret_cast<volatile std::uint32_t*>(epochMemory.data());
    PostedWriteRingConsumer epochConsumer(epochWords, true);
    epochConsumer.initialize(epoch, expectedLwCapabilities(true));
    publish(epochWords, 1, 0x04000400u, 0xabcdef01u, 49u, 0xcu);
    bool staleEpochCallback = false;
    try {
        epochConsumer.drainTo(
            1, [&](const PostedWriteEntry&) { staleEpochCallback = true; });
        return false;
    } catch (const std::runtime_error& error) {
        if (std::strstr(error.what(), "changed during read") == nullptr ||
            staleEpochCallback || epochConsumer.consumerSequence() != 0 ||
            epochWords[2] != 0 || epochWords[headerWords + 4u] != 1)
            return false;
    }
    epochWords[headerWords + 5u] = epoch;
    if (epochConsumer.drainTo(
            1, [&](const PostedWriteEntry&) { staleEpochCallback = true; }) != 1 ||
        !staleEpochCallback || epochConsumer.consumerSequence() != 1 ||
        epochWords[2] != 1)
        return false;

    // Sequence zero is both reset state and the atomic "not committed"
    // marker. Prove that 0xffffffff remains consumable once, then both idle
    // draining and a fence to zero fail before a callback can observe an
    // aliased entry. The clean 0->0 no-op is covered above.
    std::vector<std::uint32_t> wrapMemory(
        nds4mister::kPostedWriteRingBytes / sizeof(std::uint32_t));
    auto* wrapWords =
        reinterpret_cast<volatile std::uint32_t*>(wrapMemory.data());
    PostedWriteRingConsumer wrapConsumer(wrapWords, true);
    wrapConsumer.initialize(0, expectedLwCapabilities(true));
    wrapConsumer.seedConsumerSequenceForSelfTest(0xfffffffeu);
    publish(
        wrapWords, 0xffffffffu, 0x04000400u,
        0x77778888u, 53u, 0xcu);
    std::vector<PostedWriteEntry> wrapApplied;
    if (wrapConsumer.drainTo(
            0xffffffffu, [&](const PostedWriteEntry& entry) {
                wrapApplied.push_back(entry);
            }) != 1 ||
        wrapApplied.size() != 1 ||
        wrapApplied[0].sequence != 0xffffffffu ||
        wrapApplied[0].address != 0x04000400u ||
        wrapApplied[0].data != 0x77778888u ||
        wrapApplied[0].cycles != 53u ||
        wrapConsumer.consumerSequence() != 0xffffffffu ||
        wrapWords[2] != 0xffffffffu)
        return false;

    bool wrapCallbackRan = false;
    bool idleWrapRejected = false;
    try {
        wrapConsumer.tryDrainOne(
            [&](const PostedWriteEntry&) { wrapCallbackRan = true; });
    } catch (const std::runtime_error& error) {
        idleWrapRejected =
            std::strstr(error.what(), "reserved zero") != nullptr;
    }
    if (!idleWrapRejected || wrapCallbackRan ||
        wrapConsumer.consumerSequence() != 0xffffffffu ||
        wrapWords[2] != 0xffffffffu)
        return false;

    bool fenceWrapRejected = false;
    try {
        wrapConsumer.drainTo(
            0, [&](const PostedWriteEntry&) { wrapCallbackRan = true; });
    } catch (const std::runtime_error& error) {
        fenceWrapRejected =
            std::strstr(error.what(), "sequence-zero wrap") != nullptr;
    }
    if (!fenceWrapRejected || wrapCallbackRan ||
        wrapConsumer.consumerSequence() != 0xffffffffu ||
        wrapWords[2] != 0xffffffffu)
        return false;
    return true;
}

bool consumedCreditAckSelfTest() {
    constexpr std::size_t headerWords =
        nds4mister::kPostedWriteRingHeaderBytes / sizeof(std::uint32_t);
    constexpr std::size_t entryWords =
        nds4mister::kPostedWriteEntryBytes / sizeof(std::uint32_t);
    const auto publish = [](
        volatile std::uint32_t* words,
        std::uint32_t sequence,
        std::uint32_t address,
        std::uint32_t data,
        std::uint32_t cycles) {
        const std::size_t slot =
            (sequence - 1u) & (nds4mister::kPostedWriteRingEntries - 1u);
        const std::size_t base = headerWords + slot * entryWords;
        words[base + 0u] = address;
        words[base + 1u] = data;
        words[base + 2u] = cycles;
        words[base + 3u] = 0xau;
        words[base + 5u] = 0;
        __sync_synchronize();
        words[base + 4u] = sequence;
        __sync_synchronize();
    };

    std::vector<std::uint32_t> memory(
        nds4mister::kPostedWriteRingBytes / sizeof(std::uint32_t));
    auto* words = reinterpret_cast<volatile std::uint32_t*>(memory.data());
    PostedWriteRingConsumer consumer(words);
    consumer.initialize();
    ConsumedCreditAckLedger ledger(8);
    if (ledger.beginEpoch(0, true) || !ledger.faulted())
        return false;

    // Epoch-zero failure is terminal for one transport instance.
    ConsumedCreditAckLedger session(8);
    if (session.beginEpoch(0x11223344u, false) ||
        !session.beginEpoch(0x11223344u, true))
        return false;

    publish(words, 1, 0x0600c000u, 0x1111u, 37u);
    publish(words, 2, 0x0600c002u, 0x2222u, 14u);
    // Atomic commit makes entries visible to HPS, but is not consumption.
    if (session.pending() != 0 || consumer.consumerSequence() != 0)
        return false;

    std::vector<unsigned> stages;
    const auto consumePosted = [&](const PostedWriteEntry& entry) {
        const bool arm9 = (entry.control & 8u) != 0;
        if (!session.consume(
                arm9, entry.cycles, ConsumedCreditKind::Posted,
                entry.sequence,
                [&] { stages.push_back(entry.sequence * 10u + 1u); },
                [&] { stages.push_back(entry.sequence * 10u + 2u); }))
            throw std::runtime_error(
                "consumed-credit posted transport unexpectedly stalled");
    };
    if (consumer.drainTo(2, consumePosted) != 2 ||
        consumer.consumerSequence() != 2 ||
        session.pending() != 2 ||
        stages != std::vector<unsigned>({11, 12, 21, 22}))
        return false;

    // This models the live mailbox boundary exactly: drain its posted fence,
    // then consume mailbox cycles and its bus operation. The ACK is appended
    // only after both callbacks return.
    if (consumer.drainTo(2, consumePosted) != 0 ||
        !session.consume(
            false, 11, ConsumedCreditKind::Mailbox, 7,
            [&] { stages.push_back(31); },
            [&] { stages.push_back(32); }) ||
        !session.consume(
            false, 40, ConsumedCreditKind::Mailbox, 8,
            [&] { stages.push_back(41); },
            [&] { stages.push_back(42); }) ||
        !session.consume(
            true, 0, ConsumedCreditKind::Mailbox, 9,
            [&] { stages.push_back(51); },
            [&] { stages.push_back(52); }) ||
        !session.consume(
            true, 32768, ConsumedCreditKind::Halt, 10,
            [&] { stages.push_back(61); },
            [&] { stages.push_back(62); }) ||
        !session.consume(
            false, 32768, ConsumedCreditKind::Halt, 11,
            [&] { stages.push_back(71); },
            [&] { stages.push_back(72); }) ||
        !session.consume(
            true, 0, ConsumedCreditKind::IrqSet, 0x00001000u,
            [&] { stages.push_back(81); },
            [&] { stages.push_back(82); }))
        return false;
    if (stages != std::vector<unsigned>({
            11, 12, 21, 22, 31, 32, 41, 42,
            51, 52, 61, 62, 71, 72, 81, 82}))
        return false;

    const std::array<ConsumedCreditAckRecord, 8> expected{{
        {0x11223344u, 1, true, 37, ConsumedCreditKind::Posted, 1},
        {0x11223344u, 2, true, 14, ConsumedCreditKind::Posted, 2},
        {0x11223344u, 3, false, 11, ConsumedCreditKind::Mailbox, 7},
        {0x11223344u, 4, false, 40, ConsumedCreditKind::Mailbox, 8},
        {0x11223344u, 5, true, 0, ConsumedCreditKind::Mailbox, 9},
        {0x11223344u, 6, true, 32768, ConsumedCreditKind::Halt, 10},
        {0x11223344u, 7, false, 32768, ConsumedCreditKind::Halt, 11},
        {0x11223344u, 8, true, 0, ConsumedCreditKind::IrqSet,
         0x00001000u},
    }};
    std::uint64_t arm9Timestamp = 0;
    std::uint64_t arm7Timestamp = 0;
    const std::array<std::uint64_t, 8> expectedShared{
        0, 0, 11, 51, 51, 51, 32819, 32819};
    for (std::size_t index = 0; index < expected.size(); ++index) {
        ConsumedCreditAckRecord record;
        if (!session.pop(record))
            return false;
        const auto& wanted = expected[index];
        if (record.epoch != wanted.epoch ||
            record.sequence != wanted.sequence ||
            record.arm9 != wanted.arm9 ||
            record.cycles != wanted.cycles ||
            record.kind != wanted.kind ||
            record.sourceId != wanted.sourceId)
            return false;
        if (record.arm9) arm9Timestamp += record.cycles;
        else arm7Timestamp += record.cycles;
        if (std::min(arm9Timestamp, arm7Timestamp) !=
            expectedShared[index])
            return false;
    }
    if (session.pending() != 0)
        return false;

    // A full ACK transport stalls before either emulator callback runs.
    ConsumedCreditAckLedger stalled(1);
    if (!stalled.beginEpoch(0x55667788u, true))
        return false;
    unsigned advanceCalls = 0;
    unsigned applyCalls = 0;
    const auto tryConsume = [&](std::uint32_t source) {
        return stalled.consume(
            true, source, ConsumedCreditKind::Mailbox, source,
            [&] { ++advanceCalls; },
            [&] { ++applyCalls; });
    };
    if (!tryConsume(1) || tryConsume(2) ||
        advanceCalls != 1 || applyCalls != 1 ||
        stalled.pending() != 1)
        return false;
    // A new epoch cannot discard an unacknowledged consumed credit.
    if (stalled.beginEpoch(0x99aabbccu, true) || stalled.faulted())
        return false;
    ConsumedCreditAckRecord popped;
    if (!stalled.pop(popped) || popped.sequence != 1 ||
        !tryConsume(2) || advanceCalls != 2 || applyCalls != 2 ||
        !stalled.pop(popped) || popped.sequence != 2)
        return false;
    // Reusing the same epoch after quiescence is ambiguous and fail-closed.
    if (stalled.beginEpoch(0x55667788u, true) || !stalled.faulted())
        return false;

    // Sequence zero is reserved. Publish ffffffff once, then stop before any
    // later callback can change emulator state.
    ConsumedCreditAckLedger wrap(2);
    if (!wrap.beginEpoch(0xa5a5a5a5u, true))
        return false;
    wrap.seedNextSequenceForSelfTest(0xffffffffu);
    unsigned wrapEffects = 0;
    if (!wrap.consume(
            true, 3, ConsumedCreditKind::Mailbox, 0xffffffffu,
            [&] { ++wrapEffects; },
            [&] { ++wrapEffects; }) ||
        !wrap.exhausted() ||
        wrap.consume(
            true, 5, ConsumedCreditKind::Mailbox, 0,
            [&] { ++wrapEffects; },
            [&] { ++wrapEffects; }) ||
        wrapEffects != 2)
        return false;
    if (!wrap.pop(popped) || popped.sequence != 0xffffffffu ||
        wrap.pop(popped))
        return false;

    // Malformed IRQ_SET must fail before either emulator callback executes.
    ConsumedCreditAckLedger invalidIrq(2);
    unsigned invalidIrqEffects = 0;
    if (!invalidIrq.beginEpoch(0xabcdef01u, true) ||
        invalidIrq.consume(
            true, 1, ConsumedCreditKind::IrqSet, 0x00000008u,
            [&] { ++invalidIrqEffects; },
            [&] { ++invalidIrqEffects; }) ||
        !invalidIrq.faulted() || invalidIrqEffects != 0 ||
        invalidIrq.pending() != 0)
        return false;
    return true;
}

bool inputSourceArbiterSelfTest() {
    InputSourceArbiter arbiter;
    std::uint32_t fallback = 0x0a55u;
    unsigned polls = 0;
    const auto pollLocal = [&] {
        ++polls;
        return fallback;
    };
    const auto published = [](std::uint32_t joystick) {
        return (static_cast<std::uint64_t>(
                    nds4mister::kCompactInputMagic) << 32) |
            joystick;
    };

    // FPGA input remains request-synchronous while quiet evdev maintenance
    // is skipped for 63 calls and performed exactly on the 64th.
    for (unsigned call = 0;
         call + 1 < InputSourceArbiter::kLocalMaintenancePeriod; ++call) {
        const auto joystick = 1u << (call % 12u);
        if (arbiter.select(published(joystick), pollLocal) !=
                nds4mister::mister_joystick_to_ds_key_mask(joystick) ||
            polls != 0)
            return false;
    }
    if (arbiter.select(published(0x0011u), pollLocal) !=
            nds4mister::mister_joystick_to_ds_key_mask(0x0011u) ||
        polls != 1)
        return false;

    for (unsigned call = 0;
         call < InputSourceArbiter::kLocalMaintenancePeriod; ++call) {
        if (arbiter.select(published(0x0002u), pollLocal) !=
            nds4mister::mister_joystick_to_ds_key_mask(0x0002u))
            return false;
    }
    if (polls != 2) return false;

    // Consume only part of the next valid-input cadence before falling back.
    // This makes the transition test prove that invalid input resets the
    // maintenance counter rather than accidentally inheriting the partial 17.
    for (unsigned call = 0; call < 17; ++call) {
        if (arbiter.select(published(0x0010u), pollLocal) !=
                nds4mister::mister_joystick_to_ds_key_mask(0x0010u) ||
            polls != 2)
            return false;
    }

    // An invalid FPGA word must poll evdev immediately on every call, and the
    // first valid word after fallback must take effect without an evdev poll.
    fallback = 0x0123u;
    if (arbiter.select(0, pollLocal) != fallback || polls != 3)
        return false;
    fallback = 0x0456u;
    if (arbiter.select(0x1234567800000000ULL, pollLocal) != fallback ||
        polls != 4)
        return false;
    if (arbiter.select(published(0x0004u), pollLocal) !=
            nds4mister::mister_joystick_to_ds_key_mask(0x0004u) ||
        polls != 4)
        return false;

    // A fallback transition resets the cadence. Sixty-three later valid
    // samples remain poll-free; the following one performs maintenance.
    for (unsigned call = 1;
         call + 1 < InputSourceArbiter::kLocalMaintenancePeriod; ++call) {
        if (arbiter.select(published(0x0008u), pollLocal) !=
                nds4mister::mister_joystick_to_ds_key_mask(0x0008u) ||
            polls != 4)
            return false;
    }
    return arbiter.select(published(0x0008u), pollLocal) ==
               nds4mister::mister_joystick_to_ds_key_mask(0x0008u) &&
        polls == 5;
}

bool mailboxInputPacerSelfTest() {
    MailboxInputPacer pacer;
    if (!pacer.shouldService(
            0xffffffffu, 2, false, MailboxInputPacer::kDefaultPeriod))
        return false;
    for (unsigned call = 1;
         call < MailboxInputPacer::kDefaultPeriod; ++call) {
        if (pacer.shouldService(
                0x04000214u, 1, true,
                MailboxInputPacer::kDefaultPeriod))
            return false;
    }
    if (!pacer.shouldService(
            0x04000214u, 1, true,
            MailboxInputPacer::kDefaultPeriod))
        return false;

    // KEYINPUT and any access spanning EXTKEYIN stay request-synchronous and
    // reset the ordinary-request cadence.
    if (!pacer.shouldService(
            0x04000130u, 1, true,
            MailboxInputPacer::kDefaultPeriod) ||
        !pacer.shouldService(
            0x04000134u, 2, true,
            MailboxInputPacer::kDefaultPeriod))
        return false;
    if (pacer.shouldService(
            0x04000130u, 1, false,
            MailboxInputPacer::kDefaultPeriod) ||
        pacer.shouldService(
            0x04000132u, 1, true,
            MailboxInputPacer::kDefaultPeriod))
        return false;
    for (unsigned call = 2;
         call + 1 < MailboxInputPacer::kDefaultPeriod; ++call) {
        if (pacer.shouldService(
                0xffffffffu, 2, false,
                MailboxInputPacer::kDefaultPeriod))
            return false;
    }
    return pacer.shouldService(
        0xffffffffu, 2, false, MailboxInputPacer::kDefaultPeriod);
}

bool layerPublicationSelfTest() {
    std::vector<std::byte> memory(kCompactMapBytes);
    CompactPublisher publisher(memory.data());
    LayerCapture capture;
    capture.sequence = 0x1020304050607080ULL;
    capture.records[0].front().pixels[0] = 0x12345678u;
    capture.records[0].back().pixels[1] = 0x89abcdefu;
    std::array<std::int16_t, 6> audio{-11, 11, -22, 22, -33, 33};
    publisher.publish(capture, audio.data(), 3);
    capture.recordIndex = 1;
    capture.sequence++;
    capture.records[1].front().pixels[0] = 0x0badc0deu;
    capture.records[1].back().pixels[1] = 0x13579bdfu;
    std::array<std::int16_t, 8> audio2{-44, 44, -55, 55, -66, 66, -77, 77};
    publisher.publish(capture, audio2.data(), 4);
    publisher.drainLayer();
    const auto* header =
        reinterpret_cast<const nds4mister::LayerPublication*>(memory.data());
    const auto* slot = memory.data() + 2u * nds4mister::kLayerSlotBytes;
    const auto* records =
        reinterpret_cast<const nds4mister::LayerRecord*>(slot);
    return header->magic == nds4mister::kLayerPublicationMagic &&
        header->abi == 1 && header->generation == 4 &&
        header->generationCheck == 4 && header->activeSlot == 1 &&
        header->frameBytes == nds4mister::kLayerFrameBytes &&
        header->recordBytes == sizeof(nds4mister::LayerRecord) &&
        header->recordCount == nds4mister::kLayerFrameRecords &&
        header->frameSequence == capture.sequence && header->reserved == 4 &&
        records[0].pixels[0] == 0x0badc0deu &&
        records[nds4mister::kLayerFrameRecords - 1].pixels[1] == 0x13579bdfu &&
        std::memcmp(slot + nds4mister::kLayerFrameBytes, audio2.data(),
                    audio2.size() * sizeof(audio2[0])) == 0;
}

bool layerFallbackSelfTest() {
    LayerCapture capture;
    std::array<melonDS::u32, 256> aTop{}, aSecond{}, bTop{}, bSecond{};
    std::array<melonDS::u32, 256> physicalTop{}, physicalBottom{};
    std::array<melonDS::u8, 256> window{};
    window.fill(0xff);aTop.fill(0x00112233);aSecond.fill(0x00445566);
    bTop.fill(0x00010203);bSecond.fill(0x00040506);
    physicalTop.fill(0x000a0b0c);physicalBottom.fill(0x000d0e0f);

    LayerCapture::receive(3, 0, 0, false, aTop.data(), aSecond.data(),
        window.data(), 0, 0, 0, 0, 2, 0, &capture);
    LayerCapture::receive(3, 0, 1, false, bTop.data(), bSecond.data(),
        window.data(), 0, 0, 0, 0, 1, 0, &capture);
    LayerCapture::receiveOutput(
        3, 0, physicalTop.data(), physicalBottom.data(), &capture);
    if (capture.records[0][0].pixels[0] != bTop[0] ||
        capture.records[0][0].valid != 3 ||
        capture.records[0][256].pixels[0] != physicalBottom[0] ||
        capture.records[0][256].valid != 1) return false;

    LayerCapture::receiveOutput(
        3, 1, physicalTop.data(), physicalBottom.data(), &capture);
    if (capture.records[0][512].pixels[0] != physicalTop[0] ||
        capture.records[0][768].pixels[0] != physicalBottom[0]) return false;

    LayerCapture::receive(3, 2, 0, true, aTop.data(), aSecond.data(),
        window.data(), 0, 0, 0, 0, 1, 0x4001, &capture);
    LayerCapture::receive(3, 2, 1, true, bTop.data(), bSecond.data(),
        window.data(), 0, 0, 0, 0, 1, 0, &capture);
    LayerCapture::receiveOutput(
        3, 2, physicalTop.data(), physicalBottom.data(), &capture);
    return capture.records[0][1024].pixels[0] == physicalTop[0] &&
           capture.records[0][1280].pixels[0] == bTop[0];
}

std::uintptr_t parseAddress(const char* text) {
    char* end = nullptr;
    errno = 0;
    const auto value = std::strtoull(text, &end, 0);
    if (errno || !end || *end) throw std::runtime_error("invalid mailbox physical address");
    return static_cast<std::uintptr_t>(value);
}

bool busJsonlTriggerMatches(std::uint32_t address,
                            std::uint32_t trigger,
                            bool arm9,
                            bool readNotWrite,
                            unsigned access,
                            std::uint32_t writeData,
                            bool requireNonzeroArm9WordWrite) {
    if ((address & 0xfffffffcu) != (trigger & 0xfffffffcu))
        return false;
    if (!requireNonzeroArm9WordWrite)
        return true;
    return arm9 && !readNotWrite && access == 2u && writeData != 0u;
}
}

int main(int argc, char** argv) try {
#if defined(__linux__) && defined(__arm__)
    installArithmeticFaultDiagnostic();
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-div0-diagnostic") == 0) {
        volatile int zero = 0;
        return argc / zero;
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-ldiv0-diagnostic") == 0) {
        volatile std::int64_t zero = 0;
        return static_cast<int>(static_cast<std::int64_t>(argc) / zero);
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-sigfpe-fallback") == 0) {
        std::raise(SIGFPE);
        return 1;
    }
#endif
    if (argc == 2 && std::strcmp(argv[1], "--self-test-publication") == 0) {
        if (!publicationSelfTest())
            throw std::runtime_error("compact publication self-test failed");
        std::cout << "PASS: standalone HPS compact frame/audio publication layout\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-bus-jsonl-trigger") == 0) {
        const auto match = [](std::uint32_t address, bool arm9,
                              bool readNotWrite, unsigned access,
                              std::uint32_t writeData, bool strict) {
            return busJsonlTriggerMatches(address, 0x04000400u, arm9,
                                          readNotWrite, access, writeData,
                                          strict);
        };
        if (!match(0x04000400u, true, false, 2u, 1u, true) ||
            !match(0x04000403u, true, false, 2u, 1u, true) ||
            match(0x04000400u, false, false, 2u, 1u, true) ||
            match(0x04000400u, true, true, 2u, 1u, true) ||
            match(0x04000400u, true, false, 1u, 1u, true) ||
            match(0x04000400u, true, false, 2u, 0u, true) ||
            match(0x04000404u, true, false, 2u, 1u, true) ||
            !match(0x04000400u, false, true, 0u, 0u, false))
            throw std::runtime_error("bus JSONL trigger self-test failed");
        std::cout << "PASS: bus JSONL trigger can require a nonzero ARM9 "
                     "word write without changing legacy matching\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-layer-publication") == 0) {
        if (!layerPublicationSelfTest() || !layerFallbackSelfTest())
            throw std::runtime_error("layer publication self-test failed");
        std::cout << "PASS: standalone HPS FPGA-layer/audio publication and fallback layout\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-posted-ring") == 0) {
        if (!postedWriteRingSelfTest())
            throw std::runtime_error("posted-write ring self-test failed");
        std::cout << "PASS: HPS posted-write ring preserves retry-without-retire, single commit, order, timing, fence, default-off GX/ETW-IF whitelists, auxiliary isolation, and sequence-zero fail-closed semantics\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-lw-transport-protocol") == 0) {
        if (!lwTransportProtocolSelfTest() ||
            !lcdEventQueueConsumerSelfTest())
            throw std::runtime_error(
                "LW transport protocol self-test failed");
        std::cout
            << "PASS: LW ABI span, pending-authoritative mailbox sequencing, "
               "release dedupe, gap rejection, reset sequence restart, and "
               "local LCD queue ordering/recovery\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-lw-ring-startup") == 0) {
        if (!lwPostedRingStartupSelfTest())
            throw std::runtime_error(
                "LW posted-ring startup self-test failed");
        std::cout
            << "PASS: LW v2 capability preflight, exclusive claim, DDR-ring "
               "epoch initialization, and explicit session arm\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-posted-gx-ordering") == 0) {
        if (!postedGxWriteOrderingSelfTest())
            throw std::runtime_error(
                "posted GX DMA/stall ordering self-test failed");
        std::cout
            << "PASS: posted GX drains event-triggered DMA before write and "
               "preserves DMA/stall completion before consumer credit\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-consumed-credit-ack") == 0) {
        if (!consumedCreditAckSelfTest())
            throw std::runtime_error(
                "consumed-credit ACK self-test failed");
        std::cout << "PASS: default-disconnected HPS consumed-credit/IRQ_SET ledger preserves posted/mailbox order, stalls, epochs, halt catch-up, and sequence-zero fail-closed semantics\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-irq-set-capture") == 0) {
        if (!nds4mister::MelonDsBackend::self_test_irq_set_capture())
            throw std::runtime_error("melonDS IRQ_SET capture self-test failed");
        std::cout << "PASS: melonDS SetIRQ observer coalesces explicit ARM9/ARM7 IF causes with deterministic take/clear\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-time-irq-reverse") == 0) {
        if (!timeIrqReverseResponderSelfTest())
            throw std::runtime_error(
                "time/IRQ reverse responder self-test failed");
        std::cout
            << "PASS: default-off reverse responder preserves posted fences, "
               "bounded no-replay backpressure, IRQ byte lanes, read payload, "
               "and LW-plus-DDR receipt validation\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(
            argv[1],
            "--self-test-external-time-window-prerequisites") == 0) {
        if (!externalTimeWindowProductionPrerequisitesSelfTest())
            throw std::runtime_error(
                "external-time-window production prerequisite self-test "
                "failed");
        if (!nds4mister::MelonDsBackend::self_test_offline_fast_beta())
            throw std::runtime_error(
                "offline fast-beta WiFi/RTC self-test failed");
        std::cout
            << "PASS: blocking ETW requires verified-posted plus independent "
               "capability and exact 15,424-byte BRRP layout; default-off "
               "offline beta cancels WiFi/RTC timers and IRQs\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-runtime-profiler") == 0) {
        if (!RuntimeProfiler::selfTest())
            throw std::runtime_error("runtime profiler self-test failed");
        std::cout << "PASS: default-off sampled HPS runtime profiler counters\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(argv[1],
            "--self-test-lw-consumer-ack-fast-path") == 0) {
        if (!lwConsumerAckFastPathSelfTest())
            throw std::runtime_error(
                "LW consumer ACK fast-path self-test failed");
        std::cout << "PASS: unchanged LW consumer credit bypasses bridge "
                     "reads while every real ACK remains ownership checked\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(argv[1], "--self-test-input-arbitration") == 0) {
        if (!inputSourceArbiterSelfTest() || !mailboxInputPacerSelfTest())
            throw std::runtime_error("input source arbitration self-test failed");
        std::cout << "PASS: FPGA input stays request-synchronous on keypad "
                     "reads with paced mailbox and evdev maintenance\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(
            argv[1], "--self-test-fpga-audio-offload-publication") == 0) {
        if (!HpsAudioPublicationSource::selfTest())
            throw std::runtime_error(
                "FPGA-audio offload publication self-test failed");
        std::cout
            << "PASS: FPGA-audio offload suppresses HPS audio read and "
               "publication callbacks while default mode remains unchanged\n";
        return 0;
    }
    if (argc == 2 &&
        std::strcmp(
            argv[1], "--self-test-arm7-sound-mmio-trace") == 0) {
        nds4mister::Arm7SoundMmioTraceState trace(1);
        nds4mister::Arm7SoundMmioWriteTraceRecord record;
        const auto result = trace.observeSuccessfulRequest(
            0x1234u, false, false, 0x04000501u, 0u, 0x12345680u,
            0x20u, 0x100u, record);
        if (result !=
                nds4mister::Arm7SoundMmioTraceResult::CapturedAndExhausted ||
            record.byteEnable != 0x2u ||
            record.writeData != 0x12345680u ||
            record.alignedData != 0x00008000u ||
            record.arm7Cycles != 0x20u ||
            record.sharedTimestamp != 0x100u)
            throw std::runtime_error(
                "ARM7 sound-MMIO trace self-test failed");
        std::cout
            << "PASS: bounded ARM7 sound-MMIO responder trace record\n";
        return 0;
    }
    if (argc < 2 || argc > 4) {
        std::cerr << "usage: nds_hps_oracle_responder rom "
                     "[mailbox-physical-address] [--layers]\n";
        return 2;
    }
    // Oracle transport. The DDR mailbox costs four DDR interactions per request
    // and contends with the video fetcher through the shared DDRAM arbiter;
    // profiling put ~24 us of the ~42 us per-request budget in that handshake.
    // The lightweight bridge replaces it with direct register access. Requires
    // a core built with LW_MAILBOX_ENABLE.
    bool lwMailbox = false;
    if (const char* lwText = std::getenv("NDS4MISTER_LW_MAILBOX")) {
        if (std::strcmp(lwText, "1") == 0) lwMailbox = true;
        else if (std::strcmp(lwText, "0") != 0)
            throw std::runtime_error("NDS4MISTER_LW_MAILBOX must be 0 or 1");
    }
    std::uintptr_t physical = lwMailbox ? kLwBridgePhysical : kDefaultPhysical;
    bool layerPublication = false;
    bool physicalOverridden = false;
    for (int index = 2; index < argc; ++index) {
        if (std::strcmp(argv[index], "--layers") == 0) layerPublication = true;
        else { physical = parseAddress(argv[index]); physicalOverridden = true; }
    }
    (void)physicalOverridden;
    std::uint64_t traceRequests = 0;
    if (const char* traceText = std::getenv("NDS4MISTER_TRACE_REQUESTS")) {
        char* end = nullptr;
        errno = 0;
        traceRequests = std::strtoull(traceText, &end, 0);
        if (errno || !end || *end)
            throw std::runtime_error("invalid NDS4MISTER_TRACE_REQUESTS");
    }
    std::uint64_t traceSkipRequests = 0;
    if (const char* traceText =
            std::getenv("NDS4MISTER_TRACE_SKIP_REQUESTS")) {
        char* end = nullptr;
        errno = 0;
        traceSkipRequests = std::strtoull(traceText, &end, 0);
        if (errno || !end || *end)
            throw std::runtime_error(
                "invalid NDS4MISTER_TRACE_SKIP_REQUESTS");
    }
    std::uint64_t traceNonTiming = 0;
    if (const char* traceText =
            std::getenv("NDS4MISTER_TRACE_NON_TIMING")) {
        char* end = nullptr;
        errno = 0;
        traceNonTiming = std::strtoull(traceText, &end, 0);
        if (errno || !end || *end)
            throw std::runtime_error(
                "invalid NDS4MISTER_TRACE_NON_TIMING");
    }
    bool traceBadPc = std::getenv("NDS4MISTER_TRACE_BAD_PC") != nullptr;
    const bool traceBadAddressOnly =
        std::getenv("NDS4MISTER_TRACE_BAD_ADDRESS_ONLY") != nullptr;
    const bool pcXorTelemetry =
        std::getenv("NDS4MISTER_PC_XOR_TELEMETRY") != nullptr;
    bool traceExceptionReturn =
        std::getenv("NDS4MISTER_TRACE_EXCEPTION_RETURN") != nullptr;
    const bool traceArm7IpcArguments =
        std::getenv("NDS4MISTER_TRACE_ARM7_IPC_ARGUMENTS") != nullptr;
    bool traceKeyInput = false;
    if (const char* traceKeyInputText =
            std::getenv("NDS4MISTER_TRACE_KEYINPUT")) {
        if (std::strcmp(traceKeyInputText, "1") != 0)
            throw std::runtime_error(
                "invalid NDS4MISTER_TRACE_KEYINPUT (expected 1)");
        traceKeyInput = true;
    }
    std::uint64_t traceArm7SoundWrites = 0;
    if (const char* traceText =
            std::getenv("NDS4MISTER_TRACE_ARM7_SOUND_WRITES")) {
        char* end = nullptr;
        errno = 0;
        traceArm7SoundWrites = std::strtoull(traceText, &end, 0);
        if (errno || !end || end == traceText || *end ||
            *traceText == '-' ||
            traceArm7SoundWrites >
                nds4mister::kArm7SoundMmioTraceMaxWrites)
            throw std::runtime_error(
                "invalid NDS4MISTER_TRACE_ARM7_SOUND_WRITES "
                "(expected 0..1000000)");
    }
    bool exceptionReturnActive = false;
    unsigned exceptionReturnSamples = 0;
    const bool paceFrames = std::getenv("NDS4MISTER_PACE_FRAMES") != nullptr;
    bool fpgaAudioOffload = false;
    if (const char* offloadText =
            std::getenv("NDS4MISTER_FPGA_AUDIO_OFFLOAD")) {
        if (std::strcmp(offloadText, "1") != 0)
            throw std::runtime_error(
                "invalid NDS4MISTER_FPGA_AUDIO_OFFLOAD (expected 1)");
#if NDS4MISTER_FPGA_AUDIO_OFFLOAD
        fpgaAudioOffload = true;
#else
        throw std::runtime_error(
            "NDS4MISTER_FPGA_AUDIO_OFFLOAD requires an explicitly "
            "offload-enabled responder build");
#endif
    }
    bool gxPostedWrites = false;
    if (const char* gxPostedText =
            std::getenv("NDS4MISTER_GX_POSTED_ENABLE")) {
        if (std::strcmp(gxPostedText, "1") != 0)
            throw std::runtime_error(
                "invalid NDS4MISTER_GX_POSTED_ENABLE (expected 1)");
        gxPostedWrites = true;
    }
    if (gxPostedWrites && !lwMailbox)
        throw std::runtime_error(
            "GX posted writes require the epoch-aware LW transport");
    bool timeIrqReverse = false;
    if (const char* reverseText =
            std::getenv("NDS4MISTER_TIME_IRQ_REVERSE")) {
        if (std::strcmp(reverseText, "1") != 0)
            throw std::runtime_error(
                "invalid NDS4MISTER_TIME_IRQ_REVERSE (expected 1)");
        timeIrqReverse = true;
    }
    if (timeIrqReverse && !lwMailbox)
        throw std::runtime_error(
            "NDS4MISTER_TIME_IRQ_REVERSE requires "
            "NDS4MISTER_LW_MAILBOX=1");
    bool externalTimeWindow = false;
    if (const char* externalText =
            std::getenv("NDS4MISTER_EXTERNAL_TIME_WINDOW")) {
        if (std::strcmp(externalText, "1") != 0)
            throw std::runtime_error(
                "invalid NDS4MISTER_EXTERNAL_TIME_WINDOW (expected 1)");
        externalTimeWindow = true;
    }
    if (externalTimeWindow && !lwMailbox)
        throw std::runtime_error(
            "NDS4MISTER_EXTERNAL_TIME_WINDOW requires "
            "NDS4MISTER_LW_MAILBOX=1");
    if (externalTimeWindow && timeIrqReverse)
        throw std::runtime_error(
            "NDS4MISTER_EXTERNAL_TIME_WINDOW and TIME_IRQ_REVERSE share "
            "one FPGA DDR client and are mutually exclusive");
    bool localLcd = false;
    if (const char* localLcdText =
            std::getenv("NDS4MISTER_LOCAL_LCD")) {
        if (std::strcmp(localLcdText, "1") != 0)
            throw std::runtime_error(
                "invalid NDS4MISTER_LOCAL_LCD (expected 1)");
        localLcd = true;
    }
    if (localLcd && !externalTimeWindow)
        throw std::runtime_error(
            "NDS4MISTER_LOCAL_LCD requires NDS4MISTER_EXTERNAL_TIME_WINDOW=1");
    bool offlineFastBeta = false;
    if (const char* offlineText =
            std::getenv("NDS4MISTER_OFFLINE_FAST_BETA")) {
        if (std::strcmp(offlineText, "1") != 0)
            throw std::runtime_error(
                "invalid NDS4MISTER_OFFLINE_FAST_BETA (expected 1)");
        offlineFastBeta = true;
    }
    if (offlineFastBeta && !localLcd)
        throw std::runtime_error(
            "NDS4MISTER_OFFLINE_FAST_BETA requires NDS4MISTER_LOCAL_LCD=1");
    bool externalTimeWindowCapacityExperiment = false;
    if (const char* experimentText =
            std::getenv("NDS4MISTER_ETW_CAPACITY16_EXPERIMENT")) {
        if (std::strcmp(experimentText, "1") != 0)
            throw std::runtime_error(
                "invalid NDS4MISTER_ETW_CAPACITY16_EXPERIMENT "
                "(expected 1)");
        externalTimeWindowCapacityExperiment = true;
    }
    if (externalTimeWindowCapacityExperiment && !externalTimeWindow)
        throw std::runtime_error(
            "NDS4MISTER_ETW_CAPACITY16_EXPERIMENT requires "
            "NDS4MISTER_EXTERNAL_TIME_WINDOW=1");
    if (externalTimeWindow && !externalTimeWindowCapacityExperiment)
        throw std::runtime_error(
            "NDS4MISTER_EXTERNAL_TIME_WINDOW remains fail-closed because "
            "the 16-event group capacity is unproven; set "
            "NDS4MISTER_ETW_CAPACITY16_EXPERIMENT=1 only for a bounded "
            "hardware measurement");
    const std::uint32_t lwExpectedCapabilities =
        expectedLwCapabilities(
            gxPostedWrites, timeIrqReverse, externalTimeWindow, localLcd);
    std::uint32_t lwSessionCookie = 0;
    if (lwMailbox) {
        const auto ticks = static_cast<std::uint64_t>(
            std::chrono::steady_clock::now().time_since_epoch().count());
        lwSessionCookie = static_cast<std::uint32_t>(ticks) ^
            static_cast<std::uint32_t>(ticks >> 32) ^
            static_cast<std::uint32_t>(getpid()) ^ 0x4e445351u;
        if (lwSessionCookie == 0) lwSessionCookie = 1;
    }
    std::uint64_t profileIntervalSeconds = 0;
    if (const char* profileText =
            std::getenv("NDS4MISTER_PROFILE_SECONDS")) {
        char* end = nullptr;
        errno = 0;
        profileIntervalSeconds = std::strtoull(profileText, &end, 0);
        if (errno || !end || *end || profileIntervalSeconds > 3600)
            throw std::runtime_error(
                "invalid NDS4MISTER_PROFILE_SECONDS");
    }
    std::uint32_t arm9TraceTrigger = 0;
    if (const char* triggerText =
            std::getenv("NDS4MISTER_ARM9_TRACE_TRIGGER")) {
        char* end = nullptr;
        errno = 0;
        const auto parsed = std::strtoull(triggerText, &end, 0);
        const bool supportedRegion =
            parsed == 0 ||
            (parsed >= 0x02000000u && parsed < 0x02400000u) ||
            (parsed >= 0x01f00000u && parsed < 0x02000000u) ||
            (parsed >= 0xfff00000u && parsed <= UINT32_MAX);
        if (errno || !end || *end || parsed > UINT32_MAX ||
            (parsed & 3u) != 0 || !supportedRegion)
            throw std::runtime_error(
                "invalid NDS4MISTER_ARM9_TRACE_TRIGGER");
        arm9TraceTrigger = static_cast<std::uint32_t>(parsed);
    }
    std::string soundEpochPath;
    if (const char* epochPath =
            std::getenv("NDS4MISTER_SOUND_EPOCH_FILE")) {
        if (*epochPath == '\0' || *epochPath != '/')
            throw std::runtime_error(
                "invalid NDS4MISTER_SOUND_EPOCH_FILE "
                "(expected absolute path)");
        soundEpochPath = epochPath;
    }
    if (fpgaAudioOffload && !layerPublication)
        throw std::runtime_error(
            "NDS4MISTER_FPGA_AUDIO_OFFLOAD requires --layers");
    if (fpgaAudioOffload && soundEpochPath.empty())
        throw std::runtime_error(
            "NDS4MISTER_FPGA_AUDIO_OFFLOAD requires a persistent "
            "NDS4MISTER_SOUND_EPOCH_FILE");
    const long pageSizeResult = sysconf(_SC_PAGESIZE);
    const std::size_t pageSize = pageSizeResult > 0 ? static_cast<std::size_t>(pageSizeResult) : 4096u;
    const std::uintptr_t page = physical & ~(static_cast<std::uintptr_t>(pageSize) - 1u);
    const std::size_t offset = static_cast<std::size_t>(physical - page);
    const std::size_t mailboxRegisterBytes =
        !lwMailbox ? 40u
        : localLcd ? kLwLocalLcdRegisterBytes
        : externalTimeWindow ? kLwExternalTimeWindowRegisterBytes
        : timeIrqReverse ? kLwReverseRegisterBytes
                         : kLwRegisterBytes;
    if (offset + mailboxRegisterBytes > pageSize)
        throw std::runtime_error("mailbox crosses mmap page");

    // Save persistence is an HPS-only service.  Cartridge accesses still use
    // melonDS's existing save-chip emulation; this only supplies the initial
    // bytes and commits changed ranges without consuming FPGA resources.
    std::string saveRoot;
    if (const char* configuredSaveRoot =
            std::getenv("NDS4MISTER_SAVE_ROOT")) {
        if (*configuredSaveRoot &&
            std::strcmp(configuredSaveRoot, "none") != 0)
            saveRoot = configuredSaveRoot;
    } else {
        saveRoot = "/media/fat/saves/NDS";
    }
    nds4mister::MelonDsBackend backend(saveRoot);
    std::string error;
    if (externalTimeWindow && !backend.external_time_window_capable())
        throw std::runtime_error(
            "NDS4MISTER_EXTERNAL_TIME_WINDOW requires an explicitly "
            "external-time-window-enabled responder build");
    if (!backend.load_rom(argv[1], error)) throw std::runtime_error(error);
    const auto initialSaveStats = backend.save_persistence_stats();
    std::cout << "NDS4MISTER_SAVE_V1 state="
              << (backend.save_persistence_enabled() ? "active" : "disabled")
              << " bytes=" << initialSaveStats.saveBytes
              << " loaded_existing="
              << (initialSaveStats.loadedExisting ? 1 : 0)
              << "\n" << std::flush;
    if (offlineFastBeta &&
        !backend.set_external_offline_fast_beta(true, error))
        throw std::runtime_error(error);
    if (!backend.set_external_lcd_renderer_enabled(localLcd, error))
        throw std::runtime_error(error);
    if (!backend.set_fpga_audio_offload(fpgaAudioOffload, error))
        throw std::runtime_error(error);
    nds4mister::DirectBootImage bootImage;
    if (!backend.export_direct_boot_image(bootImage, error))
        throw std::runtime_error(error);
    const int fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (fd < 0) throw std::runtime_error(std::string("open /dev/mem: ") + std::strerror(errno));
    const std::size_t mailboxMapBytes = offset + mailboxRegisterBytes;
    void* mapping = mmap(nullptr, mailboxMapBytes,
        PROT_READ | PROT_WRITE, MAP_SHARED, fd,
        static_cast<off_t>(page));
    if (mapping == MAP_FAILED)
        throw std::runtime_error(std::string("mmap mailbox: ") + std::strerror(errno));
    auto* words = reinterpret_cast<volatile std::uint32_t*>(
        static_cast<std::byte*>(mapping) + offset);

    // Claim is the first operation after mapping the FPGA-owned LW registers
    // and precedes every write to surviving RAM, the ring, or descriptor. The
    // two-phase FPGA contract keeps transport admission disabled until ARM.
    if (lwMailbox && !externalTimeWindow)
        claimCleanLwSession(
            words, lwSessionCookie, lwExpectedCapabilities);

    void* mainRamMapping = mmap(nullptr, nds4mister::kStandaloneMainRamBytes,
        PROT_READ | PROT_WRITE, MAP_SHARED, fd,
        static_cast<off_t>(nds4mister::kStandaloneMainRamPhysical));
    if (mainRamMapping == MAP_FAILED)
        throw std::runtime_error(std::string("mmap standalone main RAM: ") +
                                 std::strerror(errno));
    void* sharedWramMapping = mmap(nullptr, nds4mister::kStandaloneSharedWramBytes,
        PROT_READ | PROT_WRITE, MAP_SHARED, fd,
        static_cast<off_t>(nds4mister::kStandaloneSharedWramPhysical));
    if (sharedWramMapping == MAP_FAILED)
        throw std::runtime_error(std::string("mmap standalone shared WRAM: ") +
                                 std::strerror(errno));
    void* arm7WramMapping = mmap(nullptr, nds4mister::kStandaloneArm7WramBytes,
        PROT_READ | PROT_WRITE, MAP_SHARED, fd,
        static_cast<off_t>(nds4mister::kStandaloneArm7WramPhysical));
    if (arm7WramMapping == MAP_FAILED)
        throw std::runtime_error(std::string("mmap standalone ARM7 WRAM: ") +
                                 std::strerror(errno));
    void* postedRingMapping = mmap(nullptr, nds4mister::kPostedWriteRingBytes,
        PROT_READ | PROT_WRITE, MAP_SHARED, fd,
        static_cast<off_t>(nds4mister::kPostedWriteRingPhysical));
    if (postedRingMapping == MAP_FAILED)
        throw std::runtime_error(std::string("mmap posted-write ring: ") +
                                 std::strerror(errno));
    const auto descriptorPage = nds4mister::kStandaloneBootDescriptorPhysical &
        ~(static_cast<std::uintptr_t>(pageSize) - 1u);
    const auto descriptorOffset = static_cast<std::size_t>(
        nds4mister::kStandaloneBootDescriptorPhysical - descriptorPage);
    void* descriptorMapping = mmap(nullptr, pageSize, PROT_READ | PROT_WRITE,
        MAP_SHARED, fd, static_cast<off_t>(descriptorPage));
    if (descriptorMapping == MAP_FAILED)
        throw std::runtime_error(std::string("mmap boot descriptor: ") +
                                 std::strerror(errno));
    void* compactMapping = mmap(nullptr, kCompactMapBytes,
        PROT_READ | PROT_WRITE, MAP_SHARED, fd,
        static_cast<off_t>(nds4mister::kCompactPublicationPhysical));
    void* externalTimeWindowMapping = nullptr;
    if (externalTimeWindow) {
        externalTimeWindowMapping = mmap(
            nullptr, kExternalTimeWindowBytes,
            PROT_READ | PROT_WRITE, MAP_SHARED, fd,
            static_cast<off_t>(kExternalTimeWindowPhysical));
        if (externalTimeWindowMapping == MAP_FAILED)
            throw std::runtime_error(
                std::string("mmap external time-window DDR queue: ") +
                std::strerror(errno));
    }
    void* reverseRingMapping = nullptr;
    if (timeIrqReverse) {
        reverseRingMapping = mmap(
            nullptr, nds4mister::kConsumedCreditAckRingBytes,
            PROT_READ | PROT_WRITE, MAP_SHARED, fd,
            static_cast<off_t>(
                nds4mister::kConsumedCreditAckRingPhysical));
        if (reverseRingMapping == MAP_FAILED)
            throw std::runtime_error(
                std::string("mmap reverse counted ring: ") +
                std::strerror(errno));
    }
    close(fd);
    if (compactMapping == MAP_FAILED)
        throw std::runtime_error(std::string("mmap compact publication: ") +
                                 std::strerror(errno));
    CompactPublisher publisher(compactMapping);
    CompactCapture capture;
    LayerCapture layerCapture;
    if (layerPublication) {
        backend.set_composite_line_sink(&LayerCapture::receive, &layerCapture);
        backend.set_output_line_sink(
            &LayerCapture::receiveOutput, &layerCapture);
        melonDS::NDS4MiSTer::SetCompositeLineBypass(true);
    } else {
        backend.set_output_line_sink(&CompactCapture::receive, &capture);
    }
    auto* inputWord = publisher.inputWord();
    LocalInput localInput;
    InputSourceArbiter inputSource;
    MailboxInputPacer mailboxInputPacer;
    PostedWriteRingConsumer postedRing(
        static_cast<volatile std::uint32_t*>(postedRingMapping),
        gxPostedWrites, false);
    std::unique_ptr<nds4mister::ConsumedCreditAckMappedDdrMemory>
        externalTimeWindowMemory;
    std::unique_ptr<nds4mister::ExternalTimeWindowDdrProducer>
        externalTimeWindowProducer;
    std::unique_ptr<nds4mister::ExternalTimeWindowLwControl>
        externalTimeWindowControl;
    std::unique_ptr<nds4mister::ExternalTimeWindowRuntime>
        externalTimeWindowRuntime;
    std::unique_ptr<LcdEventQueueConsumer> localLcdConsumer;
    if (localLcd) {
        localLcdConsumer = std::make_unique<LcdEventQueueConsumer>(
            words,
            [&](const nds4mister::ExternalLCDPhase& phase,
                bool render, bool resync, std::string& callbackError) {
                return backend.apply_external_lcd_phase(
                    phase, render, resync, callbackError);
            },
            [&] {
                capture.lines.fill(false);
                capture.frameReady = false;
                capture.incomplete = true;
                layerCapture.lines.fill(false);
                layerCapture.fallback.fill(false);
                layerCapture.frameReady = false;
                layerCapture.incomplete = true;
            });
    }
    std::function<bool(std::uint64_t, std::uint64_t&, std::string&)>
        drainExternalTimeWindowFence = [](
            std::uint64_t, std::uint64_t&, std::string& callbackError) {
            callbackError =
                "ETW posted-fence drain was invoked before boot release";
            return false;
        };
    if (externalTimeWindow) {
        externalTimeWindowMemory = std::make_unique<
            nds4mister::ConsumedCreditAckMappedDdrMemory>(
                externalTimeWindowMapping, kExternalTimeWindowBytes);
        externalTimeWindowProducer = std::make_unique<
            nds4mister::ExternalTimeWindowDdrProducer>(
                *externalTimeWindowMemory,
                kExternalTimeWindowLayout);
        if (externalTimeWindowProducer->requiredWords() *
                sizeof(std::uint64_t) != kExternalTimeWindowBytes)
            throw std::runtime_error(
                "external time-window DDR layout size mismatch");
        // The external session claim is still the first device write after
        // mapping LW, but ETW needs its complete DDR mapping and producer
        // layout validated before that claim. Admission remains disarmed.
        claimCleanLwSession(
            words, lwSessionCookie, lwExpectedCapabilities);
        externalTimeWindowControl = std::make_unique<
            nds4mister::ExternalTimeWindowLwControl>(
                words,
                kLwExternalTimeWindowRegisterBytes /
                    sizeof(std::uint32_t));
        nds4mister::ExternalTimeWindowRuntimeCallbacks callbacks{
            [&](bool arm9, std::uint64_t timestamp,
                std::string& callbackError) {
                return backend.report_external_time_window_cpu_reached(
                    arm9, timestamp, callbackError);
            },
            [&] { return backend.pending_external_irq_transitions(); },
            [&](std::uint64_t target,
                std::uint64_t finiteBound,
                const nds4mister::ExternalTimeWindowReplacement& replacement,
                nds4mister::ExternalTimeWindowDdrClosureOutput& output,
                std::string& callbackError) {
                nds4mister::ExternalTimeWindow window;
                if (!backend.advance_and_close_external_time_window(
                        target, finiteBound, 0, replacement,
                        window, callbackError))
                    return false;
                output.window = window;
                output.transitions =
                    backend.take_external_irq_transitions();
                return true;
            },
            [&](const nds4mister::ExternalBlockingMMIORequest& request,
                std::uint64_t finiteBound,
                const nds4mister::ExternalTimeWindowReplacement& replacement,
                nds4mister::ExternalBlockingMMIOCompletion& completion,
                std::string& callbackError) {
                nds4mister::ExternalBlockingMMIOPreAccess preAccess;
                nds4mister::ExternalBlockingMMIOExactAccess exactAccess;
                if (localLcd) {
                    preAccess = [&](std::uint64_t barrierTimestamp,
                        const nds4mister::ExternalBlockingMMIORequest& exact,
                        std::string& orderingError) {
                        if (exact.access > 2)
                            return true;
                        const std::uint64_t first = exact.address;
                        const std::uint64_t last =
                            first + (std::uint64_t{1} << exact.access) - 1u;
                        if (first > 0x04000007u || last < 0x04000004u)
                            return true;
                        try {
                            requireOwnedLwSession(
                                words, lwSessionCookie,
                                lwExpectedCapabilities);
                            // Inclusive ordering: consume every descriptor at
                            // T <= B before the exact admitted read or write.
                            // The following stock bus access then returns the
                            // mirror or applies the completed FPGA write.
                            return localLcdConsumer->drainThrough(
                                barrierTimestamp, orderingError);
                        } catch (const std::exception& exception) {
                            orderingError = exception.what();
                            return false;
                        }
                    };
                    exactAccess = [&](std::uint64_t,
                        const nds4mister::ExternalBlockingMMIORequest& exact,
                        nds4mister::ExternalBlockingMMIOOverrideResult& result,
                        std::string& accessError) {
                        // This runs after the inclusive drain and before the
                        // one access is claimed. LCD reads come only from the
                        // latest FPGA snapshot. LCD writes are acknowledged
                        // without invoking stock melonDS LCD register logic;
                        // FPGA mirrors them only after ETW completion.
                        return localLcdConsumer->exactAccess(
                            exact, result, accessError);
                    };
                }
                return backend.execute_external_blocking_mmio_transaction(
                    request, finiteBound, 0, replacement,
                    completion, callbackError, preAccess, exactAccess);
            },
            [&](bool arm9) { return backend.external_cpu_halted(arm9); },
            [&](std::uint64_t requestedFence,
                std::uint64_t& stableFence,
                std::string& callbackError) {
                return drainExternalTimeWindowFence(
                    requestedFence, stableFence, callbackError);
            },
            [&](bool enabled, std::string& callbackError) {
                return backend.set_external_time_window_enabled(
                    enabled, callbackError);
            },
        };
        externalTimeWindowRuntime = std::make_unique<
            nds4mister::ExternalTimeWindowRuntime>(
                *externalTimeWindowControl,
                *externalTimeWindowProducer,
                std::move(callbacks));
    }
    std::unique_ptr<nds4mister::ConsumedCreditAckMappedDdrMemory>
        reverseMemory;
    std::unique_ptr<nds4mister::ConsumedCreditAckDdrProducer>
        reverseProducer;
    if (timeIrqReverse) {
        reverseMemory = std::make_unique<
            nds4mister::ConsumedCreditAckMappedDdrMemory>(
                reverseRingMapping,
                nds4mister::kConsumedCreditAckRingBytes);
        reverseProducer = std::make_unique<
            nds4mister::ConsumedCreditAckDdrProducer>(
                *reverseMemory,
                nds4mister::ConsumedCreditAckDdrLayout{
                    nds4mister::kConsumedCreditAckRingEntries,
                    nds4mister::kConsumedCreditAckRingHeaderWords64,
                    nds4mister::kConsumedCreditAckRingConsumerWordOffset,
                    nds4mister::kConsumedCreditAckRingDescriptorWordOffset});
    }

    // /dev/mem on MiSTer's older kernel exposes the FPGA/HPS DDR aperture as
    // device memory.  Ordinary memcpy may use cached/vectorized stores whose
    // read-after-write behavior is not defined for that mapping, and msync is
    // unsupported there.  Force every word onto the device mapping and read
    // the CRC back through volatile accesses before publishing the descriptor.
    auto* mappedRamWords =
        static_cast<volatile std::uint32_t*>(mainRamMapping);
    const auto* sourceRamWords = reinterpret_cast<const std::uint32_t*>(
        bootImage.main_ram.data());
    for (std::size_t index = 0;
         index < nds4mister::kStandaloneMainRamBytes / sizeof(std::uint32_t);
         ++index)
        mappedRamWords[index] = sourceRamWords[index];
    __sync_synchronize();
    if (msync(mainRamMapping, nds4mister::kStandaloneMainRamBytes, MS_SYNC) != 0 &&
        errno != EINVAL && errno != ENOSYS)
        throw std::runtime_error(std::string("sync standalone main RAM: ") +
                                 std::strerror(errno));
    const auto sourceRamCrc = nds4mister::boot_crc32(
        bootImage.main_ram.data(), bootImage.main_ram.size());
    const auto* mappedRamBytes =
        static_cast<volatile const std::uint8_t*>(mainRamMapping);
    std::uint32_t mappedRamCrc = 0xffffffffu;
    std::size_t firstMismatch = nds4mister::kStandaloneMainRamBytes;
    std::size_t mismatchCount = 0;
    for (std::size_t index = 0;
         index < nds4mister::kStandaloneMainRamBytes; ++index) {
        const auto mappedByte = mappedRamBytes[index];
        if (mappedByte != bootImage.main_ram[index]) {
            if (firstMismatch == nds4mister::kStandaloneMainRamBytes)
                firstMismatch = index;
            ++mismatchCount;
        }
        mappedRamCrc ^= mappedByte;
        for (unsigned bit = 0; bit < 8; ++bit)
            mappedRamCrc = (mappedRamCrc >> 1) ^
                (0xedb88320u & (0u - (mappedRamCrc & 1u)));
    }
    mappedRamCrc = ~mappedRamCrc;
    if (mappedRamCrc != sourceRamCrc)
        throw std::runtime_error("standalone main RAM readback CRC mismatch: source=" +
                                 std::to_string(sourceRamCrc) + " mapped=" +
                                 std::to_string(mappedRamCrc) + " first_offset=" +
                                 std::to_string(firstMismatch) + " source_byte=" +
                                 std::to_string(bootImage.main_ram[firstMismatch]) +
                                 " mapped_byte=" +
                                 std::to_string(mappedRamBytes[firstMismatch]) +
                                 " mismatch_count=" +
                                 std::to_string(mismatchCount));
    if (!backend.attach_external_main_ram(
            static_cast<std::uint8_t*>(mainRamMapping),
            nds4mister::kStandaloneMainRamBytes, error))
        throw std::runtime_error(error);
    const char* traceMainRamObjectText =
        std::getenv("NDS4MISTER_TRACE_MAIN_RAM_OBJECT");
    const bool traceMainRamObject = traceMainRamObjectText != nullptr &&
        std::strcmp(traceMainRamObjectText, "0") != 0;
    constexpr std::array<std::uint32_t, 4> watchedMainRamAddresses = {
        0x020962fcu, 0x02096300u, 0x02096304u, 0x02096928u
    };
    std::array<std::uint32_t, watchedMainRamAddresses.size()>
        watchedMainRamValues{};
    auto readWatchedMainRam = [&] {
        std::array<std::uint32_t, watchedMainRamAddresses.size()> values{};
        for (std::size_t index = 0; index < values.size(); ++index) {
            const auto offset =
                watchedMainRamAddresses[index] & 0x003ffffcu;
            values[index] = mappedRamWords[offset / sizeof(std::uint32_t)];
        }
        __sync_synchronize();
        return values;
    };
    auto reportWatchedMainRam = [&](const char* stage,
                                    std::uint32_t generation,
                                    bool arm9,
                                    std::uint32_t executionPc,
                                    std::uint32_t requestAddress) {
        if (!traceMainRamObject) return;
        const auto values = readWatchedMainRam();
        for (std::size_t index = 0; index < values.size(); ++index) {
            if (values[index] == watchedMainRamValues[index]) continue;
            std::cerr << "main_ram_object_change"
                      << " stage=" << stage
                      << " generation=0x" << std::hex << generation
                      << " cpu=" << (arm9 ? 9 : 7)
                      << " pc=0x" << executionPc
                      << " request_address=0x" << requestAddress
                      << " watched_address=0x"
                      << watchedMainRamAddresses[index]
                      << " old=0x" << watchedMainRamValues[index]
                      << " new=0x" << values[index]
                      << std::dec << "\n" << std::flush;
        }
        watchedMainRamValues = values;
    };
    watchedMainRamValues = readWatchedMainRam();
    if (traceMainRamObject) {
        for (std::size_t index = 0; index < watchedMainRamValues.size();
             ++index) {
            std::cerr << "main_ram_object_initial"
                      << " watched_address=0x" << std::hex
                      << watchedMainRamAddresses[index]
                      << " value=0x" << watchedMainRamValues[index]
                      << std::dec << "\n";
        }
        std::cerr << std::flush;
    }
    auto copyToDevice = [](void* destination,
                           const std::vector<std::uint8_t>& source) {
        auto* destinationWords = static_cast<volatile std::uint32_t*>(destination);
        const auto* sourceWords =
            reinterpret_cast<const std::uint32_t*>(source.data());
        for (std::size_t index = 0;
             index < source.size() / sizeof(std::uint32_t); ++index)
            destinationWords[index] = sourceWords[index];
        __sync_synchronize();
    };
    copyToDevice(sharedWramMapping, bootImage.shared_wram);
    copyToDevice(arm7WramMapping, bootImage.arm7_wram);
    if (!backend.attach_external_wram(
            static_cast<std::uint8_t*>(sharedWramMapping),
            nds4mister::kStandaloneSharedWramBytes,
            static_cast<std::uint8_t*>(arm7WramMapping),
            nds4mister::kStandaloneArm7WramBytes, error))
        throw std::runtime_error(error);

    if (lwMailbox) {
        // Unlike the DDR mailbox, LW registers are owned by FPGA and must
        // never be blindly zeroed. Most importantly, an already-owned session
        // must be rejected before initialize() can touch surviving DDR.
        initializePostedRingAndArmLwSession(
            words, lwSessionCookie, lwExpectedCapabilities,
            [&] {
                postedRing.initialize(
                    lwSessionCookie, lwExpectedCapabilities);
                if (timeIrqReverse &&
                    !reverseProducer->beginSession(
                        lwSessionCookie, true))
                    throw std::runtime_error(
                        "reverse counted transport session initialization "
                        "failed");
                if (externalTimeWindow &&
                    (!externalTimeWindowRuntime ||
                     !externalTimeWindowRuntime->beginSession(
                         lwSessionCookie, true, error)))
                    throw std::runtime_error(
                        error.empty()
                            ? "external time-window session initialization "
                              "failed"
                            : error);
            },
            [&] { words[kLwRegArm] = lwSessionCookie; });
        if (timeIrqReverse)
            waitReverseSessionReady(
                *reverseProducer, words, lwSessionCookie,
                lwExpectedCapabilities);
        if (localLcd) {
            // LW ARM is the ownership boundary, but the ETW ring needs a few
            // FPGA clocks to bind that epoch before lcd_operating can assert.
            // During that bounded interval the queue must remain in its exact
            // clean pre-arm state. Keep transport ownership strict and wait
            // only for the enable transition; never weaken epoch checks after
            // the queue becomes active.
            const auto deadline = std::chrono::steady_clock::now() +
                std::chrono::seconds(1);
            for (;;) {
                requireOwnedLwSession(
                    words, lwSessionCookie, lwExpectedCapabilities);
                const auto armDecision = classifyLcdQueueArmState(
                    words[kLwRegLcdStatus],
                    words[kLwRegLcdDropped],
                    words[kLwRegLcdAckSequence]);
                if (armDecision == LcdQueueArmDecision::Ready)
                    break;
                if (armDecision == LcdQueueArmDecision::Fault)
                    throw std::runtime_error(
                        "local LCD queue left its clean state before enable");
                if (std::chrono::steady_clock::now() >= deadline)
                    throw std::runtime_error(
                        "local LCD queue enable transition timed out");
                sched_yield();
            }
            if (!localLcdConsumer->beginSession(error))
                throw std::runtime_error(error);
        }
    } else {
        // Both FPGA producer sequences restart at zero on reset while DDR
        // survives an RBF reload. Clear/version the ring before releasing CPU.
        postedRing.initialize();
        // Clear stale DDR mailbox generations before publishing the boot
        // descriptor. Descriptor publication releases the FPGA CPUs, whose
        // first external transaction can arrive immediately.
        for (unsigned index = 0; index < 10; ++index) words[index] = 0;
        __sync_synchronize();
    }

    if (externalTimeWindow) {
        // The CPUs are still held by the unpublished boot descriptor. Establish
        // and consume grant one now, so no instruction can race an absent time
        // horizon after descriptor publication.
        const auto deadline =
            std::chrono::steady_clock::now() + std::chrono::seconds(1);
        while (!externalTimeWindowRuntime->initialGrantConsumed()) {
            const auto result = externalTimeWindowRuntime->poll(error);
            if (result ==
                nds4mister::ExternalTimeWindowRuntimePollResult::Fault)
                throw std::runtime_error(
                    "initial external time-window grant failed: " + error);
            if (std::chrono::steady_clock::now() >= deadline)
                throw std::runtime_error(
                    "initial external time-window grant/ACK timeout");
            sched_yield();
        }
    }

    nds4mister::StandaloneBootDescriptor descriptor;
    descriptor.arm9_dtcm_irq_vector = bootImage.arm9_dtcm_irq_vector;
    descriptor.arm9_trace_trigger = arm9TraceTrigger;
    descriptor.arm9_entry = bootImage.arm9_entry;
    descriptor.arm7_entry = bootImage.arm7_entry;
    // The existing production responder keeps generation one unless the
    // simulator-first sound shadow explicitly opts into a persistent epoch.
    // Once enabled, make the value durable before publishing the descriptor:
    // a crash may skip an epoch but cannot intentionally reuse one.
    const std::uint32_t descriptorGeneration = soundEpochPath.empty()
        ? 1
        : nds4mister::allocate_persistent_sound_epoch(soundEpochPath);
    descriptor.seal(descriptorGeneration);
    auto* descriptorWords = reinterpret_cast<volatile std::uint32_t*>(
        static_cast<std::byte*>(descriptorMapping) + descriptorOffset);
    const auto* sourceWords = reinterpret_cast<const std::uint32_t*>(&descriptor);
    descriptorWords[2] = 0;
    for (unsigned index = 0; index < 16; ++index) {
        if (index != 2) descriptorWords[index] = sourceWords[index];
    }
    __sync_synchronize();
    descriptorWords[2] = descriptor.generation;
    __sync_synchronize();
    for (unsigned index = 0; index < 16; ++index) {
        if (descriptorWords[index] != sourceWords[index])
            throw std::runtime_error("standalone boot descriptor readback mismatch");
    }

    std::signal(SIGINT, stop);
    std::signal(SIGTERM, stop);

    std::uint32_t completed = 0;
    bool lwResponsePublished = false;
    std::uint32_t lastLwConsumerAck = 0;
    std::uint32_t reverseFrontier = 0;
    std::uint32_t activeKeys = 0x0fffu;
    std::uint64_t lastPublishedInput = 0;
    std::uint64_t inputSelectionEpoch = 0;
    std::uint64_t lastKeyInputReadEpoch = UINT64_MAX;
    std::uint64_t keyInputReadCount = 0;
    backend.set_key_mask(activeKeys);
    RuntimeProfiler profiler(profileIntervalSeconds);
    if (timeIrqReverse) {
        backend.set_irq_set_capture(true);
        (void)backend.take_irq_set_capture();
    }
    std::array<std::int16_t, 2048> sourceAudio{}, publishedAudio{};
    PacedAudio pacedAudio;
    std::uint64_t spins = 0;
    std::uint64_t servicedOperations = 0;
    std::size_t externalTimeWindowLoggedMaxEvents = externalTimeWindow
        ? externalTimeWindowRuntime->maxObservedGroupEventCount() : 0;
    // Cartridge ROMCTRL ready-poll collapse. Bounded so a stuck or
    // never-completing transfer degrades to the old polling behaviour
    // instead of wedging the responder.
    static constexpr std::uint32_t kCartRomCtrl = 0x040001a4u;
    static constexpr unsigned kCartPollAttempts = 4096;
    // Each advance runs melonDS's event scheduler, which profiling shows is
    // ~42% of all wall time. A small step means many scheduler calls per
    // collapsed poll, so this is tunable: larger steps trade cartridge timing
    // granularity for far fewer scheduler entries.
    std::uint32_t cartPollCycles = 32;
    if (const char* stepText = std::getenv("NDS4MISTER_CART_POLL_CYCLES")) {
        char* end = nullptr;
        const auto step = std::strtoul(stepText, &end, 0);
        if (end == stepText || *end != '\0' || step < 1 || step > 4096)
            throw std::runtime_error(
                "NDS4MISTER_CART_POLL_CYCLES must be 1..4096");
        cartPollCycles = static_cast<std::uint32_t>(step);
    }
    std::uint64_t cartPollAdvances = 0;
    // Per-request mailbox overhead reduction. Profiling at ~23.7k
    // requests/s showed serviceInput() and the publish check running on
    // EVERY mailbox request (the posted-write path already rate-limits
    // serviceInput to 1-in-64), and 16% of requests advancing zero
    // emulated cycles yet still paying a ~10 us scheduler call.
    // MEASURED WORSE ON HARDWARE and therefore DEFAULT OFF: over eight
    // matched 20 s windows this gave 4.57 FPS against 5.41 for the
    // unmodified path, while nearly tripling requests/s (47k vs 19k) --
    // the CPUs spun more without making progress. Kept behind the knob so
    // the experiment is reproducible; set NDS4MISTER_LEAN_MAILBOX=1 to
    // re-enable. Do not turn this on without re-measuring.
    bool leanMailbox = false;
    if (const char* leanText = std::getenv("NDS4MISTER_LEAN_MAILBOX")) {
        if (std::strcmp(leanText, "0") == 0) leanMailbox = false;
        else if (std::strcmp(leanText, "1") != 0)
            throw std::runtime_error(
                "NDS4MISTER_LEAN_MAILBOX must be 0 or 1");
    }
    // Carried forward when a zero-cycle request skips the scheduler call.
    // Only the diagnostic ARM7 sound-write trace consumes this value.
    std::uint64_t lastSharedTimestamp = 0;
    bool cartPollCollapse = true;
    if (const char* collapseText =
            std::getenv("NDS4MISTER_CART_POLL_COLLAPSE")) {
        if (std::strcmp(collapseText, "0") == 0) cartPollCollapse = false;
        else if (std::strcmp(collapseText, "1") != 0)
            throw std::runtime_error(
                "NDS4MISTER_CART_POLL_COLLAPSE must be 0 or 1");
    }
    // Let a halted peer CPU stop gating min(ARM9, ARM7). Stock melonDS jumps
    // a halted core straight to its target in ARMv5/ARMv4::Execute(), so this
    // restores standard behaviour the hybrid lost: the FPGA otherwise creeps a
    // halted ARM7 forward only one HALT_ADVANCE_CYCLES batch per
    // HALT_POLL_CLOCKS, throttling every shared LCD/audio/DMA event to that
    // cadence. Required for the VCOUNT collapse below to make any progress.
    bool haltedPeerAdvance = false;
    if (const char* haltText = std::getenv("NDS4MISTER_HALTED_PEER_ADVANCE")) {
        if (std::strcmp(haltText, "1") == 0) haltedPeerAdvance = true;
        else if (std::strcmp(haltText, "0") != 0)
            throw std::runtime_error(
                "NDS4MISTER_HALTED_PEER_ADVANCE must be 0 or 1");
    }
    backend.set_halted_peer_advance(haltedPeerAdvance);
    // VCOUNT ready-poll collapse. A 30000-transaction hardware trace showed
    // 25779 ARM9 reads of 0x04000006 against 4221 ARM7 HALTCNT writes: 86% of
    // steady-state mailbox traffic is this one register. Each poll advances
    // ARM9 ~28 cycles but costs a full round trip, so emulated time moves at
    // ~644k cycles/s against the DS's 33.51 MHz.
    //
    // Unlike the cartridge collapse this cannot advance only the issuing CPU:
    // VCOUNT is hardware-owned and moves on shared LCD events gated by
    // min(ARM9, ARM7). Step the whole system through its own scheduler
    // instead, which is what RunFrame() does normally.
    static constexpr std::uint32_t kVCount = 0x04000006u;
    static constexpr unsigned kVCountPollAttempts = 4096;
    bool vcountCollapse = false;
    if (const char* vcountText = std::getenv("NDS4MISTER_VCOUNT_COLLAPSE")) {
        if (std::strcmp(vcountText, "1") == 0) vcountCollapse = true;
        else if (std::strcmp(vcountText, "0") != 0)
            throw std::runtime_error(
                "NDS4MISTER_VCOUNT_COLLAPSE must be 0 or 1");
    }
    std::uint64_t vcountAdvances = 0;
    std::uint64_t vcountCollapsed = 0;
    // Geometry-FIFO backpressure.
    //
    // On real hardware a full GX FIFO stalls the ARM9: NDS::GXFIFOStall sets
    // CPUStop_GXStall and halts the CPU. In hybrid mode melonDS halts its OWN
    // ARM9, which never executes, while the FPGA's ARM9 keeps writing geometry
    // commands. The overflow lands in GPU3D's CmdStallQueue, which is only
    // FIFO<CmdFIFOEntry, 64>; past 64 entries commands are silently dropped and
    // the result is geometry with missing vertices -- stray polygons.
    //
    // The FPGA CPU is already blocked waiting for this mailbox response, so
    // simply not completing the transaction until the stall clears reproduces
    // the hardware backpressure exactly, with no RTL change. Bounded: if the
    // stall will not clear we fall back to the old lossy behaviour rather than
    // wedging the CPU forever.
    static constexpr unsigned kGxStallAttempts = 4096;
    bool gxStallBackpressure = false;
    if (const char* gxText = std::getenv("NDS4MISTER_GX_STALL_BACKPRESSURE")) {
        if (std::strcmp(gxText, "1") == 0) gxStallBackpressure = true;
        else if (std::strcmp(gxText, "0") != 0)
            throw std::runtime_error(
                "NDS4MISTER_GX_STALL_BACKPRESSURE must be 0 or 1");
    }
    std::uint64_t gxStallWaits = 0;
    std::uint64_t gxStallAdvances = 0;
    std::uint64_t gxStallTimeouts = 0;
    // WriteToGXFIFO is a stateful packed-command decoder. Both the FPGA ARM9
    // (through this mailbox) and HPS-run DMA feed it. If a CPU write lands
    // while a GXFIFO DMA is mid-transfer, the decoder desyncs and emits garbage
    // opcodes. Count those interleavings.
    static constexpr std::uint32_t kGxFifoLo = 0x04000400u;
    static constexpr std::uint32_t kGxFifoHi = 0x0400043fu;
    static constexpr std::uint32_t kGxPostedHi = 0x040005c8u;
    std::uint64_t gxWrites = 0;
    std::uint64_t gxWriteDuringDma = 0;
    std::uint64_t gxZeroWrites = 0;
    // A request whose address decoded to 0xffffffff is treated as timing-only
    // and never applied. If GX traffic is landing here, writes vanish silently.
    std::uint64_t timingOnlyWithPayload = 0;
    // GXFIFO is a 32-bit port. A write arriving with a different access size
    // would be handled by a different melonDS IO path and could be dropped or
    // half-applied, which is exactly the kind of loss that desyncs the packed
    // command decoder. Count writes by access size, and by CPU.
    std::uint64_t gxAccessHist[4] = {0,0,0,0};
    std::uint64_t gxWritesArm7 = 0;
    // Lockstep bus trace in the same JSONL contract melonDS emits, so
    // tools/compare_arm_traces.py can diff real hardware against the emulator
    // at any point in the run. The mailbox only ever carries external
    // accesses -- no instruction fetches and no TCM -- which removes the
    // classification ambiguity that dogs the Verilator bus trace.
    std::FILE* busJsonl = nullptr;
    std::uint64_t busJsonlSeq = 0;
    std::uint64_t busJsonlLimit = 200000;
    std::uint64_t busJsonlSkip = 0;
    if (const char* path = std::getenv("NDS4MISTER_BUS_JSONL")) {
        busJsonl = std::fopen(path, "w");
        if (const char* lim = std::getenv("NDS4MISTER_BUS_JSONL_LIMIT"))
            busJsonlLimit = std::strtoull(lim, nullptr, 0);
        if (const char* skp = std::getenv("NDS4MISTER_BUS_JSONL_SKIP"))
            busJsonlSkip = std::strtoull(skp, nullptr, 0);
    }
    std::uint64_t busJsonlSeen = 0;
    // Counting requests to reach a scene is unreliable: the rate varies by
    // phase, so a fixed skip either stops short or overshoots. Arm on the
    // first access to a trigger address instead -- for the GX corruption that
    // is the geometry aperture, which only sees traffic once 3D starts.
    std::uint32_t busJsonlTrigger = 0;
    bool busJsonlArmed = true;
    if (const char* trig = std::getenv("NDS4MISTER_BUS_JSONL_TRIGGER")) {
        busJsonlTrigger = static_cast<std::uint32_t>(
            std::strtoul(trig, nullptr, 0));
        busJsonlArmed = false;
    }
    bool busJsonlTriggerNonzeroArm9WordWrite = false;
    if (const char* strict = std::getenv(
            "NDS4MISTER_BUS_JSONL_TRIGGER_NONZERO_ARM9_WORD_WRITE")) {
        if (std::strcmp(strict, "1") != 0)
            throw std::runtime_error(
                "NDS4MISTER_BUS_JSONL_TRIGGER_NONZERO_ARM9_WORD_WRITE "
                "must be 1");
        if (!busJsonlTrigger)
            throw std::runtime_error(
                "strict bus JSONL trigger requires "
                "NDS4MISTER_BUS_JSONL_TRIGGER");
        busJsonlTriggerNonzeroArm9WordWrite = true;
    }
    // One serviced-operation interval between real nanosleeps, as a power of
    // two. A 50 us sleep_for costs ~1.1 ms on this kernel, so the default 8
    // (every 256 operations) parks ~40% of wall time in nanosleep — but
    // measured on hardware, raising this to 14 did NOT improve the frame
    // rate: the HPS simply spun more while the FPGA request rate stayed
    // flat, which says the bottleneck is not HPS CPU. Keep the original
    // cadence as the default and leave the knob for further experiments.
    std::uint64_t sleepMask = (1ull << 8) - 1ull;
    if (const char* shiftText = std::getenv("NDS4MISTER_SCHED_SLEEP_SHIFT")) {
        char* end = nullptr;
        const auto shift = std::strtoul(shiftText, &end, 0);
        if (end == shiftText || *end != '\0' || shift < 8 || shift > 24)
            throw std::runtime_error(
                "NDS4MISTER_SCHED_SLEEP_SHIFT must be 8..24");
        sleepMask = (1ull << shift) - 1ull;
    }
    std::uint64_t postedWrites = 0;
    std::uint64_t postedSinceInput = 0;
    HpsAudioPublicationSource hpsAudioSource(fpgaAudioOffload);
    std::uint64_t fpgaAudioVideoPublications = 0;
    auto reportFPGAAudioOffload = [&](const char* state) {
        if (!fpgaAudioOffload)
            return;
        const auto telemetry = backend.fpga_audio_offload_telemetry();
        std::cerr
            << "NDS4MISTER_FPGA_AUDIO_OFFLOAD_V1"
            << " state=" << state
            << " video_publications=" << fpgaAudioVideoPublications
            << " hps_audio_read_calls=" << hpsAudioSource.readCalls()
            << " hps_audio_read_frames=" << hpsAudioSource.readFrames()
            << " hps_audio_published_frames="
            << hpsAudioSource.publishedFrames()
            << " hps_audio_render_calls="
            << telemetry.hps_render_callbacks
            << " semantic_mix_callbacks=" << telemetry.mix_callbacks
            << " semantic_channel_advances="
            << telemetry.channel_advance_callbacks
            << " semantic_capture_advances="
            << telemetry.capture_advance_callbacks
            << "\n" << std::flush;
    };
    auto reportExternalTimeWindowProfile = [&](const char* state) {
        if (!externalTimeWindow)
            return;
        const auto profile = backend.external_time_window_profile();
        std::cerr
            << "NDS4MISTER_ETW_PROFILE_V1"
            << " state=" << state
            << " closures=" << profile.closure_count
            << " finite_bound=" << profile.finite_bound_limited_count
            << " no_event=" << profile.no_event_count;
        for (std::size_t i = 0; i < profile.event_count; ++i) {
            if (profile.limiting_event_count[i] == 0)
                continue;
            std::cerr
                << " event_" << i << "_count="
                << profile.limiting_event_count[i]
                << " event_" << i << "_cycles="
                << profile.granted_cycles[i];
        }
        std::cerr << "\n" << std::flush;
    };
    auto nextExternalTimeWindowProfileReport =
        std::chrono::steady_clock::now() + std::chrono::seconds(10);
    // A fenced mailbox request may drain posted writes, whose scheduling
    // points must not reset profiler counters halfway through that request.
    bool mailboxActive = false;
    auto nextFrameDeadline = std::chrono::steady_clock::time_point{};
    const auto framePeriod = std::chrono::nanoseconds(16715200);
    auto paceFrame = [&] {
        if (!paceFrames) return;
        const auto now = std::chrono::steady_clock::now();
        if (nextFrameDeadline == std::chrono::steady_clock::time_point{} ||
            now > nextFrameDeadline + framePeriod) {
            nextFrameDeadline = now;
        } else if (now < nextFrameDeadline) {
            std::this_thread::sleep_until(nextFrameDeadline);
        }
        nextFrameDeadline += framePeriod;
    };
    auto serviceInput = [&] {
        const bool sample = profiler.beginInput();
        const auto started = sample ? profiler.timestampNanoseconds() : 0;
        const std::uint64_t publishedInput = *inputWord;
        lastPublishedInput = publishedInput;
        const std::uint32_t keys = inputSource.select(
            publishedInput, [&] { return localInput.poll(); });
        if (keys != activeKeys) {
            backend.set_key_mask(keys);
            std::cout << "input mask=0x" << std::hex << keys << std::dec
                      << "\n" << std::flush;
            activeKeys = keys;
            ++inputSelectionEpoch;
            if (traceKeyInput) {
                std::cerr
                    << "NDS4MISTER_INPUT_SELECT_V1"
                    << " epoch=" << inputSelectionEpoch
                    << " raw_ndsj=0x" << std::hex << lastPublishedInput
                    << " selected_mask=0x" << activeKeys
                    << std::dec << "\n" << std::flush;
            }
        }
        if (sample)
            profiler.finishInput(
                profiler.timestampNanoseconds() - started);
    };
    auto publishReady = [&] {
        // A line-191 sink proves all visible lines arrived, but local-LCD mode
        // publishes only after the matching coherent frame-wrap descriptor.
        if (localLcd && !localLcdConsumer->completedFrameReady())
            return;
        if (layerPublication && layerCapture.frameReady) {
            const auto started = profiler.enabled()
                ? profiler.timestampNanoseconds() : 0;
            const int frames = hpsAudioSource.read([&] {
                return backend.read_audio(sourceAudio.data(), 1024);
            });
            const auto audioRead = profiler.enabled()
                ? profiler.timestampNanoseconds() : 0;
            const auto publishedFrames = fpgaAudioOffload ? 0u
                : paceFrames && frames > 0
                ? pacedAudio.normalize(sourceAudio.data(),
                      static_cast<std::uint32_t>(frames),
                      publishedAudio.data())
                : (frames > 0 ? static_cast<std::uint32_t>(frames) : 0u);
            const auto* audio = paceFrames ? publishedAudio.data()
                                           : sourceAudio.data();
            const auto normalized = profiler.enabled()
                ? profiler.timestampNanoseconds() : 0;
            paceFrame();
            const auto paced = profiler.enabled()
                ? profiler.timestampNanoseconds() : 0;
            publisher.publish(layerCapture, audio, publishedFrames);
            const auto finished = profiler.enabled()
                ? profiler.timestampNanoseconds() : 0;
            hpsAudioSource.recordPublished(publishedFrames);
            if (fpgaAudioOffload) {
                ++fpgaAudioVideoPublications;
                if (fpgaAudioVideoPublications == 1 ||
                    (fpgaAudioVideoPublications & 0xffu) == 0) {
                    reportFPGAAudioOffload("active");
                    reportExternalTimeWindowProfile("active");
                }
            }
            if (profiler.enabled())
                profiler.recordPublication(
                    publishedFrames, audioRead - started,
                    normalized - audioRead, paced - normalized,
                    finished - paced);
            layerCapture.frameReady = false;
            layerCapture.recordIndex ^= 1u;
            if (localLcd)
                localLcdConsumer->retireCompletedFrame();
        } else if (!layerPublication && capture.frameReady) {
            const auto started = profiler.enabled()
                ? profiler.timestampNanoseconds() : 0;
            const int frames = hpsAudioSource.read([&] {
                return backend.read_audio(sourceAudio.data(), 1024);
            });
            const auto audioRead = profiler.enabled()
                ? profiler.timestampNanoseconds() : 0;
            const auto publishedFrames = fpgaAudioOffload ? 0u
                : paceFrames && frames > 0
                ? pacedAudio.normalize(sourceAudio.data(),
                      static_cast<std::uint32_t>(frames),
                      publishedAudio.data())
                : (frames > 0 ? static_cast<std::uint32_t>(frames) : 0u);
            const auto* audio = paceFrames ? publishedAudio.data()
                                           : sourceAudio.data();
            const auto normalized = profiler.enabled()
                ? profiler.timestampNanoseconds() : 0;
            paceFrame();
            const auto paced = profiler.enabled()
                ? profiler.timestampNanoseconds() : 0;
            publisher.publish(capture, audio, publishedFrames);
            const auto finished = profiler.enabled()
                ? profiler.timestampNanoseconds() : 0;
            hpsAudioSource.recordPublished(publishedFrames);
            if (fpgaAudioOffload) {
                ++fpgaAudioVideoPublications;
                if (fpgaAudioVideoPublications == 1 ||
                    (fpgaAudioVideoPublications & 0xffu) == 0) {
                    reportFPGAAudioOffload("active");
                    reportExternalTimeWindowProfile("active");
                }
            }
            if (profiler.enabled())
                profiler.recordPublication(
                    publishedFrames, audioRead - started,
                    normalized - audioRead, paced - normalized,
                    finished - paced);
            capture.frameReady = false;
            if (localLcd)
                localLcdConsumer->retireCompletedFrame();
        }
    };
    auto schedulingPoint = [&] {
        // Keep sshd, input, and audio service responsive even if the ring and
        // mailbox keep both HPS cores continuously busy.
        //
        // A 50 us sleep_for costs about 1.1 ms of wall time on this kernel,
        // so asking for one every 256 serviced operations spent roughly 40%
        // of the run parked in nanosleep. Yield at the frequent interval,
        // which costs nothing when nothing else is runnable, and keep a real
        // sleep at a much coarser interval as a forward-progress guarantee.
        ++servicedOperations;
        if (localLcd && (servicedOperations & 0xffu) == 0)
            serviceInput();
        if ((servicedOperations & sleepMask) == 0) {
            const auto started = profiler.enabled()
                ? profiler.timestampNanoseconds() : 0;
            std::this_thread::sleep_for(std::chrono::microseconds(50));
            if (profiler.enabled())
                profiler.recordSchedulerSleep(
                    profiler.timestampNanoseconds() - started);
        } else if ((servicedOperations & 0xffu) == 0) {
            sched_yield();
        }
        if ((servicedOperations & 0xfffu) == 0 && !mailboxActive)
            profiler.maybeReport(
                postedRing.consumerSequence(), completed,
                publisher.published());
        if (externalTimeWindow && !mailboxActive &&
            std::chrono::steady_clock::now() >=
                nextExternalTimeWindowProfileReport) {
            reportExternalTimeWindowProfile("periodic");
            nextExternalTimeWindowProfileReport =
                std::chrono::steady_clock::now() +
                std::chrono::seconds(10);
        }
    };
    auto drainGxStall = [&] {
        if (!gxStallBackpressure || !backend.gx_fifo_stalled()) return;
        ++gxStallWaits;
        unsigned attempt = 0;
        std::uint64_t previous = 0;
        for (; attempt < kGxStallAttempts; ++attempt) {
            const auto reached = backend.advance_system_to_next_event(0);
            ++gxStallAdvances;
            if (!backend.gx_fifo_stalled()) break;
            if (attempt != 0 && reached == previous) break;
            previous = reached;
        }
        if (attempt >= kGxStallAttempts || backend.gx_fifo_stalled())
            ++gxStallTimeouts;
    };
    auto applyPostedWrite = [&](const PostedWriteEntry& entry) {
        if (externalTimeWindow)
            throw std::runtime_error(
                "first external time-window experiment forbids every "
                "legacy posted-write entry");
        if (entry.externalArm9If) {
            if (!externalTimeWindow || !externalTimeWindowProducer)
                throw std::runtime_error(
                    "external ARM9 IF posted entry reached a disabled "
                    "time-window path");

            // This exact tagged operation reports the FPGA CPU's absolute
            // progress and mirrors its already-committed local IF W1C. It
            // must never execute the legacy per-entry cycle advance below.
            // Startup remains rejected until a proved finite-bound closure
            // cadence can publish the resulting P/R group atomically.
            applyExternalArm9IfPostedEntry(
                entry,
                [&](std::uint64_t target, std::string& applyError) {
                    return backend.report_external_time_window_cpu_reached(
                        true, target, applyError);
                },
                [&](std::uint32_t sourceSequence,
                    std::uint64_t target,
                    std::uint32_t address,
                    std::uint32_t access,
                    std::uint32_t writeData,
                    std::uint32_t expectedFinalIF,
                    bool expectedGXFIFO,
                    nds4mister::ExternalARM9IFW1CResult& result,
                    std::string& applyError) {
                    return backend.apply_external_arm9_if_w1c(
                        sourceSequence, target, address, access,
                        writeData, expectedFinalIF, expectedGXFIFO,
                        result, applyError);
                });
            ++postedWrites;
            return;
        }

        const bool arm9 = (entry.control & 8u) != 0;
        const unsigned access = (entry.control >> 1) & 3u;
        const bool postedGx = arm9 && access == 2u &&
            (entry.address & 3u) == 0 &&
            entry.address >= kGxFifoLo && entry.address <= kGxPostedHi;
        const bool sample = profiler.beginPosted(entry.cycles);
        const auto started = sample ? profiler.timestampNanoseconds() : 0;
        std::uint64_t advanced = 0;
        const auto advance = [&] {
            backend.advance_external_cycles(arm9, entry.cycles);
            advanced = sample ? profiler.timestampNanoseconds() : 0;
        };
        const auto apply = [&] {
            const bool writeOk = postedGx
                ? applyPostedGxWriteInOrder(
                    [&] { return backend.complete_external_dma(true); },
                    [&] {
                        return backend.bus_write(
                            arm9, access, entry.address, entry.data);
                    },
                    drainGxStall)
                : backend.bus_write(
                    arm9, access, entry.address, entry.data);
            if (!writeOk)
                throw std::runtime_error(
                    postedGx
                        ? "posted GX DMA/stall completion failed"
                        : "invalid posted-write transaction");
            const auto busFinished = sample
                ? profiler.timestampNanoseconds() : 0;
            ++postedWrites;
            publishReady();
            const auto publishChecked = sample
                ? profiler.timestampNanoseconds() : 0;
            if (sample)
                profiler.finishPosted(
                    advanced - started, busFinished - advanced,
                    publishChecked - busFinished);
            if ((++postedSinceInput & 0x3fu) == 0) serviceInput();
            schedulingPoint();
            return 0u;
        };
        if (!timeIrqReverse) {
            advance();
            apply();
            return;
        }

        CountedTransactionBoundary boundary{
            {arm9, entry.cycles,
             nds4mister::ConsumedCreditAckKind::Posted,
             entry.sequence},
            0,
            {}};
        (void)publishCountedTransactionWithRetry(
            *reverseProducer, boundary, advance, apply,
            [&] { return takeIrqSetMasks(backend); },
            [&](nds4mister::ConsumedCreditAckPublishResult) {
                requireOwnedLwSession(
                    words, lwSessionCookie, lwExpectedCapabilities);
                const auto before = reverseFrontier;
                for (unsigned spin = 0; spin < 4096; ++spin) {
                    const auto frontier =
                        words[kLwRegReverseConsumer];
                    validateReverseFrontier(
                        frontier, reverseFrontier, *reverseProducer);
                    if (frontier != before) return true;
                }
                sched_yield();
                return true;
            });
    };
    auto publishLwConsumerAck = [&] {
        if (!lwMailbox) return;
        const std::uint32_t consumed = postedRing.consumerSequence();
        if (consumed == lastLwConsumerAck) return;
        publishAdvancedLwConsumerAck(
            words, consumed, lastLwConsumerAck,
            lwSessionCookie, lwExpectedCapabilities);
    };
    if (externalTimeWindow) {
        drainExternalTimeWindowFence = [&, lwSessionCookie](
            std::uint64_t requestedFence,
            std::uint64_t& stableFence,
            std::string& callbackError) {
            try {
                stableFence = 0;
                std::uint32_t requestedRaw = 0;
                if (!nds4mister::ExternalTimeWindowRuntime::
                        decodeEpochScopedFence(
                            requestedFence, lwSessionCookie,
                            requestedRaw)) {
                    callbackError =
                        "freeze snapshot carried a foreign posted epoch";
                    return false;
                }
                // Posting is intentionally disabled in the first ETW build.
                // Never feed a legacy posted entry through
                // advance_external_cycles(), which is illegal while the
                // backend's external scheduler observer is active. Two
                // ownership-bracketed samples prove that no entry raced the
                // freeze before its ACK is committed.
                requireOwnedLwSession(
                    words, lwSessionCookie, lwExpectedCapabilities);
                const std::uint32_t producer1 = words[kLwRegProducer];
                const std::uint32_t consumer1 = words[kLwRegConsumer];
                __sync_synchronize();
                requireOwnedLwSession(
                    words, lwSessionCookie, lwExpectedCapabilities);
                const std::uint32_t producer2 = words[kLwRegProducer];
                const std::uint32_t consumer2 = words[kLwRegConsumer];
                if (producer1 != producer2 || consumer1 != consumer2 ||
                    !externalTimeWindowPostedStateIsZero(
                        requestedRaw, producer2, consumer2,
                        postedRing.consumerSequence(),
                        lastLwConsumerAck)) {
                    callbackError =
                        "first ETW build observed forbidden posted-write "
                        "producer/consumer activity";
                    return false;
                }
                stableFence =
                    static_cast<std::uint64_t>(lwSessionCookie) << 32;
                return true;
            } catch (const std::exception& exception) {
                callbackError = exception.what();
                return false;
            } catch (...) {
                callbackError =
                    "freeze posted-fence drain threw an exception";
                return false;
            }
        };
    }
    struct RequestTrace {
        std::uint32_t generation, address, payload, control, cycles;
    };
    std::array<RequestTrace, 256> requestFlightRecorder{};
    std::size_t requestFlightNext = 0, requestFlightCount = 0;
    std::array<bool, 7> arm7IpcArgumentSeen{};
    std::array<std::uint32_t, 7> arm7IpcArgumentValue{};
    unsigned arm7IpcArgumentCount = 0;
    bool arm7IpcTargetReported = false;
    nds4mister::Arm7SoundMmioTraceState arm7SoundTrace(
        traceArm7SoundWrites);
    std::array<bool, 3> arm7WorkerCorruptionSeen{};
    std::array<std::uint32_t, 3> arm7WorkerCorruptionValue{};
    unsigned arm7WorkerCorruptionCount = 0;
    std::cout << "HPS oracle mailbox physical=0x" << std::hex << physical
              << " boot_descriptor=0x"
              << nds4mister::kStandaloneBootDescriptorPhysical
              << " arm9_entry=0x" << descriptor.arm9_entry
              << " arm7_entry=0x" << descriptor.arm7_entry << std::dec
              << " main_ram_crc32=" << mappedRamCrc
              << " arm9_trace_trigger=0x" << std::hex
              << descriptor.arm9_trace_trigger << std::dec
              << " posted_ring=0x" << std::hex
              << nds4mister::kPostedWriteRingPhysical << std::dec
              << " gx_posted=" << (gxPostedWrites ? "enabled" : "disabled")
              << " publication=" << (layerPublication ? "fpga-layers" : "compact")
              << " descriptor_generation=" << descriptorGeneration
              << " sound_epoch="
              << (soundEpochPath.empty() ? "disabled" : "persistent")
              << " fpga_audio_offload="
              << (fpgaAudioOffload ? "enabled" : "disabled")
              << " etw_capacity16_experiment="
              << (externalTimeWindowCapacityExperiment
                      ? "enabled" : "disabled")
              << " offline_fast_beta="
              << (offlineFastBeta ? "enabled" : "disabled")
              << " etw_max_group_events="
              << externalTimeWindowLoggedMaxEvents
              << " initial_generation=" << completed << "\n" << std::flush;
    if (arm7SoundTrace.enabled()) {
        std::cerr
            << "NDS4MISTER_ARM7_SOUND_WRITE_TRACE_BEGIN_V1"
            << " limit=" << arm7SoundTrace.remaining()
            << " range=0x04000400..0x0400051f\n"
            << std::flush;
    }
    while (running) {
        profiler.noteLoop();
        if (localLcd) {
            requireOwnedLwSession(
                words, lwSessionCookie, lwExpectedCapabilities);
            std::size_t lcdDrained = 0;
            if (!localLcdConsumer->poll(
                    kLcdDrainBatch, UINT64_MAX, lcdDrained, error))
                throw std::runtime_error(
                    "local LCD queue failed: " + error);
            if (lcdDrained != 0) {
                publishReady();
                schedulingPoint();
                continue;
            }
        }
        if (externalTimeWindow) {
            // ETW1 has its own level state and (eventually) a dedicated HPS
            // interrupt. Do not fold it into the legacy doorbell IRQ: that
            // doorbell's irqLevel/anyWork coherence knows only bits 1..4.
            (void)words[27];
            if (!externalTimeWindowPostedStateIsZero(
                    0, words[kLwRegProducer], words[kLwRegConsumer],
                    postedRing.consumerSequence(), lastLwConsumerAck))
                throw std::runtime_error(
                    "first external time-window experiment observed "
                    "forbidden posted-write state");
            // Poll even while the wire state is IDLE. The runtime needs that
            // exact intervening observation to retire a published completion
            // before the next blocking transaction freezes.
            const auto etwResult = externalTimeWindowRuntime->poll(error);
            const auto observedMax =
                externalTimeWindowRuntime->maxObservedGroupEventCount();
            if (observedMax > externalTimeWindowLoggedMaxEvents) {
                externalTimeWindowLoggedMaxEvents = observedMax;
                std::cerr
                    << "NDS4MISTER_ETW_CAPACITY16_V1 max_group_events="
                    << observedMax << " capacity="
                    << nds4mister::ExternalTimeWindowDdrProducer::kMaxEvents
                    << "\n" << std::flush;
            }
            if (etwResult ==
                nds4mister::ExternalTimeWindowRuntimePollResult::Fault) {
                // ETW faults are sticky until the core is reset, so capture
                // the complete immutable lightweight snapshot before the
                // deployment supervisor returns through menu.rbf.  In
                // particular STATUS[31:12] carries the passive stop-owner
                // predicate bitmap used to distinguish a peer-bus drain
                // failure from a later horizon/seam fault.  This diagnostic
                // is HPS-only and does not alter the FPGA transaction.
                std::cerr
                    << "NDS4MISTER_ETW_FAULT_SNAPSHOT_V1"
                    << " status=0x" << std::hex << words[27]
                    << " generation=0x" << words[28]
                    << " control_generation=0x" << words[29]
                    << " abi=0x" << words[31]
                    << " epoch=0x" << words[32]
                    << " group=0x" << words[33]
                    << " processed_lo=0x" << words[34]
                    << " processed_hi=0x" << words[35]
                    << " run_safe_lo=0x" << words[36]
                    << " run_safe_hi=0x" << words[37]
                    << " barrier=0x" << words[39]
                    << " source=0x" << words[40]
                    << " meta=0x" << words[43]
                    << " address=0x" << words[44]
                    << " write_data=0x" << words[45]
                    << " execution_pc=0x" << words[46]
                    << " arm9_time_lo=0x" << words[47]
                    << " arm9_time_hi=0x" << words[48]
                    << " arm7_time_lo=0x" << words[49]
                    << " arm7_time_hi=0x" << words[50]
                    << " required_lo=0x" << words[51]
                    << " required_hi=0x" << words[52]
                    << " completion_data=0x" << words[53]
                    << " completion_epoch=0x" << words[54]
                    << " completion_group=0x" << words[55]
                    << " completion_barrier=0x" << words[56]
                    << " completion_source=0x" << words[57]
                    << " completion_fence_lo=0x" << words[58]
                    << " completion_fence_hi=0x" << words[59]
                    << " completion_flags=0x" << words[60]
                    << " completion_generation=0x" << words[61]
                    << " completion_commit=0x" << words[62]
                    << std::dec << "\n" << std::flush;
                throw std::runtime_error(
                    "external time-window runtime failed: " + error);
            }
            if (etwResult !=
                nds4mister::ExternalTimeWindowRuntimePollResult::Idle) {
                if (etwResult ==
                    nds4mister::ExternalTimeWindowRuntimePollResult::
                        Progress) {
                    publishReady();
                    schedulingPoint();
                } else if ((++spins & 0xfffu) == 0) {
                    sched_yield();
                }
                continue;
            }
        }
        std::uint32_t magic = kMagic;
        std::uint32_t generation = completed;
        bool serviceMailbox = false;
        bool lwPostedPending = false;
        if (lwMailbox) {
            // One doorbell read is the polling fallback until the kernel IRQ
            // waiter is installed. It reports blocking and posted work plus
            // sticky faults and session reset in one coherent fabric word.
            const std::uint32_t doorbell = words[kLwRegDoorbell];
            const bool irqLevel = (doorbell & kLwDoorbellIrq) != 0;
            const bool anyWork =
                (doorbell & (kLwDoorbellError |
                             kLwDoorbellMailbox |
                             kLwDoorbellPosted |
                             kLwDoorbellSessionRequired)) != 0;
            if (irqLevel != anyWork)
                throw std::runtime_error(
                    "LW doorbell IRQ/status coherence failure");
            if ((doorbell & kLwDoorbellError) != 0)
                throw std::runtime_error("LW transport reported protocol fault");
            if ((doorbell & kLwDoorbellSessionRequired) != 0) {
                const std::uint32_t observedSession = words[kLwRegSession];
                if (observedSession == 0)
                    throw std::runtime_error(
                        "LW transport reset; fresh responder/core reload required");
                throw std::runtime_error(
                    "LW transport lost session-ready state");
            }
            lwPostedPending =
                (doorbell & kLwDoorbellPosted) != 0;
            if (externalTimeWindow && lwPostedPending)
                throw std::runtime_error(
                    "first external time-window experiment received a "
                    "forbidden posted-write doorbell");
            if ((doorbell & kLwDoorbellMailbox) != 0) {
                const std::uint32_t status = words[kLwRegStatus];
                const auto decision = classifyLwMailboxStatus(
                    status, completed, lwResponsePublished, true);
                if (decision == LwMailboxDecision::Fault)
                    throw std::runtime_error(
                        "LW mailbox sequence/pending protocol fault");
                if (decision == LwMailboxDecision::Service) {
                    generation = status >> 1;
                    serviceMailbox = true;
                }
            } else {
                // Observing the level low proves the previous response was
                // released. A later request may advance immediately without
                // requiring us to observe an interrupt edge.
                lwResponsePublished = false;
            }
        } else {
            magic = words[0];
            generation = words[1];
            serviceMailbox = magic == kMagic && generation != completed;
        }
        if (!serviceMailbox) {
            std::size_t drained = 0;
            if (!lwMailbox) {
                drained = postedRing.drainAvailable(256, applyPostedWrite);
            } else if (lwPostedPending) {
                requireOwnedLwSession(
                    words, lwSessionCookie, lwExpectedCapabilities);
                // A DDR commit can become visible to HPS one fabric clock
                // before posted_done advertises it through the LW doorbell.
                // Never consume that unadvertised next entry: snapshot the
                // producer and drain only through that exact ordering point.
                const std::uint32_t advertised = words[kLwRegProducer];
                const std::uint32_t consumed =
                    postedRing.consumerSequence();
                if (!postedDrainWithinAdvertisedFrontier(
                        advertised, consumed, advertised))
                    throw std::runtime_error(
                        "LW advertised producer is outside ring window");
                drained = postedRing.drainTo(
                    advertised, applyPostedWrite);
            }
            profiler.noteIdleDrain(drained);
            if (drained != 0) {
                publishLwConsumerAck();
                continue;
            }
            if ((++spins & 0xfffu) == 0) {
                // With global SetIRQ capture enabled, input is serviced only
                // inside the next counted posted/mailbox transaction so no
                // IRQ cause can leak outside a PRE/apply/POST group.
                if (!timeIrqReverse) serviceInput();
                const bool sampleYield = profiler.beginIdleYield();
                const auto yieldStarted = sampleYield
                    ? profiler.timestampNanoseconds() : 0;
                sched_yield();
                if (sampleYield)
                    profiler.finishIdleYield(
                        profiler.timestampNanoseconds() - yieldStarted);
                profiler.maybeReport(
                    postedRing.consumerSequence(), completed,
                    publisher.published());
            }
            continue;
        }
        __sync_synchronize();
        std::uint32_t address, writeData, control, elapsedCycles;
        std::uint32_t fenceSequence, fenceEpoch;
        if (lwMailbox) {
            address = words[kLwRegAddress];
            writeData = words[kLwRegWData];
            control = words[kLwRegControl];
            elapsedCycles = words[kLwRegCycles];
            fenceSequence = words[kLwRegFence];
            fenceEpoch = words[kLwRegFenceEpoch];
        } else {
            address = words[2];
            writeData = words[3];
            control = words[4];
            elapsedCycles = words[5];
            fenceSequence = words[9];
            fenceEpoch = 0;
        }
        __sync_synchronize();
        // The DDR mailbox is written by a burst the FPGA can be midway
        // through, so re-check the generation. The bridge registers only
        // change while the CPU is released, so there is nothing to re-check.
        if (!lwMailbox && words[1] != generation) continue;

        mailboxActive = true;
        if (lwMailbox)
            requireOwnedLwSession(
                words, lwSessionCookie, lwExpectedCapabilities);
        if (lwMailbox && fenceEpoch != lwSessionCookie)
            throw std::runtime_error(
                "LW mailbox fence epoch does not match owned session");
        const bool sampleMailbox =
            profiler.beginMailbox(address, control, elapsedCycles);
        const auto mailboxStarted = sampleMailbox
            ? profiler.timestampNanoseconds() : 0;
        // This is the ordering boundary: no I/O, timing, IRQ response, or
        // read result may overtake a locally completed FPGA VRAM write.
        if (lwMailbox) {
            const auto advertised = words[kLwRegProducer];
            const auto consumed = postedRing.consumerSequence();
            if (!postedDrainWithinAdvertisedFrontier(
                    advertised, consumed, fenceSequence))
                throw std::runtime_error(
                    "LW mailbox fence exceeds verified posted frontier");
        }
        postedRing.drainTo(fenceSequence, applyPostedWrite);
        publishLwConsumerAck();
        const auto mailboxFenceFinished = sampleMailbox
            ? profiler.timestampNanoseconds() : 0;
        const bool readNotWrite = (control & 1u) != 0;
        const unsigned access = (control >> 1) & 3u;
        const bool arm9 = (control & 8u) != 0;
        const bool timingOnly = address == 0xffffffffu;
        // The FPGA publication word cannot change the result of unrelated
        // MMIO. Read it once per short mailbox burst, while keeping actual
        // KEYINPUT/EXTKEYIN reads synchronous. This isolates the safe part of
        // the old lean-mailbox experiment: scheduler calls remain unchanged.
        const unsigned mailboxInputPeriod = leanMailbox
            ? MailboxInputPacer::kLeanPeriod
            : MailboxInputPacer::kDefaultPeriod;
        const bool serviceMailboxInput = mailboxInputPacer.shouldService(
            address, access, readNotWrite, mailboxInputPeriod);
        if (serviceMailboxInput && !timeIrqReverse)
            serviceInput();
        std::uint64_t mailboxInputFinished = sampleMailbox
            ? profiler.timestampNanoseconds() : 0;

        if (timingOnly && writeData != 0 && !readNotWrite)
            ++timingOnlyWithPayload;
        const std::uint32_t executionPc = decodeExecutionPc(
            writeData, readNotWrite, pcXorTelemetry, arm9);
        reportWatchedMainRam(
            "between_requests", generation, arm9, executionPc, address);
        if (traceArm7IpcArguments && timingOnly && !arm9) {
            const auto telemetryTag = writeData >> 24;
            if (telemetryTag >= 0xd5u && telemetryTag <= 0xdbu) {
                const auto index = telemetryTag - 0xd5u;
                arm7IpcArgumentValue[index] = writeData & 0x00ffffffu;
                if (!arm7IpcArgumentSeen[index]) {
                    arm7IpcArgumentSeen[index] = true;
                    ++arm7IpcArgumentCount;
                    std::cerr << "arm7_ipc_argument generation=0x"
                              << std::hex << generation
                              << " tag=0x" << telemetryTag
                              << " value=0x"
                              << (writeData & 0x00ffffffu)
                              << " control=0x" << control
                              << " cycles=0x" << elapsedCycles << std::dec
                              << "\n" << std::flush;
                    if (arm7IpcArgumentCount == arm7IpcArgumentSeen.size())
                        std::cerr << "arm7_ipc_arguments_complete\n"
                                  << std::flush;
                }
                if (!arm7IpcTargetReported &&
                    arm7IpcArgumentValue[4] == 0x003ffff4u &&
                    std::all_of(arm7IpcArgumentSeen.begin(),
                                arm7IpcArgumentSeen.end(),
                                [](bool seen) { return seen; })) {
                    const auto arg1 = arm7IpcArgumentValue[1] |
                        (arm7IpcArgumentValue[5] << 24);
                    std::cerr << "arm7_ipc_target"
                              << " arg0=0x" << std::hex
                              << arm7IpcArgumentValue[0]
                              << " arg1=0x" << arg1
                              << " arg2=0x" << arm7IpcArgumentValue[2]
                              << " sp_low24=0x" << arm7IpcArgumentValue[3]
                              << " output=0x" << arm7IpcArgumentValue[4]
                              << " lr_low24=0x" << arm7IpcArgumentValue[6]
                              << " generation=0x" << generation
                              << std::dec << "\n" << std::flush;
                    arm7IpcTargetReported = true;
                }
            }
            if (telemetryTag >= 0xdcu && telemetryTag <= 0xdeu) {
                const auto index = telemetryTag - 0xdcu;
                arm7WorkerCorruptionValue[index] =
                    writeData & 0x00ffffffu;
                if (!arm7WorkerCorruptionSeen[index]) {
                    arm7WorkerCorruptionSeen[index] = true;
                    ++arm7WorkerCorruptionCount;
                    std::cerr << "arm7_worker_corruption generation=0x"
                              << std::hex << generation
                              << " tag=0x" << telemetryTag
                              << " value=0x"
                              << arm7WorkerCorruptionValue[index]
                              << std::dec << "\n" << std::flush;
                    if (arm7WorkerCorruptionCount ==
                        arm7WorkerCorruptionSeen.size()) {
                        std::cerr << "arm7_worker_corruption_complete"
                                  << " pc_low24=0x" << std::hex
                                  << arm7WorkerCorruptionValue[0]
                                  << " r10_low24=0x"
                                  << arm7WorkerCorruptionValue[1]
                                  << " r11_low24=0x"
                                  << arm7WorkerCorruptionValue[2]
                                  << std::dec << "\n" << std::flush;
                    }
                }
            }
        }
        if (traceExceptionReturn && arm9) {
            const auto telemetryTag = writeData >> 28;
            const auto telemetryValue = writeData & 0x0fffffffu;
            if (!exceptionReturnActive &&
                (telemetryTag == 0x1u || telemetryTag == 0xcu) &&
                (telemetryValue & 0xfffff000u) == 0x0207c000u) {
                exceptionReturnActive = true;
                std::cerr << "exception_return_begin generation=0x"
                          << std::hex << generation
                          << " tag=0x" << telemetryTag
                          << " value=0x" << telemetryValue << "\n";
            }
            if (exceptionReturnActive) {
                std::cerr << "exception_return generation=0x" << std::hex
                          << generation << " tag=0x" << telemetryTag
                          << " value=0x" << telemetryValue
                          << " address=0x" << address
                          << " control=0x" << control
                          << " cycles=0x" << elapsedCycles << "\n";
                if (++exceptionReturnSamples == 256u) {
                    std::cerr << "exception_return_end samples=256\n"
                              << std::flush;
                    traceExceptionReturn = false;
                }
            }
        }
        // Timing-only heartbeats carry the selected FPGA CPU's live PC in
        // writeData. Record them too: once execution is fully local they are
        // the only nonintrusive way to capture the path into a bad branch.
        if (traceBadPc) {
            requestFlightRecorder[requestFlightNext] =
                {generation, address, executionPc, control, elapsedCycles};
            requestFlightNext =
                (requestFlightNext + 1u) % requestFlightRecorder.size();
            requestFlightCount =
                std::min(requestFlightCount + 1u, requestFlightRecorder.size());
            const auto pcRegion = executionPc >> 24;
            const bool validArm7Pc =
                executionPc < 0x00004000u || pcRegion == 2u ||
                pcRegion == 3u ||
                (executionPc & 0xffff0000u) == 0xffff0000u;
            const bool validPc = !readNotWrite ||
                (arm9 ? (pcRegion == 0u || pcRegion == 2u ||
                         pcRegion == 3u ||
                         (executionPc & 0xffff0000u) == 0x01ff0000u ||
                         (executionPc & 0xffff0000u) == 0xffff0000u)
                      : validArm7Pc);
            // DS RAM, VRAM, cartridge, and I/O accesses are all below
            // 0x10000000. ARM9 high BIOS is the one legitimate upper
            // aperture. Trigger the same bounded flight recorder on any
            // other upper address so a valid-looking PC that launches a
            // corrupt access still preserves its immediate predecessor path.
            const bool invalidExternalAddress =
                !timingOnly && address >= 0x10000000u &&
                address < 0xffff0000u;
            if (shouldTriggerBadPc(
                    timingOnly, validPc, invalidExternalAddress,
                    traceBadAddressOnly)) {
                std::cerr << "BAD_PC_OR_ADDRESS reason="
                          << ((!traceBadAddressOnly && !timingOnly &&
                               !validPc) ? "pc" : "address")
                          << " flight_recorder entries="
                          << requestFlightCount << "\n";
                const auto first =
                    (requestFlightNext + requestFlightRecorder.size() -
                     requestFlightCount) % requestFlightRecorder.size();
                for (std::size_t index = 0; index < requestFlightCount;
                     ++index) {
                    const auto& entry = requestFlightRecorder[
                        (first + index) % requestFlightRecorder.size()];
                    std::cerr << "flight generation=0x" << std::hex
                              << entry.generation
                              << " address=0x" << entry.address
                              << ((entry.control & 1u) ? " read_pc=0x"
                                                       : " write_data=0x")
                              << entry.payload << " control=0x"
                              << entry.control << " cycles=0x" << entry.cycles
                              << std::dec << "\n";
                }
                traceBadPc = false;
            }
        }
        const bool traceEligible = traceSkipRequests == 0;
        if (traceSkipRequests != 0) --traceSkipRequests;
        const bool traceThisRequest = traceEligible &&
            (traceRequests != 0 ||
             (traceNonTiming != 0 && !timingOnly));
        if (traceThisRequest) {
            std::cerr << "request generation=0x" << std::hex << generation
                      << " cpu=" << (arm9 ? 9 : 7)
                      << " address=0x" << address
                      << (readNotWrite ? " read_pc=0x" : " write_data=0x")
                      << executionPc;
            if (readNotWrite && pcXorTelemetry) {
                std::cerr << " encoded_pc=0x" << writeData;
            }
            std::cerr << " control=0x" << control
                      << " cycles=0x" << elapsedCycles << std::dec << "\n";
            if (traceRequests != 0) --traceRequests;
            else --traceNonTiming;
        }
        std::uint64_t mailboxAdvanceStarted = 0;
        std::uint64_t mailboxAdvanceFinished = 0;
        std::uint64_t sharedTimestamp = lastSharedTimestamp;
        const auto advanceMailbox = [&] {
            if (timeIrqReverse && serviceMailboxInput) {
                serviceInput();
                mailboxInputFinished = sampleMailbox
                    ? profiler.timestampNanoseconds() : 0;
            }
            mailboxAdvanceStarted = sampleMailbox
                ? profiler.timestampNanoseconds() : 0;
            // A zero-cycle request moves emulated time by nothing, so the
            // scheduler call is pure overhead (~10 us measured).
            if (!(leanMailbox && elapsedCycles == 0))
                lastSharedTimestamp =
                    backend.advance_external_cycles(arm9, elapsedCycles);
            sharedTimestamp = lastSharedTimestamp;
            mailboxAdvanceFinished = sampleMailbox
                ? profiler.timestampNanoseconds() : 0;
            reportWatchedMainRam(
                "after_advance", generation, arm9, executionPc, address);
            // Collapse cartridge and VCOUNT ready polls inside the same
            // counted advance phase; all IRQ causes they raise are PRE events.
            if (cartPollCollapse && readNotWrite && !timingOnly &&
                address == kCartRomCtrl) {
                for (unsigned attempt = 0; attempt < kCartPollAttempts;
                     ++attempt) {
                    std::uint32_t romctrl = 0;
                    if (!backend.bus_read(
                            arm9, 2, kCartRomCtrl, romctrl, executionPc))
                        break;
                    const bool blockBusy = (romctrl & 0x80000000u) != 0;
                    const bool wordReady = (romctrl & 0x00800000u) != 0;
                    if (!blockBusy || wordReady) break;
                    backend.advance_external_cycles(arm9, cartPollCycles);
                    ++cartPollAdvances;
                }
            }
            if (vcountCollapse && readNotWrite && !timingOnly &&
                address == kVCount) {
                std::uint32_t startVCount = 0;
                if (backend.bus_read(
                        arm9, 1, kVCount, startVCount, executionPc)) {
                    bool changed = false;
                    std::uint64_t previous = 0;
                    for (unsigned attempt = 0;
                         attempt < kVCountPollAttempts; ++attempt) {
                        const auto reached =
                            backend.advance_system_to_next_event(0);
                        if (attempt != 0 && reached == previous) break;
                        previous = reached;
                        ++vcountAdvances;
                        std::uint32_t nowVCount = 0;
                        if (!backend.bus_read(
                                arm9, 1, kVCount, nowVCount, executionPc))
                            break;
                        if (nowVCount != startVCount) {
                            changed = true;
                            break;
                        }
                    }
                    if (changed) ++vcountCollapsed;
                }
            }
        };
        if (!timeIrqReverse) advanceMailbox();
        std::uint32_t result = 0;
        auto countedBoundary = makeMailboxCountedBoundary(
            arm9, elapsedCycles, generation, fenceSequence, timingOnly,
            readNotWrite, access, address, writeData);
        nds4mister::ConsumedCreditAckDdrReceipt countedReceipt{};
        std::uint64_t mailboxBusStarted = 0;
        std::uint64_t mailboxBusFinished = 0;
        std::uint64_t mailboxPublishStarted = 0;
        std::uint64_t mailboxPublishFinished = 0;
        std::uint64_t mailboxResponseStarted = 0;
        std::uint64_t traceSystemCycles = 0;
        bool traceIrq9 = false;
        bool traceIrq7 = false;
        const auto applyMailbox = [&] {
            mailboxBusStarted = sampleMailbox
                ? profiler.timestampNanoseconds() : 0;
            const bool ok = timingOnly ? true : (readNotWrite
                ? backend.bus_read(
                    arm9, access, address, result, executionPc)
                : backend.bus_write(
                    arm9, access, address, writeData));
            if (!ok)
                throw std::runtime_error("invalid oracle transaction");
            // Preserve the production DMA completion boundary before the
            // counted transaction can become visible to FPGA.
            if (!timingOnly && !readNotWrite) {
                const int dmaDrain = backend.complete_external_dma(arm9);
                if (dmaDrain < 0)
                    throw std::runtime_error(
                        "external DMA did not quiesce before CPU response");
            }
            mailboxBusFinished = sampleMailbox
                ? profiler.timestampNanoseconds() : 0;

            if (timeIrqReverse) {
                if (traceThisRequest) {
                    traceSystemCycles =
                        backend.advance_external_cycles(arm9, 0);
                    traceIrq9 = backend.irq_pending(true);
                    traceIrq7 = backend.irq_pending(false);
                }
                mailboxPublishStarted = sampleMailbox
                    ? profiler.timestampNanoseconds() : 0;
                publishReady();
                mailboxPublishFinished = sampleMailbox
                    ? profiler.timestampNanoseconds() : 0;
                mailboxResponseStarted = sampleMailbox
                    ? profiler.timestampNanoseconds() : 0;
                // Any time/IRQ work needed to empty GX belongs to POST.
                drainGxStall();
            }
            return result;
        };
        if (timeIrqReverse) {
            countedReceipt = publishCountedTransactionWithRetry(
                *reverseProducer, countedBoundary,
                advanceMailbox, applyMailbox,
                [&] { return takeIrqSetMasks(backend); },
                [&](nds4mister::ConsumedCreditAckPublishResult) {
                    requireOwnedLwSession(
                        words, lwSessionCookie, lwExpectedCapabilities);
                    const auto before = reverseFrontier;
                    for (unsigned spin = 0; spin < 4096; ++spin) {
                        const auto frontier =
                            words[kLwRegReverseConsumer];
                        validateReverseFrontier(
                            frontier, reverseFrontier, *reverseProducer);
                        if (frontier != before) return true;
                    }
                    sched_yield();
                    return true;
                });
        } else {
            applyMailbox();
        }
        if (arm7SoundTrace.enabled()) {
            nds4mister::Arm7SoundMmioWriteTraceRecord record;
            const auto traceResult =
                arm7SoundTrace.observeSuccessfulRequest(
                    generation, arm9, readNotWrite, address, access,
                    writeData, elapsedCycles, sharedTimestamp, record);
            if (traceResult !=
                nds4mister::Arm7SoundMmioTraceResult::None) {
                std::array<char, 512> line{};
                const auto length =
                    nds4mister::formatArm7SoundMmioWriteTrace(
                        line.data(), line.size(), record);
                if (length == 0)
                    throw std::runtime_error(
                        "ARM7 sound-MMIO trace line overflow");
                std::cerr.write(line.data(),
                                static_cast<std::streamsize>(length));
                if (traceResult ==
                    nds4mister::Arm7SoundMmioTraceResult::
                        CapturedAndExhausted) {
                    const auto endLength =
                        nds4mister::formatArm7SoundMmioTraceEnd(
                            line.data(), line.size(), record);
                    if (endLength == 0)
                        throw std::runtime_error(
                            "ARM7 sound-MMIO trace-end line overflow");
                    std::cerr.write(
                        line.data(),
                        static_cast<std::streamsize>(endLength));
                }
            }
        }
        if (traceKeyInput && readNotWrite &&
            address == 0x04000130u) {
            ++keyInputReadCount;
            if (lastKeyInputReadEpoch != inputSelectionEpoch) {
                std::cerr
                    << "NDS4MISTER_KEYINPUT_READ_V1"
                    << " read_count=" << keyInputReadCount
                    << " selection_epoch=" << inputSelectionEpoch
                    << " generation=0x" << std::hex << generation
                    << " cpu=" << std::dec << (arm9 ? 9 : 7)
                    << " access=" << access
                    << " request_pc=0x" << std::hex << executionPc
                    << " raw_ndsj=0x" << lastPublishedInput
                    << " selected_mask=0x" << activeKeys
                    << " result=0x" << result
                    << std::dec << "\n" << std::flush;
                lastKeyInputReadEpoch = inputSelectionEpoch;
            }
        }
        reportWatchedMainRam(
            "after_bus", generation, arm9, executionPc, address);
        if (traceThisRequest) {
            if (!timeIrqReverse) {
                traceSystemCycles =
                    backend.advance_external_cycles(arm9, 0);
                traceIrq9 = backend.irq_pending(true);
                traceIrq7 = backend.irq_pending(false);
            }
            std::cerr << "response generation=0x" << std::hex << generation
                      << " result=0x" << result
                      << " system_cycles=0x" << traceSystemCycles
                      << " irq9=" << (traceIrq9 ? 1u : 0u)
                      << " irq7=" << (traceIrq7 ? 1u : 0u)
                      << std::dec << "\n";
        }

        if (!timeIrqReverse) {
            mailboxPublishStarted = sampleMailbox
                ? profiler.timestampNanoseconds() : 0;
            publishReady();
            mailboxPublishFinished = sampleMailbox
                ? profiler.timestampNanoseconds() : 0;

            mailboxResponseStarted = sampleMailbox
                ? profiler.timestampNanoseconds() : 0;
            // Hold the response while the geometry FIFO is stalled. The write
            // has already been applied; the FPGA CPU must not push more into a
            // queue that is about to overflow and drop commands.
            drainGxStall();
        }
        if (!readNotWrite && !timingOnly &&
            address >= kGxFifoLo && address <= kGxFifoHi) {
            // 0x04000400 is GXFIFO for ARM9 but SOUND0CNT for ARM7 -- the
            // same address is a different peripheral per CPU, so only ARM9
            // traffic here is geometry.
            if (arm9) {
                ++gxWrites;
                gxAccessHist[access & 3u]++;
                if (writeData == 0) ++gxZeroWrites;
            } else {
                ++gxWritesArm7;
            }
            if (backend.gxfifo_dma_active()) ++gxWriteDuringDma;
        }
        if (busJsonl && !timingOnly) {
            ++busJsonlSeen;
            if (!busJsonlArmed && busJsonlTrigger &&
                busJsonlTriggerMatches(
                    address, busJsonlTrigger, arm9, readNotWrite, access,
                    writeData, busJsonlTriggerNonzeroArm9WordWrite))
                busJsonlArmed = true;
            if (busJsonlArmed && busJsonlSeen > busJsonlSkip &&
                busJsonlSeq < busJsonlLimit) {
                std::fprintf(busJsonl,
                    "{\"event\":\"bus\",\"cpu\":\"%s\",\"seq\":%llu,"
                    "\"kind\":\"%s\",\"addr\":\"%08x\",\"size\":%u,"
                    "\"value\":\"%08x\",\"pc\":\"%08x\"}\n",
                    arm9 ? "arm9" : "arm7",
                    static_cast<unsigned long long>(busJsonlSeq++),
                    readNotWrite ? "read" : "write",
                    address,
                    access == 0 ? 1u : (access == 1 ? 2u : 4u),
                    readNotWrite ? result : writeData,
                    executionPc);
                if ((busJsonlSeq & 0x3ffu) == 0) std::fflush(busJsonl);
            }
        }
        if (timeIrqReverse)
            waitReverseReceipt(
                *reverseProducer, countedReceipt, words,
                lwSessionCookie, lwExpectedCapabilities,
                reverseFrontier);
        const std::uint32_t responseFlags =
            (backend.irq_pending(true) ? 1u : 0u) |
            (backend.irq_pending(false) ? 2u : 0u) |
            (backend.external_cpu_halted(true) ? 4u : 0u) |
            (backend.external_cpu_halted(false) ? 8u : 0u);
        if (lwMailbox) {
            // Payload first, then flags: the flag write is the completion
            // point that releases the stalled CPU, so the data must already
            // be latched when it lands.
            requireOwnedLwSession(
                words, lwSessionCookie, lwExpectedCapabilities);
            words[kLwRegRData] = result;
            __sync_synchronize();
            words[kLwRegFlags] = responseFlags;
            __sync_synchronize();
            lwResponsePublished = true;
        } else {
            words[6] = result;
            words[8] = responseFlags;
            __sync_synchronize();
            words[7] = generation;
            __sync_synchronize();
        }
        completed = generation;
        if (sampleMailbox) {
            const auto mailboxResponseFinished =
                profiler.timestampNanoseconds();
            profiler.finishMailbox(
                mailboxFenceFinished - mailboxStarted,
                mailboxInputFinished - mailboxFenceFinished,
                mailboxAdvanceFinished - mailboxAdvanceStarted,
                mailboxBusFinished - mailboxBusStarted,
                mailboxPublishFinished - mailboxPublishStarted,
                mailboxResponseFinished - mailboxResponseStarted,
                mailboxResponseFinished - mailboxStarted);
        }
        mailboxActive = false;
        schedulingPoint();
    }
    profiler.maybeReport(
        postedRing.consumerSequence(), completed, publisher.published(), true);
    reportFPGAAudioOffload("final");
    reportExternalTimeWindowProfile("final");
    if (!backend.flush_save(error))
        throw std::runtime_error("save flush failed: " + error);
    const auto saveStats = backend.save_persistence_stats();
    if (timeIrqReverse) {
        backend.set_irq_set_capture(false);
        reverseProducer->stopSession();
        reverseProducer.reset();
        reverseMemory.reset();
        munmap(
            reverseRingMapping,
            nds4mister::kConsumedCreditAckRingBytes);
    }
    if (externalTimeWindow) {
        externalTimeWindowRuntime.reset();
        externalTimeWindowControl.reset();
        externalTimeWindowProducer->stopSession();
        externalTimeWindowProducer.reset();
        externalTimeWindowMemory.reset();
        munmap(externalTimeWindowMapping, kExternalTimeWindowBytes);
    }
    munmap(mapping, mailboxMapBytes);
    munmap(mainRamMapping, nds4mister::kStandaloneMainRamBytes);
    munmap(sharedWramMapping, nds4mister::kStandaloneSharedWramBytes);
    munmap(arm7WramMapping, nds4mister::kStandaloneArm7WramBytes);
    munmap(postedRingMapping, nds4mister::kPostedWriteRingBytes);
    munmap(descriptorMapping, pageSize);
    if (layerPublication) publisher.drainLayer();
    if (layerPublication) {
        melonDS::NDS4MiSTer::SetCompositeLineBypass(false);
        backend.set_composite_line_sink(nullptr, nullptr);
        backend.set_output_line_sink(nullptr, nullptr);
    } else backend.set_output_line_sink(nullptr, nullptr);
    std::cout << "published_frames=" << publisher.published()
              << " posted_writes=" << postedWrites
              << " capture_overruns="
              << (layerPublication ? layerCapture.overruns : capture.overruns)
              << " incomplete_frames="
              << ((layerPublication ? layerCapture.incomplete : capture.incomplete) ? 1 : 0)
              << " cart_poll_advances=" << cartPollAdvances
              << " vcount_advances=" << vcountAdvances
              << " vcount_collapsed=" << vcountCollapsed
              << " halted_peer_advance=" << (haltedPeerAdvance ? 1 : 0)
              << " gx_stall_waits=" << gxStallWaits
              << " gx_stall_advances=" << gxStallAdvances
              << " gx_stall_timeouts=" << gxStallTimeouts
              << " gx_command_drops=" << backend.gx_command_drops()
              << " clip_zero_den=" << backend.clip_zero_den()
              << " clip_interp=" << backend.clip_interp()
              << " gx_invalid_cmd=" << backend.gx_invalid_cmd()
              << " gx_executed=" << backend.gx_executed()
              << " gx_invalid_top=[" << backend.gx_invalid_top() << "]"
              << " gx_writes=" << gxWrites
              << " gx_write_during_dma=" << gxWriteDuringDma
              << " gx_zero_writes=" << gxZeroWrites
              << " gx_acc8=" << gxAccessHist[0]
              << " gx_acc16=" << gxAccessHist[1]
              << " gx_acc32=" << gxAccessHist[2]
              << " gx_acc3=" << gxAccessHist[3]
              << " gx_writes_arm7=" << gxWritesArm7
              << " timing_only_with_payload=" << timingOnlyWithPayload
              << " save_persistence="
              << (backend.save_persistence_enabled() ? "enabled" : "disabled")
              << " save_bytes=" << saveStats.saveBytes
              << " save_loaded_existing="
              << (saveStats.loadedExisting ? 1 : 0)
              << " save_callbacks=" << saveStats.callbacks
              << " save_callback_bytes=" << saveStats.callbackBytes
              << " save_commits=" << saveStats.commits
              << " save_failures=" << saveStats.failures
              << " save_dirty=" << (saveStats.dirty ? 1 : 0)
              << "\n";
    if (busJsonl) std::fclose(busJsonl);
    munmap(compactMapping, kCompactMapBytes);
    return 0;
} catch (const std::exception& error) {
    std::cerr << "nds_hps_oracle_responder: " << error.what() << "\n";
    return 1;
}
