#include "melonds/MelonDsBackend.h"

#include "Args.h"
#include "NDS.h"
#include "NDSCart.h"
#include "NDS4MiSTer_2DTrace.h"

#include <chrono>
#include <cstring>
#include <fstream>
#include <cstdint>
#include <limits>
#include <memory>
#include <string>

#if !defined(_WIN32)
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#endif

namespace nds4mister {
namespace {

std::string basename(const std::string& path)
{
    const auto slash = path.find_last_of("/\\");
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

void unmap_rom(melonDS::u8* data, melonDS::u32 size) noexcept
{
#if !defined(_WIN32)
    munmap(data, size);
#else
    delete[] data;
#endif
}

bool make_rom_writable(melonDS::u8* data, melonDS::u32 total_size, melonDS::u32 offset, melonDS::u32 size) noexcept
{
#if !defined(_WIN32)
    if (!data || offset > total_size || size > (total_size - offset)) {
        return false;
    }

    const long page_size_long = sysconf(_SC_PAGESIZE);
    const std::uintptr_t page_size = page_size_long > 0
        ? static_cast<std::uintptr_t>(page_size_long)
        : static_cast<std::uintptr_t>(4096);
    const std::uintptr_t start = reinterpret_cast<std::uintptr_t>(data) + offset;
    const std::uintptr_t end = start + size;
    const std::uintptr_t aligned_start = start & ~(page_size - 1);
    const std::uintptr_t aligned_end = (end + page_size - 1) & ~(page_size - 1);

    return mprotect(
        reinterpret_cast<void*>(aligned_start),
        aligned_end - aligned_start,
        PROT_READ | PROT_WRITE) == 0;
#else
    (void)data;
    (void)total_size;
    (void)offset;
    (void)size;
    return true;
#endif
}

bool map_file(const std::string& path, melonDS::NDSCart::ROMBuffer& data, melonDS::u32& data_size, std::string& error)
{
    (void)error;
#if defined(_WIN32)
    (void)path;
    (void)data;
    (void)data_size;
    return false;
#else
    const int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        return false;
    }

    struct stat st {};
    if (fstat(fd, &st) != 0) {
        close(fd);
        return false;
    }

    if (st.st_size <= 0 || st.st_size > 512LL * 1024LL * 1024LL) {
        close(fd);
        return false;
    }

    void* mapping = mmap(nullptr, static_cast<std::size_t>(st.st_size), PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapping == MAP_FAILED) {
        return false;
    }

    data_size = static_cast<melonDS::u32>(st.st_size);
    data = melonDS::NDSCart::ROMBuffer(static_cast<melonDS::u8*>(mapping), data_size, unmap_rom, make_rom_writable);
    return true;
#endif
}

bool read_file(const std::string& path, melonDS::NDSCart::ROMBuffer& data, melonDS::u32& data_size, std::string& error)
{
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) {
        error = "failed to open ROM: " + path;
        return false;
    }

    const std::streamsize size = file.tellg();
    if (size <= 0) {
        error = "ROM is empty: " + path;
        return false;
    }
    if (size > 512LL * 1024LL * 1024LL) {
        error = "ROM is larger than melonDS supports: " + path;
        return false;
    }

    data_size = static_cast<melonDS::u32>(size);
    auto heap_data = std::make_unique<melonDS::u8[]>(data_size);

    file.seekg(0, std::ios::beg);
    if (!file.read(reinterpret_cast<char*>(heap_data.get()), size)) {
        error = "failed to read ROM: " + path;
        return false;
    }

    data = melonDS::NDSCart::ROMBuffer::FromUnique(std::move(heap_data), data_size);
    return true;
}

const char* external_time_window_error(
    melonDS::ExternalTimeWindowResult result) noexcept
{
    using Result = melonDS::ExternalTimeWindowResult;
    switch (result)
    {
    case Result::Success:
        return nullptr;
    case Result::CapabilityDisabled:
        return "external time-window capability is disabled in this build";
    case Result::NotEnabled:
        return "external time-window runtime opt-in is disabled";
    case Result::ProtocolFaulted:
        return "external time-window protocol is faulted; NDS reset required";
    case Result::UnsupportedAuthoritativeEventMask:
        return "no FPGA-authoritative scheduler event mask is supported yet";
    case Result::InvalidFiniteBound:
        return "external time-window bound must be finite";
    case Result::BoundBeforeProcessed:
        return "external time-window bound precedes processed scheduler time";
    case Result::CausalTargetNotReached:
        return "both external CPUs have not causally reached the closure target";
    case Result::NoActiveGrant:
        return "external CPU progress requires an active run-safe grant";
    case Result::InvalidCPU:
        return "external CPU progress named an invalid CPU";
    case Result::CPUProgressRegressed:
        return "external CPU progress regressed";
    case Result::CPUProgressBeyondRunSafe:
        return "external CPU progress exceeded the inclusive run-safe grant";
    case Result::TimestampOverflow:
        return "external CPU timestamp cannot be represented internally";
    case Result::BoundarySkipped:
        return "external closure skipped the exact next causal boundary";
    case Result::SchedulerAdvancedOutsideClosure:
        return "scheduler advanced outside an explicit time-window closure";
    case Result::FrontierRegressed:
        return "external time-window frontier regressed";
    case Result::LateEvent:
        return "scheduler discovered an event inside an already granted horizon";
    case Result::EventBeforeClosureTarget:
        return "scheduler has an overdue event before the exact closure target";
    case Result::ClosureDidNotConverge:
        return "scheduler same-timestamp closure did not converge";
    case Result::DMAClosureFailed:
        return "both external DMA stop masks could not be drained";
    case Result::UnrepresentableSideEffect:
        return "closure produced an unrepresentable IRQ or halt side effect";
    case Result::EventSequenceExhausted:
        return "external IRQ transition sequence exhausted";
    case Result::InvalidExternalIFWrite:
        return "external ARM9 IF mirror requires a nonzero source sequence and exactly one aligned word write at 0x04000214";
    case Result::ExternalIFWriteReplay:
        return "external ARM9 IF mirror source order or timestamp replayed/regressed";
    case Result::ExternalIFWriteStateMismatch:
        return "external ARM9 IF mirror does not match the active grant or reported final state";
    case Result::ExternalIFWriteFailed:
        return "external ARM9 IF mirror did not perform exactly its W1C and GXFIFO side effects";
    case Result::InvalidBlockingMMIOBarrierIdentity:
        return "blocking-MMIO barrier requires one nonzero epoch and ordered nonzero source/barrier identities";
    case Result::BlockingMMIOBarrierReplay:
        return "blocking-MMIO barrier source or barrier identity replayed, regressed, or skipped";
    case Result::BlockingMMIOBarrierStateMismatch:
        return "blocking-MMIO barrier does not match the active P/R grant or effective CPU state";
    case Result::InvalidExternalTimeWindowIdentity:
        return "verified external time-window identity is missing or changed epoch";
    case Result::ExternalTimeWindowIdentityReplay:
        return "verified external time-window replacement replayed, skipped, or regressed its grant/fence";
    case Result::BlockingMMIOWindowIdentityMismatch:
        return "blocking-MMIO descriptor does not match the verified active grant, P/R/event high-water, or producer fence";
    case Result::InvalidBlockingMMIORequest:
        return "blocking-MMIO descriptor has an invalid CPU, width, read payload, or execution PC";
    case Result::BlockingMMIOAccessRequired:
        return "blocking-MMIO barrier requires exactly one completed HPS access before closure";
    case Result::BlockingMMIOAccessAlreadyClaimed:
        return "blocking-MMIO barrier already claimed its single HPS access";
    case Result::BlockingMMIOAccessDescriptorMismatch:
        return "blocking-MMIO execution did not exactly match its admitted immutable request";
    case Result::BlockingMMIOAccessFailed:
        return "blocking-MMIO HPS access or ordered IRQ capture failed";
    }
    return "unknown external time-window failure";
}

} // namespace

MelonDsBackend::MelonDsBackend() = default;
MelonDsBackend::~MelonDsBackend()
{
    melonDS::NDS4MiSTer::SetCompositeLineSink(nullptr, nullptr);
    melonDS::NDS4MiSTer::SetOutputLineSink(nullptr, nullptr);
    close_trace_2d();
    if (nds_) {
        if (internal_main_ram_) nds_->MainRAM = internal_main_ram_;
        if (internal_shared_wram_ && internal_arm7_wram_) {
            nds_->ReplaceWRAMBacking(
                internal_shared_wram_, internal_arm7_wram_);
        }
    }
}

const char* MelonDsBackend::name() const
{
    return "melonDS";
}

void MelonDsBackend::close_trace_2d() noexcept
{
    melonDS::NDS4MiSTer::SetTrace2DSink(nullptr, nullptr);
    if (trace_2d_.is_open()) {
        trace_2d_.close();
    }
}

bool MelonDsBackend::set_2d_trace_path(const std::string& path, std::string& error)
{
    close_trace_2d();

    trace_2d_.open(path, std::ios::binary | std::ios::trunc);
    if (!trace_2d_) {
        error = "failed to open 2D trace output: " + path;
        return false;
    }

    const auto header = melonDS::NDS4MiSTer::MakeTrace2DFileHeader();
    trace_2d_.write(reinterpret_cast<const char*>(&header), sizeof(header));
    if (!trace_2d_) {
        error = "failed to write 2D trace header: " + path;
        close_trace_2d();
        return false;
    }

    melonDS::NDS4MiSTer::SetTrace2DSink(
        [](const void* data, std::size_t size, void* userdata) {
            auto* out = static_cast<std::ofstream*>(userdata);
            out->write(reinterpret_cast<const char*>(data), static_cast<std::streamsize>(size));
        },
        &trace_2d_);
    return true;
}

void MelonDsBackend::set_2d_trace_sink(melonDS::NDS4MiSTer::Trace2DSink sink,void* userdata)
{
    close_trace_2d();
    melonDS::NDS4MiSTer::SetTrace2DSink(sink,userdata);
}

void MelonDsBackend::set_composite_line_sink(melonDS::NDS4MiSTer::CompositeLineSink sink,void* userdata)
{
    melonDS::NDS4MiSTer::SetCompositeLineSink(sink,userdata);
}

void MelonDsBackend::set_output_line_sink(melonDS::NDS4MiSTer::OutputLineSink sink,void* userdata)
{
    melonDS::NDS4MiSTer::SetOutputLineSink(sink,userdata);
}

void MelonDsBackend::set_key_mask(melonDS::u32 mask)
{
    if(nds_) nds_->SetKeyMask(mask & 0xFFFu);
}

std::uint64_t MelonDsBackend::advance_external_cycles(bool arm9, std::uint32_t cycles)
{
    return nds_ ? nds_->AdvanceExternalCPU(arm9 ? 0u : 1u, cycles) : 0;
}

void MelonDsBackend::irq_set_sink(
    std::uint32_t cpu, std::uint32_t mask, void* userdata) noexcept
{
    auto* backend = static_cast<MelonDsBackend*>(userdata);
    if (!backend || cpu > 1) return;
    backend->irq_set_capture_[cpu] |= mask;
}

void MelonDsBackend::set_irq_set_capture(bool enable) noexcept
{
    irq_set_capture_ = {};
    if (nds_)
        nds_->SetExternalIRQSetSink(
            enable ? &MelonDsBackend::irq_set_sink : nullptr,
            enable ? this : nullptr);
}

IRQSetCapture MelonDsBackend::take_irq_set_capture() noexcept
{
    IRQSetCapture capture{
        irq_set_capture_[0],
        irq_set_capture_[1]
    };
    irq_set_capture_ = {};
    return capture;
}

bool MelonDsBackend::self_test_irq_set_capture()
{
    MelonDsBackend backend;
    melonDS::NDSArgs args;
    args.JIT = std::nullopt;
    backend.nds_ = std::make_unique<melonDS::NDS>(
        std::move(args), nullptr);
    backend.set_irq_set_capture(true);
    backend.nds_->SetIRQ(0, melonDS::IRQ_VBlank);
    backend.nds_->SetIRQ(1, melonDS::IRQ_Timer2);
    backend.nds_->SetIRQ(0, melonDS::IRQ_VBlank);
    const auto first = backend.take_irq_set_capture();
    const auto second = backend.take_irq_set_capture();
    backend.set_irq_set_capture(false);
    backend.nds_->SetIRQ(1, melonDS::IRQ_SPI);
    const auto disabled = backend.take_irq_set_capture();
    return first.arm9_mask == (1u << melonDS::IRQ_VBlank) &&
           first.arm7_mask == (1u << melonDS::IRQ_Timer2) &&
           second.arm9_mask == 0 && second.arm7_mask == 0 &&
           disabled.arm9_mask == 0 && disabled.arm7_mask == 0;
}

bool MelonDsBackend::external_time_window_capable() const noexcept
{
#if NDS4MISTER_EXTERNAL_TIME_WINDOW
    return true;
#else
    return false;
#endif
}

bool MelonDsBackend::irq_transition_sink(
    const melonDS::ExternalIRQTransition& transition,
    void* userdata) noexcept
{
    auto* backend = static_cast<MelonDsBackend*>(userdata);
    if (!backend || transition.CPU > 1 || transition.Mask == 0)
        return false;
    try {
        backend->external_irq_transitions_.push_back({
            transition.Sequence,
            transition.Timestamp,
            transition.CPU == 0,
            transition.Set,
            transition.Mask,
        });
        return true;
    } catch (...) {
        backend->external_irq_transition_delivery_failed_ = true;
        return false;
    }
}

void MelonDsBackend::rollback_external_blocking_mmio_barrier() noexcept
{
    if (external_blocking_mmio_barrier_active_ &&
        external_blocking_mmio_transition_checkpoint_ <=
            external_irq_transitions_.size())
        external_irq_transitions_.resize(
            external_blocking_mmio_transition_checkpoint_);
    external_blocking_mmio_barrier_active_ = false;
    external_blocking_mmio_transition_checkpoint_ = 0;
}

bool MelonDsBackend::set_external_time_window_enabled(
    bool enable, std::string& error)
{
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }
    if (!enable) {
        const bool disabled = nds_->SetExternalTimeWindowEnabled(false);
        nds_->SetExternalIRQTransitionSink(nullptr, nullptr);
        if (!disabled) {
            rollback_external_blocking_mmio_barrier();
            error = "external time-window epoch has published a grant; "
                    "NDS reset required before disabling";
            return false;
        }
#if NDS4MISTER_FPGA_AUDIO_OFFLOAD
        if (!nds_->SPU.SetFPGAAudioTimeAuthority(false)) {
            error = "failed to restore HPS SPU time authority";
            return false;
        }
#endif
        rollback_external_blocking_mmio_barrier();
        return true;
    }
    if (external_blocking_mmio_barrier_active_ ||
        nds_->ExternalBlockingMMIOBarrierPending()) {
        error = "external time-window enable requires no active blocking-MMIO transaction";
        return false;
    }
    if (!external_irq_transitions_.empty()) {
        error = "external time-window enable requires all prior external IRQ transitions to be consumed";
        return false;
    }
    nds_->SetExternalIRQTransitionSink(
        &MelonDsBackend::irq_transition_sink, this);
    if (!nds_->SetExternalTimeWindowEnabled(true)) {
        rollback_external_blocking_mmio_barrier();
        nds_->SetExternalIRQTransitionSink(nullptr, nullptr);
        error = external_time_window_capable()
            ? "external time-window protocol is faulted; NDS reset required"
            : "external time-window capability is disabled in this build";
        return false;
    }
#if NDS4MISTER_FPGA_AUDIO_OFFLOAD
    if (nds_->SPU.GetFPGAAudioOffload() &&
        !nds_->SPU.SetFPGAAudioTimeAuthority(true)) {
        nds_->SetExternalIRQTransitionSink(nullptr, nullptr);
        error = "failed to transfer SPU time authority to FPGA";
        return false;
    }
#endif
    // Enabling is never an implicit acknowledgement.  The checks above keep an
    // untagged suffix from crossing Reset into a fresh epoch; only an explicitly
    // consumed empty queue may be associated with the new identity.
    external_irq_transition_delivery_failed_ = false;
    if (!nds_->ExternalBlockingMMIOBarrierPending())
        rollback_external_blocking_mmio_barrier();
    return true;
}

bool MelonDsBackend::set_external_offline_fast_beta(
    bool enable, std::string& error)
{
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }
    if (!nds_->SetExternalOfflineFastBeta(enable)) {
        error = enable
            ? "offline fast-beta mode must be selected before the external time-window epoch"
            : "offline fast-beta mode is one-way for the loaded ROM epoch";
        return false;
    }
    return true;
}

bool MelonDsBackend::set_external_lcd_renderer_enabled(
    bool enable, std::string& error)
{
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }
    if (!nds_->SetExternalLCDRendererEnabled(enable)) {
        error = "external LCD renderer authority must be selected before the external time-window epoch";
        return false;
    }
    return true;
}

bool MelonDsBackend::apply_external_lcd_phase(
    const ExternalLCDPhase& phase, bool render, bool resync,
    std::string& error)
{
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }
    if (!nds_->ApplyExternalLCDRendererPhase(
            static_cast<std::uint32_t>(phase.kind), phase.line,
            phase.vcount, phase.dispstat9, phase.dispstat7,
            phase.frameSequence, render, resync)) {
        error = "external LCD renderer phase was rejected";
        return false;
    }
    return true;
}

bool MelonDsBackend::report_external_time_window_cpu_reached(
    bool arm9, std::uint64_t normalizedTimestamp,
    std::string& error)
{
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }
    const auto result = nds_->ReportExternalTimeWindowCPUReached(
        arm9 ? 0u : 1u, normalizedTimestamp);
    if (result == melonDS::ExternalTimeWindowResult::Success)
        return true;
    error = external_time_window_error(result);
    return false;
}

bool MelonDsBackend::advance_and_close_external_time_window(
    std::uint64_t closeThrough,
    std::uint64_t finiteBound,
    std::uint64_t fpgaAuthoritativeEventMask,
    const ExternalTimeWindowReplacement& replacement,
    ExternalTimeWindow& out,
    std::string& error)
{
    out = {};
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }
    if (external_irq_transition_delivery_failed_) {
        error = "external IRQ transition delivery previously failed";
        return false;
    }

    const bool completingBlockingMMIO =
        external_blocking_mmio_barrier_active_;
    const std::size_t transitionCheckpoint = completingBlockingMMIO
        ? external_blocking_mmio_transition_checkpoint_
        : external_irq_transitions_.size();
    melonDS::ExternalTimeWindow window;
    const melonDS::ExternalTimeWindowReplacement modelReplacement{
        replacement.epoch,
        replacement.grantSequence,
        replacement.replacesGrantSequence,
        replacement.verifiedProducerFence};
    const auto result = nds_->AdvanceAndCloseExternalTimeWindowVerified(
        closeThrough, finiteBound, fpgaAuthoritativeEventMask,
        modelReplacement, window);
    if (result != melonDS::ExternalTimeWindowResult::Success) {
        error = external_time_window_error(result);
        // A failed closure has no grant naming its new records. Retain older
        // successful records but roll back this attempt's undeliverable tail.
        external_irq_transitions_.resize(transitionCheckpoint);
        if (completingBlockingMMIO)
            rollback_external_blocking_mmio_barrier();
        return false;
    }
    out = {window.ProcessedThrough,
           window.RunSafeThrough,
           window.LastEventSequence,
           window.Epoch,
           window.GrantSequence,
           window.ReplacesGrantSequence,
           window.VerifiedProducerFence,
           window.ReplacesBlockingMMIO,
           window.BarrierSourceSequence,
           window.BarrierSequence,
           window.BarrierTimestamp};
    if (completingBlockingMMIO) {
        external_blocking_mmio_barrier_active_ = false;
        external_blocking_mmio_transition_checkpoint_ = 0;
    }
    return true;
}

bool MelonDsBackend::close_and_query_external_time_window(
    std::uint64_t finiteBound,
    std::uint64_t fpgaAuthoritativeEventMask,
    const ExternalTimeWindowReplacement& replacement,
    ExternalTimeWindow& out,
    std::string& error)
{
    out = {};
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }
    if (external_irq_transition_delivery_failed_) {
        error = "external IRQ transition delivery previously failed";
        return false;
    }

    const bool completingBlockingMMIO =
        external_blocking_mmio_barrier_active_;
    const std::size_t transitionCheckpoint = completingBlockingMMIO
        ? external_blocking_mmio_transition_checkpoint_
        : external_irq_transitions_.size();
    melonDS::ExternalTimeWindow window;
    const melonDS::ExternalTimeWindowReplacement modelReplacement{
        replacement.epoch,
        replacement.grantSequence,
        replacement.replacesGrantSequence,
        replacement.verifiedProducerFence};
    const auto result = nds_->CloseAndQueryExternalTimeWindowVerified(
        finiteBound, fpgaAuthoritativeEventMask,
        modelReplacement, window);
    if (result != melonDS::ExternalTimeWindowResult::Success) {
        error = external_time_window_error(result);
        // A failed closure has no grant naming its new records.  Retain older
        // successful records but roll back this attempt's undeliverable tail.
        external_irq_transitions_.resize(transitionCheckpoint);
        if (completingBlockingMMIO)
            rollback_external_blocking_mmio_barrier();
        return false;
    }
    out = {window.ProcessedThrough,
           window.RunSafeThrough,
           window.LastEventSequence,
           window.Epoch,
           window.GrantSequence,
           window.ReplacesGrantSequence,
           window.VerifiedProducerFence,
           window.ReplacesBlockingMMIO,
           window.BarrierSourceSequence,
           window.BarrierSequence,
           window.BarrierTimestamp};
    if (completingBlockingMMIO) {
        external_blocking_mmio_barrier_active_ = false;
        external_blocking_mmio_transition_checkpoint_ = 0;
    }
    return true;
}

bool MelonDsBackend::begin_external_blocking_mmio_barrier(
    const ExternalBlockingMMIORequest& request,
    std::uint64_t& barrierTimestamp,
    std::string& error)
{
    barrierTimestamp = 0;
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }
    if (external_irq_transition_delivery_failed_) {
        error = "external IRQ transition delivery previously failed";
        return false;
    }
    // A replacement transaction may only name the IRQ suffix caused by this
    // barrier. Requiring the prior suffix to be empty prevents old records
    // from being silently relabelled under the replacement grant.
    if (!external_irq_transitions_.empty()) {
        error = "blocking-MMIO admission requires all prior external IRQ transitions to be consumed";
        return false;
    }
    const std::size_t transitionCheckpoint =
        external_blocking_mmio_barrier_active_
            ? external_blocking_mmio_transition_checkpoint_
            : external_irq_transitions_.size();
    const melonDS::ExternalBlockingMMIORequest modelRequest{
        request.epoch,
        request.activeGrantSequence,
        request.activeProcessedThrough,
        request.activeRunSafeThrough,
        request.activeEventSequence,
        request.sourceSequence,
        request.barrierSequence,
        request.verifiedProducerFence,
        request.arm9NormalizedTimestamp,
        request.arm7NormalizedTimestamp,
        request.arm9 ? 0u : 1u,
        request.write,
        request.access,
        request.address,
        request.writeData,
        request.executionPC};
    const auto result = nds_->BeginExternalBlockingMMIOBarrier(
        modelRequest, barrierTimestamp);
    if (result != melonDS::ExternalTimeWindowResult::Success) {
        if (transitionCheckpoint <= external_irq_transitions_.size())
            external_irq_transitions_.resize(transitionCheckpoint);
        rollback_external_blocking_mmio_barrier();
        barrierTimestamp = 0;
        error = external_time_window_error(result);
        return false;
    }
    external_blocking_mmio_barrier_active_ = true;
    external_blocking_mmio_transition_checkpoint_ = transitionCheckpoint;
    return true;
}

bool MelonDsBackend::execute_external_blocking_mmio_transaction(
    const ExternalBlockingMMIORequest& request,
    std::uint64_t finiteBound,
    std::uint64_t fpgaAuthoritativeEventMask,
    const ExternalTimeWindowReplacement& replacement,
    ExternalBlockingMMIOCompletion& out,
    std::string& error,
    const ExternalBlockingMMIOPreAccess& preAccess,
    const ExternalBlockingMMIOExactAccess& exactAccess)
{
    out = {};
    if (external_blocking_mmio_barrier_active_ ||
        (nds_ && nds_->ExternalBlockingMMIOBarrierPending())) {
        error = "blocking-MMIO transaction is already active";
        return false;
    }

    std::uint64_t barrierTimestamp = 0;
    if (!begin_external_blocking_mmio_barrier(
            request, barrierTimestamp, error))
        return false;

    // The barrier timestamp is the exact inclusive CPU access time. A local
    // FPGA owner may use this hook only to bring its passive HPS mirror
    // through that time before the one admitted model access is claimed.
    if (preAccess && !preAccess(barrierTimestamp, request, error)) {
        if (error.empty())
            error = "blocking-MMIO pre-access ordering hook failed";
        if (nds_->ClaimExternalBlockingMMIOAccess(
                request.arm9 ? 0u : 1u, request.write, request.access,
                request.address, request.writeData,
                request.executionPC) ==
            melonDS::ExternalTimeWindowResult::Success)
            (void)nds_->FinishExternalBlockingMMIOAccess(false);
        rollback_external_blocking_mmio_barrier();
        return false;
    }

    ExternalBlockingMMIOOverrideResult overrideResult;
    if (exactAccess && !exactAccess(
            barrierTimestamp, request, overrideResult, error)) {
        if (error.empty())
            error = "blocking-MMIO exact-access override failed";
        if (nds_->ClaimExternalBlockingMMIOAccess(
                request.arm9 ? 0u : 1u, request.write, request.access,
                request.address, request.writeData,
                request.executionPC) ==
            melonDS::ExternalTimeWindowResult::Success)
            (void)nds_->FinishExternalBlockingMMIOAccess(false);
        rollback_external_blocking_mmio_barrier();
        return false;
    }

    std::uint32_t readData = overrideResult.readData;
    bool accessSucceeded = false;
    if (overrideResult.handled) {
        const auto claimed = nds_->ClaimExternalBlockingMMIOAccess(
            request.arm9 ? 0u : 1u, request.write, request.access,
            request.address, request.writeData, request.executionPC);
        if (claimed == melonDS::ExternalTimeWindowResult::Success) {
            nds_->CurCPU = request.arm9 ? 0u : 1u;
            accessSucceeded =
                nds_->FinishExternalBlockingMMIOAccess(true) ==
                melonDS::ExternalTimeWindowResult::Success;
        }
    } else {
        accessSucceeded = request.write
            ? bus_write(
                request.arm9, request.access, request.address,
                request.writeData, request.executionPC)
            : bus_read(
                request.arm9, request.access, request.address,
                readData, request.executionPC);
    }
    if (!accessSucceeded) {
        if (error.empty())
            error = "blocking-MMIO exact HPS access failed";
        rollback_external_blocking_mmio_barrier();
        return false;
    }

    ExternalTimeWindow window;
    if (!close_and_query_external_time_window(
            finiteBound, fpgaAuthoritativeEventMask,
            replacement, window, error))
        return false;

    // Entry required an empty queue, and the successful verified close is what
    // names this tail.  Swap all three results only now so a caller can never
    // observe an access result or IRQ suffix without its replacement grant.
    auto transitions = take_external_irq_transitions();
    out.readData = readData;
    out.window = window;
    out.transitions.swap(transitions);
    return true;
}

bool MelonDsBackend::apply_external_arm9_if_w1c(
    std::uint32_t sourceSequence,
    std::uint64_t normalizedTimestamp,
    std::uint32_t address,
    std::uint32_t access,
    std::uint32_t writeData,
    std::uint32_t expectedFinalIF,
    bool expectedGXFIFOAsserted,
    ExternalARM9IFW1CResult& out,
    std::string& error)
{
    out = {};
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }
    if (external_irq_transition_delivery_failed_) {
        error = "external IRQ transition delivery previously failed";
        return false;
    }

    melonDS::ExternalARM9IFW1CResult result;
    const auto status = nds_->ApplyExternalARM9IFW1C(
        sourceSequence, normalizedTimestamp, address, access, writeData,
        expectedFinalIF, expectedGXFIFOAsserted, result);
    if (status != melonDS::ExternalTimeWindowResult::Success) {
        error = external_time_window_error(status);
        return false;
    }
    out = {result.FinalIF, result.GXFIFOAsserted};
    return true;
}

std::vector<ExternalIRQTransition>
MelonDsBackend::take_external_irq_transitions() noexcept
{
    std::vector<ExternalIRQTransition> transitions;
    if (external_blocking_mmio_barrier_active_) {
        // The transition tail is not named by a replacement P/R until Close
        // succeeds. Never expose it to the DDR producer early.
        if (nds_ && nds_->ExternalBlockingMMIOBarrierPending())
            (void)nds_->FinishExternalBlockingMMIOAccess(false);
        rollback_external_blocking_mmio_barrier();
        return transitions;
    }
    transitions.swap(external_irq_transitions_);
    return transitions;
}

bool MelonDsBackend::self_test_external_time_window()
{
    if (!melonDS::NDS::SelfTestExternalTimeWindow())
        return false;

    MelonDsBackend profileBackend;
    melonDS::NDSArgs profileArgs;
    profileArgs.JIT = std::nullopt;
    profileBackend.nds_ = std::make_unique<melonDS::NDS>(
        std::move(profileArgs), nullptr);
    const auto emptyProfile =
        profileBackend.external_time_window_profile();
    if (emptyProfile.event_count != melonDS::Event_MAX ||
        emptyProfile.closure_count != 0 ||
        emptyProfile.finite_bound_limited_count != 0 ||
        emptyProfile.no_event_count != 0)
        return false;

#if NDS4MISTER_FPGA_AUDIO_OFFLOAD
    // FPGA audio is already the functional sound owner in the standalone
    // core. Transferring scheduler authority must remove the otherwise-empty
    // 1,024-cycle HPS SPU event, or every ETW grant is needlessly truncated.
    MelonDsBackend audioAuthorityBackend;
    melonDS::NDSArgs audioArgs;
    audioArgs.JIT = std::nullopt;
    audioAuthorityBackend.nds_ = std::make_unique<melonDS::NDS>(
        std::move(audioArgs), nullptr);
    audioAuthorityBackend.nds_->Reset();
    audioAuthorityBackend.nds_->SPU.SetFPGAAudioOffload(true);
    std::string audioError;
    ExternalTimeWindow audioWindow;
    if (!audioAuthorityBackend.set_external_time_window_enabled(
            true, audioError) ||
        !audioAuthorityBackend.nds_->SPU.GetFPGAAudioTimeAuthority() ||
        !audioAuthorityBackend.advance_and_close_external_time_window(
            0, 1u << 20, 0, {1, 1, 0, 10},
            audioWindow, audioError) ||
        audioWindow.runSafeThrough <= 1023 ||
        audioAuthorityBackend.nds_->SPU.GetFPGAAudioOffloadStats().
                MixCallbacks != 0)
        return false;
#endif

    // A failed shutdown must retain already-delivered records, but an untagged
    // retained suffix must block a post-Reset epoch until explicitly consumed.
    MelonDsBackend backend;
    melonDS::NDSArgs args;
    args.JIT = std::nullopt;
    backend.nds_ = std::make_unique<melonDS::NDS>(
        std::move(args), nullptr);
    std::string error;
    ExternalTimeWindow window;
    if (!backend.set_external_time_window_enabled(true, error) ||
        !backend.advance_and_close_external_time_window(
            0, 10, 0, {1, 1, 0, 10}, window, error) ||
        !backend.report_external_time_window_cpu_reached(true, 10, error) ||
        !backend.report_external_time_window_cpu_reached(false, 10, error))
        return false;
    backend.nds_->IF[0] = 1u << melonDS::IRQ_VBlank;
    backend.nds_->UpdateIRQ(0);
    backend.nds_->GPU.GPU3D.GXStat = 0;
    ExternalARM9IFW1CResult ifResult;
    if (!backend.apply_external_arm9_if_w1c(
            1, 10, 0x04000214u, 2,
            1u << melonDS::IRQ_VBlank, 0, false,
            ifResult, error) ||
        ifResult.finalIF != 0 || ifResult.gxFIFOAsserted ||
        backend.pending_external_irq_transitions() != 0)
        return false;
    backend.external_irq_transitions_.push_back(
        {77, 0, true, true, 1u << melonDS::IRQ_VBlank});
    if (backend.set_external_time_window_enabled(false, error) ||
        backend.pending_external_irq_transitions() != 1 ||
        backend.external_irq_transitions_.size() != 1 ||
        backend.set_external_time_window_enabled(true, error) ||
        backend.external_irq_transitions_.size() != 1)
        return false;
    backend.nds_->Reset();
    if (backend.set_external_time_window_enabled(true, error) ||
        backend.external_irq_transitions_.size() != 1)
        return false;
    const auto retained = backend.take_external_irq_transitions();
    if (retained.size() != 1 || retained[0].sequence != 77 ||
        backend.pending_external_irq_transitions() != 0 ||
        !backend.external_irq_transitions_.empty() ||
        !backend.set_external_time_window_enabled(true, error))
        return false;

    // Exercise the atomic non-yielding barrier facade. A dirty prior IRQ suffix
    // is rejected before admission; after it is consumed, the exact descriptor
    // claims once and read data, replacement identity, and suffix return
    // together.
    backend.nds_->Reset();
    std::uint64_t barrierTimestamp = 99;
    ExternalBlockingMMIORequest readRequest{
        1, 1, 0, 20, 0, 1, 1, 10, 8, 6,
        true, false, 1, 0x04000130u, 0, 0x02000040u};
    if (backend.begin_external_blocking_mmio_barrier(
            readRequest, barrierTimestamp, error) ||
        barrierTimestamp != 0 ||
        !backend.set_external_time_window_enabled(true, error) ||
        !backend.advance_and_close_external_time_window(
            0, 20, 0, {1, 1, 0, 10}, window, error))
        return false;
    backend.external_irq_transitions_.push_back(
        {88, 0, true, true, 1u << melonDS::IRQ_VBlank});
    ExternalBlockingMMIOCompletion completion;
    unsigned exactAccessOrder = 0;
    const ExternalBlockingMMIOPreAccess preAccess =
        [&](std::uint64_t timestamp,
            const ExternalBlockingMMIORequest& exactRequest,
            std::string& hookError) {
            if (exactAccessOrder != 0 || timestamp != 8 ||
                exactRequest.address != readRequest.address ||
                exactRequest.write ||
                !backend.external_blocking_mmio_barrier_active_ ||
                !backend.nds_->ExternalBlockingMMIOBarrierPending() ||
                completion.readData != 0 || completion.window.epoch != 0 ||
                !completion.transitions.empty()) {
                hookError = "blocking-MMIO pre-access hook order mismatch";
                return false;
            }
            exactAccessOrder = 1;
            return true;
        };
    const ExternalBlockingMMIOExactAccess exactAccess =
        [&](std::uint64_t timestamp,
            const ExternalBlockingMMIORequest& exactRequest,
            ExternalBlockingMMIOOverrideResult& result,
            std::string& hookError) {
            if (exactAccessOrder != 1 || timestamp != 8 ||
                exactRequest.address != readRequest.address ||
                exactRequest.write ||
                !backend.external_blocking_mmio_barrier_active_ ||
                !backend.nds_->ExternalBlockingMMIOBarrierPending() ||
                completion.readData != 0 || completion.window.epoch != 0 ||
                !completion.transitions.empty()) {
                hookError = "blocking-MMIO exact-access hook order mismatch";
                return false;
            }
            exactAccessOrder = 2;
            result.handled = true;
            result.readData = 0x00005a5au;
            return true;
        };
    if (backend.execute_external_blocking_mmio_transaction(
            readRequest, 30, 0, {1, 2, 1, 10},
            completion, error) ||
        backend.take_external_irq_transitions().size() != 1 ||
        !backend.execute_external_blocking_mmio_transaction(
            readRequest, 30, 0, {1, 2, 1, 10},
            completion, error, preAccess, exactAccess))
        return false;
    if (exactAccessOrder != 2 || completion.readData != 0x00005a5au ||
        backend.nds_->CurCPU != 0 ||
        completion.window.processedThrough != 8 ||
        completion.window.runSafeThrough != 30 ||
        completion.window.epoch != 1 ||
        completion.window.grantSequence != 2 ||
        completion.window.replacesGrantSequence != 1 ||
        completion.window.verifiedProducerFence != 10 ||
        !completion.window.replacesBlockingMMIO ||
        completion.window.barrierSourceSequence != 1 ||
        completion.window.barrierSequence != 1 ||
        completion.window.barrierTimestamp != 8 ||
        !completion.transitions.empty() ||
        backend.pending_external_irq_transitions() != 0 ||
        backend.nds_->ExternalBlockingMMIOBarrierPending())
        return false;

    // A handled local-LCD write claims the exact request but does not call the
    // stock melonDS register writer. The caller cannot observe a completion
    // until the replacement close succeeds, which is the FPGA mirror-release
    // point.
    MelonDsBackend lcdWriteBackend;
    melonDS::NDSArgs lcdWriteArgs;
    lcdWriteArgs.JIT = std::nullopt;
    lcdWriteBackend.nds_ = std::make_unique<melonDS::NDS>(
        std::move(lcdWriteArgs), nullptr);
    lcdWriteBackend.nds_->Reset();
    if (!lcdWriteBackend.set_external_time_window_enabled(true, error) ||
        !lcdWriteBackend.advance_and_close_external_time_window(
            0, 20, 0, {3, 1, 0, 10}, window, error))
        return false;
    lcdWriteBackend.nds_->GPU.DispStat[0] = 0;
    const ExternalBlockingMMIORequest lcdWriteRequest{
        3, 1, 0, 20, 0, 1, 1, 10, 8, 7,
        true, true, 1, 0x04000004u, 0x00001238u, 0x020000c0u};
    ExternalBlockingMMIOCompletion lcdWriteCompletion;
    unsigned lcdWriteOrder = 0;
    const ExternalBlockingMMIOPreAccess lcdWritePreAccess =
        [&](std::uint64_t timestamp,
            const ExternalBlockingMMIORequest& exactRequest,
            std::string& hookError) {
            if (lcdWriteOrder != 0 || timestamp != 8 ||
                !exactRequest.write ||
                exactRequest.address != lcdWriteRequest.address ||
                lcdWriteCompletion.window.epoch != 0) {
                hookError = "local-LCD write pre-access hook order mismatch";
                return false;
            }
            lcdWriteOrder = 1;
            return true;
        };
    const ExternalBlockingMMIOExactAccess lcdWriteExactAccess =
        [&](std::uint64_t timestamp,
            const ExternalBlockingMMIORequest& exactRequest,
            ExternalBlockingMMIOOverrideResult& result,
            std::string& hookError) {
            if (lcdWriteOrder != 1 || timestamp != 8 ||
                !exactRequest.write ||
                exactRequest.address != lcdWriteRequest.address ||
                lcdWriteBackend.nds_->GPU.DispStat[0] != 0 ||
                lcdWriteCompletion.window.epoch != 0) {
                hookError = "local-LCD write exact-access hook order mismatch";
                return false;
            }
            lcdWriteOrder = 2;
            result.handled = true;
            return true;
        };
    if (!lcdWriteBackend.execute_external_blocking_mmio_transaction(
            lcdWriteRequest, 30, 0, {3, 2, 1, 10},
            lcdWriteCompletion, error,
            lcdWritePreAccess, lcdWriteExactAccess) ||
        lcdWriteOrder != 2 ||
        lcdWriteBackend.nds_->GPU.DispStat[0] != 0 ||
        lcdWriteCompletion.readData != 0 ||
        lcdWriteCompletion.window.epoch != 3 ||
        !lcdWriteCompletion.window.replacesBlockingMMIO ||
        lcdWriteCompletion.window.barrierTimestamp != 8 ||
        lcdWriteBackend.external_blocking_mmio_barrier_active_ ||
        lcdWriteBackend.nds_->ExternalBlockingMMIOBarrierPending())
        return false;

    // Transitions raised by the access are not externally visible before its
    // replacement close. If that close fails, the whole ungranted tail rolls
    // back to the barrier-begin checkpoint.
    backend.nds_->Reset();
    if (!backend.set_external_time_window_enabled(true, error) ||
        !backend.advance_and_close_external_time_window(
            0, 20, 0, {2, 1, 0, 10}, window, error))
        return false;
    backend.nds_->IF[0] = 1u << melonDS::IRQ_VBlank;
    backend.nds_->UpdateIRQ(0);
    backend.nds_->GPU.GPU3D.GXStat = 0;
    const ExternalBlockingMMIORequest writeRequest{
        2, 1, 0, 20, 0, 1, 1, 10, 8, 7,
        true, true, 2, 0x04000214u,
        1u << melonDS::IRQ_VBlank, 0x02000080u};
    if (!backend.begin_external_blocking_mmio_barrier(
            writeRequest, barrierTimestamp, error) ||
        backend.set_external_time_window_enabled(true, error) ||
        !backend.external_blocking_mmio_barrier_active_ ||
        !backend.bus_write(true, 2, 0x04000214u,
                           1u << melonDS::IRQ_VBlank, 0x02000080u) ||
        backend.external_irq_transitions_.empty() ||
        backend.pending_external_irq_transitions() != 0 ||
        backend.close_and_query_external_time_window(
            std::numeric_limits<std::uint64_t>::max(),
            0, {2, 2, 1, 10}, window, error) ||
        !backend.external_irq_transitions_.empty() ||
        backend.external_blocking_mmio_barrier_active_)
        return false;
    return true;
}

bool MelonDsBackend::self_test_offline_fast_beta()
{
    return melonDS::NDS::SelfTestExternalOfflineFastBeta();
}

void MelonDsBackend::set_halted_peer_advance(bool enabled)
{
    if (nds_) nds_->ExternalHaltedPeerAdvance = enabled;
}

bool MelonDsBackend::gx_fifo_stalled() const
{
    return nds_ && (nds_->CPUStop & melonDS::CPUStop_GXStall) != 0;
}

std::uint64_t MelonDsBackend::gx_command_drops() const
{
    return nds_ ? nds_->GPU.GPU3D.GXCommandDrops : 0;
}

std::uint64_t MelonDsBackend::clip_zero_den() const
{
    return melonDS::NDS4MiSTerClipZeroDen;
}

std::uint64_t MelonDsBackend::clip_interp() const
{
    return melonDS::NDS4MiSTerClipInterp;
}

std::uint64_t MelonDsBackend::gx_invalid_cmd() const
{
    return melonDS::NDS4MiSTerGXInvalidCmd;
}

std::uint64_t MelonDsBackend::gx_executed() const
{
    return melonDS::NDS4MiSTerGXExecuted;
}

bool MelonDsBackend::gxfifo_dma_active() const
{
    return nds_ && nds_->ExternalGXFIFODMAActive();
}

std::string MelonDsBackend::gx_invalid_top() const
{
    std::string out;
    for (int pass = 0; pass < 6; ++pass) {
        int best = -1; unsigned long long bestv = 0;
        for (int i = 0; i < 256; ++i) {
            const auto v = melonDS::NDS4MiSTerGXInvalidHist[i];
            if (v > bestv) { bestv = v; best = i; }
        }
        if (best < 0 || bestv == 0) break;
        char buf[48];
        snprintf(buf, sizeof(buf), "%02x:%llu ", best, bestv);
        out += buf;
        melonDS::NDS4MiSTerGXInvalidHist[best] = 0;
    }
    return out;
}

std::uint64_t MelonDsBackend::advance_system_to_next_event(std::uint64_t bound)
{
    return nds_ ? nds_->AdvanceExternalSystemToNextEvent(bound) : 0;
}

int MelonDsBackend::complete_external_dma(bool arm9)
{
    if (!nds_) return 0;
    const auto mask = arm9 ? melonDS::CPUStop_DMA9 : melonDS::CPUStop_DMA7;
    if ((nds_->CPUStop & mask) == 0) return 0;
    return nds_->CompleteExternalDMA(arm9 ? 0u : 1u) ? 1 : -1;
}

bool MelonDsBackend::attach_external_main_ram(
    std::uint8_t* ram, std::size_t bytes, std::string& error)
{
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }
    if (!ram || bytes != 0x00400000u) {
        error = "external DS main RAM must be exactly 4 MiB";
        return false;
    }
    // Standalone mode never executes melonDS's ARM cores or JIT. Point the
    // peripheral/DMA side at the same physical DDR bytes used by the FPGA
    // CPUs so GPU/DMA reads cannot observe the emulator's stale private copy.
    if (!internal_main_ram_) internal_main_ram_ = nds_->MainRAM;
    nds_->MainRAM = ram;
    nds_->MainRAMMask = static_cast<melonDS::u32>(bytes - 1u);
    return true;
}

bool MelonDsBackend::attach_external_wram(
    std::uint8_t* shared, std::size_t shared_bytes,
    std::uint8_t* arm7, std::size_t arm7_bytes, std::string& error)
{
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }
    if (!shared || shared_bytes != 0x00008000u ||
        !arm7 || arm7_bytes != 0x00010000u) {
        error = "external DS WRAM must be 32 KiB shared plus 64 KiB ARM7";
        return false;
    }
    if (!internal_shared_wram_) internal_shared_wram_ = nds_->SharedWRAM;
    if (!internal_arm7_wram_) internal_arm7_wram_ = nds_->ARM7WRAM;
    nds_->ReplaceWRAMBacking(shared, arm7);
    return true;
}

bool MelonDsBackend::irq_pending(bool arm9) const
{
    if (!nds_) return false;
    return arm9 ? nds_->ARM9.IRQ != 0 : nds_->ARM7.IRQ != 0;
}

bool MelonDsBackend::external_cpu_halted(bool arm9)
{
    if (!nds_) return false;
    auto& cpu = arm9 ? static_cast<melonDS::ARM&>(nds_->ARM9)
                     : static_cast<melonDS::ARM&>(nds_->ARM7);
    // The software CPU is not executed in hybrid mode, so perform the wake
    // transition that ARM::Execute would normally do once an enabled IRQ
    // interrupts HALT. This prevents a stale halt from being reasserted after
    // the FPGA CPU has entered and completed its IRQ handler.
    if (cpu.Halted && nds_->HaltInterrupted(arm9 ? 0u : 1u))
        cpu.Halt(0);
    if (cpu.Halted == 2) {
        const std::uint32_t mask = arm9
            ? (melonDS::CPUStop_DMA9 | melonDS::CPUStop_GXStall)
            : melonDS::CPUStop_DMA7;
        if ((nds_->CPUStop & mask) == 0) cpu.Halt(0);
    }
    return cpu.Halted != 0;
}

int MelonDsBackend::read_audio(std::int16_t* samples, int stereo_frames)
{
    return nds_ ? nds_->SPU.ReadOutput(samples, stereo_frames) : 0;
}

bool MelonDsBackend::set_fpga_audio_offload(bool enable, std::string& error)
{
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }
#if NDS4MISTER_FPGA_AUDIO_OFFLOAD
    nds_->SPU.SetFPGAAudioOffload(enable);
    return true;
#else
    if (enable) {
        error = "responder was not built with NDS4MISTER_FPGA_AUDIO_OFFLOAD";
        return false;
    }
    return true;
#endif
}

FPGAAudioOffloadTelemetry
MelonDsBackend::fpga_audio_offload_telemetry() const
{
    FPGAAudioOffloadTelemetry telemetry;
#if NDS4MISTER_FPGA_AUDIO_OFFLOAD
    if (nds_) {
        const auto stats = nds_->SPU.GetFPGAAudioOffloadStats();
        telemetry.mix_callbacks = stats.MixCallbacks;
        telemetry.hps_render_callbacks = stats.HPSRenderCallbacks;
        telemetry.channel_advance_callbacks =
            stats.ChannelAdvanceCallbacks;
        telemetry.capture_advance_callbacks =
            stats.CaptureAdvanceCallbacks;
    }
#endif
    return telemetry;
}

ExternalTimeWindowProfile MelonDsBackend::external_time_window_profile() const
{
    ExternalTimeWindowProfile result;
#if NDS4MISTER_EXTERNAL_TIME_WINDOW
    static_assert(melonDS::Event_MAX <= result.limiting_event_count.size());
    result.event_count = melonDS::Event_MAX;
    if (nds_) {
        const auto& source = nds_->GetExternalTimeWindowProfile();
        result.closure_count = source.ClosureCount;
        result.finite_bound_limited_count =
            source.FiniteBoundLimitedCount;
        result.no_event_count = source.NoEventCount;
        for (std::size_t i = 0; i < result.event_count; ++i) {
            result.limiting_event_count[i] =
                source.LimitingEventCount[i];
            result.granted_cycles[i] = source.GrantedCycles[i];
        }
    }
#endif
    return result;
}

bool MelonDsBackend::bus_read(bool arm9, unsigned access,
    std::uint32_t address, std::uint32_t& value, std::uint32_t execution_pc)
{
    if (!nds_) return false;
    const bool blockingBarrier =
        nds_->ExternalBlockingMMIOBarrierPending();
    if (blockingBarrier != external_blocking_mmio_barrier_active_) {
        if (blockingBarrier) {
            if (nds_->ClaimExternalBlockingMMIOAccess(
                    arm9 ? 0u : 1u, false, access, address, 0,
                    execution_pc) ==
                melonDS::ExternalTimeWindowResult::Success)
                (void)nds_->FinishExternalBlockingMMIOAccess(false);
        }
        rollback_external_blocking_mmio_barrier();
        return false;
    }
    if (blockingBarrier &&
        nds_->ClaimExternalBlockingMMIOAccess(
            arm9 ? 0u : 1u, false, access, address, 0,
            execution_pc) !=
            melonDS::ExternalTimeWindowResult::Success) {
        rollback_external_blocking_mmio_barrier();
        return false;
    }
    if (blockingBarrier)
        nds_->CurCPU = arm9 ? 0u : 1u;
    if (access > 2) {
        if (blockingBarrier)
            (void)nds_->FinishExternalBlockingMMIOAccess(false);
        rollback_external_blocking_mmio_barrier();
        return false;
    }
    // melonDS enforces BIOS visibility using the executing CPU's R15. Its
    // internal CPUs are dormant in hybrid mode, so synchronize R15 from the
    // FPGA read telemetry before applying the normal memory protection rules.
    if (execution_pc != UINT32_MAX) {
        if (arm9) nds_->ARM9.R[15] = execution_pc;
        else nds_->ARM7.R[15] = execution_pc;
    }
    try {
        if (arm9) {
            if (access == 0) value = nds_->ARM9Read8(address);
            else if (access == 1) value = nds_->ARM9Read16(address);
            else value = nds_->ARM9Read32(address);
        } else {
            if (access == 0) value = nds_->ARM7Read8(address);
            else if (access == 1) value = nds_->ARM7Read16(address);
            else value = nds_->ARM7Read32(address);
        }
    } catch (...) {
        if (blockingBarrier)
            (void)nds_->FinishExternalBlockingMMIOAccess(false);
        rollback_external_blocking_mmio_barrier();
        return false;
    }
    if (!blockingBarrier) return true;
    if (nds_->FinishExternalBlockingMMIOAccess(true) !=
        melonDS::ExternalTimeWindowResult::Success) {
        rollback_external_blocking_mmio_barrier();
        return false;
    }
    return true;
}

bool MelonDsBackend::bus_write(bool arm9, unsigned access,
    std::uint32_t address, std::uint32_t value,
    std::uint32_t execution_pc)
{
    if (!nds_) return false;
    const bool blockingBarrier =
        nds_->ExternalBlockingMMIOBarrierPending();
    if (blockingBarrier != external_blocking_mmio_barrier_active_) {
        if (blockingBarrier) {
            if (nds_->ClaimExternalBlockingMMIOAccess(
                    arm9 ? 0u : 1u, true, access, address, value,
                    execution_pc) ==
                melonDS::ExternalTimeWindowResult::Success)
                (void)nds_->FinishExternalBlockingMMIOAccess(false);
        }
        rollback_external_blocking_mmio_barrier();
        return false;
    }
    if (blockingBarrier &&
        nds_->ClaimExternalBlockingMMIOAccess(
            arm9 ? 0u : 1u, true, access, address, value,
            execution_pc) !=
            melonDS::ExternalTimeWindowResult::Success) {
        rollback_external_blocking_mmio_barrier();
        return false;
    }
    if (blockingBarrier)
        nds_->CurCPU = arm9 ? 0u : 1u;
    if (access > 2) {
        if (blockingBarrier)
            (void)nds_->FinishExternalBlockingMMIOAccess(false);
        rollback_external_blocking_mmio_barrier();
        return false;
    }
    if (execution_pc != UINT32_MAX) {
        if (arm9) nds_->ARM9.R[15] = execution_pc;
        else nds_->ARM7.R[15] = execution_pc;
    }
    try {
        if (arm9) {
            if (access == 0) nds_->ARM9Write8(address, static_cast<melonDS::u8>(value));
            else if (access == 1) nds_->ARM9Write16(address, static_cast<melonDS::u16>(value));
            else nds_->ARM9Write32(address, value);
        } else {
            if (access == 0) nds_->ARM7Write8(address, static_cast<melonDS::u8>(value));
            else if (access == 1) nds_->ARM7Write16(address, static_cast<melonDS::u16>(value));
            else nds_->ARM7Write32(address, value);
        }
    } catch (...) {
        if (blockingBarrier)
            (void)nds_->FinishExternalBlockingMMIOAccess(false);
        rollback_external_blocking_mmio_barrier();
        return false;
    }
    if (!blockingBarrier) return true;
    if (nds_->FinishExternalBlockingMMIOAccess(true) !=
        melonDS::ExternalTimeWindowResult::Success) {
        rollback_external_blocking_mmio_barrier();
        return false;
    }
    return true;
}

bool MelonDsBackend::load_rom(const std::string& path, std::string& error)
{
    melonDS::NDSCart::ROMBuffer rom;
    melonDS::u32 rom_size = 0;
    if (!map_file(path, rom, rom_size, error) && !read_file(path, rom, rom_size, error)) {
        return false;
    }

    auto cart = melonDS::NDSCart::ParseROM(
        std::move(rom),
        rom_size,
        nullptr,
        std::nullopt);
    if (!cart) {
        error = "melonDS failed to parse ROM: " + path;
        return false;
    }

    melonDS::NDSArgs args;
#ifdef JIT_ENABLED
    args.JIT = melonDS::JITArgs{};
#else
    args.JIT = std::nullopt;
#endif
    nds_ = std::make_unique<melonDS::NDS>(std::move(args), nullptr);
    melonDS::RendererSettings rendererSettings{1, true, false, false};
    nds_->GetRenderer().SetRenderSettings(rendererSettings);
    nds_->SetNDSCart(std::move(cart));
    nds_->Reset();
    nds_->SetupDirectBoot(basename(path));
    nds_->Start();

    return true;
}

bool MelonDsBackend::export_direct_boot_image(
    DirectBootImage& image, std::string& error) const
{
    if (!nds_ || !nds_->GetNDSCart()) {
        error = "ROM has not been loaded";
        return false;
    }
    if (nds_->MainRAMMask + 1u < 0x00400000u) {
        error = "melonDS main RAM is smaller than the DS 4 MiB image";
        return false;
    }
    const auto& header = nds_->GetNDSCart()->GetHeader();
    image.main_ram.assign(nds_->MainRAM, nds_->MainRAM + 0x00400000u);
    image.shared_wram.assign(nds_->SharedWRAM, nds_->SharedWRAM + 0x00008000u);
    image.arm7_wram.assign(nds_->ARM7WRAM, nds_->ARM7WRAM + 0x00010000u);
    image.wramcnt = nds_->GetWRAMCnt() & 0x3u;
    image.arm9_entry = header.ARM9EntryAddress;
    image.arm7_entry = header.ARM7EntryAddress;
    // Direct boot installs the game's IRQ dispatcher at the last DTCM word.
    // The FPGA owns a private DTCM BRAM, so carry this non-RAM boot state
    // across explicitly rather than relying on uninitialized block memory.
    std::memcpy(&image.arm9_dtcm_irq_vector,
                nds_->ARM9.DTCM + 0x3ffcu,
                sizeof(image.arm9_dtcm_irq_vector));
    // melonDS direct boot leaves this word zero until the Nintendo SDK startup
    // installs its standard IRQ dispatcher. Hardware can receive its first
    // peripheral IRQ before that local DTCM write becomes observable, and an
    // uninitialized FPGA BRAM word then becomes an arbitrary branch target.
    // Seed the standard SDK ITCM dispatcher entry deterministically; normal
    // ARM9 writes retain ownership and may replace it at any time.  The BIOS
    // branches to the prologue at 0x01ffd5e4.  0x01ffd5ec is merely the first
    // instruction previously visible in coarse telemetry and is eight bytes
    // too late; using it as the vector makes the startup guard reject the
    // game's real 0x01ffd5e4 write forever.
    if (image.arm9_dtcm_irq_vector == 0)
        image.arm9_dtcm_irq_vector = 0x01ffd5e4u;
    return true;
}

bool MelonDsBackend::run_frame(FrameTimings& timings, std::string& error)
{
    if (!nds_) {
        error = "ROM has not been loaded";
        return false;
    }

    const auto start = std::chrono::steady_clock::now();
    nds_->RunFrame();
    const auto end = std::chrono::steady_clock::now();

    const double bucketed = nds_->LastFramePerformance.CPUSeconds
        + nds_->LastFramePerformance.GPUSeconds
        + nds_->LastFramePerformance.AudioSeconds;
    if (bucketed > 0.0) {
        timings.cpu_seconds = nds_->LastFramePerformance.CPUSeconds;
        timings.gpu_seconds = nds_->LastFramePerformance.GPUSeconds;
        timings.audio_seconds = nds_->LastFramePerformance.AudioSeconds;
    } else {
        timings.cpu_seconds = std::chrono::duration<double>(end - start).count();
        timings.gpu_seconds = 0.0;
        timings.audio_seconds = 0.0;
    }
    return true;
}

} // namespace nds4mister
