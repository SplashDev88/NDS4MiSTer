#include "Args.h"
#include "GPU.h"
#include "NDS.h"
#include "replay/ArmCrashDump.h"
#include "replay/ArmVideoShadow.h"
#include "replay/FpgaCrashMonitor.h"
#include "replay/Hybrid3DAbi.h"
#include "replay/Hybrid3DFramePacket.h"
#include "replay/ReplaySpscState.h"

#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/mman.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <utility>
#include <vector>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif

#ifdef __linux__
#include <linux/futex.h>
#include <pthread.h>
#include <sched.h>
#include <sys/syscall.h>
#endif

namespace {

using nds4mister::h3d::AccessWidth;
using nds4mister::h3d::Event;
using nds4mister::h3d::EventType;
using nds4mister::h3d::FaultBadEvent;
using nds4mister::h3d::FaultBadFrame;
using nds4mister::h3d::FaultBadHeader;
using nds4mister::h3d::FaultBadSession;
using nds4mister::h3d::FaultSequenceGap;
using nds4mister::h3d::FaultTornEvent;
using nds4mister::h3d::Header;
using nds4mister::h3d::HeaderSize;
using nds4mister::h3d::PlaneBytes;
using nds4mister::h3d::PlaneHeight;
using nds4mister::h3d::PlanePixels;
using nds4mister::h3d::PlanePublisher;
using nds4mister::h3d::PlaneWidth;
using nds4mister::h3d::QuiesceMagic;
using nds4mister::h3d::ServiceState;
using nds4mister::h3d::event_byte_enable;
using nds4mister::h3d::event_is_arm7;
using nds4mister::h3d::event_timestamp;
using nds4mister::h3d::event_width;
using nds4mister::h3d::load_acquire;
using nds4mister::h3d::make_metadata;
using nds4mister::h3d::store_release;
namespace frame_packet = nds4mister::h3d::frame_packet;

constexpr std::size_t MappingBytes = 0x400000;
constexpr std::size_t Bank0Offset = 0x100000;
constexpr std::size_t Bank1Offset = 0x140000;
constexpr std::size_t FramebufferOffset = 0x200000;
constexpr off_t PhysicalBase = 0x3fc00000;
constexpr std::size_t PublicationMappingBytes = MappingBytes - Bank0Offset;
constexpr off_t PublicationPhysicalBase = PhysicalBase + Bank0Offset;
constexpr const char* PlaneStatsPath = "/tmp/nds-h3d-plane-stats.log";
constexpr const char* PipelineProfilePath =
    "/tmp/nds-h3d-pipeline-profile.log";
// The FPGA fence and replay ring remain occupied for milliseconds. The old
// 50 us retries generated roughly 5,600 polls per second on each HPS CPU and
// consumed about one fifth of each core without advancing either queue.
// Half-millisecond retries remain far below one 16.7 ms display frame while
// reducing that measured scheduler and device-memory polling overhead.
constexpr auto HpsQueuePollInterval = std::chrono::microseconds(500);

#ifdef __linux__
static_assert(
    std::atomic<std::uint32_t>::is_always_lock_free,
    "the Linux replay futex requires lock-free 32-bit atomics");

int replay_futex_wait(
    std::atomic<std::uint32_t>& value, std::uint32_t expected,
    const timespec* timeout)
{
    return static_cast<int>(syscall(
        SYS_futex, reinterpret_cast<std::uint32_t*>(&value),
        FUTEX_WAIT_PRIVATE, expected, timeout, nullptr, 0));
}

void replay_futex_wake(std::atomic<std::uint32_t>& value)
{
    (void)syscall(
        SYS_futex, reinterpret_cast<std::uint32_t*>(&value),
        FUTEX_WAKE_PRIVATE, 1, nullptr, nullptr, 0);
}
#endif

void bind_current_thread_to_cpu(unsigned cpu)
{
#ifdef __linux__
    cpu_set_t affinity;
    CPU_ZERO(&affinity);
    CPU_SET(cpu, &affinity);
    const auto result = pthread_setaffinity_np(
        pthread_self(), sizeof(affinity), &affinity);
    if (result != 0) {
        std::ostringstream message;
        message << "could not bind H3D thread to CPU" << cpu
                << ": " << std::strerror(result);
        throw std::runtime_error(message.str());
    }
#else
    (void)cpu;
#endif
}

void prioritize_current_thread_for_publication()
{
#ifdef __linux__
    // Plane publication owns the display-facing fence for only about 1.1 ms
    // per completed frame, then sleeps while the FPGA consumes that plane.
    // The measured normal-policy worker nevertheless spent 7.2% of wall time
    // runnable but waiting for CPU0, filling and replacing completed frames.
    // Use the least urgent FIFO priority so this bounded copy/fence handoff
    // runs promptly without raising the long replay or renderer work above the
    // rest of the system.
    const int priority = sched_get_priority_min(SCHED_FIFO);
    if (priority < 0) {
        std::ostringstream message;
        message << "could not query H3D publication scheduling priority: "
                << std::strerror(errno);
        throw std::runtime_error(message.str());
    }
    sched_param parameters {};
    parameters.sched_priority = priority;
    const auto result = pthread_setschedparam(
        pthread_self(), SCHED_FIFO, &parameters);
    if (result != 0) {
        std::ostringstream message;
        message << "could not prioritize H3D publication thread: "
                << std::strerror(result);
        throw std::runtime_error(message.str());
    }
#endif
}

static_assert(Bank0Offset + PlaneBytes <= Bank1Offset);
static_assert(Bank1Offset + PlaneBytes <= MappingBytes);
static_assert(
    FramebufferOffset +
        nds4mister::h3d::FullFrameBankCount *
            nds4mister::h3d::FullFrameBankStride ==
    MappingBytes);

volatile std::sig_atomic_t stop_requested = 0;

void request_stop(int)
{
    stop_requested = 1;
}

[[noreturn]] void system_error(const std::string& operation)
{
    throw std::runtime_error(operation + ": " + std::strerror(errno));
}

std::uint64_t parse_count(const char* text, const char* name)
{
    if (!text || !*text || *text == '-')
        throw std::runtime_error(std::string("invalid ") + name);
    char* end = nullptr;
    errno = 0;
    const auto value = std::strtoull(text, &end, 0);
    if (errno || !end || *end)
        throw std::runtime_error(std::string("invalid ") + name);
    return value;
}

class Mapping {
public:
    explicit Mapping(const std::string& path)
    {
        const bool physical = path == "/dev/mem";
        fd_ = open(path.c_str(), O_RDWR | O_SYNC | O_CLOEXEC);
        if (fd_ < 0) system_error("open " + path);

        if (!physical) {
            struct stat status {};
            if (fstat(fd_, &status)) system_error("stat " + path);
            if (status.st_size < static_cast<off_t>(MappingBytes))
                throw std::runtime_error(
                    "memory file is smaller than 0x400000 bytes");
        }

        bytes_ = mmap(
            nullptr, MappingBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd_,
            physical ? PhysicalBase : 0);
        if (bytes_ == MAP_FAILED) {
            bytes_ = nullptr;
            system_error("map " + path);
        }
    }

    Mapping(const Mapping&) = delete;
    Mapping& operator=(const Mapping&) = delete;

    ~Mapping()
    {
        if (bytes_) munmap(bytes_, MappingBytes);
        if (fd_ >= 0) close(fd_);
    }

    void* data() const { return bytes_; }

private:
    int fd_ = -1;
    void* bytes_ = nullptr;
};

// DreamSTer avoids turning every framebuffer word into a separate ordered
// AXI transaction by mapping only its bulk pixel window as Normal
// Non-Cacheable/write-combined memory. Keep H3D control, packet, and ownership
// fields on /dev/mem's Device mapping; an unavailable or incompatible helper
// therefore degrades to the existing known-good path without changing any
// protocol behavior.
class WriteCombinedPublicationMapping {
public:
    explicit WriteCombinedPublicationMapping(bool enabled)
    {
        if (!enabled) return;
        const char* device = "/dev/nds_mem_wc";
        int fd = open(device, O_RDWR | O_SYNC | O_CLOEXEC);
        if (fd < 0) {
            // Also accept DreamSTer's original general-purpose helper when a
            // user already has it installed. The NDS package ships the
            // restricted node above and never requires unrestricted mapping.
            device = "/dev/mem_wc";
            fd = open(device, O_RDWR | O_SYNC | O_CLOEXEC);
        }
        if (fd < 0) {
            std::cerr << "H3D: write-combined device unavailable ("
                      << std::strerror(errno)
                      << "); using Device-memory publication\n";
            return;
        }
        void* mapped = mmap(
            nullptr, PublicationMappingBytes, PROT_READ | PROT_WRITE,
            MAP_SHARED, fd, PublicationPhysicalBase);
        const int map_error = errno;
        close(fd);
        if (mapped == MAP_FAILED) {
            std::cerr << "H3D: " << device << " publication map failed ("
                      << std::strerror(map_error)
                      << "); using Device-memory publication\n";
            return;
        }
        bytes_ = mapped;
        std::cout << "H3D: write-combined 3D publication enabled via "
                  << device << '\n';
    }

    WriteCombinedPublicationMapping(
        const WriteCombinedPublicationMapping&) = delete;
    WriteCombinedPublicationMapping& operator=(
        const WriteCombinedPublicationMapping&) = delete;

    ~WriteCombinedPublicationMapping()
    {
        if (bytes_) munmap(bytes_, PublicationMappingBytes);
    }

    void* data() const { return bytes_; }
    bool active() const { return bytes_ != nullptr; }

private:
    void* bytes_ = nullptr;
};

class SingletonLock {
public:
    SingletonLock()
    {
        fd_ = open(
            "/tmp/nds-hybrid-3d-service.lock",
            O_RDWR | O_CREAT | O_CLOEXEC, 0600);
        if (fd_ < 0) system_error("open service lock");
        if (flock(fd_, LOCK_EX | LOCK_NB))
            system_error("lock hybrid 3D service");
    }

    SingletonLock(const SingletonLock&) = delete;
    SingletonLock& operator=(const SingletonLock&) = delete;

    ~SingletonLock()
    {
        if (fd_ >= 0) close(fd_);
    }

private:
    int fd_ = -1;
};

class CrashHeaderRegistration {
public:
    explicit CrashHeaderRegistration(Header& header)
    {
        nds4mister::crash::set_arm_crash_shared_header(&header);
    }

    CrashHeaderRegistration(const CrashHeaderRegistration&) = delete;
    CrashHeaderRegistration& operator=(const CrashHeaderRegistration&) = delete;

    ~CrashHeaderRegistration()
    {
        nds4mister::crash::set_arm_crash_shared_header(nullptr);
    }
};

enum class PollResult {
    Empty,
    Applied,
    WaitingForFrameAck,
    Fault,
};

enum class SharedPhase {
    Wait,
    Quiesce,
    FreshSession,
    RestartRequired,
};

// A complete DS 3D plane may legitimately become empty, but an empty raster
// while melonDS still has visible render state is derived output that cannot
// replace the last complete plane without producing a full-layer flash.  An
// authoritative clear (no polygons and transparent clear color) publishes
// immediately.  Otherwise require four consecutive empty renders before
// accepting the clear.  This preserves real scene transitions while rejecting
// the alternating populated/empty pattern that makes moving 3D look transparent.
class PlaneVisibilityFilter {
public:
    bool publish(bool has_alpha, bool expected_alpha)
    {
        if (has_alpha) {
            populated_ = true;
            empty_streak_ = 0;
            return true;
        }
        if (!populated_) return true;
        if (!expected_alpha) {
            populated_ = false;
            empty_streak_ = 0;
            return true;
        }
        if (++empty_streak_ < SuspiciousEmptyLimit) return false;
        populated_ = false;
        empty_streak_ = 0;
        return true;
    }

    void reset()
    {
        populated_ = false;
        empty_streak_ = 0;
    }

private:
    static constexpr unsigned SuspiciousEmptyLimit = 4;
    bool populated_ = false;
    unsigned empty_streak_ = 0;
};

// Catch-up may deliberately discard an obsolete polygon build while keeping
// all architectural GX state. The next renderer result can consequently be
// transparent even though the game did not author a clear. Carry that fact
// into PlaneVisibilityFilter's expected-alpha input until a visible render
// proves recovery. Generations prevent completion of an older asynchronous
// render from clearing a discard that arrived while it was running.
class CatchupVisibilityTaint {
public:
    using Generation = std::uint64_t;

    void reset() noexcept
    {
        current_ = 0;
        recovered_ = 0;
    }

    void mark_discarded() noexcept { ++current_; }

    Generation capture_for_render() const noexcept { return current_; }

    bool expected_alpha(
        Generation generation, bool native_expected_alpha) const noexcept
    {
        return native_expected_alpha || generation > recovered_;
    }

    void complete_render(Generation generation, bool has_alpha) noexcept
    {
        if (has_alpha && generation > recovered_) recovered_ = generation;
    }

    bool active() const noexcept { return current_ > recovered_; }

private:
    Generation current_ = 0;
    Generation recovered_ = 0;
};

constexpr bool catchup_should_discard_geometry(
    std::uint32_t render_cadence) noexcept
{
    return render_cadence >= 3;
}

bool plane_has_alpha(const std::uint32_t* pixels)
{
    if (!pixels) return false;
    for (std::size_t index = 0; index < PlanePixels; ++index) {
        if (pixels[index] & 0x1f000000u) return true;
    }
    return false;
}

bool copy_plane_row_and_has_alpha(
    std::uint32_t* destination, const std::uint32_t* source,
    std::size_t pixel_count)
{
    if (!destination || !source) return false;
    std::uint32_t pixel_or = 0;
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
    auto pixel_or_0 = vdupq_n_u32(0);
    auto pixel_or_1 = vdupq_n_u32(0);
    auto pixel_or_2 = vdupq_n_u32(0);
    auto pixel_or_3 = vdupq_n_u32(0);
    std::size_t index = 0;
    for (; index + 16 <= pixel_count; index += 16) {
        const auto pixels_0 = vld1q_u32(source + index);
        const auto pixels_1 = vld1q_u32(source + index + 4);
        const auto pixels_2 = vld1q_u32(source + index + 8);
        const auto pixels_3 = vld1q_u32(source + index + 12);
        vst1q_u32(destination + index, pixels_0);
        vst1q_u32(destination + index + 4, pixels_1);
        vst1q_u32(destination + index + 8, pixels_2);
        vst1q_u32(destination + index + 12, pixels_3);
        pixel_or_0 = vorrq_u32(pixel_or_0, pixels_0);
        pixel_or_1 = vorrq_u32(pixel_or_1, pixels_1);
        pixel_or_2 = vorrq_u32(pixel_or_2, pixels_2);
        pixel_or_3 = vorrq_u32(pixel_or_3, pixels_3);
    }
    pixel_or_0 = vorrq_u32(pixel_or_0, pixel_or_1);
    pixel_or_2 = vorrq_u32(pixel_or_2, pixel_or_3);
    pixel_or_0 = vorrq_u32(pixel_or_0, pixel_or_2);
    alignas(16) std::uint32_t lanes[4];
    vst1q_u32(lanes, pixel_or_0);
    pixel_or = lanes[0] | lanes[1] | lanes[2] | lanes[3];
    for (; index < pixel_count; ++index) {
        const auto pixel = source[index];
        destination[index] = pixel;
        pixel_or |= pixel;
    }
#else
    for (std::size_t index = 0; index < pixel_count; ++index) {
        const auto pixel = source[index];
        destination[index] = pixel;
        pixel_or |= pixel;
    }
#endif
    return (pixel_or & 0x1f000000u) != 0;
}

struct PlaneSample {
    std::uint32_t frame = 0;
    std::uint32_t packet_sequence = 0;
    std::uint32_t polygons = 0;
    std::uint32_t alpha_pixels = 0;
    std::uint16_t alpha_rows = 0;
    std::uint16_t min_x = 0;
    std::uint16_t min_y = 0;
    std::uint16_t max_x = 0;
    std::uint16_t max_y = 0;
    std::uint64_t hash = 0;
};

PlaneSample summarize_plane(
    std::uint32_t frame, std::uint32_t packet_sequence,
    std::uint32_t polygons, const std::uint32_t* pixels)
{
    PlaneSample sample {};
    sample.frame = frame;
    sample.packet_sequence = packet_sequence;
    sample.polygons = polygons;
    sample.min_x = PlaneWidth;
    sample.min_y = PlaneHeight;
    sample.hash = 1469598103934665603ull;
    for (std::uint32_t y = 0; y < PlaneHeight; ++y) {
        bool row_has_alpha = false;
        for (std::uint32_t x = 0; x < PlaneWidth; ++x) {
            const auto pixel = pixels[std::size_t(y) * PlaneWidth + x];
            sample.hash ^= pixel;
            sample.hash *= 1099511628211ull;
            if ((pixel & 0x1f000000u) == 0) continue;
            ++sample.alpha_pixels;
            row_has_alpha = true;
            sample.min_x = std::min<std::uint16_t>(sample.min_x, x);
            sample.min_y = std::min<std::uint16_t>(sample.min_y, y);
            sample.max_x = std::max<std::uint16_t>(sample.max_x, x);
            sample.max_y = std::max<std::uint16_t>(sample.max_y, y);
        }
        sample.alpha_rows += row_has_alpha;
    }
    if (sample.alpha_pixels == 0)
        sample.min_x = sample.min_y = sample.max_x = sample.max_y = 0;
    return sample;
}

SharedPhase inspect_shared_phase(Header& header)
{
    const auto magic = load_acquire(&header.magic);
    if (load_acquire(&header.version) != nds4mister::h3d::Version ||
        load_acquire(&header.header_size) != HeaderSize)
        return SharedPhase::Wait;

    std::uint32_t request = 0;
    if (!nds4mister::h3d::load_counter(
            &header.quiesce_request,
            &header.quiesce_request_reserved, request) ||
        request == 0)
        return SharedPhase::Wait;

    // H3DQ authorizes the replacement service to repair a stale/dirty HPS
    // acknowledgement word.  Do not validate old word15 before classifying
    // this phase; first-use DDR contents are intentionally untrusted.
    if (magic == QuiesceMagic)
        return SharedPhase::Quiesce;
    std::uint32_t acknowledged = 0;
    if (!nds4mister::h3d::load_counter(
            &header.quiesce_ack,
            &header.quiesce_ack_reserved, acknowledged))
        return SharedPhase::Wait;
    if (magic != nds4mister::h3d::Magic || acknowledged != request ||
        load_acquire(&header.fpga_session) == 0)
        return SharedPhase::Wait;

    const auto state = load_acquire(&header.service_state);
    const auto accepted = load_acquire(&header.accepted_session);
    if (state == static_cast<std::uint32_t>(ServiceState::Offline) &&
        accepted == 0)
        return SharedPhase::FreshSession;
    return SharedPhase::RestartRequired;
}

bool acknowledge_quiesce(Header& header)
{
    std::uint32_t request = 0;
    if (load_acquire(&header.magic) != QuiesceMagic ||
        load_acquire(&header.version) != nds4mister::h3d::Version ||
        load_acquire(&header.header_size) != HeaderSize ||
        !nds4mister::h3d::load_counter(
            &header.quiesce_request,
            &header.quiesce_request_reserved, request) ||
        request == 0)
        return false;

    // Once acknowledged, remain strictly read-only. Rewriting the same ack
    // in a polling loop could race the FPGA's subsequent header clearing.
    std::uint32_t acknowledged = 0;
    if (nds4mister::h3d::load_counter(
            &header.quiesce_ack,
            &header.quiesce_ack_reserved, acknowledged) &&
        acknowledged == request)
        return true;

    // This is the HPS's final write for the old generation.  The caller must
    // destroy the renderer and stop every other shared-memory writer first.
    nds4mister::h3d::store_counter(
        &header.quiesce_ack, &header.quiesce_ack_reserved, request);
    return load_acquire(&header.magic) == QuiesceMagic &&
        load_acquire(&header.quiesce_request) == request;
}

bool request_fresh_session(Header& header)
{
    if (inspect_shared_phase(header) != SharedPhase::RestartRequired)
        return false;
    // Publishing RestartRequested is a one-shot request.  Until the FPGA
    // answers with H3DQ this process owns no active renderer generation and
    // must remain read-only; repeatedly rewriting the same state would still
    // race an FPGA-side header transition.
    if (load_acquire(&header.service_state) ==
        static_cast<std::uint32_t>(ServiceState::RestartRequested))
        return true;
    store_release(
        &header.service_state,
        static_cast<std::uint32_t>(ServiceState::RestartRequested));
    return true;
}

class Hybrid3DService {
public:
    static constexpr std::uint32_t HeartbeatPollInterval = 256;
    static constexpr std::size_t MaxTextureTraceRecords = 65536;
    // One buffer may be owned by the FPGA publication fence, one newest
    // completed successor may wait, and one may be filled by the renderer.
    // A deeper FIFO measured as permanent 2D/3D skew (nine frames with the
    // former seven-entry limit), so replace obsolete completed planes instead
    // of smoothing them into the future display stream.
    static constexpr std::size_t PendingPublicationLimit = 1;
    static constexpr std::size_t PublicationBufferCount =
        PendingPublicationLimit + 2;
    static constexpr std::size_t ArmVideoBufferCount = 2;
    using PlaneBuffer = std::array<std::uint32_t, PlanePixels>;
    using FullVideoBuffer = std::array<PlaneBuffer, 2>;

    Hybrid3DService(
        void* mapping, std::size_t mapping_size,
        std::string texture_trace_path = {},
        bool asynchronous_plane_publication = false,
        bool plane_stats_enabled = false,
        bool arm_video_render_shadow = false,
        bool asynchronous_arm_video_replay = false,
        bool pipeline_profile_enabled = false,
        bool bind_hps_worker_cores = false,
        nds4mister::crash::FpgaRuntimeTelemetry* runtime_telemetry = nullptr,
        void* publication_mapping = nullptr,
        bool publication_write_combined = false)
        : mapping_(static_cast<std::byte*>(mapping)),
          publication_mapping_(publication_mapping ?
              static_cast<std::byte*>(publication_mapping) : mapping_),
          separate_publication_mapping_(publication_mapping != nullptr),
          header_(*checked_header(mapping, mapping_size)),
          consumer_(
              mapping, mapping_size,
              !texture_trace_path.empty()),
          publisher_(
              header_, publication_pointer(Bank0Offset),
              publication_pointer(Bank1Offset),
              publication_write_combined),
          full_frame_publisher_(
              header_, publication_pointer(FramebufferOffset)),
          asynchronous_plane_publication_(asynchronous_plane_publication),
          plane_stats_enabled_(plane_stats_enabled),
          arm_video_render_shadow_(arm_video_render_shadow),
          asynchronous_arm_video_replay_(asynchronous_arm_video_replay),
          pipeline_profile_enabled_(pipeline_profile_enabled),
          bind_hps_worker_cores_(bind_hps_worker_cores),
          runtime_telemetry_(runtime_telemetry),
          texture_trace_path_(std::move(texture_trace_path))
    {
        if (!texture_trace_path_.empty()) {
            texture_trace_records_.reserve(MaxTextureTraceRecords);
            completed_texture_trace_.reserve(MaxTextureTraceRecords);
        }
    }

    ~Hybrid3DService()
    {
        stop_replay_worker();
        stop_publication_worker();
        dump_plane_samples();
        dump_pipeline_profile();
        write_texture_trace_dump();
    }

    bool initialize()
    {
        session_ = load_acquire(&header_.fpga_session);
        if (!session_) return fail(FaultBadSession, "zero FPGA session");
        if (!shared_session_current(false))
            return fail(FaultBadSession, "H3D1 session is not stable");
        store_release(
            &header_.service_state,
            static_cast<std::uint32_t>(ServiceState::Initializing));
        if (!reset_machine()) return false;
        if (!consumer_.initialize(session_)) {
            error_ = "frame-packet consumer rejected the H3D1 session";
            return false;
        }
        if (!shared_session_current(false))
            return fail(FaultBadSession, "H3D1 changed during initialization");
        store_release(&header_.accepted_session, session_);
        store_release(
            &header_.service_state,
            static_cast<std::uint32_t>(ServiceState::Ready));
        if (asynchronous_plane_publication_)
            start_publication_worker();
        if (asynchronous_arm_video_replay_)
            start_replay_worker();
        heartbeat(true);
        return true;
    }

    PollResult poll()
    {
        if (faulted_.load(std::memory_order_acquire))
            return PollResult::Fault;
        if (publication_worker_faulted())
            return fail_result(FaultBadFrame, publication_worker_error());
        if (asynchronous_arm_video_replay_)
            return poll_replay_input();
        if (!shared_session_current(true))
            return fail_result(
                FaultBadSession, "H3D1 session changed during packet polling");
        heartbeat();

        if (!asynchronous_plane_publication_ && frame_pending_)
            return finish_frame_event();

        if (!packet_pending_) {
            if (!consumer_.begin(packet_header_)) {
                if (consumer_.local_faults()) {
                    return consumer_fault_result(
                        "frame-packet consumer rejected a packet");
                }
                // When authoritative input has caught up, collect a render
                // that was started at the preceding VBlank. If another
                // packet is already available we deliberately leave the ARM
                // render worker running while it is copied and applied.
                if (arm_render_pending_) {
                    if (!finish_arm_render()) return PollResult::Fault;
                    return PollResult::Applied;
                }
                return PollResult::Empty;
            }
            if (!shared_session_current(true))
                return fail_result(
                    FaultBadSession,
                    "H3D1 changed while acquiring a frame packet");
            packet_pending_ = true;
        }

        frame_packet::Record record {};
        while (consumer_.next_record(record)) {
            const auto kind = frame_packet::record_kind(record);
            const bool final_record =
                consumer_.applied_record_count() + 1 ==
                consumer_.pending_record_count();
            if (kind == frame_packet::RecordKind::GxPacked) {
                if (!valid_packed_gx_record(record))
                    return fail_result(
                        FaultBadEvent, "invalid packed GX record");
                for (std::size_t index = 0; index < 3; ++index) {
                    if (frame_packet::packed_gx_tag(record, index) != 0x50)
                        continue;
                    if (index != 2 ||
                        packet_header_.flags !=
                            frame_packet::FlagFrameEnd ||
                        !final_record)
                        return fail_result(
                            FaultBadFrame,
                            "packed SWAP_BUFFERS was not the final command");
                }
            } else if (kind == frame_packet::RecordKind::GxCommand &&
                       frame_packet::record_tag(record) == 0x50) {
                if (packet_header_.flags != frame_packet::FlagFrameEnd ||
                    !final_record)
                    return fail_result(
                        FaultBadFrame,
                        "SWAP_BUFFERS was not the final FRAME_END record");
            }
            if (!texture_record_fits(record)) return PollResult::Fault;
            if (!apply(record)) return PollResult::Fault;
            if (!consumer_.record_applied())
                return fail_result(
                    FaultBadEvent, "frame-packet record acknowledgement failed");
            if (!retain_texture_record(record)) return PollResult::Fault;
            events_applied_ +=
                kind == frame_packet::RecordKind::GxPacked ? 3 : 1;
            // A single packet can contain thousands of records. Count that
            // successful progress toward the existing throttled heartbeat so
            // one long packet poll cannot look dead to the FPGA watchdog.
            heartbeat();
        }
        flush_pending_geometry();
        flush_external_vram_revisions();

        if (packet_header_.flags == frame_packet::FlagContinuation) {
            if (packet_saw_swap_)
                return fail_result(
                    FaultBadFrame,
                    "continuation packet contained SWAP_BUFFERS");
            // melonDS narrows the elapsed geometry interval to signed 32 bits.
            // Bound that interval once per full packet so an arbitrarily long
            // VRAM-only continuation chain cannot wrap it before FRAME_END.
            nds_->GPU.GPU3D.Run();
            if (!shared_session_current(true))
                return fail_result(
                    FaultBadSession,
                    "H3D1 changed before continuation acknowledgement");
            if (!consumer_.acknowledge())
                return consumer_fault_result(
                    "continuation packet acknowledgement failed");
            packet_pending_ = false;
            ++packets_applied_;
            return PollResult::Applied;
        }
        if (packet_header_.flags != frame_packet::FlagFrameEnd)
            return fail_result(FaultBadEvent, "invalid frame-packet flags");
        if (!texture_trace_path_.empty() &&
            !consumer_.terminal_diagnostic_verified())
            return fail_result(
                FaultBadEvent, "terminal packet lacks verified H3V1 data");
        if (!texture_trace_matches_verifier()) return PollResult::Fault;
        // An explicitly armed trace still requires H3V1. Production does not
        // retain the completed diagnostic harness or pay its per-record cost.
        complete_texture_trace();

        const auto disposition = frame_disposition();
        if (disposition == FrameDisposition::Fault) return PollResult::Fault;
        const bool render = disposition == FrameDisposition::Render;
        const auto terminal_frame = packet_header_.frame;
        // melonDS normally finishes frame N before latching frame N+1 at
        // VBlank.  Preserve that ordering while allowing all intervening
        // packet copy/application work to overlap its software rasterizer.
        if (!arm_video_render_shadow_ &&
            arm_render_pending_ && !finish_arm_render())
            return PollResult::Fault;
        if (!arm_video_render_shadow_ &&
            !advance_frame_boundary(terminal_frame))
            return PollResult::Fault;

        // The packet is authoritative input; the return plane is derived
        // display output. Once Run/VBlank and the H3V1-verified records are
        // complete, release the H3B slot before the optional synchronous
        // renderer/copy/publisher can hold producer credit across VBlanks.
        // acknowledge_terminal_packet() performs the fresh lifecycle fence
        // immediately before its sole shared ownership transfer. No slot data
        // is accessed below this point.
        const auto acknowledge_result = acknowledge_terminal_packet();
        if (acknowledge_result != PollResult::Applied)
            return acknowledge_result;
        if (arm_video_render_shadow_) return acknowledge_result;
        if (!render) return acknowledge_result;
        // The renderer runs on its own worker and is substantially faster
        // than the DS frame cadence.  Do not suppress a render merely because
        // the producer published newer authoritative input while this packet
        // was being copied and applied: that policy turned harmless producer
        // lead into deliberate one-in-several-frame display decimation.  The
        // plane fence remains the sole fail-soft output drop authority.
        if (!start_arm_render(
                terminal_frame, packet_header_.packet_sequence))
            return PollResult::Fault;
        if (asynchronous_plane_publication_) return PollResult::Applied;
        return finish_frame_event();
    }

    const std::string& error() const { return error_; }
    std::uint64_t events_applied() const { return events_applied_; }
    std::uint64_t frames_published() const
    {
        return frames_published_.load(std::memory_order_relaxed);
    }
    std::uint64_t frames_rendered() const
    {
        return frames_rendered_.load(std::memory_order_relaxed);
    }
    std::uint64_t identical_plane_republications() const
    {
        return identical_plane_republications_.load(
            std::memory_order_relaxed);
    }
    std::uint64_t replay_packets_applied() const
    {
        return replay_packets_applied_.load(std::memory_order_acquire);
    }
    std::uint64_t replay_slot_capacity_growths() const
    {
        return replay_slot_capacity_growths_.load(std::memory_order_relaxed);
    }
    std::uint64_t replay_slot_reuses() const
    {
        return replay_slot_reuses_.load(std::memory_order_relaxed);
    }
    std::uint64_t publication_queue_replacements() const
    {
        return publication_queue_replacements_.load(
            std::memory_order_relaxed);
    }
    std::size_t publication_queue_high_water() const
    {
        return publication_queue_high_water_.load(
            std::memory_order_relaxed);
    }
    bool session_current() const { return shared_session_current(true); }
    melonDS::NDS& nds() { return *nds_; }
    const nds4mister::ArmVideoShadow& arm_video_shadow() const {
        return arm_video_shadow_;
    }
    bool arm_video_frame_ready() const noexcept {
        return arm_video_frame_ready_;
    }
    std::uint32_t arm_video_frame() const noexcept {
        return arm_video_frame_;
    }
    std::uint32_t arm_video_pixel(
        std::size_t screen, std::size_t x, std::size_t y) const
    {
        if (screen >= 2 || x >= PlaneWidth || y >= PlaneHeight ||
            arm_video_completed_index_ < 0)
            throw std::out_of_range("ARM video pixel is out of bounds");
        return arm_video_frames_[arm_video_completed_index_][screen]
            [y * PlaneWidth + x];
    }

private:
    struct ReplayPacket {
        frame_packet::PacketHeader header {};
        std::vector<frame_packet::Record> records;
    };

    // Beta100's NSMB map transition latched the FPGA console-source overflow
    // fault while the ARM process remained healthy. The final shared state
    // had drained producer==consumer, identifying a transient admission burst
    // rather than a dead replay worker. The former 256-packet local queue can
    // stop H3B acknowledgements long enough to fill the FPGA's exact VBlank
    // boundary queue. Doubling the logical wait queue keeps input ownership
    // moving while the existing frame-lead policy catches the replay worker
    // up. One additional physical slot is the worker-owned head; this
    // preserves the original limit of 512 waiting packets plus one active
    // packet while every vector allocation remains attached to recycled arena
    // storage.
    static constexpr std::size_t ReplayQueueCapacity = 512;
    static constexpr std::size_t ReplayArenaCapacity =
        ReplayQueueCapacity + 1;
    // Keep normal all-frame rendering while replay is current. Source-frame
    // lead, rather than packet count, is the authoritative audio/video age:
    // one source frame can span many continuation packets. Catch up more
    // aggressively as age grows, but always render at least one boundary
    // between omissions so moving 3D never turns into a clustered freeze.
    // Adaptive-v2 is the currently deployed smooth baseline. It preserves all
    // command/state replay and reduces only derived renders when either source
    // frame age or the private packet queue demonstrates sustained pressure.
    // The thresholds below were recovered and verified against the deployed
    // ARM binary before adding dual-core rasterization, so this A/B changes no
    // catch-up policy at the same time as the renderer implementation.
    // The dual-core renderer measured 57.3 published FPS against a 60.0 FPS
    // source in NSMB's final castle. Waiting for the old 32-frame pressure
    // point therefore stabilized smooth output roughly half a second late.
    // NSMB play testing showed the remaining age as rubber-banding: a heavy
    // on-screen interval accumulated a few derived 3D frames, then rapidly
    // displayed them when geometry moved off screen. Scale render cadence at
    // 2/4/8/16 frames of source lead so replay still applies every command in
    // order but does not visibly fast-forward through obsolete render output.
    // Packet thresholds remain deliberately unchanged as the independent
    // transport-burst safety valve.
    static constexpr std::uint32_t ReplayCatchupHalfFrames = 2;
    static constexpr std::uint32_t ReplayCatchupThirdFrames = 4;
    static constexpr std::uint32_t ReplayCatchupQuarterFrames = 8;
    static constexpr std::uint32_t ReplayCatchupEighthFrames = 16;
    static constexpr std::size_t ReplayCatchupHalfPackets = 64;
    static constexpr std::size_t ReplayCatchupThirdPackets = 128;
    static constexpr std::size_t ReplayCatchupQuarterPackets = 256;
    static constexpr std::size_t ReplayCatchupEighthPackets = 384;
    // Diagnostic pressure valve: the old fast pipelined ARM-video run stayed
    // near the DS cadence with an 87% render-skip rate and never filled its
    // replay queue. Preserve every state transition, but derive only one
    // complete display frame per eight source frames so the FPGA can repeat
    // the last completed bank while authoritative input catches up.
    static constexpr std::uint32_t ReplayRenderCadence = 8;

    static Header* checked_header(void* mapping, std::size_t mapping_size)
    {
        if (!mapping || mapping_size < MappingBytes)
            throw std::runtime_error("H3D1 mapping is smaller than 0x400000 bytes");
        return static_cast<Header*>(mapping);
    }

    std::uint32_t* publication_pointer(std::size_t offset) const
    {
        if (!separate_publication_mapping_)
            return reinterpret_cast<std::uint32_t*>(mapping_ + offset);
        if (offset < Bank0Offset || offset >= MappingBytes)
            throw std::runtime_error(
                "publication pointer is outside the mapped pixel window");
        return reinterpret_cast<std::uint32_t*>(
            publication_mapping_ + (offset - Bank0Offset));
    }

    bool reset_machine()
    {
        // A session reset is a hard boundary. Release every resource from the
        // prior emulation instance before a replacement can become visible.
        nds_.reset();
        melonDS::NDSArgs args;
        args.JIT = std::nullopt;
        nds_ = std::make_unique<melonDS::NDS>(std::move(args), nullptr);
        nds_->Reset();
        nds_->GPU.GPU3D.SetEnabled(true, true);
        nds_->GPU.GPU3D.SetExternalCommandReplay(true);
        // This service always publishes melonDS's native software output.
        // HiresPosition is only read by its OpenGL/compute renderers, while
        // calculating it costs two 64-bit divisions for every accepted
        // vertex on the Cortex-A9.
        nds_->GPU.GPU3D.SetHighResolutionCoordinatesEnabled(false);
        arm_video_shadow_ = nds4mister::ArmVideoShadow {};
        if (asynchronous_plane_publication_ || arm_video_render_shadow_) {
            // Restore the measured fast ARM-video split: CPU0 rasterizes the
            // preceding 3D frame while CPU1 replays commands and draws 2D.
            // Do not also start the engine-B helper on CPU0; two renderer
            // workers competing there made complete frames slower. The later
            // polygon-RAM fences and complete-frame publication remain the
            // ownership boundary for this pipelined 3D worker.
            constexpr bool Threaded3D = true;
            constexpr bool Parallel2D = false;
            const bool FullFrame3D = !arm_video_render_shadow_;
            melonDS::RendererSettings settings {
                1, Threaded3D, false, false,
                arm_video_render_shadow_,
                Parallel2D, arm_video_render_shadow_,
                pipeline_profile_enabled_, FullFrame3D};
            auto& renderer = nds_->GPU.GetRenderer();
            renderer.SetRenderSettings(settings);
            if (Threaded3D) {
                // SoftRenderer3D::SetThreaded() starts one render job while
                // enabling its worker. Consume that job's complete-frame
                // fence before the first real H3D frame. The plane-only path
                // intentionally does not publish per-scanline tokens.
                renderer.Finish3DRendering();
                for (std::uint32_t y = 0; y < PlaneHeight; ++y) {
                    if (!renderer.Get3DScanline(y))
                        return fail(
                            FaultBadFrame,
                            "melonDS startup 3D render returned a null line");
                }
            }
        }
        last_timestamp_ = 0;
        have_timestamp_ = false;
        frame_pending_ = false;
        packet_pending_ = false;
        packet_saw_swap_ = false;
        packet_timestamp_ = 0;
        pending_geometry_commands_ = 0;
        pending_external_vram_mask_ = 0;
        arm_render_pending_ = false;
        arm_render_expected_alpha_ = false;
        arm_render_visibility_generation_ = 0;
        arm_video_phase_started_ = false;
        arm_video_renderer_started_ = false;
        arm_video_render_in_flight_ = false;
        arm_video_render_this_frame_ = false;
        arm_video_skipped_frames_ = 0;
        arm_video_frame_ready_ = false;
        arm_video_frame_ = 0;
        arm_video_completed_index_ = -1;
        pending_frame_expected_alpha_ = false;
        plane_visibility_filter_.reset();
        completed_plane_generation_ = 0;
        published_plane_generation_.store(0, std::memory_order_relaxed);
        texture_trace_records_.clear();
        completed_texture_trace_.clear();
        texture_trace_state_ = frame_packet::DiagnosticCrcInitial;
        completed_trace_valid_ = false;
        replay_read_index_ = 0;
        replay_write_index_ = 0;
        replay_state_.reset();
        replay_queue_high_water_.store(0, std::memory_order_relaxed);
        latest_replay_frame_.store(0, std::memory_order_relaxed);
        replay_render_skip_countdown_ = 0;
        replay_render_cadence_ = 1;
        catchup_visibility_taint_.reset();
        replay_frame_active_ = false;
        replay_frame_skip_render_ = false;
        replay_frame_discard_geometry_ = false;
        replay_active_frame_ = 0;
        replay_geometry_discard_frames_ = 0;
        replay_stop_.store(false, std::memory_order_relaxed);
        replay_packets_applied_.store(0, std::memory_order_relaxed);
        replay_slot_capacity_growths_.store(0, std::memory_order_relaxed);
        replay_slot_reuses_.store(0, std::memory_order_relaxed);
        publication_active_index_ = -1;
        publication_filling_index_ = -1;
        publication_queue_read_index_ = 0;
        publication_queue_write_index_ = 0;
        publication_queue_count_ = 0;
        publication_queue_high_water_.store(0, std::memory_order_relaxed);
        if (runtime_telemetry_) runtime_telemetry_->reset(session_);
        return true;
    }

    std::uint32_t replay_queue_count() const noexcept
    {
        return replay_state_.count();
    }

    bool replay_queue_has_capacity()
    {
        const auto snapshot = replay_state_.consumer_snapshot();
        const auto published = snapshot.published;
        auto claimed = snapshot.claimed;
        if (published - claimed != ReplayQueueCapacity)
            return true;

        const auto full_polls = replay_queue_full_polls_.fetch_add(
            1, std::memory_order_relaxed) + 1;
#ifdef __linux__
        // The HPS queue count is also its futex word. FUTEX_WAIT closes the
        // dequeue-before-sleep race by checking the count in the kernel, so a
        // saturated producer parks without mutex arbitration or periodic
        // scheduler polling on the replay CPU.
        const timespec timeout {0, 1000000};
        (void)replay_futex_wait(
            replay_state_.claimed_word(), claimed, &timeout);
#else
        std::unique_lock<std::mutex> lock(replay_mutex_);
        replay_cv_.wait_for(
            lock, std::chrono::milliseconds(1), [this] {
                return replay_stop_.load(std::memory_order_acquire) ||
                    replay_queue_count() != ReplayQueueCapacity;
            });
#endif
        if ((full_polls & 31u) == 0) publish_runtime_telemetry();
        claimed = replay_state_.consumer_snapshot().claimed;
        return published - claimed != ReplayQueueCapacity;
    }

    PollResult poll_replay_input()
    {
        if (!shared_session_current(true))
            return fail_result(
                FaultBadSession, "H3D1 session changed during packet polling");
        heartbeat();

        // Ownership can advance only after the complete immutable packet has
        // room in the local replay ring. The worker is the sole reader and can
        // only reduce this count, so one pre-begin capacity check is enough.
        if (!replay_queue_has_capacity()) {
            return PollResult::Empty;
        }

        // The producer exclusively owns the current free tail slot until it
        // publishes queue_count below. ReplayArenaCapacity has one more slot
        // than the bounded wait queue, so write_index cannot wrap onto the
        // worker-owned active head.
        auto& packet = replay_queue_[replay_write_index_];
        const auto slot_capacity_before = packet.records.capacity();
        if (!consumer_.begin(packet_header_, packet.records)) {
            if (consumer_.local_faults())
                return consumer_fault_result(
                    "frame-packet consumer rejected a packet");
            return PollResult::Empty;
        }
        if (!shared_session_current(true))
            return fail_result(
                FaultBadSession,
                "H3D1 changed while acquiring a frame packet");
        packet_pending_ = true;
        auto input_started = std::chrono::steady_clock::time_point {};
        if (pipeline_profile_enabled_)
            input_started = std::chrono::steady_clock::now();

        packet.header = packet_header_;
        bool saw_swap = false;
        for (std::size_t index = 0; index < packet.records.size(); ++index) {
            const auto& record = packet.records[index];
            const bool final_record = index + 1 == packet.records.size();
            if (saw_swap)
                return fail_result(
                    FaultBadFrame,
                    "record followed SWAP_BUFFERS in one frame packet");
            const auto kind = frame_packet::record_kind(record);
            if (kind == frame_packet::RecordKind::GxPacked) {
                if (!valid_packed_gx_record(record))
                    return fail_result(
                        FaultBadEvent, "invalid packed GX record");
                for (std::size_t command_index = 0;
                     command_index < 3; ++command_index) {
                    if (frame_packet::packed_gx_tag(
                            record, command_index) != 0x50)
                        continue;
                    if (command_index != 2 ||
                        packet_header_.flags !=
                            frame_packet::FlagFrameEnd ||
                        !final_record)
                        return fail_result(
                            FaultBadFrame,
                            "packed SWAP_BUFFERS was not the final command");
                    saw_swap = true;
                }
            } else if (kind == frame_packet::RecordKind::GxCommand) {
                if (!valid_gx_record(record))
                    return fail_result(
                        FaultBadEvent, "invalid normalized GX command record");
                if (frame_packet::record_tag(record) == 0x50) {
                    if (packet_header_.flags !=
                            frame_packet::FlagFrameEnd ||
                        !final_record)
                        return fail_result(
                            FaultBadFrame,
                            "SWAP_BUFFERS was not the final FRAME_END record");
                    saw_swap = true;
                }
            }
            if (!texture_record_fits(record)) return PollResult::Fault;
            if (!retain_texture_record(record)) return PollResult::Fault;
            events_applied_ +=
                kind == frame_packet::RecordKind::GxPacked ? 3 : 1;
            heartbeat();
        }

        if (packet_header_.flags == frame_packet::FlagContinuation) {
            if (saw_swap)
                return fail_result(
                    FaultBadFrame,
                    "continuation packet contained SWAP_BUFFERS");
        } else if (packet_header_.flags == frame_packet::FlagFrameEnd) {
            if (!texture_trace_path_.empty() &&
                !consumer_.terminal_diagnostic_verified())
                return fail_result(
                    FaultBadEvent,
                    "terminal packet lacks verified H3V1 data");
            if (!texture_trace_matches_verifier()) return PollResult::Fault;
            complete_texture_trace();
        } else {
            return fail_result(
                FaultBadEvent, "invalid frame-packet flags");
        }

        if (!consumer_.accept_all_records())
            return fail_result(
                FaultBadEvent,
                "frame-packet batch acknowledgement failed");

        if (!shared_session_current(true))
            return fail_result(
                FaultBadSession,
                "H3D1 changed before queued packet acknowledgement");
        if (!consumer_.acknowledge())
            return consumer_fault_result(
                "queued frame packet acknowledgement failed");
        packet_pending_ = false;
        ++packets_applied_;

        if (packet.records.capacity() > slot_capacity_before)
            replay_slot_capacity_growths_.fetch_add(
                1, std::memory_order_relaxed);
        else
            replay_slot_reuses_.fetch_add(1, std::memory_order_relaxed);

        const auto record_count = packet.records.size();
        replay_write_index_ =
            (replay_write_index_ + 1) % ReplayArenaCapacity;
        // Release-publish the completely populated slot. Only the producer
        // writes this cache-line-separated index; the replay worker's acquire
        // load makes every header/vector write visible without a contended
        // counter RMW or replay_mutex_ on each packet.
        const auto publication = replay_state_.publish(packet_header_.frame);
        const auto queue_count = publication.count();
        const auto high_water = replay_queue_high_water_.load(
            std::memory_order_relaxed);
        if (queue_count > high_water)
            replay_queue_high_water_.store(
                queue_count, std::memory_order_relaxed);
        if (pipeline_profile_enabled_) {
            replay_input_records_.fetch_add(
                record_count, std::memory_order_relaxed);
            record_profile_sample(
                replay_input_packets_, replay_input_total_ns_,
                replay_input_max_ns_, input_started);
        }
        if (queue_count == 1) {
#ifdef __linux__
            replay_futex_wake(replay_state_.published_word());
#else
            // Serialize only the empty-to-nonempty transition with a worker
            // that may be between its predicate check and sleep. Backlogged
            // packets never enter this mutex path.
            std::lock_guard<std::mutex> lock(replay_mutex_);
            replay_cv_.notify_one();
#endif
        }
        return PollResult::Applied;
    }

    void enqueue_trusted_replay_geometry_command(
        std::uint8_t command, std::uint32_t data)
    {
        // poll_replay_input() validated this immutable private packet before
        // acknowledging its shared H3B slot. Rechecking every command here
        // made the replay worker validate the same high-volume GX stream two
        // more times after ownership had already transferred.
        if (command == 0x50) packet_saw_swap_ = true;
        nds_->GPU.GPU3D.WriteExternalNormalizedCommand(command, data);
    }

    bool enqueue_replay_geometry_command(
        std::uint8_t command, std::uint32_t data)
    {
        if (!valid_gx_command(command) || (command == 0 && data != 0))
            return fail(FaultBadEvent, "invalid normalized GX command record");
        if (packet_saw_swap_)
            return fail(
                FaultBadEvent,
                "record followed SWAP_BUFFERS in one frame packet");
        enqueue_trusted_replay_geometry_command(command, data);
        return true;
    }

    bool enqueue_replay_geometry_record(
        const frame_packet::Record& record)
    {
        if (!valid_gx_record(record))
            return fail(FaultBadEvent, "invalid normalized GX command record");
        return enqueue_replay_geometry_command(
            frame_packet::record_tag(record),
            static_cast<std::uint32_t>(record.data));
    }

    static bool geometry_record_kind(frame_packet::RecordKind kind)
    {
        return kind == frame_packet::RecordKind::GxCommand ||
            kind == frame_packet::RecordKind::GxPacked;
    }

    bool apply_replay_geometry_run(
        const frame_packet::Record* records, std::size_t count)
    {
        if (!records || count == 0)
            return fail(FaultBadEvent, "empty mixed GX command run");

        // A preceding VRAM run must publish its texture-cache revision before
        // geometry can consume it. Packed and unpacked GX records are merely
        // two encodings of the same ordered stream, so one mixed run may cross
        // those encoding boundaries without changing any hardware ordering.
        flush_external_vram_revisions();

        constexpr std::uint64_t RawArm9ClockStep = 1u << 16;
        const auto step =
            RawArm9ClockStep >> nds_->ARM9ClockShift;
        const auto limit =
            std::numeric_limits<std::uint64_t>::max() >>
            nds_->ARM9ClockShift;
        if (step == 0 || packet_timestamp_ > limit)
            return fail(FaultBadEvent, "mixed GX run initial timestamp overflow");

        std::size_t command_count = 0;
        for (std::size_t index = 0; index < count; ++index) {
            const auto kind = frame_packet::record_kind(records[index]);
            if (!geometry_record_kind(kind))
                return fail(FaultBadEvent, "non-GX record in mixed GX run");
            const std::size_t added =
                kind == frame_packet::RecordKind::GxPacked ? 3 : 1;
            if (command_count >
                std::numeric_limits<std::size_t>::max() - added)
                return fail(FaultBadEvent, "mixed GX command count overflow");
            command_count += added;
        }
        if (command_count > (limit - packet_timestamp_) / step)
            return fail(FaultBadEvent, "mixed GX run timestamp overflow");

        const auto enqueue = [this, step](
                                 std::uint8_t command,
                                 std::uint32_t data) {
            enqueue_trusted_replay_geometry_command(command, data);
            packet_timestamp_ += step;
            ++pending_geometry_commands_;
            last_timestamp_ = packet_timestamp_;
            have_timestamp_ = true;
            if (pending_geometry_commands_ == GeometryRunBatch)
                flush_pending_geometry();
        };

        for (std::size_t record_index = 0;
             record_index < count; ++record_index) {
            const auto& record = records[record_index];
            if (frame_packet::record_kind(record) ==
                frame_packet::RecordKind::GxCommand) {
                enqueue(
                    frame_packet::record_tag(record),
                    static_cast<std::uint32_t>(record.data));
                continue;
            }
            for (std::size_t command_index = 0;
                 command_index < 3; ++command_index) {
                enqueue(
                    frame_packet::packed_gx_tag(record, command_index),
                    frame_packet::packed_gx_data(record, command_index));
            }
        }
        return true;
    }

    bool apply_replay_packet(const ReplayPacket& packet)
    {
        replay_packet_frame_ = packet.header.frame;
        packet_saw_swap_ = false;
        std::size_t index = 0;
        while (index != packet.records.size()) {
            const auto kind = frame_packet::record_kind(packet.records[index]);
            const auto kind_index =
                static_cast<std::uint32_t>(kind) - 1u;
            std::size_t run_end = index + 1;
            if (geometry_record_kind(kind)) {
                while (run_end != packet.records.size() &&
                       geometry_record_kind(frame_packet::record_kind(
                           packet.records[run_end])))
                    ++run_end;
            } else {
                while (run_end != packet.records.size() &&
                       frame_packet::record_kind(packet.records[run_end]) ==
                           kind)
                    ++run_end;
            }

            auto kind_run_started = std::chrono::steady_clock::time_point {};
            if (pipeline_profile_enabled_) {
                kind_run_started = std::chrono::steady_clock::now();
                if (!geometry_record_kind(kind) &&
                    kind_index < replay_record_kind_counts_.size())
                    replay_record_kind_counts_[kind_index] += run_end - index;
                if (geometry_record_kind(kind)) {
                    for (std::size_t record_index = index;
                         record_index < run_end; ++record_index)
                    {
                        const auto record_kind = frame_packet::record_kind(
                            packet.records[record_index]);
                        const auto record_kind_index =
                            static_cast<std::uint32_t>(record_kind) - 1u;
                        if (record_kind_index <
                            replay_record_kind_counts_.size())
                            ++replay_record_kind_counts_[record_kind_index];
                        if (record_kind ==
                            frame_packet::RecordKind::GxCommand) {
                            ++replay_gx_command_counts_[
                                frame_packet::record_tag(
                                    packet.records[record_index])];
                        } else {
                            for (std::size_t command_index = 0;
                                 command_index < 3; ++command_index)
                                ++replay_gx_command_counts_[
                                    frame_packet::packed_gx_tag(
                                        packet.records[record_index],
                                        command_index)];
                        }
                    }
                }
            }

            if (geometry_record_kind(kind)) {
                if (!apply_replay_geometry_run(
                        packet.records.data() + index, run_end - index))
                    return false;
            } else {
                for (std::size_t record_index = index;
                     record_index < run_end; ++record_index) {
                    if (!apply(packet.records[record_index])) return false;
                }
            }
            if (pipeline_profile_enabled_ &&
                kind_index < replay_kind_run_total_ns_.size())
                record_kind_run(kind_index, kind_run_started);
            if (packet_saw_swap_ && run_end != packet.records.size())
                return fail(
                    FaultBadFrame,
                    "record followed queued SWAP_BUFFERS");
            index = run_end;
        }

        // No renderer can observe state between adjacent replay packets, but
        // publish the final run's cache revision before a packet boundary can
        // run geometry or complete a frame.
        auto boundary_started = std::chrono::steady_clock::time_point {};
        if (pipeline_profile_enabled_)
            boundary_started = std::chrono::steady_clock::now();
        flush_pending_geometry();
        flush_external_vram_revisions();

        if (packet.header.flags == frame_packet::FlagContinuation) {
            if (packet_saw_swap_)
                return fail(
                    FaultBadFrame,
                    "queued continuation contained SWAP_BUFFERS");
            // Keep melonDS's signed geometry interval bounded even while the
            // input owner is several packets ahead of this replay worker.
            auto run_started = std::chrono::steady_clock::time_point {};
            if (pipeline_profile_enabled_)
                run_started = std::chrono::steady_clock::now();
            nds_->GPU.GPU3D.Run();
            if (pipeline_profile_enabled_)
                record_plain_profile_sample(
                    replay_continuation_runs_,
                    replay_continuation_run_total_ns_,
                    replay_continuation_run_max_ns_, run_started);
        } else if (packet.header.flags != frame_packet::FlagFrameEnd) {
            return fail(FaultBadEvent, "invalid queued frame-packet flags");
        }
        if (pipeline_profile_enabled_)
            record_plain_profile_sample(
                replay_packet_boundaries_, replay_packet_boundary_total_ns_,
                replay_packet_boundary_max_ns_, boundary_started);
        packet_saw_swap_ = false;
        return true;
    }

    void start_replay_worker()
    {
        replay_stop_.store(false, std::memory_order_release);
        replay_worker_ = std::thread([this] {
            if (bind_hps_worker_cores_) {
                try {
                    // MiSTer's frontend is pinned to CPU1 and continuously
                    // runnable, but the production supervisor now starts H3D
                    // at nice -20. Give command replay CPU1 explicitly so it
                    // preempts that idle loop instead of migrating onto CPU0
                    // and contending with the software rasterizer.
                    bind_current_thread_to_cpu(1);
                } catch (const std::exception& error) {
                    fail(FaultBadFrame, error.what());
                    return;
                }
            }
            for (;;) {
                if (replay_stop_.load(std::memory_order_acquire)) return;
                auto snapshot = replay_state_.consumer_snapshot();
                auto claimed = snapshot.claimed;
                auto published = snapshot.published;
                if (published == claimed) {
#ifdef __linux__
                    while (!replay_stop_.load(std::memory_order_acquire) &&
                           published == claimed) {
                        const int result = replay_futex_wait(
                            replay_state_.published_word(), published, nullptr);
                        if (result != 0 && errno != EAGAIN && errno != EINTR)
                            std::this_thread::yield();
                        snapshot = replay_state_.consumer_snapshot();
                        claimed = snapshot.claimed;
                        published = snapshot.published;
                    }
#else
                    std::unique_lock<std::mutex> lock(replay_mutex_);
                    replay_cv_.wait(lock, [this] {
                        return replay_stop_.load(std::memory_order_acquire) ||
                            replay_queue_count() != 0;
                    });
                    snapshot = replay_state_.consumer_snapshot();
                    claimed = snapshot.claimed;
                    published = snapshot.published;
#endif
                    if (replay_stop_.load(std::memory_order_acquire)) return;
                }

                auto* packet = &replay_queue_[replay_read_index_];
                replay_read_index_ =
                    (replay_read_index_ + 1) % ReplayArenaCapacity;
                const bool was_full =
                    published - claimed == ReplayQueueCapacity;
                ++claimed;
                replay_state_.claim(claimed);
                if (was_full) {
#ifdef __linux__
                    replay_futex_wake(replay_state_.claimed_word());
#else
                    // Match the producer's full-queue parking transition;
                    // ordinary dequeues remain lock-free.
                    std::lock_guard<std::mutex> lock(replay_mutex_);
                    replay_cv_.notify_one();
#endif
                }
                // The 513-slot arena exposes at most 512 queued packets. Even
                // though this slot is claimed before replay, the producer can
                // fill every other slot but cannot wrap onto this one until
                // the consumer claims another packet.
                const auto packet_frame = packet->header.frame;
                const auto packet_flags = packet->header.flags;
                const auto packet_sequence = packet->header.packet_sequence;
                auto replay_started = std::chrono::steady_clock::time_point {};
                if (pipeline_profile_enabled_)
                    replay_started = std::chrono::steady_clock::now();
                if (!arm_video_render_shadow_ &&
                    !prepare_replay_frame(packet_frame))
                    return;
                if (!apply_replay_packet(*packet)) return;
                latest_replay_frame_.store(
                    packet_frame, std::memory_order_relaxed);
                if (packet_flags == frame_packet::FlagFrameEnd &&
                    !arm_video_render_shadow_) {
                    const auto disposition = frame_disposition();
                    if (disposition == FrameDisposition::Fault) return;
                    const bool render =
                        disposition == FrameDisposition::Render &&
                        !replay_frame_skip_render_;

                    // This is the asynchronous equivalent of poll()'s
                    // terminal-packet path. The input owner has already
                    // copied and acknowledged this immutable packet before it
                    // can enter replay_queue_, so only private melonDS state
                    // is touched here. Finish frame N while the input owner
                    // has been copying N+1, then advance and launch N+1.
                    if (arm_render_pending_ && !finish_arm_render()) return;
                    if (!advance_frame_boundary(packet_frame)) return;
                    complete_replay_frame();
                    if (render && !start_arm_render(
                            packet_frame, packet_sequence))
                        return;
                }
                replay_packets_applied_.fetch_add(
                    1, std::memory_order_release);
                if (pipeline_profile_enabled_)
                    record_profile_sample(
                        replay_profile_packets_, replay_profile_total_ns_,
                        replay_profile_max_ns_, replay_started);

                // clear() preserves the allocation for this physical slot.
                // The 513-slot arena and 512-packet wait bound keep the active
                // slot unreachable by the producer until this worker advances
                // to its next head on the following iteration.
                packet->records.clear();

                // If authoritative input is caught up, collect the render
                // immediately instead of waiting indefinitely for another
                // terminal packet. A packet arriving just after this check is
                // still safe; it simply loses overlap with this one render.
                if (!arm_video_render_shadow_ && arm_render_pending_ &&
                    replay_queue_count() == 0 &&
                    !finish_arm_render())
                    return;
            }
        });
    }

    bool replay_render_deadline_missed(
        std::uint32_t replay_frame, bool& discard_geometry)
    {
        discard_geometry = false;
        const auto latest = replay_state_.latest_input_frame();
        const auto lead = latest >= replay_frame ? latest - replay_frame : 0;
        const auto backlog = replay_queue_count();

        std::uint32_t cadence = 1;
        if (lead >= ReplayCatchupEighthFrames ||
            backlog >= ReplayCatchupEighthPackets)
            cadence = 8;
        else if (lead >= ReplayCatchupQuarterFrames ||
                 backlog >= ReplayCatchupQuarterPackets)
            cadence = 4;
        else if (lead >= ReplayCatchupThirdFrames ||
                 backlog >= ReplayCatchupThirdPackets)
            cadence = 3;
        else if (lead >= ReplayCatchupHalfFrames ||
                 backlog >= ReplayCatchupHalfPackets)
            cadence = 2;

        if (cadence == 1) {
            replay_render_skip_countdown_ = 0;
            replay_render_cadence_ = 1;
            return false;
        }

        if (cadence != replay_render_cadence_ ||
            replay_render_skip_countdown_ == 0) {
            replay_render_cadence_ = cadence;
            replay_render_skip_countdown_ = cadence - 1;
            return false;
        }

        --replay_render_skip_countdown_;
        // A two-frame lead is common transient jitter. Preserve its complete
        // GX polygon build and skip only the expensive software raster pass;
        // the next admitted render then remains a valid moving plane. Once
        // the lead reaches the three-way catch-up tier, discarding obsolete
        // geometry is worth the CPU1 savings and the visibility guard keeps
        // its derived empty result away from scanout.
        discard_geometry = catchup_should_discard_geometry(cadence);
        frame_drop_replay_budget_.fetch_add(1, std::memory_order_relaxed);
        return true;
    }

    bool prepare_replay_frame(std::uint32_t frame)
    {
        if (replay_frame_active_) {
            if (replay_active_frame_ == frame) return true;
            return fail(
                FaultBadFrame,
                "queued frame changed before its terminal packet");
        }

        replay_frame_active_ = true;
        replay_active_frame_ = frame;
        // A primitive list can cross the service's frame packets. If its head
        // was discarded, the tail cannot legally construct polygons from
        // missing TempVertexBuffer entries. Taint this entire frame and keep
        // discarding until GPU3D observes the list's real END/FLUSH.
        bool discard_for_budget = false;
        const bool skip_for_budget = replay_render_deadline_missed(
            frame, discard_for_budget);
        const bool carried_discard =
            nds_->GPU.GPU3D.ExternalGeometryDiscardInProgress();
        replay_frame_skip_render_ = carried_discard || skip_for_budget;
        replay_frame_discard_geometry_ =
            carried_discard || discard_for_budget;
        nds_->GPU.GPU3D.SetExternalGeometryDiscard(
            replay_frame_discard_geometry_);
        if (replay_frame_discard_geometry_) {
            catchup_visibility_taint_.mark_discarded();
            ++replay_geometry_discard_frames_;
        }
        return true;
    }

    void complete_replay_frame() noexcept
    {
        nds_->GPU.GPU3D.SetExternalGeometryDiscard(false);
        replay_frame_active_ = false;
        replay_frame_skip_render_ = false;
        replay_frame_discard_geometry_ = false;
    }

    void stop_replay_worker()
    {
        if (!replay_worker_.joinable()) return;
#ifdef __linux__
        replay_stop_.store(true, std::memory_order_release);
        replay_futex_wake(replay_state_.published_word());
#else
        {
            std::lock_guard<std::mutex> lock(replay_mutex_);
            replay_stop_.store(true, std::memory_order_release);
            replay_cv_.notify_one();
        }
#endif
        replay_worker_.join();
    }

    void heartbeat(bool force = false)
    {
        if (!force && ++heartbeat_poll_count_ < HeartbeatPollInterval)
            return;
        heartbeat_poll_count_ = 0;
        publish_runtime_telemetry();
        if (!shared_session_current(true)) return;
        nds4mister::h3d::store_counter(
            &header_.hps_heartbeat, &header_.hps_heartbeat_reserved,
            ++heartbeat_);
    }

    void publish_runtime_telemetry() noexcept
    {
        if (!runtime_telemetry_) return;
        runtime_telemetry_->session.store(session_, std::memory_order_relaxed);
        runtime_telemetry_->replay_backlog.store(
            replay_queue_count(),
            std::memory_order_relaxed);
        runtime_telemetry_->replay_queue_high_water.store(
            static_cast<std::uint32_t>(replay_queue_high_water_.load(
                std::memory_order_relaxed)),
            std::memory_order_relaxed);
        runtime_telemetry_->latest_input_frame.store(
            replay_state_.latest_input_frame(),
            std::memory_order_relaxed);
        runtime_telemetry_->latest_replay_frame.store(
            latest_replay_frame_.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
        runtime_telemetry_->input_packets.store(
            packets_applied_, std::memory_order_relaxed);
        runtime_telemetry_->replay_packets.store(
            replay_packets_applied_.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
        runtime_telemetry_->replay_queue_full_polls.store(
            replay_queue_full_polls_.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
        runtime_telemetry_->frames_rendered.store(
            frames_rendered_.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
        runtime_telemetry_->frames_published.store(
            frames_published_.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
        runtime_telemetry_->replay_budget_drops.store(
            frame_drop_replay_budget_.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
        runtime_telemetry_->publication_replacements.store(
            publication_queue_replacements_.load(std::memory_order_relaxed),
            std::memory_order_relaxed);
        runtime_telemetry_->publication_queue_high_water.store(
            static_cast<std::uint32_t>(publication_queue_high_water_.load(
                std::memory_order_relaxed)),
            std::memory_order_relaxed);
    }

    bool fail(std::uint32_t bit, const std::string& message)
    {
        if (shared_session_current(true)) {
            const auto current = load_acquire(&header_.hps_fault_bits);
            store_release(&header_.hps_fault_bits, current | bit);
            store_release(
                &header_.service_state,
                static_cast<std::uint32_t>(ServiceState::Fault));
        }
        if (message.find("timestamp overflow") != std::string::npos) {
            std::ostringstream detail;
            detail << message
                   << " packet_timestamp=" << packet_timestamp_
                   << " arm9_shift=" << (nds_ ? nds_->ARM9ClockShift : 0)
                   << " replay_frame=" << replay_packet_frame_
                   << " pending_geometry=" << pending_geometry_commands_;
            error_ = detail.str();
        } else {
            error_ = message;
        }
        faulted_.store(true, std::memory_order_release);
        return false;
    }

    PollResult fail_result(std::uint32_t bit, const std::string& message)
    {
        fail(bit, message);
        return PollResult::Fault;
    }

    PollResult consumer_fault_result(const std::string& message)
    {
        const auto faults = consumer_.local_faults();
        std::uint32_t bit = FaultBadEvent;
        if (faults & frame_packet::FaultBadSession)
            bit = FaultBadSession;
        else if (faults & frame_packet::FaultSequence)
            bit = FaultSequenceGap;
        else if (faults & frame_packet::FaultTornHeader)
            bit = FaultTornEvent;
        else if (faults &
                 (frame_packet::FaultBadMapping |
                  frame_packet::FaultBadControl |
                  frame_packet::FaultBadHeader))
            bit = FaultBadHeader;
        return fail_result(bit, message);
    }

    static bool address_in_range(
        std::uint32_t address, std::uint32_t bytes,
        std::uint32_t first, std::uint32_t last)
    {
        if (!bytes || address < first || address > last) return false;
        return bytes - 1 <= last - address;
    }

    static bool gpu_io_range(std::uint32_t address, std::uint32_t bytes)
    {
        return
            address_in_range(address, bytes, 0x04000060u, 0x04000063u) ||
            address_in_range(address, bytes, 0x04000240u, 0x04000249u) ||
            address_in_range(address, bytes, 0x04000304u, 0x04000307u) ||
            address_in_range(address, bytes, 0x04000320u, 0x040003bfu) ||
            address_in_range(address, bytes, 0x04000400u, 0x040005cbu) ||
            address_in_range(address, bytes, 0x04000600u, 0x04000613u);
    }

    static bool gpu_register_range(
        std::uint32_t address, std::uint32_t bytes)
    {
        return
            address_in_range(address, bytes, 0x04000060u, 0x04000063u) ||
            address_in_range(address, bytes, 0x04000304u, 0x04000307u) ||
            address_in_range(address, bytes, 0x04000320u, 0x040003bfu) ||
            address_in_range(address, bytes, 0x04000600u, 0x04000613u);
    }

    static bool valid_gx_command(std::uint8_t command)
    {
        return command == 0 ||
            (command >= 0x10 && command <= 0x1c) ||
            (command >= 0x20 && command <= 0x2b) ||
            (command >= 0x30 && command <= 0x34) ||
            (command >= 0x40 && command <= 0x41) ||
            command == 0x50 || command == 0x60 ||
            (command >= 0x70 && command <= 0x72);
    }

    static bool valid_gx_record(const frame_packet::Record& record)
    {
        if (frame_packet::record_kind(record) !=
                frame_packet::RecordKind::GxCommand ||
            frame_packet::record_byte_enable(record) != 0 ||
            record.address_or_aux != 0 || (record.data >> 32) != 0)
            return false;
        const auto command = frame_packet::record_tag(record);
        return valid_gx_command(command) &&
            (command != 0 || static_cast<std::uint32_t>(record.data) == 0);
    }

    static bool valid_packed_gx_record(
        const frame_packet::Record& record)
    {
        if (frame_packet::record_kind(record) !=
            frame_packet::RecordKind::GxPacked)
            return false;
        for (std::size_t index = 0; index < 3; ++index) {
            const auto command = frame_packet::packed_gx_tag(record, index);
            const auto data = frame_packet::packed_gx_data(record, index);
            if (!valid_gx_command(command) || (command == 0 && data != 0))
                return false;
        }
        return true;
    }

    static bool virtual_vram_range(std::uint32_t address)
    {
        return (address & 0xff000000u) == 0x06000000u;
    }

    bool set_timestamp(const Event& event)
    {
        const auto timestamp = event_timestamp(event);
        if (have_timestamp_ && timestamp < last_timestamp_)
            return fail(FaultBadEvent, "event timestamp moved backward");
        // Normalized VRAM and 2D mutations between two GX commands share one
        // architectural timestamp. Avoid rewriting four melonDS clock words
        // for every record in those often-thousands-long runs.
        if (have_timestamp_ && timestamp == last_timestamp_) return true;
        if (timestamp >
            (std::numeric_limits<std::uint64_t>::max() >>
             nds_->ARM9ClockShift))
            return fail(FaultBadEvent, "event timestamp overflow");
        // H3D1 timestamps are normalized DS system clocks (the ARM7 clock),
        // regardless of which CPU originated an event. melonDS stores ARM9
        // time in raw CPU cycles and converts it back with ARM9ClockShift.
        nds_->ARM9Timestamp = timestamp << nds_->ARM9ClockShift;
        nds_->ARM7Timestamp = timestamp;
        nds_->ARM9Target = nds_->ARM9Timestamp;
        nds_->ARM7Target = timestamp;
        last_timestamp_ = timestamp;
        have_timestamp_ = true;
        return true;
    }

    struct IoAccess {
        std::uint32_t address = 0;
        std::uint32_t value = 0;
        std::uint32_t bytes = 0;
    };

    static std::optional<IoAccess> decode_io_access(const Event& event)
    {
        const auto be = event_byte_enable(event);
        const auto base = event.address & ~std::uint32_t(3);
        const auto low = event.address & 3u;
        switch (event_width(event)) {
        case AccessWidth::Byte: {
            if (!be || (be & (be - 1))) return std::nullopt;
            unsigned lane = 0;
            while (((be >> lane) & 1u) == 0) ++lane;
            if (low && low != lane) return std::nullopt;
            return IoAccess {
                base + lane, (event.data >> (lane * 8)) & 0xffu, 1};
        }
        case AccessWidth::Half: {
            unsigned lane = 0;
            if (be == 0x0c) lane = 2;
            else if (be != 0x03) return std::nullopt;
            if ((low && low != lane) || (low & 1u)) return std::nullopt;
            return IoAccess {
                base + lane, (event.data >> (lane * 8)) & 0xffffu, 2};
        }
        case AccessWidth::Word:
            if (be != 0x0f || low) return std::nullopt;
            return IoAccess {base, event.data, 4};
        }
        return std::nullopt;
    }

    bool apply_gpu_io(const Event& event)
    {
        if (event_is_arm7(event) || (event.metadata >> 15))
            return fail(FaultBadEvent, "invalid ARM9 GPU I/O metadata");
        const auto access = decode_io_access(event);
        if (!access || !gpu_io_range(access->address, access->bytes))
            return fail(FaultBadEvent, "invalid ARM9 GPU I/O access");
        if (!set_timestamp(event)) return false;

        // Run pending geometry to the FPGA timestamp before applying the next
        // raw write. NDS::ARM9Write preserves melonDS's packed GXFIFO decoder
        // and also routes VRAMCNT and POWCNT1 writes through their real logic.
        flush_pending_geometry();
        if (access->bytes == 1)
            nds_->ARM9Write8(
                access->address, static_cast<melonDS::u8>(access->value));
        else if (access->bytes == 2)
            nds_->ARM9Write16(
                access->address, static_cast<melonDS::u16>(access->value));
        else
            nds_->ARM9Write32(access->address, access->value);
        return true;
    }

    bool apply_vram(const Event& event, bool arm7)
    {
        if (event_is_arm7(event) != arm7 || (event.metadata >> 15) ||
            !virtual_vram_range(event.address))
            return fail(FaultBadEvent, "invalid virtual VRAM event");
        if (!set_timestamp(event)) return false;

        const auto access = decode_io_access(event);
        if (!access || !virtual_vram_range(access->address))
            return fail(FaultBadEvent, "invalid virtual VRAM byte enable");
        if (arm7) {
            pending_external_vram_mask_ |=
                nds_->GPU.VRAMMap_ARM7[(access->address >> 17) & 1u];
            if (access->bytes == 1)
                nds_->ARM7Write8(
                    access->address,
                    static_cast<melonDS::u8>(access->value));
            else if (access->bytes == 2)
                nds_->ARM7Write16(
                    access->address,
                    static_cast<melonDS::u16>(access->value));
            else
                nds_->ARM7Write32(access->address, access->value);
        } else {
            // ARM9 byte writes to VRAM are architecturally ignored. For the
            // supported halfword/word writes, use the GPU's mapped VRAM path
            // directly. The hybrid service has no display-capture renderer,
            // so ARM9Write's JIT invalidation and capture synchronization are
            // pure overhead; WriteVRAM_* retains the real bank mapping and
            // dirty tracking needed by GPU3D texture coherency.
            if (access->bytes == 1)
                return true;
            const auto address = access->address;
            const auto region = address & 0x00e00000u;
            std::uint32_t bank_mask = 0;
            if (region == 0x00000000u)
                bank_mask = nds_->GPU.VRAMMap_ABG[(address >> 14) & 0x1fu];
            else if (region == 0x00200000u)
                bank_mask = nds_->GPU.VRAMMap_BBG[(address >> 14) & 0x07u];
            else if (region == 0x00400000u)
                bank_mask = nds_->GPU.VRAMMap_AOBJ[(address >> 14) & 0x0fu];
            else if (region == 0x00600000u)
                bank_mask = nds_->GPU.VRAMMap_BOBJ[(address >> 14) & 0x07u];
            else
                bank_mask = nds_->GPU.VRAMMap_LCDC;
            pending_external_vram_mask_ |= bank_mask;
            if (access->bytes == 2) {
                const auto value = static_cast<melonDS::u16>(access->value);
                if (region == 0x00000000u)
                    nds_->GPU.WriteVRAM_ABG<melonDS::u16>(address, value);
                else if (region == 0x00200000u)
                    nds_->GPU.WriteVRAM_BBG<melonDS::u16>(address, value);
                else if (region == 0x00400000u)
                    nds_->GPU.WriteVRAM_AOBJ<melonDS::u16>(address, value);
                else if (region == 0x00600000u)
                    nds_->GPU.WriteVRAM_BOBJ<melonDS::u16>(address, value);
                else
                    nds_->GPU.WriteVRAM_LCDC<melonDS::u16>(address, value);
            } else {
                const auto value = access->value;
                if (region == 0x00000000u)
                    nds_->GPU.WriteVRAM_ABG<melonDS::u32>(address, value);
                else if (region == 0x00200000u)
                    nds_->GPU.WriteVRAM_BBG<melonDS::u32>(address, value);
                else if (region == 0x00400000u)
                    nds_->GPU.WriteVRAM_AOBJ<melonDS::u32>(address, value);
                else if (region == 0x00600000u)
                    nds_->GPU.WriteVRAM_BOBJ<melonDS::u32>(address, value);
                else
                    nds_->GPU.WriteVRAM_LCDC<melonDS::u32>(address, value);
            }
        }
        return true;
    }

    void flush_external_vram_revisions()
    {
        if (!pending_external_vram_mask_) return;
        auto started = std::chrono::steady_clock::time_point {};
        if (pipeline_profile_enabled_)
            started = std::chrono::steady_clock::now();
        nds_->GPU.MarkExternalRenderVRAMMask(pending_external_vram_mask_);
        pending_external_vram_mask_ = 0;
        if (pipeline_profile_enabled_)
            record_plain_profile_sample(
                external_vram_flushes_, external_vram_flush_total_ns_,
                external_vram_flush_max_ns_, started);
    }

    static AccessWidth packet_width(const frame_packet::Record& record)
    {
        return static_cast<AccessWidth>(frame_packet::record_tag(record) & 3u);
    }

    static bool packet_is_arm7(const frame_packet::Record& record)
    {
        return (frame_packet::record_tag(record) & 4u) != 0;
    }

    static Event packet_write_event(
        const frame_packet::Record& record, EventType type,
        std::uint64_t timestamp)
    {
        Event event {};
        event.address = record.address_or_aux;
        event.data = static_cast<std::uint32_t>(record.data);
        event.metadata = make_metadata(
            type, packet_is_arm7(record), packet_width(record),
            frame_packet::record_byte_enable(record));
        event.timestamp_low = static_cast<std::uint32_t>(timestamp);
        event.timestamp_high = static_cast<std::uint32_t>(timestamp >> 32);
        return event;
    }

    bool valid_packet_write(const frame_packet::Record& record) const
    {
        return (frame_packet::record_tag(record) & 0xf8u) == 0 &&
            static_cast<unsigned>(packet_width(record)) <=
                static_cast<unsigned>(AccessWidth::Word) &&
            (record.data >> 32) == 0;
    }

    bool apply_arm_video_write(const frame_packet::Record& record)
    {
        const auto kind = frame_packet::record_kind(record);
        // The packet consumer has already validated every compact record. In
        // production the shadow is diagnostic-only and otherwise duplicates
        // every register/palette/OAM mutation that melonDS applies below.
        // Retain its inexpensive HBlank continuity check, and retain the full
        // reconstruction for the synchronous self-test/diagnostic path.
        if ((!asynchronous_arm_video_replay_ ||
             kind == frame_packet::RecordKind::HBlank) &&
            !arm_video_shadow_.apply_compact_record(
                record, asynchronous_arm_video_replay_ ?
                    replay_packet_frame_ : packet_header_.frame))
            return fail(
                FaultBadEvent, arm_video_shadow_.error().c_str());

        if (kind == frame_packet::RecordKind::HBlank)
            return apply_arm_video_phase(record);

        const auto raw_width = static_cast<std::uint8_t>(
            (record.metadata >> 8) & 0x03u);
        if (raw_width > static_cast<std::uint8_t>(AccessWidth::Word))
            return fail(FaultBadEvent, "invalid ARM video write width");

        Event event {};
        event.address = record.address_or_aux;
        event.data = static_cast<std::uint32_t>(record.data);
        event.metadata = make_metadata(
            EventType::Arm9GpuIoWrite, false,
            static_cast<AccessWidth>(raw_width),
            frame_packet::record_byte_enable(record));
        const auto access = decode_io_access(event);
        if (!access)
            return fail(FaultBadEvent, "invalid ARM video byte enable");

        // These records describe writes that the FPGA has already accepted.
        // Feed them through melonDS's normal ARM9 memory API so GPU2D register
        // masks, palette/OAM power rules, dirty tracking, and mapped VRAM
        // rendering all use the maintained emulator implementation. Only a
        // complete frame from that private renderer is published to scanout.
        if (access->bytes == 1)
            nds_->ARM9Write8(
                access->address, static_cast<melonDS::u8>(access->value));
        else if (access->bytes == 2)
            nds_->ARM9Write16(
                access->address, static_cast<melonDS::u16>(access->value));
        else
            nds_->ARM9Write32(access->address, access->value);
        if (access->address >= 0x05000000u &&
            access->address < 0x05000800u)
            nds_->GPU.MarkExternalRenderPalette(
                access->address & 0x7ffu, access->bytes);
        else if (access->address >= 0x07000000u &&
                 access->address < 0x07000800u)
            nds_->GPU.MarkExternalRenderOAM(
                access->address & 0x7ffu, access->bytes);
        return true;
    }

    bool apply_arm_video_phase(const frame_packet::Record& record)
    {
        if (!arm_video_render_shadow_) return true;

        const auto line = record.address_or_aux;
        const auto display_frame = static_cast<std::uint32_t>(record.data);
        // Admission may occur midway through a display frame. Wait for the
        // first complete line-0 epoch instead of publishing a partial shadow.
        if (!arm_video_phase_started_ && line != 0) return true;

        if (line == 0) {
            // A copied packet can outlive its H3B slot. Advance every melonDS
            // state transition, but derive the first complete frame and then
            // exactly one frame per cadence. Publication swaps only completed
            // banks, so omitted frames repeat the previous valid image.
            arm_video_render_this_frame_ =
                !asynchronous_arm_video_replay_ ||
                !arm_video_frame_ready_ ||
                arm_video_skipped_frames_ >= ReplayRenderCadence - 1;
            if (arm_video_render_this_frame_)
                arm_video_skipped_frames_ = 0;
            else {
                ++arm_video_skipped_frames_;
                replay_render_skips_.fetch_add(1, std::memory_order_relaxed);
            }
            arm_video_phase_started_ = true;
            if (arm_video_render_this_frame_) {
                int destination_index = 0;
                if (asynchronous_plane_publication_) {
                    std::lock_guard<std::mutex> lock(publication_mutex_);
                    destination_index = reserve_publication_buffer_locked();
                    if (destination_index < 0)
                        return fail(
                            FaultBadFrame,
                            "no safe private full-video buffer is available");
                    publication_filling_index_ = destination_index;
                } else {
                    publication_filling_index_ = destination_index;
                }
            }
        }

        const auto vblank = line >= 192 && line < 262 ? 1u : 0u;
        if (line == 192) nds_->GPU.GPU3D.Run();
        // A skipped frame still performs the architectural VBlank below.
        // That is the first point that can replace RenderPolygonRAM and make
        // the just-finished input bank writable again. Keep CPU0 rasterizing
        // in parallel through the preceding 192 lines, then fence at this
        // exact lifetime boundary rather than blocking replay at line 0.
        if (line == 192 && !arm_video_render_this_frame_ &&
            arm_video_render_in_flight_) {
            auto fence_started = std::chrono::steady_clock::time_point {};
            if (pipeline_profile_enabled_)
                fence_started = std::chrono::steady_clock::now();
            nds_->GPU.GetRenderer().Finish3DRendering();
            if (pipeline_profile_enabled_)
                record_plain_profile_sample(
                    arm_video_fences_, arm_video_fence_total_ns_,
                    arm_video_fence_max_ns_, fence_started);
            arm_video_render_in_flight_ = false;
            arm_video_renderer_started_ = false;
        }
        const auto start_kind = line == 0 ? 2u : 0u;
        const bool renderer_resync =
            line == 0 && arm_video_render_this_frame_ &&
            !arm_video_renderer_started_;
        auto phase_started = std::chrono::steady_clock::time_point {};
        if (pipeline_profile_enabled_)
            phase_started = std::chrono::steady_clock::now();
        if (!nds_->GPU.ApplyExternalRendererPhase(
                start_kind, line, line, vblank, vblank,
                display_frame, arm_video_render_this_frame_,
                renderer_resync))
            return fail(FaultBadFrame, "melonDS rejected LCD start phase");
        if (renderer_resync)
            arm_video_render_in_flight_ = true;
        if (line == 0 && arm_video_render_this_frame_)
            arm_video_renderer_started_ = true;
        if (!nds_->GPU.ApplyExternalRendererPhase(
                1, line, line, vblank | 2u, vblank | 2u,
                display_frame, arm_video_render_this_frame_, false))
            return fail(FaultBadFrame, "melonDS rejected LCD HBlank phase");
        if (pipeline_profile_enabled_ && arm_video_render_this_frame_ &&
            line < PlaneHeight) {
            bool reused_a = false;
            bool reused_b = false;
            if (!nds_->GPU.GetRenderer().GetExternalLineCacheResult(
                    reused_a, reused_b))
                return fail(
                    FaultBadFrame,
                    "melonDS returned no ARM-video cache result");
            ++arm_video_cache_lines_;
            arm_video_cache_hits_a_ += reused_a ? 1u : 0u;
            arm_video_cache_hits_b_ += reused_b ? 1u : 0u;
            arm_video_cache_double_hits_ += reused_a && reused_b ? 1u : 0u;
        }
        if (pipeline_profile_enabled_) {
            if (arm_video_render_this_frame_)
                record_plain_profile_sample(
                    arm_video_render_phases_,
                    arm_video_render_phase_total_ns_,
                    arm_video_render_phase_max_ns_, phase_started);
            else
                record_plain_profile_sample(
                    arm_video_skip_phases_, arm_video_skip_phase_total_ns_,
                    arm_video_skip_phase_max_ns_, phase_started);
        }
        if (arm_video_render_this_frame_ && line == 192)
            arm_video_render_in_flight_ = false;
        else if (arm_video_render_this_frame_ && line == 215)
            arm_video_render_in_flight_ = true;

        if (!arm_video_render_this_frame_) return true;

        if (line < PlaneHeight) {
            auto scanline_started = std::chrono::steady_clock::time_point {};
            if (pipeline_profile_enabled_)
                scanline_started = std::chrono::steady_clock::now();
            std::uint32_t* top = nullptr;
            std::uint32_t* bottom = nullptr;
            if (!nds_->GPU.GetRenderer().GetRenderedScanlines(
                    line, &top, &bottom) || !top || !bottom)
                return fail(
                    FaultBadFrame,
                    "melonDS returned no full-video scanline");
            const auto destination_index = publication_filling_index_;
            if (destination_index < 0 ||
                destination_index >=
                    static_cast<int>(ArmVideoBufferCount))
                return fail(
                    FaultBadFrame,
                    "ARM full-video frame has no local destination");
            std::memcpy(
                arm_video_frames_[destination_index][0].data() +
                    line * PlaneWidth,
                top, PlaneWidth * sizeof(std::uint32_t));
            std::memcpy(
                arm_video_frames_[destination_index][1].data() +
                    line * PlaneWidth,
                bottom, PlaneWidth * sizeof(std::uint32_t));
            if (pipeline_profile_enabled_)
                record_plain_profile_sample(
                    arm_video_scanlines_, arm_video_scanline_total_ns_,
                    arm_video_scanline_max_ns_, scanline_started);
            if (line == PlaneHeight - 1) {
                arm_video_frame_ = display_frame;
                arm_video_frame_ready_ = true;
                arm_video_completed_index_ = destination_index;
                ++frames_rendered_;
                if (asynchronous_plane_publication_) {
                    {
                        std::lock_guard<std::mutex> lock(publication_mutex_);
                        publication_frame_numbers_[destination_index] =
                            display_frame;
                        publication_filling_index_ = -1;
                        if (!enqueue_publication_buffer_locked(
                                destination_index))
                            return fail(
                                FaultBadFrame,
                                "completed full-video buffer could not be queued");
                    }
                    publication_cv_.notify_one();
                    return true;
                }
                const auto disposition = frame_disposition();
                if (disposition == FrameDisposition::Fault) return false;
                if (disposition == FrameDisposition::Render) {
                    if (!full_frame_publisher_.publish(
                            session_, display_frame,
                            arm_video_frames_[destination_index][0].data(),
                            arm_video_frames_[destination_index][1].data(),
                            true))
                        return fail(
                            FaultBadFrame,
                            "full ARM framebuffer publication failed");
                    frames_published_.fetch_add(
                        1, std::memory_order_relaxed);
                }
            }
        }
        return true;
    }

    bool apply(const frame_packet::Record& record)
    {
        if (packet_timestamp_ >
            (std::numeric_limits<std::uint64_t>::max() >>
             nds_->ARM9ClockShift))
            return fail(FaultBadEvent, "record timestamp overflow");
        const auto timestamp = packet_timestamp_;
        const auto kind = frame_packet::record_kind(record);
        if (kind != frame_packet::RecordKind::GxCommand &&
            kind != frame_packet::RecordKind::GxPacked)
            flush_pending_geometry();
        if (kind != frame_packet::RecordKind::VramWrite)
            flush_external_vram_revisions();
        switch (kind) {
        case frame_packet::RecordKind::GxCommand: {
            // These are already normalized direct command-port writes. Match
            // Replay3D's proven fallback exactly: enqueue directly into
            // GPU3D, then advance once. The
            // generic ARM9Write path ran geometry once before this write and
            // advance_packet_geometry() ran it again afterwards. After the
            // first command, that pre-write Run was always at the timestamp
            // already consumed by the preceding post-write Run, so it could
            // do no work; it also paid the full ARM9 address decoder for the
            // 73.6% record kind dominating the measured board stream. Run
            // the FIFO once per bounded command batch; every non-command and
            // packet boundary flushes it first, preserving global order. The
            // batch owns no emulated CPU, so commit its final synthetic clock
            // once at Run() instead of rewriting four clock words per input.
            if (!enqueue_replay_geometry_record(record)) return false;
            return advance_packet_geometry();
        }
        case frame_packet::RecordKind::GxPacked:
            if (!valid_packed_gx_record(record))
                return fail(FaultBadEvent, "invalid packed GX record");
            for (std::size_t index = 0; index < 3; ++index) {
                if (!enqueue_replay_geometry_command(
                        frame_packet::packed_gx_tag(record, index),
                        frame_packet::packed_gx_data(record, index)) ||
                    !advance_packet_geometry())
                    return false;
            }
            return true;
        case frame_packet::RecordKind::GxRegister: {
            if (packet_saw_swap_)
                return fail(
                    FaultBadEvent,
                    "record followed SWAP_BUFFERS in one frame packet");
            if (!valid_packet_write(record) || packet_is_arm7(record))
                return fail(FaultBadEvent, "invalid GX register record");
            const auto event = packet_write_event(
                record, EventType::Arm9GpuIoWrite, timestamp);
            const auto access = decode_io_access(event);
            if (!access ||
                !gpu_register_range(access->address, access->bytes))
                return fail(FaultBadEvent, "unsupported GX register access");
            return apply_gpu_io(event);
        }
        case frame_packet::RecordKind::VramWrite: {
            if (packet_saw_swap_)
                return fail(
                    FaultBadEvent,
                    "record followed SWAP_BUFFERS in one frame packet");
            if (!valid_packet_write(record))
                return fail(FaultBadEvent, "invalid VRAM write record");
            const bool arm7 = packet_is_arm7(record);
            const auto event = packet_write_event(
                record,
                arm7 ? EventType::Arm7VramWrite
                     : EventType::Arm9VramWrite,
                timestamp);
            return apply_vram(event, arm7);
        }
        case frame_packet::RecordKind::VramMap: {
            if (packet_saw_swap_)
                return fail(
                    FaultBadEvent,
                    "record followed SWAP_BUFFERS in one frame packet");
            if (!valid_packet_write(record) || packet_is_arm7(record) ||
                record.address_or_aux < 0x04000240u ||
                record.address_or_aux > 0x04000249u)
                return fail(FaultBadEvent, "invalid VRAM map record");
            const auto event = packet_write_event(
                record, EventType::Arm9GpuIoWrite, timestamp);
            const auto access = decode_io_access(event);
            if (!access || !address_in_range(
                    access->address, access->bytes,
                    0x04000240u, 0x04000249u))
                return fail(FaultBadEvent, "invalid VRAM map access");
            return apply_gpu_io(event);
        }
        case frame_packet::RecordKind::Gpu2DRegister:
        case frame_packet::RecordKind::PaletteWrite:
        case frame_packet::RecordKind::OamWrite:
        case frame_packet::RecordKind::HBlank:
            if (packet_saw_swap_)
                return fail(
                    FaultBadEvent,
                    "ARM video shadow record followed SWAP_BUFFERS");
            return apply_arm_video_write(record);
        }
        return fail(FaultBadEvent, "unknown frame-packet record kind");
    }

    bool advance_packet_geometry()
    {
        // Replay3D's proven non-exact fallback advances the raw ARM9 clock by
        // 1<<16 after each normalized command. Packet time is stored in the
        // ARM7/system-clock domain, so scale that step down before applying
        // it here.
        constexpr std::uint64_t RawArm9ClockStep = 1u << 16;
        const auto normalized_clock_step =
            RawArm9ClockStep >> nds_->ARM9ClockShift;
        const auto limit =
            std::numeric_limits<std::uint64_t>::max() >>
            nds_->ARM9ClockShift;
        if (packet_timestamp_ > limit - normalized_clock_step)
            return fail(FaultBadEvent, "geometry step timestamp overflow");
        packet_timestamp_ += normalized_clock_step;
        if (++pending_geometry_commands_ == GeometryRunBatch)
            flush_pending_geometry();
        last_timestamp_ = packet_timestamp_;
        have_timestamp_ = true;
        return true;
    }

    void flush_pending_geometry()
    {
        if (pending_geometry_commands_ == 0) return;
        auto started = std::chrono::steady_clock::time_point {};
        if (pipeline_profile_enabled_)
            started = std::chrono::steady_clock::now();
        nds_->ARM9Timestamp = packet_timestamp_ << nds_->ARM9ClockShift;
        nds_->ARM7Timestamp = packet_timestamp_;
        nds_->ARM9Target = nds_->ARM9Timestamp;
        nds_->ARM7Target = packet_timestamp_;
        nds_->GPU.GPU3D.Run();
        pending_geometry_commands_ = 0;
        if (pipeline_profile_enabled_)
            record_plain_profile_sample(
                geometry_flushes_, geometry_flush_total_ns_,
                geometry_flush_max_ns_, started);
    }

    enum class FrameDisposition {
        Render,
        Drop,
        Fault,
    };

    FrameDisposition frame_disposition()
    {
        if (!shared_session_current(true)) {
            fail(FaultBadSession, "session changed before frame boundary");
            return FrameDisposition::Fault;
        }

        std::uint32_t published = 0;
        std::uint32_t acknowledged = 0;
        for (unsigned attempt = 0; attempt < 3; ++attempt) {
            if (asynchronous_plane_publication_ &&
                frame_publication_fence_active_.load(
                    std::memory_order_acquire)) {
                // The renderer and its two private output buffers do not
                // touch the shared descriptor or DDR plane. Keep preparing
                // the next frame while the publisher commits the previous
                // one; the publication worker will wait for bank ownership.
                frame_render_local_fence_overlap_.fetch_add(
                    1, std::memory_order_relaxed);
                frame_render_admissions_.fetch_add(
                    1, std::memory_order_relaxed);
                return FrameDisposition::Render;
            }
            if (!nds4mister::h3d::load_counter(
                    &header_.frame_publish_sequence,
                    &header_.frame_publish_sequence_reserved, published) ||
                !nds4mister::h3d::load_counter(
                    &header_.frame_ack_sequence,
                    &header_.frame_ack_sequence_reserved, acknowledged)) {
                fail(FaultBadFrame, "invalid reserved frame fence word");
                return FrameDisposition::Fault;
            }
            if (asynchronous_plane_publication_ &&
                frame_publication_fence_active_.load(
                    std::memory_order_acquire)) {
                frame_render_local_fence_overlap_.fetch_add(
                    1, std::memory_order_relaxed);
                frame_render_admissions_.fetch_add(
                    1, std::memory_order_relaxed);
                return FrameDisposition::Render;
            }
            if ((published & 1u) == 0) break;
            // The publisher may have completed between the counter read and
            // the second flag snapshot. Re-read the now-stable even fence;
            // a persistent odd value without an active local publisher is a
            // real ABI fault and still fails closed below.
        }
        if (published & 1u) {
            fail(FaultBadFrame, "odd frame publication sequence observed");
            return FrameDisposition::Fault;
        }
        if ((acknowledged & 1u) != 0 || acknowledged > published) {
            fail(FaultBadFrame, "invalid frame acknowledgement sequence");
            return FrameDisposition::Fault;
        }

        const auto frame_gap = published - acknowledged;
        if (frame_gap == 0) {
            frame_render_admissions_.fetch_add(1, std::memory_order_relaxed);
            return FrameDisposition::Render;
        }
        if (frame_gap == 2) {
            if (asynchronous_plane_publication_) {
                // One displayed plane may remain owned by the FPGA while the
                // ARM rasterizer fills a private successor. A later private
                // result can replace an older queued result, but neither can
                // overwrite the immutable shared bank before ACK.
                frame_render_shared_fence_overlap_.fetch_add(
                    1, std::memory_order_relaxed);
                frame_render_admissions_.fetch_add(
                    1, std::memory_order_relaxed);
                return FrameDisposition::Render;
            }
            frame_drop_shared_fence_.fetch_add(
                1, std::memory_order_relaxed);
            return FrameDisposition::Drop;
        }
        fail(FaultBadFrame, "invalid outstanding frame count");
        return FrameDisposition::Fault;
    }

    bool advance_frame_boundary(std::uint32_t frame)
    {
        nds_->NumFrames = frame;
        // Packet mode carries architectural order rather than raw bus time.
        // Advance once beyond the last record so melonDS drains the normalized
        // GX command FIFO before the frame's VBlank/render boundary. A
        // FRAME_END without SWAP_BUFFERS is a real VBlank boundary: melonDS
        // retains the prior 3D buffer while the packet transport still makes
        // forward progress through 2D-only or register-only frames.
        constexpr std::uint64_t RawArm9ClockStep = 1u << 16;
        const auto normalized_clock_step =
            RawArm9ClockStep >> nds_->ARM9ClockShift;
        const auto limit =
            std::numeric_limits<std::uint64_t>::max() >>
            nds_->ARM9ClockShift;
        if (packet_timestamp_ > limit - normalized_clock_step)
            return fail(FaultBadFrame, "frame boundary timestamp overflow");
        packet_timestamp_ += normalized_clock_step;
        nds_->ARM9Timestamp = packet_timestamp_ << nds_->ARM9ClockShift;
        nds_->ARM7Timestamp = packet_timestamp_;
        nds_->ARM9Target = nds_->ARM9Timestamp;
        nds_->ARM7Target = packet_timestamp_;
        nds_->GPU.GPU3D.Run();
        nds_->GPU.GPU3D.VBlank();
        return true;
    }

    bool start_arm_render(
        std::uint32_t frame, std::uint32_t packet_sequence)
    {
        // Derived work must never retain or reread an H3B slot. The terminal
        // acknowledgement above clears packet_pending_ only after the shared
        // ownership store and its device barrier have completed.
        if (asynchronous_arm_video_replay_) {
            std::uint32_t acknowledged = 0;
            if (!nds4mister::h3d::load_counter(
                    &header_.consumer_sequence,
                    &header_.consumer_sequence_reserved, acknowledged) ||
                acknowledged < packet_sequence)
                return fail(
                    FaultBadFrame,
                    "queued rendering began before terminal packet acknowledgement");
        } else if (packet_pending_) {
            return fail(
                FaultBadFrame,
                "derived rendering began before terminal packet acknowledgement");
        }
        arm_render_visibility_generation_ =
            catchup_visibility_taint_.capture_for_render();
        arm_render_expected_alpha_ = catchup_visibility_taint_.expected_alpha(
            arm_render_visibility_generation_,
            nds_->GPU.GPU3D.RenderNumPolygons != 0 ||
                ((nds_->GPU.GPU3D.RenderClearAttr1 >> 16) & 0x1fu) != 0);
        arm_render_sequence_ = packet_sequence;
        arm_render_polygon_count_ = nds_->GPU.GPU3D.RenderNumPolygons;
        if (asynchronous_plane_publication_) {
            if (arm_render_pending_)
                return fail(FaultBadFrame, "ARM renderer already has a frame pending");
            nds_->GPU.GetRenderer().Start3DRendering();
            arm_render_frame_ = frame;
            arm_render_pending_ = true;
            return true;
        }

        auto& renderer = nds_->GPU.GetRenderer();
        renderer.Start3DRendering();
        renderer.Finish3DRendering();
        return copy_rendered_frame(frame, renderer);
    }

    bool finish_arm_render()
    {
        if (!arm_render_pending_) return true;
        auto& renderer = nds_->GPU.GetRenderer();
        auto wait_started = std::chrono::steady_clock::time_point {};
        if (pipeline_profile_enabled_)
            wait_started = std::chrono::steady_clock::now();
        renderer.Finish3DRendering();
        if (pipeline_profile_enabled_)
            record_profile_sample(
                arm_render_finishes_, arm_render_finish_total_ns_,
                arm_render_finish_max_ns_, wait_started);
        const auto frame = arm_render_frame_;
        arm_render_pending_ = false;
        return copy_rendered_frame(frame, renderer);
    }

    bool publication_index_queued_locked(int index) const
    {
        for (std::size_t offset = 0; offset < publication_queue_count_;
             ++offset) {
            const auto queue_index =
                (publication_queue_read_index_ + offset) %
                PublicationBufferCount;
            if (publication_queue_[queue_index] == index) return true;
        }
        return false;
    }

    std::size_t publication_buffer_count() const
    {
        return arm_video_render_shadow_ ?
            ArmVideoBufferCount : PublicationBufferCount;
    }

    int reserve_publication_buffer_locked()
    {
        const auto buffer_count = publication_buffer_count();
        for (std::size_t index = 0; index < buffer_count; ++index) {
            const auto candidate = static_cast<int>(index);
            if (candidate != publication_active_index_ &&
                candidate != publication_filling_index_ &&
                !publication_index_queued_locked(candidate))
                return candidate;
        }

        // The publisher has enough measured average throughput, but can be
        // descheduled during short replay bursts. If every private buffer is
        // occupied, keep the newest completed work by replacing only the
        // oldest queued frame; the active frame remains immutable.
        if (publication_queue_count_ == 0) return -1;
        const auto replacement =
            publication_queue_[publication_queue_read_index_];
        publication_queue_read_index_ =
            (publication_queue_read_index_ + 1) % PublicationBufferCount;
        --publication_queue_count_;
        publication_queue_replacements_.fetch_add(
            1, std::memory_order_relaxed);
        return replacement;
    }

    bool enqueue_publication_buffer_locked(int index)
    {
        const auto buffer_count = publication_buffer_count();
        if (index < 0 ||
            index >= static_cast<int>(buffer_count) ||
            publication_queue_count_ == buffer_count ||
            publication_index_queued_locked(index))
            return false;
        if (!arm_video_render_shadow_ &&
            publication_queue_count_ == PendingPublicationLimit) {
            // Keep a shallow FIFO to absorb renderer/publisher phase bursts,
            // but bound its age by evicting the oldest pending plane before
            // appending the newest complete result.  The active publication
            // remains immutable until the FPGA acknowledges it.
            publication_queue_read_index_ =
                (publication_queue_read_index_ + 1) %
                PublicationBufferCount;
            publication_queue_replacements_.fetch_add(
                1, std::memory_order_relaxed);
            --publication_queue_count_;
        }
        publication_queue_[publication_queue_write_index_] = index;
        publication_queue_write_index_ =
            (publication_queue_write_index_ + 1) % PublicationBufferCount;
        ++publication_queue_count_;
        auto high_water = publication_queue_high_water_.load(
            std::memory_order_relaxed);
        while (high_water < publication_queue_count_ &&
               !publication_queue_high_water_.compare_exchange_weak(
                   high_water, publication_queue_count_,
                   std::memory_order_relaxed,
                   std::memory_order_relaxed)) {
        }
        return true;
    }

    int dequeue_publication_buffer_locked()
    {
        if (publication_queue_count_ == 0) return -1;
        const auto index = publication_queue_[publication_queue_read_index_];
        publication_queue_read_index_ =
            (publication_queue_read_index_ + 1) % PublicationBufferCount;
        --publication_queue_count_;
        return index;
    }

    bool copy_rendered_frame(
        std::uint32_t frame, melonDS::Renderer& renderer)
    {
        auto copy_started = std::chrono::steady_clock::time_point {};
        if (pipeline_profile_enabled_)
            copy_started = std::chrono::steady_clock::now();
        bool copied_plane_has_alpha = false;
        std::uint32_t* destination = native_frame_.data();
        int destination_index = -1;
        const bool identical = renderer.Is3DFrameIdentical();
        const auto completed_generation = completed_plane_generation_;
        const bool reuse_published_plane =
            asynchronous_plane_publication_ && identical &&
            completed_generation != 0 &&
            published_plane_generation_.load(std::memory_order_acquire) ==
                completed_generation;
        if (asynchronous_plane_publication_) {
            std::lock_guard<std::mutex> lock(publication_mutex_);
            destination_index = reserve_publication_buffer_locked();
            if (destination_index < 0)
                return fail(
                    FaultBadFrame,
                    "no safe private 3D publication buffer is available");
            publication_filling_index_ = destination_index;
            destination = publication_frames_[destination_index].data();
        }
        if (reuse_published_plane) {
            {
                std::lock_guard<std::mutex> lock(publication_mutex_);
                publication_frame_numbers_[destination_index] = frame;
                publication_frame_reuses_plane_[destination_index] = true;
                publication_frame_generations_[destination_index] =
                    completed_generation;
                publication_filling_index_ = -1;
                if (!enqueue_publication_buffer_locked(destination_index))
                    return fail(
                        FaultBadFrame,
                        "identical 3D publication could not be queued");
            }
            publication_cv_.notify_one();
            ++frames_rendered_;
            identical_plane_republications_.fetch_add(
                1, std::memory_order_relaxed);
            return true;
        }
        for (std::uint32_t y = 0; y < PlaneHeight; ++y) {
            const auto* line = renderer.Get3DScanline(y);
            if (!line) {
                if (asynchronous_plane_publication_) {
                    std::lock_guard<std::mutex> lock(publication_mutex_);
                    publication_filling_index_ = -1;
                }
                return fail(FaultBadFrame, "melonDS returned a null 3D line");
            }
            auto* destination_line =
                destination + std::size_t(y) * PlaneWidth;
            if (copied_plane_has_alpha) {
                // Alpha is a frame-wide yes/no result. Once one row proves
                // the plane visible, let libc's wider tuned copy handle all
                // remaining rows instead of continuing the fused OR scan on
                // CPU1's replay-critical path.
                std::memcpy(
                    destination_line, line,
                    PlaneWidth * sizeof(std::uint32_t));
            } else {
                copied_plane_has_alpha = copy_plane_row_and_has_alpha(
                    destination_line, line, PlaneWidth);
            }
        }
        catchup_visibility_taint_.complete_render(
            arm_render_visibility_generation_, copied_plane_has_alpha);
        if (!identical || completed_plane_generation_ == 0)
            ++completed_plane_generation_;
        if (asynchronous_plane_publication_) {
            {
                std::lock_guard<std::mutex> lock(publication_mutex_);
                publication_frame_numbers_[destination_index] = frame;
                publication_frame_reuses_plane_[destination_index] = false;
                publication_frame_generations_[destination_index] =
                    completed_plane_generation_;
                const bool sample_plane =
                    plane_stats_enabled_ &&
                    !plane_samples_dumped_.load(std::memory_order_acquire);
                PlaneSample sample {};
                if (sample_plane)
                    sample = summarize_plane(
                        frame, arm_render_sequence_,
                        arm_render_polygon_count_, destination);
                publication_frame_has_alpha_[destination_index] =
                    sample_plane ? sample.alpha_pixels != 0 :
                        copied_plane_has_alpha;
                publication_frame_expected_alpha_[destination_index] =
                    arm_render_expected_alpha_;
                if (sample_plane)
                    publication_frame_samples_[destination_index] = sample;
                publication_filling_index_ = -1;
                if (!enqueue_publication_buffer_locked(destination_index))
                    return fail(
                        FaultBadFrame,
                        "completed 3D publication buffer could not be queued");
            }
            publication_cv_.notify_one();
            ++frames_rendered_;
            if (pipeline_profile_enabled_)
                record_profile_sample(
                    arm_render_copies_, arm_render_copy_total_ns_,
                    arm_render_copy_max_ns_, copy_started);
            return true;
        }
        pending_frame_number_ = frame;
        pending_frame_has_alpha_ = copied_plane_has_alpha;
        pending_frame_expected_alpha_ = arm_render_expected_alpha_;
        frame_pending_ = true;
        ++frames_rendered_;
        if (pipeline_profile_enabled_)
            record_profile_sample(
                arm_render_copies_, arm_render_copy_total_ns_,
                arm_render_copy_max_ns_, copy_started);
        return true;
    }

    void start_publication_worker()
    {
        publication_stop_ = false;
        publication_worker_ = std::thread([this] {
            if (bind_hps_worker_cores_) {
                try {
                    // Current hybrid-plane profiling measures the CPU0 3D
                    // renderer at roughly 3.7x the CPU1 replay cost. Plane
                    // publication is bounded and FIFO-prioritized, so place it
                    // on CPU1 with replay instead of preempting rasterization
                    // for every completed frame.
                    bind_current_thread_to_cpu(1);
                    prioritize_current_thread_for_publication();
                } catch (const std::exception& error) {
                    publication_fail(error.what());
                    return;
                }
            }
            publication_worker_loop();
        });
    }

    void stop_publication_worker()
    {
        if (!publication_worker_.joinable()) return;
        {
            std::lock_guard<std::mutex> lock(publication_mutex_);
            publication_stop_ = true;
            publication_queue_read_index_ = 0;
            publication_queue_write_index_ = 0;
            publication_queue_count_ = 0;
        }
        publication_cv_.notify_one();
        publication_worker_.join();
    }

    void publication_fail(std::string message)
    {
        std::lock_guard<std::mutex> lock(publication_mutex_);
        if (publication_stop_) return;
        publication_worker_error_ = std::move(message);
        publication_worker_fault_.store(true, std::memory_order_release);
    }

    bool publication_worker_faulted() const
    {
        return publication_worker_fault_.load(std::memory_order_acquire);
    }

    std::string publication_worker_error()
    {
        std::lock_guard<std::mutex> lock(publication_mutex_);
        return publication_worker_error_.empty() ?
            "asynchronous 3D plane publication failed" :
            publication_worker_error_;
    }

    static void update_profile_max(
        std::atomic<std::uint64_t>& maximum, std::uint64_t sample)
    {
        auto observed = maximum.load(std::memory_order_relaxed);
        while (observed < sample &&
               !maximum.compare_exchange_weak(
                   observed, sample, std::memory_order_relaxed,
                   std::memory_order_relaxed)) {
        }
    }

    static void record_profile_sample(
        std::atomic<std::uint64_t>& count,
        std::atomic<std::uint64_t>& total_ns,
        std::atomic<std::uint64_t>& maximum_ns,
        std::chrono::steady_clock::time_point started)
    {
        const auto elapsed = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - started).count());
        count.fetch_add(1, std::memory_order_relaxed);
        total_ns.fetch_add(elapsed, std::memory_order_relaxed);
        update_profile_max(maximum_ns, elapsed);
    }

    static std::uint64_t profile_elapsed_ns(
        std::chrono::steady_clock::time_point started)
    {
        return static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - started).count());
    }

    static void record_plain_profile_sample(
        std::uint64_t& count, std::uint64_t& total_ns,
        std::uint64_t& maximum_ns,
        std::chrono::steady_clock::time_point started)
    {
        const auto elapsed = profile_elapsed_ns(started);
        ++count;
        total_ns += elapsed;
        maximum_ns = std::max(maximum_ns, elapsed);
    }

    void record_kind_run(
        std::uint32_t kind_index,
        std::chrono::steady_clock::time_point started)
    {
        if (kind_index >= replay_kind_run_total_ns_.size()) return;
        const auto elapsed = profile_elapsed_ns(started);
        ++replay_kind_runs_[kind_index];
        replay_kind_run_total_ns_[kind_index] += elapsed;
        replay_kind_run_max_ns_[kind_index] = std::max(
            replay_kind_run_max_ns_[kind_index], elapsed);
    }

    void publication_worker_loop()
    {
        for (;;) {
            int index = -1;
            std::uint32_t frame = 0;
            {
                std::unique_lock<std::mutex> lock(publication_mutex_);
                publication_cv_.wait(lock, [this] {
                    return publication_stop_ || publication_queue_count_ != 0;
                });
                if (publication_stop_) return;
                index = dequeue_publication_buffer_locked();
                if (index < 0) {
                    publication_worker_error_ =
                        "publication queue became empty while locked";
                    publication_worker_fault_.store(
                        true, std::memory_order_release);
                    return;
                }
                publication_active_index_ = index;
                frame = publication_frame_numbers_[index];
            }

            if (arm_video_render_shadow_) {
                bool published = false;
                while (!published) {
                    {
                        std::lock_guard<std::mutex> lock(publication_mutex_);
                        if (publication_stop_) return;
                    }
                    std::uint32_t producer = 0;
                    std::uint32_t acknowledged = 0;
                    if (!nds4mister::h3d::load_counter(
                            &header_.frame_publish_sequence,
                            &header_.frame_publish_sequence_reserved,
                            producer) ||
                        !nds4mister::h3d::load_counter(
                            &header_.frame_ack_sequence,
                            &header_.frame_ack_sequence_reserved,
                            acknowledged) ||
                        (producer & 1u) != 0 || acknowledged > producer ||
                        producer - acknowledged > 2) {
                        publication_fail(
                            "invalid asynchronous full-frame fence");
                        return;
                    }
                    if (producer != acknowledged) {
                        std::this_thread::sleep_for(HpsQueuePollInterval);
                        continue;
                    }
                    auto publication_started =
                        std::chrono::steady_clock::time_point {};
                    if (pipeline_profile_enabled_)
                        publication_started = std::chrono::steady_clock::now();
                    if (!full_frame_publisher_.publish(
                            session_, frame,
                            arm_video_frames_[index][0].data(),
                            arm_video_frames_[index][1].data(), true)) {
                        publication_fail(
                            "asynchronous full-frame publication failed");
                        return;
                    }
                    if (pipeline_profile_enabled_)
                        record_profile_sample(
                            full_frame_publications_,
                            full_frame_publication_total_ns_,
                            full_frame_publication_max_ns_, publication_started);
                    published = true;
                    frames_published_.fetch_add(
                        1, std::memory_order_relaxed);
                }

                std::lock_guard<std::mutex> lock(publication_mutex_);
                publication_active_index_ = -1;
                continue;
            }

            const bool reuses_plane =
                publication_frame_reuses_plane_[index];
            if (!reuses_plane && !plane_visibility_filter_.publish(
                    publication_frame_has_alpha_[index],
                    publication_frame_expected_alpha_[index])) {
                std::lock_guard<std::mutex> lock(publication_mutex_);
                publication_active_index_ = -1;
                continue;
            }

            bool published = false;
            auto acknowledgement_wait_started =
                std::chrono::steady_clock::time_point {};
            if (pipeline_profile_enabled_)
                acknowledgement_wait_started = std::chrono::steady_clock::now();
            while (!published) {
                {
                    std::lock_guard<std::mutex> lock(publication_mutex_);
                    if (publication_stop_) return;
                }
                std::uint32_t producer = 0;
                std::uint32_t acknowledged = 0;
                if (!nds4mister::h3d::load_counter(
                        &header_.frame_publish_sequence,
                        &header_.frame_publish_sequence_reserved, producer) ||
                    !nds4mister::h3d::load_counter(
                        &header_.frame_ack_sequence,
                        &header_.frame_ack_sequence_reserved, acknowledged) ||
                    (producer & 1u) != 0 || acknowledged > producer ||
                    producer - acknowledged > 2) {
                    publication_fail("invalid asynchronous plane fence");
                    return;
                }
                if (producer != acknowledged) {
                    if (pipeline_profile_enabled_)
                        plane_publication_wait_polls_.fetch_add(
                            1, std::memory_order_relaxed);
                    std::this_thread::sleep_for(HpsQueuePollInterval);
                    continue;
                }
                if (pipeline_profile_enabled_)
                    record_profile_sample(
                        plane_publication_ack_waits_,
                        plane_publication_ack_wait_total_ns_,
                        plane_publication_ack_wait_max_ns_,
                        acknowledgement_wait_started);
                auto publication_started =
                    std::chrono::steady_clock::time_point {};
                if (pipeline_profile_enabled_)
                    publication_started = std::chrono::steady_clock::now();
                const bool publication_ok = reuses_plane ?
                    publisher_.republish_last(
                        session_, frame,
                        &frame_publication_fence_active_) :
                    publisher_.publish(
                        session_, frame, publication_frames_[index].data(),
                        &frame_publication_fence_active_);
                if (!publication_ok) {
                    publication_fail("asynchronous 3D plane publication failed");
                    return;
                }
                if (pipeline_profile_enabled_)
                    record_profile_sample(
                        plane_publications_, plane_publication_total_ns_,
                        plane_publication_max_ns_, publication_started);
                published = true;
                frames_published_.fetch_add(1, std::memory_order_relaxed);
                if (!reuses_plane)
                    published_plane_generation_.store(
                        publication_frame_generations_[index],
                        std::memory_order_release);
                if (!reuses_plane)
                    retain_plane_sample(publication_frame_samples_[index]);
            }

            std::lock_guard<std::mutex> lock(publication_mutex_);
            publication_active_index_ = -1;
        }
    }

    bool shared_session_current(bool require_accepted) const
    {
        return nds4mister::h3d::active_session_current(
            header_, session_, 0, require_accepted);
    }

    void retain_plane_sample(const PlaneSample& sample)
    {
        if (!plane_stats_enabled_ ||
            plane_samples_dumped_.load(std::memory_order_acquire))
            return;
        // The bounded first 512 publications cover roughly 8.5 seconds at
        // 60 Hz, including both parities of an alternating output, without a
        // hot-path log stream or a new shared-memory ABI.
        plane_samples_[plane_sample_count_++] = sample;
        if (plane_sample_count_ == plane_samples_.size())
            dump_plane_samples();
    }

    void dump_plane_samples()
    {
        if (!plane_stats_enabled_ ||
            plane_samples_dumped_.load(std::memory_order_acquire) ||
            plane_sample_count_ == 0)
            return;
        std::ostringstream output;
        output << "H3D_PLANE_STATS_BEGIN count=" << plane_sample_count_ << '\n';
        for (std::size_t index = 0; index < plane_sample_count_; ++index) {
            const auto& sample = plane_samples_[index];
            output << "H3DP f=" << sample.frame
                   << " s=" << sample.packet_sequence
                   << " p=" << sample.polygons
                   << " a=" << sample.alpha_pixels
                   << " r=" << sample.alpha_rows
                   << " b=" << sample.min_x << ',' << sample.min_y << ','
                   << sample.max_x << ',' << sample.max_y
                   << " h=";
            output.setf(std::ios::hex, std::ios::basefield);
            output << sample.hash;
            output.setf(std::ios::dec, std::ios::basefield);
            output << '\n';
        }
        output << "H3D_PLANE_STATS_END\n";
        const auto contents = output.str();
        std::string temporary = std::string(PlaneStatsPath) + ".tmp.XXXXXX";
        std::vector<char> temporary_name(temporary.begin(), temporary.end());
        temporary_name.push_back('\0');
        const int fd = mkstemp(temporary_name.data());
        if (fd < 0) return;
        bool ok = write_all(
            fd, reinterpret_cast<const std::byte*>(contents.data()),
            contents.size());
        if (ok) ok = fsync(fd) == 0;
        if (close(fd) != 0) ok = false;
        if (ok)
            ok = rename(temporary_name.data(), PlaneStatsPath) == 0;
        if (!ok) {
            unlink(temporary_name.data());
            return;
        }
        std::cout << contents << std::flush;
        plane_samples_dumped_.store(true, std::memory_order_release);
    }

    void dump_pipeline_profile()
    {
        if (!pipeline_profile_enabled_) return;
        const auto elapsed_ns = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() -
                pipeline_profile_started_).count());
        const auto input_packets =
            replay_input_packets_.load(std::memory_order_relaxed);
        const auto replay_packets =
            replay_profile_packets_.load(std::memory_order_relaxed);
        const auto publications =
            full_frame_publications_.load(std::memory_order_relaxed);
        const auto renderer_profile =
            nds_->GPU.GetRenderer().GetExternalRendererStageProfile();
        std::ostringstream output;
        output << "H3D_PIPELINE_PROFILE_V1"
               << " session=" << session_
               << " elapsed_ns=" << elapsed_ns
               << " queue_capacity=" << ReplayQueueCapacity
               << " queue_high_water="
               << replay_queue_high_water_.load(std::memory_order_relaxed)
               << " queue_at_stop="
               << replay_queue_count()
               << " queue_full_polls="
               << replay_queue_full_polls_.load(std::memory_order_relaxed)
               << " input_packets=" << input_packets
               << " input_records="
               << replay_input_records_.load(std::memory_order_relaxed)
               << " input_total_ns="
               << replay_input_total_ns_.load(std::memory_order_relaxed)
               << " input_max_ns="
               << replay_input_max_ns_.load(std::memory_order_relaxed)
               << " input_average_ns="
               << (input_packets ?
                   replay_input_total_ns_.load(std::memory_order_relaxed) /
                       input_packets : 0)
               << " replay_packets=" << replay_packets
               << " replay_total_ns="
               << replay_profile_total_ns_.load(std::memory_order_relaxed)
               << " replay_max_ns="
               << replay_profile_max_ns_.load(std::memory_order_relaxed)
               << " replay_average_ns="
               << (replay_packets ?
                   replay_profile_total_ns_.load(std::memory_order_relaxed) /
                       replay_packets : 0)
               << " publications=" << publications
               << " publication_total_ns="
               << full_frame_publication_total_ns_.load(
                      std::memory_order_relaxed)
               << " publication_max_ns="
               << full_frame_publication_max_ns_.load(
                      std::memory_order_relaxed)
               << " publication_average_ns="
               << (publications ?
                   full_frame_publication_total_ns_.load(
                       std::memory_order_relaxed) / publications : 0)
               << " packets_acknowledged=" << packets_applied_
               << " replay_packets_applied="
               << replay_packets_applied_.load(std::memory_order_relaxed)
               << " replay_slot_capacity_growths="
               << replay_slot_capacity_growths_.load(
                      std::memory_order_relaxed)
               << " replay_slot_reuses="
               << replay_slot_reuses_.load(std::memory_order_relaxed)
               << " kind_gx_command=" << replay_record_kind_counts_[0]
               << " kind_gx_register=" << replay_record_kind_counts_[1]
               << " kind_vram_write=" << replay_record_kind_counts_[2]
               << " kind_vram_map=" << replay_record_kind_counts_[3]
               << " kind_gpu2d_register=" << replay_record_kind_counts_[4]
               << " kind_palette_write=" << replay_record_kind_counts_[5]
               << " kind_oam_write=" << replay_record_kind_counts_[6]
               << " kind_hblank=" << replay_record_kind_counts_[7]
               << " kind_gx_packed=" << replay_record_kind_counts_[8]
               << " gx_run_count=" << replay_kind_runs_[0]
               << " gx_run_total_ns=" << replay_kind_run_total_ns_[0]
               << " gx_run_max_ns=" << replay_kind_run_max_ns_[0]
               << " gx_register_run_count=" << replay_kind_runs_[1]
               << " gx_register_run_total_ns="
               << replay_kind_run_total_ns_[1]
               << " gx_register_run_max_ns=" << replay_kind_run_max_ns_[1]
               << " vram_run_count=" << replay_kind_runs_[2]
               << " vram_run_total_ns=" << replay_kind_run_total_ns_[2]
               << " vram_run_max_ns=" << replay_kind_run_max_ns_[2]
               << " vram_map_run_count=" << replay_kind_runs_[3]
               << " vram_map_run_total_ns=" << replay_kind_run_total_ns_[3]
               << " vram_map_run_max_ns=" << replay_kind_run_max_ns_[3]
               << " gpu2d_run_count=" << replay_kind_runs_[4]
               << " gpu2d_run_total_ns=" << replay_kind_run_total_ns_[4]
               << " gpu2d_run_max_ns=" << replay_kind_run_max_ns_[4]
               << " palette_run_count=" << replay_kind_runs_[5]
               << " palette_run_total_ns=" << replay_kind_run_total_ns_[5]
               << " palette_run_max_ns=" << replay_kind_run_max_ns_[5]
               << " oam_run_count=" << replay_kind_runs_[6]
               << " oam_run_total_ns=" << replay_kind_run_total_ns_[6]
               << " oam_run_max_ns=" << replay_kind_run_max_ns_[6]
               << " hblank_run_count=" << replay_kind_runs_[7]
               << " hblank_run_total_ns=" << replay_kind_run_total_ns_[7]
               << " hblank_run_max_ns=" << replay_kind_run_max_ns_[7]
               << " gx_packed_run_count=" << replay_kind_runs_[8]
               << " gx_packed_run_total_ns="
               << replay_kind_run_total_ns_[8]
               << " gx_packed_run_max_ns="
               << replay_kind_run_max_ns_[8]
               << " packet_boundaries=" << replay_packet_boundaries_
               << " packet_boundary_total_ns="
               << replay_packet_boundary_total_ns_
               << " packet_boundary_max_ns=" << replay_packet_boundary_max_ns_
               << " continuation_runs=" << replay_continuation_runs_
               << " continuation_run_total_ns="
               << replay_continuation_run_total_ns_
               << " continuation_run_max_ns="
               << replay_continuation_run_max_ns_
               << " geometry_flushes=" << geometry_flushes_
               << " geometry_flush_total_ns=" << geometry_flush_total_ns_
               << " geometry_flush_max_ns=" << geometry_flush_max_ns_
               << " external_vram_flushes=" << external_vram_flushes_
               << " external_vram_flush_total_ns="
               << external_vram_flush_total_ns_
               << " external_vram_flush_max_ns="
               << external_vram_flush_max_ns_
               << " arm_video_render_phases=" << arm_video_render_phases_
               << " arm_video_render_phase_total_ns="
               << arm_video_render_phase_total_ns_
               << " arm_video_render_phase_max_ns="
               << arm_video_render_phase_max_ns_
               << " arm_video_skip_phases=" << arm_video_skip_phases_
               << " arm_video_skip_phase_total_ns="
               << arm_video_skip_phase_total_ns_
               << " arm_video_skip_phase_max_ns="
               << arm_video_skip_phase_max_ns_
               << " arm_video_fences=" << arm_video_fences_
               << " arm_video_fence_total_ns=" << arm_video_fence_total_ns_
               << " arm_video_fence_max_ns=" << arm_video_fence_max_ns_
               << " arm_video_scanlines=" << arm_video_scanlines_
               << " arm_video_scanline_total_ns="
               << arm_video_scanline_total_ns_
               << " arm_video_scanline_max_ns=" << arm_video_scanline_max_ns_
               << " arm_video_cache_lines=" << arm_video_cache_lines_
               << " arm_video_cache_hits_a=" << arm_video_cache_hits_a_
               << " arm_video_cache_hits_b=" << arm_video_cache_hits_b_
               << " arm_video_cache_double_hits="
               << arm_video_cache_double_hits_
               << " renderer_scanlines=" << renderer_profile.Scanlines
               << " renderer_scanline_total_ns="
               << renderer_profile.ScanlineTotalNs
               << " renderer_output3d_ns=" << renderer_profile.Output3DNs
               << " renderer_cache_decision_ns="
               << renderer_profile.CacheDecisionNs
               << " renderer_engine_a_ns=" << renderer_profile.EngineANs
               << " renderer_engine_b_ns=" << renderer_profile.EngineBNs
               << " renderer_composite_a_ns="
               << renderer_profile.CompositeANs
               << " renderer_composite_b_ns="
               << renderer_profile.CompositeBNs
               << " renderer_cache_commit_ns="
               << renderer_profile.CacheCommitNs
               << " renderer_sprites_a_ns="
               << renderer_profile.SpritesANs
               << " renderer_sprites_b_ns="
               << renderer_profile.SpritesBNs
               << " renderer_parallel_wait_ns="
               << renderer_profile.ParallelWaitNs
               << " renderer_parallel_wait_max_ns="
               << renderer_profile.ParallelWaitMaxNs
               << " renderer_parallel_tasks="
               << renderer_profile.ParallelTasks
               << " renderer_parallel_worker_sleeps="
               << renderer_profile.ParallelWorkerSleeps
               << " renderer_parallel_spin_completions="
               << renderer_profile.ParallelSpinCompletions
               << " renderer_parallel_sleep_fallbacks="
               << renderer_profile.ParallelSleepFallbacks
               << " renderer_engine_b_max_ns="
               << renderer_profile.EngineBMaxNs
               << " renderer_sprites_b_max_ns="
               << renderer_profile.SpritesBMaxNs
               << " renderer_composite_fast_a="
               << renderer_profile.CompositeFastLines[0]
               << " renderer_composite_fast_b="
               << renderer_profile.CompositeFastLines[1]
               << " renderer_composite_mixed_a="
               << renderer_profile.CompositeMixedLines[0]
               << " renderer_composite_mixed_b="
               << renderer_profile.CompositeMixedLines[1]
               << " renderer_composite_slow_a="
               << renderer_profile.CompositeSlowLines[0]
               << " renderer_composite_slow_b="
               << renderer_profile.CompositeSlowLines[1]
               << " renderer_3d_frames="
               << renderer_profile.ThreeDFrames
               << " renderer_3d_identical_frames="
               << renderer_profile.ThreeDIdenticalFrames
               << " renderer_3d_coherence_ns="
               << renderer_profile.ThreeDCoherenceNs
               << " renderer_3d_clear_ns="
               << renderer_profile.ThreeDClearNs
               << " renderer_3d_setup_ns="
               << renderer_profile.ThreeDSetupNs
               << " renderer_3d_raster_ns="
               << renderer_profile.ThreeDRasterNs
               << " renderer_3d_final_pass_ns="
               << renderer_profile.ThreeDFinalPassNs
               << " renderer_3d_parallel_frames="
               << renderer_profile.ThreeDParallelFrames
               << " renderer_3d_primary_raster_ns="
               << renderer_profile.ThreeDPrimaryRasterNs
               << " renderer_3d_secondary_raster_ns="
               << renderer_profile.ThreeDSecondaryRasterNs
               << " renderer_3d_parallel_join_ns="
               << renderer_profile.ThreeDParallelJoinNs
               << " renderer_3d_adaptive_frames="
               << renderer_profile.ThreeDAdaptiveFrames
               << " renderer_3d_adaptive_primary_permille_total="
               << renderer_profile.ThreeDAdaptivePrimaryPermilleTotal
               << " renderer_3d_adaptive_primary_permille_min="
               << renderer_profile.ThreeDAdaptivePrimaryPermilleMin
               << " renderer_3d_adaptive_primary_permille_max="
               << renderer_profile.ThreeDAdaptivePrimaryPermilleMax
               << " renderer_3d_adaptive_split_line_total="
               << renderer_profile.ThreeDAdaptiveSplitLineTotal
               << " renderer_3d_adaptive_split_line_min="
               << renderer_profile.ThreeDAdaptiveSplitLineMin
               << " renderer_3d_adaptive_split_line_max="
               << renderer_profile.ThreeDAdaptiveSplitLineMax
               << " renderer_3d_band_queue_frames="
               << renderer_profile.ThreeDBandQueueFrames
               << " renderer_3d_band_queue_jobs="
               << renderer_profile.ThreeDBandQueueJobs
               << " renderer_3d_band_queue_advanced_scanlines="
               << renderer_profile.ThreeDBandQueueAdvancedScanlines
               << " renderer_3d_band_queue_shadow_fallback_frames="
               << renderer_profile.ThreeDBandQueueShadowFallbackFrames
               << " renderer_3d_polygon_frames="
               << renderer_profile.ThreeDPolygonFrames
               << " renderer_3d_polygons="
               << renderer_profile.ThreeDPolygons
               << " renderer_3d_polygon_scanlines="
               << renderer_profile.ThreeDPolygonScanlines
               << " renderer_3d_max_polygons="
               << renderer_profile.ThreeDMaxPolygons
               << " renderer_3d_scheduled_polygon_frames="
               << renderer_profile.ThreeDScheduledPolygonFrames
               << " render_skips="
               << replay_render_skips_.load(std::memory_order_relaxed)
               << " frame_render_admissions="
               << frame_render_admissions_.load(std::memory_order_relaxed)
               << " frame_render_local_fence_overlap="
               << frame_render_local_fence_overlap_.load(
                      std::memory_order_relaxed)
               << " frame_render_shared_fence_overlap="
               << frame_render_shared_fence_overlap_.load(
                      std::memory_order_relaxed)
               << " frame_drop_local_fence="
               << frame_drop_local_fence_.load(std::memory_order_relaxed)
               << " frame_drop_shared_fence="
               << frame_drop_shared_fence_.load(std::memory_order_relaxed)
               << " frame_drop_replay_budget="
               << frame_drop_replay_budget_.load(
                      std::memory_order_relaxed)
               << " geometry_discard_frames="
               << replay_geometry_discard_frames_
               << " geometry_discard_vertices="
               << nds_->GPU.GPU3D.ExternalDiscardedVertices
               << " arm_render_finishes="
               << arm_render_finishes_.load(std::memory_order_relaxed)
               << " arm_render_finish_total_ns="
               << arm_render_finish_total_ns_.load(std::memory_order_relaxed)
               << " arm_render_finish_max_ns="
               << arm_render_finish_max_ns_.load(std::memory_order_relaxed)
               << " arm_render_copies="
               << arm_render_copies_.load(std::memory_order_relaxed)
               << " arm_render_copy_total_ns="
               << arm_render_copy_total_ns_.load(std::memory_order_relaxed)
               << " arm_render_copy_max_ns="
               << arm_render_copy_max_ns_.load(std::memory_order_relaxed)
               << " identical_plane_republications="
               << identical_plane_republications_.load(
                      std::memory_order_relaxed)
               << " publication_queue_replacements="
               << publication_queue_replacements_.load(
                      std::memory_order_relaxed)
               << " publication_queue_high_water="
               << publication_queue_high_water_.load(
                      std::memory_order_relaxed)
               << " plane_publications="
               << plane_publications_.load(std::memory_order_relaxed)
               << " plane_publication_total_ns="
               << plane_publication_total_ns_.load(std::memory_order_relaxed)
               << " plane_publication_max_ns="
               << plane_publication_max_ns_.load(std::memory_order_relaxed)
               << " plane_publication_ack_waits="
               << plane_publication_ack_waits_.load(
                      std::memory_order_relaxed)
               << " plane_publication_ack_wait_total_ns="
               << plane_publication_ack_wait_total_ns_.load(
                      std::memory_order_relaxed)
               << " plane_publication_ack_wait_max_ns="
               << plane_publication_ack_wait_max_ns_.load(
                      std::memory_order_relaxed)
               << " plane_publication_wait_polls="
               << plane_publication_wait_polls_.load(
                      std::memory_order_relaxed)
               << " frames_rendered="
               << frames_rendered_.load(std::memory_order_relaxed)
               << " frames_published="
               << frames_published_.load(std::memory_order_relaxed);
        for (std::size_t command = 0;
             command < replay_gx_command_counts_.size(); ++command) {
            if (replay_gx_command_counts_[command] == 0) continue;
            output << " gx_command_" << command << '='
                   << replay_gx_command_counts_[command];
        }
        output << '\n';
        const auto contents = output.str();
        std::string temporary =
            std::string(PipelineProfilePath) + ".tmp.XXXXXX";
        std::vector<char> temporary_name(temporary.begin(), temporary.end());
        temporary_name.push_back('\0');
        const int fd = mkstemp(temporary_name.data());
        if (fd < 0) return;
        bool ok = write_all(
            fd, reinterpret_cast<const std::byte*>(contents.data()),
            contents.size());
        if (ok) ok = fsync(fd) == 0;
        if (close(fd) != 0) ok = false;
        if (ok)
            ok = rename(temporary_name.data(), PipelineProfilePath) == 0;
        if (!ok) unlink(temporary_name.data());
        if (ok) std::cout << contents << std::flush;
    }

    PollResult finish_frame_event()
    {
        const auto disposition = frame_disposition();
        if (disposition == FrameDisposition::Fault) return PollResult::Fault;
        if (disposition != FrameDisposition::Render)
            return fail_result(
                FaultBadFrame, "frame fence changed during rendering");
        if (!plane_visibility_filter_.publish(
                pending_frame_has_alpha_,
                pending_frame_expected_alpha_)) {
            frame_pending_ = false;
            return PollResult::Applied;
        }
        if (!publisher_.publish(
                session_, pending_frame_number_, native_frame_.data()))
            return fail_result(FaultBadFrame, "3D plane publication failed");
        frames_published_.fetch_add(1, std::memory_order_relaxed);
        frame_pending_ = false;
        return PollResult::Applied;
    }

    PollResult acknowledge_terminal_packet()
    {
        if (!shared_session_current(true))
            return fail_result(
                FaultBadSession,
                "H3D1 changed before frame packet acknowledgement");
        if (!consumer_.acknowledge())
            return consumer_fault_result(
                "frame packet acknowledgement failed");
        packet_pending_ = false;
        packet_saw_swap_ = false;
        ++packets_applied_;
        return PollResult::Applied;
    }

    bool packet_backlog_after(
        std::uint32_t acknowledged_sequence, std::uint32_t& backlog)
    {
        std::uint32_t producer = 0;
        if (!nds4mister::h3d::load_counter(
                &header_.producer_sequence,
                &header_.producer_sequence_reserved, producer))
            return fail(FaultBadFrame, "invalid producer fence after ACK");
        if (producer < acknowledged_sequence ||
            producer - acknowledged_sequence > frame_packet::SlotCount)
            return fail(FaultBadFrame, "invalid packet backlog after ACK");
        backlog = producer - acknowledged_sequence;
        return true;
    }

    bool retain_texture_record(const frame_packet::Record& record)
    {
        if (texture_trace_path_.empty() ||
            !frame_packet::diagnostic_record_selected(record))
            return true;
        if (frame_packet::record_kind(record) ==
            frame_packet::RecordKind::GxPacked) {
            for (std::size_t index = 0; index < 3; ++index) {
                const auto command =
                    frame_packet::unpack_gx_command(record, index);
                if (!frame_packet::diagnostic_record_selected(command))
                    continue;
                texture_trace_records_.push_back(command);
                texture_trace_state_ =
                    frame_packet::diagnostic_crc32c_update(
                        texture_trace_state_, command);
            }
            return true;
        }
        texture_trace_records_.push_back(record);
        texture_trace_state_ = frame_packet::diagnostic_crc32c_update(
            texture_trace_state_, record);
        return true;
    }

    bool texture_record_fits(const frame_packet::Record& record)
    {
        if (texture_trace_path_.empty())
            return true;
        const auto added = frame_packet::diagnostic_selected_count(record);
        if (added == 0 ||
            added <= MaxTextureTraceRecords -
                std::min(
                    texture_trace_records_.size(), MaxTextureTraceRecords))
            return true;
        return fail(
            FaultBadEvent, "texture round-trip trace exceeded its bound");
    }

    bool texture_trace_matches_verifier()
    {
        if (texture_trace_path_.empty()) return true;
        if (texture_trace_records_.size() !=
                consumer_.verified_selected_count() ||
            frame_packet::diagnostic_crc32c_finalize(texture_trace_state_) !=
                consumer_.verified_crc32c())
            return fail(
                FaultBadEvent,
                "texture round-trip trace disagrees with verified H3V1 data");
        return true;
    }

    void complete_texture_trace()
    {
        if (texture_trace_path_.empty()) return;
        completed_texture_trace_.swap(texture_trace_records_);
        texture_trace_records_.clear();
        completed_trace_session_ = session_;
        completed_trace_sequence_ = packet_header_.packet_sequence;
        completed_trace_frame_ = packet_header_.frame;
        completed_trace_count_ = consumer_.verified_selected_count();
        completed_trace_crc32c_ = consumer_.verified_crc32c();
        completed_trace_valid_ = true;
        texture_trace_state_ = frame_packet::DiagnosticCrcInitial;
    }

    static void store_le16(std::byte* output, std::uint16_t value)
    {
        output[0] = static_cast<std::byte>(value & 0xffu);
        output[1] = static_cast<std::byte>((value >> 8) & 0xffu);
    }

    static void store_le32(std::byte* output, std::uint32_t value)
    {
        for (unsigned byte = 0; byte < 4; ++byte)
            output[byte] =
                static_cast<std::byte>((value >> (byte * 8)) & 0xffu);
    }

    static bool write_all(int fd, const std::byte* data, std::size_t bytes)
    {
        while (bytes != 0) {
            const auto written = ::write(fd, data, bytes);
            if (written < 0) {
                if (errno == EINTR) continue;
                return false;
            }
            if (written == 0) return false;
            data += static_cast<std::size_t>(written);
            bytes -= static_cast<std::size_t>(written);
        }
        return true;
    }

    void write_texture_trace_dump() noexcept
    {
        if (texture_trace_path_.empty() || !completed_trace_valid_) return;
        try {
            constexpr std::uint32_t TraceMagic = 0x31543348u; // H3T1
            constexpr std::uint16_t TraceVersion = 1;
            constexpr std::uint16_t TraceHeaderBytes = 64;
            std::array<std::byte, TraceHeaderBytes> header{};
            store_le32(header.data() + 0, TraceMagic);
            store_le16(header.data() + 4, TraceVersion);
            store_le16(header.data() + 6, TraceHeaderBytes);
            store_le32(header.data() + 8, completed_trace_session_);
            store_le32(header.data() + 12, completed_trace_sequence_);
            store_le32(header.data() + 16, completed_trace_frame_);
            store_le32(header.data() + 20, completed_trace_count_);
            store_le32(header.data() + 24, completed_trace_crc32c_);
            const auto payload_bytes = static_cast<std::uint32_t>(
                completed_texture_trace_.size() *
                frame_packet::RecordBytes);
            store_le32(header.data() + 28, payload_bytes);
            store_le32(
                header.data() + 32,
                static_cast<std::uint32_t>(frame_packet::RecordBytes));

            std::string temporary = texture_trace_path_ + ".tmp.XXXXXX";
            std::vector<char> temporary_name(
                temporary.begin(), temporary.end());
            temporary_name.push_back('\0');
            int fd = mkstemp(temporary_name.data());
            if (fd < 0) return;
            bool ok = write_all(fd, header.data(), header.size());
            std::array<std::byte, frame_packet::RecordBytes> encoded{};
            for (const auto& record : completed_texture_trace_) {
                store_le32(encoded.data() + 0, record.metadata);
                store_le32(encoded.data() + 4, record.address_or_aux);
                store_le32(
                    encoded.data() + 8,
                    static_cast<std::uint32_t>(record.data));
                store_le32(
                    encoded.data() + 12,
                    static_cast<std::uint32_t>(record.data >> 32));
                if (ok) ok = write_all(fd, encoded.data(), encoded.size());
            }
            if (ok) ok = fsync(fd) == 0;
            if (close(fd) != 0) ok = false;
            if (ok)
                ok = rename(
                    temporary_name.data(), texture_trace_path_.c_str()) == 0;
            if (!ok) {
                unlink(temporary_name.data());
                return;
            }
            std::ostringstream summary;
            summary << "H3D_TEXTURE_ROUNDTRIP path=" << texture_trace_path_
                    << " session=" << completed_trace_session_
                    << " terminal_seq=" << completed_trace_sequence_
                    << " frame=" << completed_trace_frame_
                    << " selected_count=" << completed_trace_count_
                    << " crc32c=0x";
            summary.setf(std::ios::hex, std::ios::basefield);
            summary.width(8);
            summary.fill('0');
            summary << completed_trace_crc32c_;
            summary.setf(std::ios::dec, std::ios::basefield);
            summary << " payload_bytes=" << payload_bytes;
            std::cout << summary.str() << '\n';
        } catch (...) {
            // Destruction and quiesce ownership must never be delayed or
            // converted into an exception by an optional diagnostic dump.
        }
    }

    std::byte* mapping_ = nullptr;
    std::byte* publication_mapping_ = nullptr;
    bool separate_publication_mapping_ = false;
    Header& header_;
    frame_packet::Consumer consumer_;
    PlanePublisher publisher_;
    nds4mister::h3d::FullFramePublisher full_frame_publisher_;
    nds4mister::ArmVideoShadow arm_video_shadow_;
    std::unique_ptr<melonDS::NDS> nds_;
    PlaneBuffer native_frame_ {};
    std::unique_ptr<FullVideoBuffer[]> arm_video_frames_ {
        new FullVideoBuffer[ArmVideoBufferCount] {}};
    std::unique_ptr<PlaneBuffer[]> publication_frames_ {
        new PlaneBuffer[PublicationBufferCount] {}};
    std::array<std::uint32_t, PublicationBufferCount>
        publication_frame_numbers_ {};
    std::array<bool, PublicationBufferCount> publication_frame_has_alpha_ {};
    std::array<bool, PublicationBufferCount>
        publication_frame_expected_alpha_ {};
    std::array<bool, PublicationBufferCount>
        publication_frame_reuses_plane_ {};
    std::array<std::uint64_t, PublicationBufferCount>
        publication_frame_generations_ {};
    std::array<PlaneSample, PublicationBufferCount>
        publication_frame_samples_ {};
    mutable std::mutex publication_mutex_;
    std::condition_variable publication_cv_;
    std::thread publication_worker_;
    std::atomic<bool> publication_worker_fault_ {false};
    std::atomic<std::uint64_t> frames_published_ {0};
    std::string publication_worker_error_;
    int publication_active_index_ = -1;
    int publication_filling_index_ = -1;
    std::array<int, PublicationBufferCount> publication_queue_ {};
    std::size_t publication_queue_read_index_ = 0;
    std::size_t publication_queue_write_index_ = 0;
    std::size_t publication_queue_count_ = 0;
    bool publication_stop_ = false;
    bool asynchronous_plane_publication_ = false;
    bool plane_stats_enabled_ = false;
    bool arm_video_render_shadow_ = false;
    bool asynchronous_arm_video_replay_ = false;
    bool pipeline_profile_enabled_ = false;
    bool bind_hps_worker_cores_ = false;
    nds4mister::crash::FpgaRuntimeTelemetry* runtime_telemetry_ = nullptr;
    bool arm_video_phase_started_ = false;
    bool arm_video_renderer_started_ = false;
    bool arm_video_render_in_flight_ = false;
    bool arm_video_render_this_frame_ = false;
    std::uint32_t arm_video_skipped_frames_ = 0;
    bool arm_video_frame_ready_ = false;
    std::uint32_t arm_video_frame_ = 0;
    int arm_video_completed_index_ = -1;
    std::atomic<bool> frame_publication_fence_active_ {false};
    bool arm_render_pending_ = false;
    bool arm_render_expected_alpha_ = false;
    CatchupVisibilityTaint::Generation arm_render_visibility_generation_ = 0;
    std::uint32_t arm_render_sequence_ = 0;
    std::uint32_t arm_render_polygon_count_ = 0;
    PlaneVisibilityFilter plane_visibility_filter_;
    std::uint32_t arm_render_frame_ = 0;
    std::uint32_t session_ = 0;
    std::uint32_t pending_frame_number_ = 0;
    bool pending_frame_has_alpha_ = false;
    bool pending_frame_expected_alpha_ = false;
    std::uint64_t completed_plane_generation_ = 0;
    std::atomic<std::uint64_t> published_plane_generation_ {0};
    std::uint64_t last_timestamp_ = 0;
    std::uint32_t heartbeat_ = 0;
    std::uint32_t heartbeat_poll_count_ = 0;
    std::uint64_t events_applied_ = 0;
    std::uint64_t packets_applied_ = 0;
    std::atomic<std::uint64_t> frames_rendered_ {0};
    std::array<PlaneSample, 512> plane_samples_ {};
    std::size_t plane_sample_count_ = 0;
    std::atomic<bool> plane_samples_dumped_ {false};
    std::uint64_t packet_timestamp_ = 0;
    // The 128-command experiment cut Run() call count by 44%, but increased
    // total geometry time and did not improve rendered or published FPS.
    // Retain the measured-safe lower batching latency.
    // No emulator consumer can observe state inside one contiguous normalized
    // GX run: register/VRAM records and every packet boundary explicitly flush
    // it. The old 64-command threshold forced 378,677 GPU3D::Run calls in a
    // 63.7-second NSMB profile. A 3,840-command experiment cut call count but
    // raised measured cost from 925 to 947 ns/command because overflow entries
    // took a second trip through melonDS's emergency stall queue. Batch at the
    // architectural 256-entry GX FIFO depth: four times fewer Run calls, with
    // no spill/reload pass and the same explicit ordering boundaries.
    static constexpr std::uint32_t GeometryRunBatch = 256;
    std::uint32_t pending_geometry_commands_ = 0;
    std::string error_;
    bool have_timestamp_ = false;
    bool frame_pending_ = false;
    bool packet_pending_ = false;
    bool packet_saw_swap_ = false;
    frame_packet::PacketHeader packet_header_ {};
    std::string texture_trace_path_;
    std::vector<frame_packet::Record> texture_trace_records_;
    std::vector<frame_packet::Record> completed_texture_trace_;
    std::uint32_t texture_trace_state_ =
        frame_packet::DiagnosticCrcInitial;
    std::uint32_t completed_trace_session_ = 0;
    std::uint32_t completed_trace_sequence_ = 0;
    std::uint32_t completed_trace_frame_ = 0;
    std::uint32_t completed_trace_count_ = 0;
    std::uint32_t completed_trace_crc32c_ = 0;
    bool completed_trace_valid_ = false;
    std::array<ReplayPacket, ReplayArenaCapacity> replay_queue_ {};
    std::size_t replay_read_index_ = 0;
    std::size_t replay_write_index_ = 0;
    nds4mister::replay::ReplaySpscState replay_state_;
    std::atomic<std::uint32_t> replay_queue_high_water_ {0};
    std::mutex replay_mutex_;
    std::condition_variable replay_cv_;
    std::thread replay_worker_;
    std::atomic<std::uint32_t> latest_replay_frame_ {0};
    std::uint32_t replay_render_skip_countdown_ = 0;
    std::uint32_t replay_render_cadence_ = 1;
    CatchupVisibilityTaint catchup_visibility_taint_;
    bool replay_frame_active_ = false;
    bool replay_frame_skip_render_ = false;
    bool replay_frame_discard_geometry_ = false;
    std::uint32_t replay_active_frame_ = 0;
    std::uint64_t replay_geometry_discard_frames_ = 0;
    std::atomic<std::uint64_t> replay_packets_applied_ {0};
    std::atomic<std::uint64_t> replay_slot_capacity_growths_ {0};
    std::atomic<std::uint64_t> replay_slot_reuses_ {0};
    std::atomic<std::uint64_t> replay_queue_full_polls_ {0};
    std::atomic<std::uint64_t> replay_input_packets_ {0};
    std::atomic<std::uint64_t> replay_input_records_ {0};
    std::atomic<std::uint64_t> replay_input_total_ns_ {0};
    std::atomic<std::uint64_t> replay_input_max_ns_ {0};
    std::atomic<std::uint64_t> replay_profile_packets_ {0};
    std::atomic<std::uint64_t> replay_profile_total_ns_ {0};
    std::atomic<std::uint64_t> replay_profile_max_ns_ {0};
    std::atomic<std::uint64_t> replay_render_skips_ {0};
    std::atomic<std::uint64_t> frame_render_admissions_ {0};
    std::atomic<std::uint64_t> frame_render_local_fence_overlap_ {0};
    std::atomic<std::uint64_t> frame_render_shared_fence_overlap_ {0};
    std::atomic<std::uint64_t> frame_drop_local_fence_ {0};
    std::atomic<std::uint64_t> frame_drop_shared_fence_ {0};
    std::atomic<std::uint64_t> frame_drop_replay_budget_ {0};
    std::atomic<std::uint64_t> arm_render_finishes_ {0};
    std::atomic<std::uint64_t> arm_render_finish_total_ns_ {0};
    std::atomic<std::uint64_t> arm_render_finish_max_ns_ {0};
    std::atomic<std::uint64_t> arm_render_copies_ {0};
    std::atomic<std::uint64_t> arm_render_copy_total_ns_ {0};
    std::atomic<std::uint64_t> arm_render_copy_max_ns_ {0};
    std::atomic<std::uint64_t> identical_plane_republications_ {0};
    std::atomic<std::uint64_t> publication_queue_replacements_ {0};
    std::atomic<std::size_t> publication_queue_high_water_ {0};
    std::atomic<std::uint64_t> plane_publications_ {0};
    std::atomic<std::uint64_t> plane_publication_total_ns_ {0};
    std::atomic<std::uint64_t> plane_publication_max_ns_ {0};
    std::atomic<std::uint64_t> plane_publication_ack_waits_ {0};
    std::atomic<std::uint64_t> plane_publication_ack_wait_total_ns_ {0};
    std::atomic<std::uint64_t> plane_publication_ack_wait_max_ns_ {0};
    std::atomic<std::uint64_t> plane_publication_wait_polls_ {0};
    std::array<std::uint64_t, 9> replay_record_kind_counts_ {};
    std::array<std::uint64_t, 256> replay_gx_command_counts_ {};
    std::array<std::uint64_t, 9> replay_kind_runs_ {};
    std::array<std::uint64_t, 9> replay_kind_run_total_ns_ {};
    std::array<std::uint64_t, 9> replay_kind_run_max_ns_ {};
    std::uint64_t replay_packet_boundaries_ = 0;
    std::uint64_t replay_packet_boundary_total_ns_ = 0;
    std::uint64_t replay_packet_boundary_max_ns_ = 0;
    std::uint64_t replay_continuation_runs_ = 0;
    std::uint64_t replay_continuation_run_total_ns_ = 0;
    std::uint64_t replay_continuation_run_max_ns_ = 0;
    std::uint64_t geometry_flushes_ = 0;
    std::uint64_t geometry_flush_total_ns_ = 0;
    std::uint64_t geometry_flush_max_ns_ = 0;
    std::uint64_t external_vram_flushes_ = 0;
    std::uint64_t external_vram_flush_total_ns_ = 0;
    std::uint64_t external_vram_flush_max_ns_ = 0;
    std::uint64_t arm_video_render_phases_ = 0;
    std::uint64_t arm_video_render_phase_total_ns_ = 0;
    std::uint64_t arm_video_render_phase_max_ns_ = 0;
    std::uint64_t arm_video_skip_phases_ = 0;
    std::uint64_t arm_video_skip_phase_total_ns_ = 0;
    std::uint64_t arm_video_skip_phase_max_ns_ = 0;
    std::uint64_t arm_video_fences_ = 0;
    std::uint64_t arm_video_fence_total_ns_ = 0;
    std::uint64_t arm_video_fence_max_ns_ = 0;
    std::uint64_t arm_video_scanlines_ = 0;
    std::uint64_t arm_video_scanline_total_ns_ = 0;
    std::uint64_t arm_video_scanline_max_ns_ = 0;
    std::uint64_t arm_video_cache_lines_ = 0;
    std::uint64_t arm_video_cache_hits_a_ = 0;
    std::uint64_t arm_video_cache_hits_b_ = 0;
    std::uint64_t arm_video_cache_double_hits_ = 0;
    std::atomic<std::uint64_t> full_frame_publications_ {0};
    std::atomic<std::uint64_t> full_frame_publication_total_ns_ {0};
    std::atomic<std::uint64_t> full_frame_publication_max_ns_ {0};
    std::atomic<bool> replay_stop_ {false};
    std::uint32_t replay_packet_frame_ = 0;
    std::uint32_t pending_external_vram_mask_ = 0;
    std::atomic<bool> faulted_ {false};
    std::chrono::steady_clock::time_point pipeline_profile_started_ {
        std::chrono::steady_clock::now()};
};

struct Fixture {
    std::vector<std::byte> bytes {MappingBytes};
    Header* header = reinterpret_cast<Header*>(bytes.data());
    std::uint32_t diagnostic_state = frame_packet::DiagnosticCrcInitial;
    std::uint32_t diagnostic_count = 0;

    explicit Fixture(std::uint32_t session)
    {
        *header = {};
        header->magic = nds4mister::h3d::Magic;
        header->version = nds4mister::h3d::Version;
        header->header_size = HeaderSize;
        header->fpga_session = session;
        // Packet mode owns words 2/3 as the 32-bit producer/ack counters;
        // the old event-ring entry count is the session high word and is zero.
        header->entry_count = 0;
        header->quiesce_request = session;
        header->quiesce_ack = session;
    }

    frame_packet::DiagnosticEntry* diagnostic(std::uint32_t sequence)
    {
        const auto index =
            (sequence - 1) & (frame_packet::DiagnosticEntryCount - 1);
        return reinterpret_cast<frame_packet::DiagnosticEntry*>(
            bytes.data() + frame_packet::DiagnosticMappingOffset +
            std::size_t(index) * frame_packet::DiagnosticEntryBytes);
    }

    void publish(
        std::uint32_t sequence, std::uint32_t frame, std::uint32_t flags,
        const std::vector<frame_packet::Record>& records)
    {
        const auto index = (sequence - 1) & (frame_packet::SlotCount - 1);
        auto* packet = reinterpret_cast<frame_packet::PacketHeader*>(
            bytes.data() + frame_packet::SlotsMappingOffset +
            std::size_t(index) * frame_packet::SlotBytes);
        *packet = {};
        packet->magic = frame_packet::Magic;
        packet->version = frame_packet::Version;
        packet->header_size = frame_packet::HeaderSize;
        packet->session = header->fpga_session;
        packet->packet_sequence = sequence;
        packet->frame = frame;
        packet->flags = flags;
        packet->payload_bytes = static_cast<std::uint32_t>(
            records.size() * frame_packet::RecordBytes);
        packet->record_count = static_cast<std::uint32_t>(records.size());
        packet->slot_index = index;
        if (!records.empty())
            std::memcpy(packet + 1, records.data(), packet->payload_bytes);
        for (const auto& record : records) {
            if (!frame_packet::diagnostic_record_selected(record)) continue;
            diagnostic_state = frame_packet::diagnostic_crc32c_update(
                diagnostic_state, record);
            diagnostic_count +=
                frame_packet::diagnostic_selected_count(record);
        }
        if (flags == frame_packet::FlagFrameEnd) {
            auto* verifier = diagnostic(sequence);
            *verifier = {};
            verifier->magic = frame_packet::DiagnosticMagic;
            verifier->version = frame_packet::DiagnosticVersion;
            verifier->entry_size = frame_packet::DiagnosticSize;
            verifier->session = header->fpga_session;
            verifier->terminal_sequence = sequence;
            verifier->frame = frame;
            verifier->selected_count = diagnostic_count;
            verifier->crc32c =
                frame_packet::diagnostic_crc32c_finalize(diagnostic_state);
            verifier->commit_sequence = sequence;
            diagnostic_state = frame_packet::DiagnosticCrcInitial;
            diagnostic_count = 0;
        }
        packet->commit_sequence = sequence;
        nds4mister::h3d::store_counter(
            &header->producer_sequence,
            &header->producer_sequence_reserved, sequence);
    }
};

frame_packet::Record packet_record(
    frame_packet::RecordKind kind, std::uint8_t tag, std::uint8_t be,
    std::uint32_t address, std::uint32_t data)
{
    frame_packet::Record record {};
    record.metadata = frame_packet::make_record_metadata(kind, tag, be);
    record.address_or_aux = address;
    record.data = data;
    return record;
}

[[noreturn]] void self_test_fail(const char* message)
{
    throw std::runtime_error(std::string("self-test: ") + message);
}

void run_self_test()
{
    constexpr std::uint32_t Session = 0x12345678;
    if (catchup_should_discard_geometry(1) ||
        catchup_should_discard_geometry(2) ||
        !catchup_should_discard_geometry(3) ||
        !catchup_should_discard_geometry(8))
        self_test_fail("mild catch-up discarded complete geometry");
    {
        std::array<std::uint32_t, 37> source {};
        std::array<std::uint32_t, 37> destination {};
        source[3] = 0x00abcdefu;
        source[35] = 0x1f123456u;
        if (!copy_plane_row_and_has_alpha(
                destination.data(), source.data(), source.size()) ||
            destination != source)
            self_test_fail("fused plane copy lost pixels or alpha");
        source[35] = 0x00123456u;
        if (copy_plane_row_and_has_alpha(
                destination.data(), source.data(), source.size()) ||
            destination != source)
            self_test_fail("fused plane copy invented alpha");
    }
    {
        PlaneVisibilityFilter filter;
        CatchupVisibilityTaint catchup_taint;
        std::array<std::uint32_t, PlanePixels> plane {};
        if (!filter.publish(false, false) || plane_has_alpha(plane.data()))
            self_test_fail("initial transparent plane was rejected");
        plane[123] = 0x01000000u;
        if (!plane_has_alpha(plane.data()) || !filter.publish(true, true))
            self_test_fail("populated plane was rejected");
        plane[std::size_t(7) * PlaneWidth + 5] = 0x1f010203u;
        plane[std::size_t(9) * PlaneWidth + 11] = 0x01040506u;
        const auto sample = summarize_plane(17, 23, 29, plane.data());
        if (sample.frame != 17 || sample.packet_sequence != 23 ||
            sample.polygons != 29 || sample.alpha_pixels != 3 ||
            sample.alpha_rows != 3 || sample.min_x != 5 ||
            sample.min_y != 0 || sample.max_x != 123 || sample.max_y != 9 ||
            sample.hash == 0)
            self_test_fail("plane summary is invalid");
        if (filter.publish(false, true) || filter.publish(false, true) ||
            filter.publish(false, true) || !filter.publish(true, true) ||
            filter.publish(false, true) || filter.publish(false, true) ||
            filter.publish(false, true) || !filter.publish(false, true))
            self_test_fail("suspicious transparent-plane filter is invalid");
        if (!filter.publish(true, true) || !filter.publish(false, false))
            self_test_fail("authoritative transparent-plane clear was rejected");
        filter.reset();
        if (!filter.publish(false, true))
            self_test_fail("transparent-plane filter reset failed");

        // A catch-up discard must not turn the next derived empty raster into
        // an authoritative clear.  Keep the last populated plane through the
        // exact repeated-empty sequence, then remove the taint only after a
        // genuinely populated render.  A later game-authored clear remains
        // immediate.
        filter.reset();
        if (!filter.publish(true, true))
            self_test_fail("catch-up visibility fixture rejected population");
        const auto pre_discard_generation =
            catchup_taint.capture_for_render();
        catchup_taint.mark_discarded();
        // An older asynchronous render may complete after this discard; its
        // visible result must not clear the newer catch-up taint.
        catchup_taint.complete_render(pre_discard_generation, true);
        const auto recovery_generation =
            catchup_taint.capture_for_render();
        if (!catchup_taint.active() ||
            filter.publish(
                false, catchup_taint.expected_alpha(
                    recovery_generation, false)) ||
            filter.publish(
                false, catchup_taint.expected_alpha(
                    recovery_generation, false)) ||
            filter.publish(
                false, catchup_taint.expected_alpha(
                    recovery_generation, false)))
            self_test_fail("catch-up discard published a derived empty plane");
        catchup_taint.complete_render(recovery_generation, true);
        if (catchup_taint.active() ||
            !filter.publish(
                true, catchup_taint.expected_alpha(
                    recovery_generation, true)) ||
            !filter.publish(
                false, catchup_taint.expected_alpha(
                    recovery_generation, false)))
            self_test_fail("catch-up visibility guard hid a real plane clear");
    }
    Fixture fixture(Session);
    const std::vector<frame_packet::Record> continuation {
        packet_record(
            frame_packet::RecordKind::GxRegister,
            static_cast<std::uint8_t>(AccessWidth::Half), 0x03,
            0x04000304, 0x0000820f),
        packet_record(
            frame_packet::RecordKind::Gpu2DRegister,
            static_cast<std::uint8_t>(AccessWidth::Half), 0x03,
            0x04000018, 0x00000123),
        packet_record(
            frame_packet::RecordKind::PaletteWrite,
            static_cast<std::uint8_t>(AccessWidth::Half), 0x03,
            0x05000024, 0x00007c1f),
        packet_record(
            frame_packet::RecordKind::OamWrite,
            static_cast<std::uint8_t>(AccessWidth::Word), 0x0f,
            0x07000410, 0x89abcdef),
        packet_record(
            frame_packet::RecordKind::HBlank, 0, 0, 7, 9),
        packet_record(
            frame_packet::RecordKind::VramMap,
            static_cast<std::uint8_t>(AccessWidth::Byte), 0x01,
            0x04000240, 0x00000080),
        packet_record(
            frame_packet::RecordKind::VramWrite,
            static_cast<std::uint8_t>(AccessWidth::Half), 0x03,
            0x06800000, 0x00002211),
        packet_record(
            frame_packet::RecordKind::GxRegister,
            static_cast<std::uint8_t>(AccessWidth::Half), 0x03,
            0x04000060, 0),
    };
    const std::vector<frame_packet::Record> terminal {
        packet_record(
            frame_packet::RecordKind::VramMap,
            static_cast<std::uint8_t>(AccessWidth::Byte), 0x04,
            0x04000240, 0x00820000),
        packet_record(
            frame_packet::RecordKind::VramWrite,
            static_cast<std::uint8_t>(AccessWidth::Half) | 4u, 0x03,
            0x06000000, 0x00006655),
        packet_record(
            frame_packet::RecordKind::GxCommand, 0x10, 0,
            0, 0),
        packet_record(
            frame_packet::RecordKind::GxCommand, 0x50, 0,
            0, 0),
    };
    fixture.publish(1, 9, frame_packet::FlagContinuation, continuation);
    fixture.publish(2, 9, frame_packet::FlagFrameEnd, terminal);

    // Keep the previous plane outstanding. The derived terminal image is
    // dropped, but the fully applied authoritative packet must still retire.
    fixture.header->frame_publish_sequence = 2;
    fixture.header->frame_ack_sequence = 0;

    Hybrid3DService service(fixture.bytes.data(), fixture.bytes.size());
    if (!service.initialize()) self_test_fail("valid service init failed");
    if (service.poll() != PollResult::Applied ||
        fixture.header->consumer_sequence != 1 ||
        service.events_applied() != continuation.size() ||
        service.frames_published() != 0)
        self_test_fail("CONT packet rendered or was not acknowledged");
    if (service.nds().ARM9Timestamp != 0 ||
        service.nds().ARM7Timestamp != 0)
        self_test_fail("non-command packet records advanced synthetic time");
    if (service.poll() != PollResult::Applied ||
        fixture.header->consumer_sequence != 2 ||
        service.events_applied() !=
            continuation.size() + terminal.size() ||
        service.frames_published() != 0 ||
        service.frames_rendered() != 0 ||
        fixture.header->frame_publish_sequence != 2 ||
        fixture.header->frame.sequence != 0)
        self_test_fail("busy return plane did not drop and retire cleanly");

    // Once the prior descriptor is acknowledged, a later terminal packet
    // publishes normally. The dropped frame must never be replayed late.
    fixture.header->frame_ack_sequence = 2;
    fixture.publish(3, 10, frame_packet::FlagFrameEnd, {});
    if (service.poll() != PollResult::Applied ||
        fixture.header->consumer_sequence != 3)
        self_test_fail("return-plane publication did not recover");
    if (fixture.header->service_state !=
            static_cast<std::uint32_t>(ServiceState::Ready))
        self_test_fail("service did not stay ready");
    if (fixture.header->frame_publish_sequence != 4 ||
        fixture.header->frame.sequence != 4 ||
        fixture.header->frame.session != Session ||
        fixture.header->frame.frame != 10 ||
        fixture.header->frame.format !=
            nds4mister::h3d::PixelFormatRgb666A5)
        self_test_fail("published frame descriptor is invalid");
    if (service.nds().ARM9Read8(0x06800000) != 0x11 ||
        service.nds().ARM9Read8(0x06800001) != 0x22)
        self_test_fail("ARM9 VRAM byte enables were not applied");
    if (service.nds().ARM7Read8(0x06000000) != 0x55 ||
        service.nds().ARM7Read8(0x06000001) != 0x66)
        self_test_fail("ARM7 VRAM byte enables were not applied");
    if (service.arm_video_shadow().gpu2d_registers(0)[0x18] != 0x23 ||
        service.arm_video_shadow().gpu2d_registers(0)[0x19] != 0x01)
        self_test_fail("shadow GPU2D register record was not reconstructed");
    const auto& shadow_palette = service.arm_video_shadow().memory(
        melonDS::NDS4MiSTer::Trace2DMemoryRegion::Palette);
    const auto& shadow_oam = service.arm_video_shadow().memory(
        melonDS::NDS4MiSTer::Trace2DMemoryRegion::OAM);
    if (shadow_palette[0x24] != 0x1f ||
        shadow_palette[0x25] != 0x7c ||
        shadow_oam[0x410] != 0xef || shadow_oam[0x411] != 0xcd ||
        shadow_oam[0x412] != 0xab || shadow_oam[0x413] != 0x89 ||
        !service.arm_video_shadow().have_compact_hblank() ||
        service.arm_video_shadow().compact_frame() != 9 ||
        service.arm_video_shadow().compact_line() != 7)
        self_test_fail("shadow palette/OAM/HBlank records were not reconstructed");
    if (service.nds().GPU.GPU2D_A.BGXPos[2] != 0x0123)
        self_test_fail("live melonDS BG2 scroll did not follow the shadow");
    if (service.nds().GPU.ReadPalette<melonDS::u16>(0x05000024) != 0x7c1f)
        self_test_fail("live melonDS palette did not follow the shadow");
    if (service.nds().GPU.ReadOAM<melonDS::u32>(0x07000410) != 0x89abcdef)
        self_test_fail("live melonDS OAM did not follow the shadow");

    // A complete visible phase prefix renders privately on ARM. A solid red
    // backdrop is deliberately asymmetric so this proves live screen routing
    // and color conversion rather than merely counting 192 markers.
    {
        Fixture arm_video_fixture(Session + 21);
        std::vector<frame_packet::Record> arm_video_records {
            packet_record(
                frame_packet::RecordKind::GxRegister,
                static_cast<std::uint8_t>(AccessWidth::Half), 0x03,
                0x04000304, 0x0000820f),
            packet_record(
                frame_packet::RecordKind::Gpu2DRegister,
                static_cast<std::uint8_t>(AccessWidth::Word), 0x0f,
                0x04000000, 0x00010000),
            packet_record(
                frame_packet::RecordKind::PaletteWrite,
                static_cast<std::uint8_t>(AccessWidth::Half), 0x03,
                0x05000000, 0x0000001f),
        };
        for (std::uint32_t line = 0; line <= 262; ++line) {
            arm_video_records.push_back(packet_record(
                frame_packet::RecordKind::HBlank, 0, 0, line, 77));
        }
        arm_video_records.push_back(packet_record(
            frame_packet::RecordKind::HBlank, 0, 0, 0, 78));
        arm_video_fixture.publish(
            1, 77, frame_packet::FlagContinuation, arm_video_records);
        Hybrid3DService arm_video_service(
            arm_video_fixture.bytes.data(), arm_video_fixture.bytes.size(),
            {}, true, false, true);
        if (!arm_video_service.initialize() ||
            arm_video_service.poll() != PollResult::Applied ||
            arm_video_fixture.header->consumer_sequence != 1 ||
            !arm_video_service.arm_video_frame_ready() ||
            arm_video_service.arm_video_frame() != 77)
            self_test_fail("ARM full-video shadow did not complete a frame");
        for (unsigned attempt = 0;
             attempt < 250 && arm_video_service.frames_published() == 0;
             ++attempt)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (arm_video_service.frames_published() != 1 ||
            arm_video_fixture.header->frame_publish_sequence != 2 ||
            arm_video_fixture.header->frame.sequence != 2 ||
            arm_video_fixture.header->frame.frame != 77 ||
            arm_video_fixture.header->frame.bank != 1 ||
            arm_video_fixture.header->frame.format !=
                nds4mister::h3d::PixelFormatFullRgb666)
            self_test_fail("ARM full-video worker did not publish a frame");
        const auto top = arm_video_service.arm_video_pixel(0, 0, 191);
        const auto bottom = arm_video_service.arm_video_pixel(1, 0, 191);
        if (top != 0x2000003eu || bottom != 0xff3f3f3fu)
            self_test_fail("ARM full-video shadow did not render backdrop");
        const auto* framebuffer = reinterpret_cast<const std::uint32_t*>(
            arm_video_fixture.bytes.data() + FramebufferOffset);
        const auto bank_words =
            nds4mister::h3d::FullFrameBankStride / sizeof(std::uint32_t);
        const auto screen_words =
            nds4mister::h3d::FullFrameScreenStride /
            sizeof(std::uint32_t);
        if (framebuffer[bank_words] != 0x3eu ||
            framebuffer[bank_words + screen_words] != 0x3ffffu)
            self_test_fail("ARM full-video framebuffer packing is invalid");
    }

    // Production copies and acknowledges input independently of melonDS's
    // renderer. Three complete LCD packets must retire from the four-slot H3B
    // ring immediately, then replay in order on the private worker. A slower
    // worker may omit obsolete drawing, but it may not omit any packet.
    {
        Fixture replay_fixture(Session + 22);
        for (std::uint32_t sequence = 1; sequence <= 3; ++sequence) {
            std::vector<frame_packet::Record> records;
            records.reserve(263);
            if (sequence == 1) {
                records.push_back(packet_record(
                    frame_packet::RecordKind::VramMap,
                    static_cast<std::uint8_t>(AccessWidth::Byte), 0x01,
                    0x04000240, 0x00000081));
                records.push_back(packet_record(
                    frame_packet::RecordKind::VramWrite,
                    static_cast<std::uint8_t>(AccessWidth::Half), 0x03,
                    0x06000000, 0x00002211));
                records.push_back(packet_record(
                    frame_packet::RecordKind::VramWrite,
                    static_cast<std::uint8_t>(AccessWidth::Half), 0x0c,
                    0x06000002, 0x44330000));
            }
            for (std::uint32_t line = 0; line <= 262; ++line) {
                records.push_back(packet_record(
                    frame_packet::RecordKind::HBlank, 0, 0,
                    line, 100 + sequence));
            }
            replay_fixture.publish(
                sequence, 100 + sequence,
                frame_packet::FlagFrameEnd, records);
        }
        Hybrid3DService replay_service(
            replay_fixture.bytes.data(), replay_fixture.bytes.size(),
            {}, true, false, true, true);
        if (!replay_service.initialize())
            self_test_fail("asynchronous replay fixture init failed");
        for (std::uint32_t sequence = 1; sequence <= 3; ++sequence) {
            if (replay_service.poll() != PollResult::Applied ||
                replay_fixture.header->consumer_sequence != sequence)
                self_test_fail(
                    "asynchronous replay did not retire copied input");
        }
        for (unsigned attempt = 0;
             attempt < 2000 &&
                 replay_service.replay_packets_applied() != 3;
             ++attempt)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (replay_service.replay_packets_applied() != 3)
            self_test_fail("asynchronous replay worker lost packet order");
        if (replay_service.nds().GPU.ReadVRAM_ABG<melonDS::u32>(
                0x06000000) != 0x44332211 ||
            replay_service.nds().GPU.ExternalRenderMemorySequence != 1 ||
            replay_service.nds().GPU.ExternalRenderVRAMRevision[0] != 1)
            self_test_fail(
                "asynchronous replay did not batch ordered VRAM revisions");
    }

    // A maximum-size contiguous GX packet exercises fifteen complete batches.
    // It must drain completely at the packet boundary, preserve every command,
    // and advance the same synthetic clock that per-command replay used before
    // batching.
    {
        Fixture geometry_batch_fixture(Session + 24);
        std::vector<frame_packet::Record> records;
        records.reserve(frame_packet::MaxRecordCount);
        for (std::uint32_t index = 0;
             index < frame_packet::MaxRecordCount; ++index) {
            records.push_back(packet_record(
                frame_packet::RecordKind::GxCommand, 0x10, 0,
                0, index & 3u));
        }
        geometry_batch_fixture.publish(
            1, 150, frame_packet::FlagContinuation, records);
        Hybrid3DService geometry_batch_service(
            geometry_batch_fixture.bytes.data(),
            geometry_batch_fixture.bytes.size(),
            {}, true, false, false, true);
        if (!geometry_batch_service.initialize() ||
            geometry_batch_service.poll() != PollResult::Applied ||
            geometry_batch_fixture.header->consumer_sequence != 1)
            self_test_fail("maximum GX batch was not accepted");
        for (unsigned attempt = 0;
             attempt < 2000 &&
                 geometry_batch_service.replay_packets_applied() != 1;
             ++attempt)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        const auto step =
            (std::uint64_t {1} << 16) >>
            geometry_batch_service.nds().ARM9ClockShift;
        auto& geometry = geometry_batch_service.nds().GPU.GPU3D;
        if (geometry_batch_service.replay_packets_applied() != 1 ||
            geometry.GXCommandDrops != 0 ||
            !geometry.CmdPIPE.IsEmpty() || !geometry.CmdFIFO.IsEmpty() ||
            !geometry.CmdStallQueue.IsEmpty() ||
            geometry_batch_service.nds().ARM7Timestamp !=
                frame_packet::MaxRecordCount * step ||
            (geometry_batch_service.nds().ARM9Timestamp >>
                 geometry_batch_service.nds().ARM9ClockShift) !=
                frame_packet::MaxRecordCount * step)
            self_test_fail("maximum GX batch lost work or time");
    }

    // A packed run can begin after an ordinary GX command and therefore land
    // exactly on the shared 256-command batch boundary. It must flush there
    // before a following ordinary run computes its available batch capacity.
    {
        Fixture mixed_batch_fixture(Session + 28);
        std::vector<frame_packet::Record> records;
        records.reserve(87);
        const auto command = packet_record(
            frame_packet::RecordKind::GxCommand, 0x10, 0, 0, 0);
        records.push_back(command);
        for (std::uint32_t index = 0; index < 85; ++index)
            records.push_back(frame_packet::pack_gx_commands(
                command, command, command));
        records.push_back(command);
        mixed_batch_fixture.publish(
            1, 150, frame_packet::FlagContinuation, records);
        Hybrid3DService mixed_batch_service(
            mixed_batch_fixture.bytes.data(),
            mixed_batch_fixture.bytes.size(),
            {}, true, false, false, true);
        if (!mixed_batch_service.initialize() ||
            mixed_batch_service.poll() != PollResult::Applied ||
            mixed_batch_fixture.header->consumer_sequence != 1)
            self_test_fail("mixed packed GX batch was not accepted");
        for (unsigned attempt = 0;
             attempt < 2000 &&
                 mixed_batch_service.replay_packets_applied() != 1;
             ++attempt)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        const auto step =
            (std::uint64_t {1} << 16) >>
            mixed_batch_service.nds().ARM9ClockShift;
        if (mixed_batch_service.replay_packets_applied() != 1 ||
            mixed_batch_fixture.header->hps_fault_bits != 0 ||
            mixed_batch_service.nds().ARM7Timestamp != 257 * step)
            self_test_fail("mixed packed GX batch boundary failed");
    }

    // Use the synchronous per-record path as an in-process melonDS oracle for
    // the production contiguous-run path. Exercise lighting, texture state,
    // two-parameter vertices, polygon submission, and two FIFO flushes; the
    // resulting geometry state and vertex RAM must be byte-identical.
    {
        std::vector<frame_packet::Record> records;
        records.reserve(510);
        records.push_back(packet_record(
            frame_packet::RecordKind::GxCommand, 0x40, 0, 0, 0));
        for (std::uint32_t vertex = 0; vertex < 127; ++vertex) {
            records.push_back(packet_record(
                frame_packet::RecordKind::GxCommand, 0x21, 0, 0,
                0x000001ffu ^ vertex));
            records.push_back(packet_record(
                frame_packet::RecordKind::GxCommand, 0x22, 0, 0,
                (vertex << 16) | vertex));
            records.push_back(packet_record(
                frame_packet::RecordKind::GxCommand, 0x23, 0, 0,
                ((vertex * 3u) << 16) | (vertex * 2u)));
            records.push_back(packet_record(
                frame_packet::RecordKind::GxCommand, 0x23, 0, 0,
                vertex * 4u));
        }
        records.push_back(packet_record(
            frame_packet::RecordKind::GxCommand, 0x41, 0, 0, 0));

        std::vector<frame_packet::Record> packed_records;
        packed_records.reserve((records.size() + 2) / 3);
        std::size_t packed_index = 0;
        for (; packed_index + 2 < records.size(); packed_index += 3)
            packed_records.push_back(frame_packet::pack_gx_commands(
                records[packed_index], records[packed_index + 1],
                records[packed_index + 2]));
        for (; packed_index < records.size(); ++packed_index)
            packed_records.push_back(records[packed_index]);

        Fixture geometry_oracle_fixture(Session + 25);
        Fixture geometry_run_fixture(Session + 26);
        Fixture geometry_packed_fixture(Session + 27);
        geometry_oracle_fixture.publish(
            1, 151, frame_packet::FlagContinuation, records);
        geometry_run_fixture.publish(
            1, 151, frame_packet::FlagContinuation, records);
        geometry_packed_fixture.publish(
            1, 151, frame_packet::FlagContinuation, packed_records);
        Hybrid3DService geometry_oracle_service(
            geometry_oracle_fixture.bytes.data(),
            geometry_oracle_fixture.bytes.size());
        Hybrid3DService geometry_run_service(
            geometry_run_fixture.bytes.data(),
            geometry_run_fixture.bytes.size(),
            {}, false, false, false, true);
        Hybrid3DService geometry_packed_service(
            geometry_packed_fixture.bytes.data(),
            geometry_packed_fixture.bytes.size(),
            {}, false, false, false, true);
        if (!geometry_oracle_service.initialize() ||
            !geometry_run_service.initialize() ||
            !geometry_packed_service.initialize())
            self_test_fail("GX contiguous-run oracle fixture failed");
        // Keep the synchronous reference on melonDS's ordinary four-entry
        // GX pipe. The production services below use the hybrid contiguous
        // FIFO, so this comparison catches any ordering or terminal-state
        // change introduced by that transport-only fast path.
        geometry_oracle_service.nds().GPU.GPU3D.SetExternalCommandReplay(
            false);
        if (geometry_oracle_service.poll() != PollResult::Applied ||
            geometry_run_service.poll() != PollResult::Applied ||
            geometry_packed_service.poll() != PollResult::Applied)
            self_test_fail("GX contiguous-run oracle fixture failed");
        for (unsigned attempt = 0;
             attempt < 2000 &&
                 geometry_run_service.replay_packets_applied() != 1;
             ++attempt)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        for (unsigned attempt = 0;
             attempt < 2000 &&
                 geometry_packed_service.replay_packets_applied() != 1;
             ++attempt)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));

        const auto& oracle_nds = geometry_oracle_service.nds();
        const auto& run_nds = geometry_run_service.nds();
        const auto& packed_nds = geometry_packed_service.nds();
        const auto& oracle = oracle_nds.GPU.GPU3D;
        const auto& run = run_nds.GPU.GPU3D;
        const auto& packed = packed_nds.GPU.GPU3D;
        if (geometry_run_service.replay_packets_applied() != 1 ||
            geometry_packed_service.replay_packets_applied() != 1 ||
            geometry_oracle_fixture.header->consumer_sequence != 1 ||
            geometry_run_fixture.header->consumer_sequence != 1 ||
            geometry_packed_fixture.header->consumer_sequence != 1 ||
            oracle_nds.ARM7Timestamp != run_nds.ARM7Timestamp ||
            oracle_nds.ARM7Timestamp != packed_nds.ARM7Timestamp ||
            oracle_nds.ARM9Timestamp != run_nds.ARM9Timestamp ||
            oracle_nds.ARM9Timestamp != packed_nds.ARM9Timestamp ||
            oracle.GXCommandDrops != 0 || run.GXCommandDrops != 0 ||
            packed.GXCommandDrops != 0 ||
            !oracle.CmdPIPE.IsEmpty() || !oracle.CmdFIFO.IsEmpty() ||
            !oracle.CmdStallQueue.IsEmpty() || !run.CmdPIPE.IsEmpty() ||
            !run.CmdFIFO.IsEmpty() || !run.CmdStallQueue.IsEmpty() ||
            !packed.CmdPIPE.IsEmpty() || !packed.CmdFIFO.IsEmpty() ||
            !packed.CmdStallQueue.IsEmpty() ||
            oracle.ExecParamCount != run.ExecParamCount ||
            oracle.ExecParamCount != packed.ExecParamCount ||
            oracle.NumVertices == 0 || oracle.NumPolygons == 0 ||
            oracle.NumVertices != run.NumVertices ||
            oracle.NumVertices != packed.NumVertices ||
            oracle.NumPolygons != run.NumPolygons ||
            oracle.NumPolygons != packed.NumPolygons ||
            std::memcmp(
                oracle.CurVertex, run.CurVertex,
                sizeof(oracle.CurVertex)) != 0 ||
            std::memcmp(
                oracle.CurVertex, packed.CurVertex,
                sizeof(oracle.CurVertex)) != 0 ||
            std::memcmp(
                oracle.VertexColor, run.VertexColor,
                sizeof(oracle.VertexColor)) != 0 ||
            std::memcmp(
                oracle.VertexColor, packed.VertexColor,
                sizeof(oracle.VertexColor)) != 0 ||
            std::memcmp(
                oracle.RawTexCoords, run.RawTexCoords,
                sizeof(oracle.RawTexCoords)) != 0 ||
            std::memcmp(
                oracle.RawTexCoords, packed.RawTexCoords,
                sizeof(oracle.RawTexCoords)) != 0 ||
            std::memcmp(
                oracle.Normal, run.Normal, sizeof(oracle.Normal)) != 0 ||
            std::memcmp(
                oracle.Normal, packed.Normal, sizeof(oracle.Normal)) != 0 ||
            std::memcmp(
                oracle.VertexRAM, run.VertexRAM,
                oracle.NumVertices * sizeof(oracle.VertexRAM[0])) != 0)
            self_test_fail(
                "GX packed replay diverged from melonDS oracle");
        if (std::memcmp(
                oracle.VertexRAM, packed.VertexRAM,
                oracle.NumVertices * sizeof(oracle.VertexRAM[0])) != 0)
            self_test_fail(
                "GX packed vertex RAM diverged from melonDS oracle");
    }

    // Catch-up may discard only the derived polygon list for an obsolete
    // frame. Compare it with a full melonDS oracle across a subsequent visible
    // frame: persistent matrices, lighting/texture inputs, primitive state,
    // and the selected frame's vertex RAM must converge byte-for-byte.
    {
        auto make_geometry_nds = [] {
            melonDS::NDSArgs args;
            args.JIT = std::nullopt;
            auto nds = std::make_unique<melonDS::NDS>(
                std::move(args), nullptr);
            nds->Reset();
            nds->GPU.GPU3D.SetEnabled(true, true);
            nds->GPU.GPU3D.SetExternalCommandReplay(true);
            nds->GPU.GPU3D.SetHighResolutionCoordinatesEnabled(false);
            return nds;
        };
        auto oracle = make_geometry_nds();
        auto discard = make_geometry_nds();
        const auto push = [](melonDS::NDS& nds,
                             std::uint8_t command,
                             std::uint32_t parameter) {
            nds.GPU.GPU3D.WriteExternalNormalizedCommand(
                command, parameter);
            nds.ARM9Timestamp += std::uint64_t {1} << 16;
            nds.ARM9Target = nds.ARM9Timestamp;
            nds.ARM7Timestamp =
                nds.ARM9Timestamp >> nds.ARM9ClockShift;
            nds.ARM7Target = nds.ARM7Timestamp;
            nds.GPU.GPU3D.Run();
        };
        const auto vertex10 = [](std::int32_t x, std::int32_t y,
                                 std::int32_t z) {
            return (static_cast<std::uint32_t>(x) & 0x3ffu) |
                ((static_cast<std::uint32_t>(y) & 0x3ffu) << 10) |
                ((static_cast<std::uint32_t>(z) & 0x3ffu) << 20);
        };
        const auto first_frame = [&](melonDS::NDS& nds) {
            push(nds, 0x10, 1); // position matrix
            push(nds, 0x15, 0); // identity
            push(nds, 0x1c, 0x100);
            push(nds, 0x1c, 0);
            push(nds, 0x1c, 0);
            push(nds, 0x20, 0x00003def);
            push(nds, 0x22, 0x00200010);
            push(nds, 0x29, 0x001f00c0);
            push(nds, 0x40, 0);
            push(nds, 0x24, vertex10(-256, -256, 0));
            push(nds, 0x24, vertex10(256, -256, 0));
            push(nds, 0x24, vertex10(0, 256, 0));
            push(nds, 0x41, 0);
            push(nds, 0x50, 0);
        };
        const auto selected_frame = [&](melonDS::NDS& nds) {
            push(nds, 0x40, 0);
            push(nds, 0x24, vertex10(-192, -128, 0));
            push(nds, 0x24, vertex10(224, -96, 0));
            push(nds, 0x24, vertex10(32, 224, 0));
            push(nds, 0x41, 0);
            push(nds, 0x50, 0);
        };

        discard->GPU.GPU3D.SetExternalGeometryDiscard(true);
        first_frame(*oracle);
        first_frame(*discard);
        if (oracle->GPU.GPU3D.NumVertices == 0 ||
            oracle->GPU.GPU3D.NumPolygons == 0 ||
            discard->GPU.GPU3D.NumVertices != 0 ||
            discard->GPU.GPU3D.NumPolygons != 0 ||
            discard->GPU.GPU3D.ExternalDiscardedVertices != 3)
            self_test_fail(
                "obsolete-frame geometry was not selectively discarded");
        oracle->GPU.GPU3D.VBlank();
        discard->GPU.GPU3D.VBlank();
        discard->GPU.GPU3D.SetExternalGeometryDiscard(false);

        selected_frame(*oracle);
        selected_frame(*discard);
        const auto& oracle_gpu = oracle->GPU.GPU3D;
        const auto& discard_gpu = discard->GPU.GPU3D;
        if (oracle_gpu.NumVertices == 0 || oracle_gpu.NumPolygons == 0 ||
            oracle_gpu.NumVertices != discard_gpu.NumVertices ||
            oracle_gpu.NumPolygons != discard_gpu.NumPolygons ||
            oracle_gpu.CurRAMBank != discard_gpu.CurRAMBank ||
            std::memcmp(
                oracle_gpu.PosMatrix, discard_gpu.PosMatrix,
                sizeof(oracle_gpu.PosMatrix)) != 0 ||
            std::memcmp(
                oracle_gpu.CurVertex, discard_gpu.CurVertex,
                sizeof(oracle_gpu.CurVertex)) != 0 ||
            std::memcmp(
                oracle_gpu.VertexColor, discard_gpu.VertexColor,
                sizeof(oracle_gpu.VertexColor)) != 0 ||
            std::memcmp(
                oracle_gpu.RawTexCoords, discard_gpu.RawTexCoords,
                sizeof(oracle_gpu.RawTexCoords)) != 0 ||
            std::memcmp(
                oracle_gpu.CurVertexRAM, discard_gpu.CurVertexRAM,
                oracle_gpu.NumVertices *
                    sizeof(oracle_gpu.CurVertexRAM[0])) != 0)
            self_test_fail(
                "visible geometry diverged after obsolete-frame discard");

        // Mario Kart can build one polygon buffer across multiple VBlanks and
        // issue FLUSH later. Once any list in that buffer is discarded, the
        // entire build remains non-renderable through its real FLUSH; mixing
        // later visible lists into the incomplete buffer produces black areas
        // and stray geometry.
        auto split_oracle = make_geometry_nds();
        auto split_discard = make_geometry_nds();
        for (auto* nds : {split_oracle.get(), split_discard.get()}) {
            push(*nds, 0x10, 1); // position matrix
            push(*nds, 0x15, 0); // identity
            push(*nds, 0x20, 0x00003def);
            push(*nds, 0x29, 0x001f00c0);
        }
        split_discard->GPU.GPU3D.SetExternalGeometryDiscard(true);
        push(*split_oracle, 0x40, 0);
        push(*split_discard, 0x40, 0);
        push(*split_oracle, 0x24, vertex10(-256, -256, 0));
        push(*split_discard, 0x24, vertex10(-256, -256, 0));
        push(*split_oracle, 0x24, vertex10(256, -256, 0));
        push(*split_discard, 0x24, vertex10(256, -256, 0));
        push(*split_oracle, 0x24, vertex10(0, 256, 0));
        push(*split_discard, 0x24, vertex10(0, 256, 0));
        push(*split_oracle, 0x41, 0);
        push(*split_discard, 0x41, 0);
        if (!split_discard->GPU.GPU3D
                 .ExternalGeometryDiscardInProgress() ||
            split_discard->GPU.GPU3D.NumVertices != 0 ||
            split_discard->GPU.GPU3D.NumPolygons != 0)
            self_test_fail(
                "discarded polygon buffer lost taint before flush");
        // The service's packet boundary toggles the external request. VBlank
        // itself does not own this taint; the following request transition is
        // the invariant that previously exposed the incomplete buffer.
        split_discard->GPU.GPU3D.SetExternalGeometryDiscard(false);
        if (!split_discard->GPU.GPU3D
                 .ExternalGeometryDiscardInProgress())
            self_test_fail(
                "discarded polygon buffer lost taint at frame boundary");

        // prepare_replay_frame() sees the carried taint and discards the
        // whole continuation frame.
        split_discard->GPU.GPU3D.SetExternalGeometryDiscard(true);
        push(*split_oracle, 0x40, 0);
        push(*split_discard, 0x40, 0);
        push(*split_oracle, 0x24, vertex10(-192, -128, 0));
        push(*split_discard, 0x24, vertex10(-192, -128, 0));
        push(*split_oracle, 0x24, vertex10(224, -96, 0));
        push(*split_discard, 0x24, vertex10(224, -96, 0));
        push(*split_oracle, 0x24, vertex10(32, 224, 0));
        push(*split_discard, 0x24, vertex10(32, 224, 0));
        push(*split_oracle, 0x41, 0);
        push(*split_discard, 0x41, 0);
        push(*split_oracle, 0x50, 0);
        push(*split_discard, 0x50, 0);
        if (split_discard->GPU.GPU3D
                .ExternalGeometryDiscardInProgress() ||
            split_discard->GPU.GPU3D.NumVertices != 0 ||
            split_discard->GPU.GPU3D.NumPolygons != 0 ||
            split_discard->GPU.GPU3D.ExternalDiscardedVertices != 6)
            self_test_fail(
                "tainted polygon buffer was not discarded through flush");
        split_oracle->GPU.GPU3D.VBlank();
        split_discard->GPU.GPU3D.VBlank();
        split_discard->GPU.GPU3D.SetExternalGeometryDiscard(false);

        selected_frame(*split_oracle);
        selected_frame(*split_discard);
        const auto& split_oracle_gpu = split_oracle->GPU.GPU3D;
        const auto& split_discard_gpu = split_discard->GPU.GPU3D;
        if (split_oracle_gpu.NumVertices == 0 ||
            split_oracle_gpu.NumPolygons == 0 ||
            split_oracle_gpu.NumVertices != split_discard_gpu.NumVertices ||
            split_oracle_gpu.NumPolygons != split_discard_gpu.NumPolygons ||
            split_oracle_gpu.CurRAMBank != split_discard_gpu.CurRAMBank ||
            std::memcmp(
                split_oracle_gpu.CurVertexRAM,
                split_discard_gpu.CurVertexRAM,
                split_oracle_gpu.NumVertices *
                    sizeof(split_oracle_gpu.CurVertexRAM[0])) != 0)
            self_test_fail(
                "visible geometry diverged after tainted-buffer discard");
    }

    // The four-band scheduler may change only ownership of disjoint scanline
    // rows. Render the same polygon buffer through stock single-worker
    // melonDS and the queued dual-core path, then compare the externally
    // visible plane plus complete native color/depth/attribute buffers.
    {
        const auto saved_environment = [](const char* name) {
            const char* value = std::getenv(name);
            return value ? std::optional<std::string>(value) : std::nullopt;
        };
        const auto saved_dual = saved_environment("NDS4MISTER_DUAL_CORE_3D");
        const auto saved_adaptive =
            saved_environment("NDS4MISTER_ADAPTIVE_RASTER_SPLIT");
        const auto saved_bands =
            saved_environment("NDS4MISTER_RASTER_BAND_QUEUE");
        const auto saved_band_delay = saved_environment(
            "NDS4MISTER_RASTER_BAND_TEST_DELAY_WORKER");
        const auto restore_environment = [](const char* name,
                                            const auto& value) {
            if (value)
                setenv(name, value->c_str(), 1);
            else
                unsetenv(name);
        };
        const auto make_renderer_nds = [](bool band_queue) {
            if (band_queue)
            {
                setenv("NDS4MISTER_DUAL_CORE_3D", "1", 1);
                setenv("NDS4MISTER_ADAPTIVE_RASTER_SPLIT", "1", 1);
                setenv("NDS4MISTER_RASTER_BAND_QUEUE", "1", 1);
                setenv(
                    "NDS4MISTER_RASTER_BAND_TEST_DELAY_WORKER", "1", 1);
            }
            else
            {
                unsetenv("NDS4MISTER_DUAL_CORE_3D");
                unsetenv("NDS4MISTER_ADAPTIVE_RASTER_SPLIT");
                unsetenv("NDS4MISTER_RASTER_BAND_QUEUE");
                unsetenv("NDS4MISTER_RASTER_BAND_TEST_DELAY_WORKER");
            }
            melonDS::NDSArgs args;
            args.JIT = std::nullopt;
            auto nds = std::make_unique<melonDS::NDS>(
                std::move(args), nullptr);
            nds->Reset();
            nds->GPU.GPU3D.SetEnabled(true, true);
            nds->GPU.GPU3D.SetExternalCommandReplay(true);
            nds->GPU.GPU3D.SetHighResolutionCoordinatesEnabled(false);
            melonDS::RendererSettings settings {
                1, true, false, false, false, false, false, true, true};
            auto& renderer = nds->GPU.GetRenderer();
            renderer.SetRenderSettings(settings);
            // Enabling melonDS's threaded renderer launches one initial job.
            renderer.Finish3DRendering();
            for (std::uint32_t y = 0; y < PlaneHeight; ++y)
                if (!renderer.Get3DScanline(y))
                    self_test_fail("band-queue startup render returned null");
            return nds;
        };
        auto oracle = make_renderer_nds(false);
        auto queued = make_renderer_nds(true);
        const auto push = [](melonDS::NDS& nds,
                             std::uint8_t command,
                             std::uint32_t parameter) {
            nds.GPU.GPU3D.WriteExternalNormalizedCommand(
                command, parameter);
            nds.ARM9Timestamp += std::uint64_t {1} << 16;
            nds.ARM9Target = nds.ARM9Timestamp;
            nds.ARM7Timestamp =
                nds.ARM9Timestamp >> nds.ARM9ClockShift;
            nds.ARM7Target = nds.ARM7Timestamp;
            nds.GPU.GPU3D.Run();
        };
        const auto vertex10 = [](std::int32_t x, std::int32_t y,
                                 std::int32_t z) {
            return (static_cast<std::uint32_t>(x) & 0x3ffu) |
                ((static_cast<std::uint32_t>(y) & 0x3ffu) << 10) |
                ((static_cast<std::uint32_t>(z) & 0x3ffu) << 20);
        };
        const auto build_frame = [&](melonDS::NDS& nds) {
            push(nds, 0x10, 1); // position matrix
            push(nds, 0x15, 0); // identity
            push(nds, 0x20, 0x001f00c0);
            push(nds, 0x29, 0x001f00c0);
            for (int triangle = 0; triangle < 10; ++triangle)
            {
                const std::int32_t dx = (triangle % 5 - 2) * 12;
                const std::int32_t dy = (triangle / 5) * 16;
                push(nds, 0x40, 0); // triangles
                push(nds, 0x24, vertex10(-256 + dx, -256 + dy, 0));
                push(nds, 0x24, vertex10(256 + dx, -256 + dy, 0));
                push(nds, 0x24, vertex10(dx, 256 + dy, 0));
                push(nds, 0x41, 0);
            }
            push(nds, 0x50, 0); // flush
            nds.GPU.GPU3D.VBlank();
        };
        build_frame(*oracle);
        build_frame(*queued);
        if (oracle->GPU.GPU3D.RenderNumPolygons <= 8 ||
            oracle->GPU.GPU3D.RenderNumPolygons !=
                queued->GPU.GPU3D.RenderNumPolygons)
            self_test_fail("band-queue oracle polygon fixture is too small");

        auto& oracle_renderer = oracle->GPU.GetRenderer();
        auto& queued_renderer = queued->GPU.GetRenderer();
        oracle_renderer.Start3DRendering();
        queued_renderer.Start3DRendering();
        oracle_renderer.Finish3DRendering();
        queued_renderer.Finish3DRendering();
        for (std::uint32_t y = 0; y < PlaneHeight; ++y)
        {
            const auto* oracle_line = oracle_renderer.Get3DScanline(y);
            const auto* queued_line = queued_renderer.Get3DScanline(y);
            if (!oracle_line || !queued_line ||
                std::memcmp(
                    oracle_line, queued_line,
                    PlaneWidth * sizeof(std::uint32_t)) != 0)
                self_test_fail("band-queue color plane diverged from oracle");
        }
        melonDS::u64 oracle_hashes[3] {};
        melonDS::u64 queued_hashes[3] {};
        if (!oracle_renderer.Get3DNativeBufferHashes(oracle_hashes) ||
            !queued_renderer.Get3DNativeBufferHashes(queued_hashes) ||
            std::memcmp(
                oracle_hashes, queued_hashes,
                sizeof(oracle_hashes)) != 0)
            self_test_fail("band-queue native buffers diverged from oracle");
        const auto queue_profile =
            queued_renderer.GetExternalRendererStageProfile();
        if (queue_profile.ThreeDBandQueueFrames != 1 ||
            queue_profile.ThreeDBandQueueJobs != 4 ||
            queue_profile.ThreeDBandQueueAdvancedScanlines < 48)
            self_test_fail("four-band raster queue did not execute");
        std::cout << "H3D_RASTER_BAND_ORACLE_PASS jobs="
                  << queue_profile.ThreeDBandQueueJobs
                  << " advanced_scanlines="
                  << queue_profile.ThreeDBandQueueAdvancedScanlines << '\n';

        queued.reset();
        oracle.reset();
        restore_environment("NDS4MISTER_DUAL_CORE_3D", saved_dual);
        restore_environment(
            "NDS4MISTER_ADAPTIVE_RASTER_SPLIT", saved_adaptive);
        restore_environment("NDS4MISTER_RASTER_BAND_QUEUE", saved_bands);
        restore_environment(
            "NDS4MISTER_RASTER_BAND_TEST_DELAY_WORKER", saved_band_delay);
    }

    // Production's 3D-only split combines both asynchronous workers. A
    // terminal packet must advance VBlank and launch/collect the 3D renderer
    // on the replay worker; merely applying and acknowledging its records
    // would leave the FPGA with no return plane forever.
    {
        Fixture pipeline_fixture(Session + 23);
        for (std::uint32_t sequence = 1; sequence <= 3; ++sequence)
            pipeline_fixture.publish(
                sequence, 2000 + sequence,
                frame_packet::FlagFrameEnd, {});
        Hybrid3DService pipeline_service(
            pipeline_fixture.bytes.data(), pipeline_fixture.bytes.size(),
            {}, true, false, false, true);
        if (!pipeline_service.initialize())
            self_test_fail("asynchronous 3D pipeline fixture init failed");
        for (std::uint32_t sequence = 1; sequence <= 3; ++sequence) {
            if (pipeline_service.poll() != PollResult::Applied ||
                pipeline_fixture.header->consumer_sequence != sequence)
                self_test_fail(
                    "asynchronous 3D pipeline did not retire input");
        }
        for (unsigned attempt = 0;
             attempt < 2000 &&
                 (pipeline_service.replay_packets_applied() != 3 ||
                  pipeline_service.frames_published() == 0);
             ++attempt)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (pipeline_service.replay_packets_applied() != 3 ||
            pipeline_service.frames_rendered() == 0 ||
            pipeline_service.frames_published() == 0 ||
            pipeline_fixture.header->frame_publish_sequence != 2)
            self_test_fail(
                "asynchronous 3D replay omitted frame rendering");
    }

    // Exercise two complete turns of the private 512-slot replay queue. This
    // reports real vector-capacity ownership behavior for the old moving
    // packet queue and the recycled-slot implementation using the same
    // validated frame-packet consumer and replay worker.
    {
        constexpr std::uint32_t PacketCount = 1024;
        Fixture arena_fixture(Session + 31);
        const std::vector<frame_packet::Record> arena_records {
            packet_record(
                frame_packet::RecordKind::Gpu2DRegister,
                static_cast<std::uint8_t>(AccessWidth::Half), 0x03,
                0x04000018, 0x00000123)
        };
        Hybrid3DService arena_service(
            arena_fixture.bytes.data(), arena_fixture.bytes.size(),
            {}, false, false, false, true);
        if (!arena_service.initialize())
            self_test_fail("replay-slot arena fixture init failed");
        const auto arena_started = std::chrono::steady_clock::now();
        for (std::uint32_t sequence = 1;
             sequence <= PacketCount; ++sequence) {
            arena_fixture.publish(
                sequence, 1, frame_packet::FlagContinuation,
                arena_records);
            for (;;) {
                const auto result = arena_service.poll();
                if (result == PollResult::Applied) break;
                if (result == PollResult::Fault)
                    throw std::runtime_error(
                        "self-test: replay-slot arena fixture faulted at " +
                        std::to_string(sequence) + ": " +
                        arena_service.error());
                std::this_thread::sleep_for(
                    std::chrono::microseconds(50));
            }
        }
        for (unsigned attempt = 0;
             attempt < 10000 &&
                 arena_service.replay_packets_applied() != PacketCount;
             ++attempt)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (arena_service.replay_packets_applied() != PacketCount)
            self_test_fail("replay-slot arena did not drain");
        if (arena_service.replay_slot_capacity_growths() != 513 ||
            arena_service.replay_slot_reuses() != 511)
            self_test_fail(
                "replay-slot arena did not retain one allocation per slot");
        const auto arena_elapsed_ns = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - arena_started).count());
        std::cout << "H3D_PACKET_ARENA_BENCH packets=" << PacketCount
                  << " capacity_growths="
                  << arena_service.replay_slot_capacity_growths()
                  << " reused_packets="
                  << arena_service.replay_slot_reuses()
                  << " elapsed_ns=" << arena_elapsed_ns
                  << " ns_per_packet=" << arena_elapsed_ns / PacketCount
                  << "\n";
    }

    if (service.events_applied() !=
            continuation.size() + terminal.size() ||
        service.frames_published() != 1 || service.frames_rendered() != 1)
        self_test_fail("service counters are invalid");
    const auto normalized_fallback_step =
        (std::uint64_t {1} << 16) >> service.nds().ARM9ClockShift;
    if (service.nds().ARM7Timestamp != 4 * normalized_fallback_step ||
        (service.nds().ARM9Timestamp >> service.nds().ARM9ClockShift) !=
            service.nds().ARM7Timestamp)
        self_test_fail("Replay3D fallback timestamp cadence diverged");

    // A newer committed packet must not suppress rendering of the current
    // terminal. Producer lead is normal while packet copy/application runs;
    // only the plane fence may drop derived output.
    {
        Fixture backlog(Session + 18);
        backlog.publish(1, 20, frame_packet::FlagFrameEnd, {});
        backlog.publish(2, 21, frame_packet::FlagFrameEnd, {});
        backlog.publish(3, 22, frame_packet::FlagFrameEnd, {});
        Hybrid3DService backlog_service(
            backlog.bytes.data(), backlog.bytes.size());
        if (!backlog_service.initialize())
            self_test_fail("backlog fixture init failed");
        if (backlog_service.poll() != PollResult::Applied ||
            backlog.header->consumer_sequence != 1 ||
            backlog_service.frames_rendered() != 1 ||
            backlog_service.frames_published() != 1 ||
            backlog.header->frame.frame != 20)
            self_test_fail("producer lead incorrectly suppressed rendering");
        if (backlog_service.poll() != PollResult::Applied ||
            backlog.header->consumer_sequence != 2 ||
            backlog_service.frames_rendered() != 1 ||
            backlog_service.frames_published() != 1 ||
            backlog.header->frame.frame != 20)
            self_test_fail("busy plane fence did not remain the drop authority");
        backlog.header->frame_ack_sequence =
            backlog.header->frame_publish_sequence;
        if (backlog_service.poll() != PollResult::Applied ||
            backlog.header->consumer_sequence != 3 ||
            backlog_service.frames_rendered() != 2 ||
            backlog_service.frames_published() != 2 ||
            backlog.header->frame.frame != 22)
            self_test_fail("latest queued packet did not render after catch-up");
    }

    // VBlank is also a terminal packet boundary when a frame has no
    // SWAP_BUFFERS command. This keeps packet/frame ownership moving during
    // 2D-only and register-only intervals while melonDS retains its prior 3D
    // buffer for the newly published frame.
    {
        Fixture boundary_only(Session + 13);
        boundary_only.publish(
            1, 3, frame_packet::FlagFrameEnd, {});
        Hybrid3DService boundary_service(
            boundary_only.bytes.data(), boundary_only.bytes.size());
        if (!boundary_service.initialize() ||
            boundary_service.poll() != PollResult::Applied ||
            boundary_only.header->consumer_sequence != 1 ||
            boundary_only.header->frame.frame != 3 ||
            boundary_service.frames_published() != 1 ||
            boundary_service.nds().ARM7Timestamp !=
                ((std::uint64_t {1} << 16) >>
                 boundary_service.nds().ARM9ClockShift))
            self_test_fail("empty VBlank packet did not publish and retire");
    }

    {
        Fixture bad_nop(Session + 10);
        bad_nop.publish(
            1, 1, frame_packet::FlagContinuation,
            {packet_record(
                frame_packet::RecordKind::GxCommand, 0, 0, 0, 1)});
        Hybrid3DService rejecting_nop(
            bad_nop.bytes.data(), bad_nop.bytes.size());
        if (!rejecting_nop.initialize())
            self_test_fail("nonzero-NOP fixture init failed");
        if (rejecting_nop.poll() != PollResult::Fault ||
            bad_nop.header->consumer_sequence != 0 ||
            rejecting_nop.events_applied() != 0 ||
            (bad_nop.header->hps_fault_bits & FaultBadEvent) == 0)
            self_test_fail("normalized command zero accepted a parameter");
    }

    {
        Fixture continued_swap(Session + 11);
        continued_swap.publish(
            1, 1, frame_packet::FlagContinuation,
            {packet_record(
                frame_packet::RecordKind::GxCommand, 0x50, 0, 0, 0)});
        Hybrid3DService rejecting_continued_swap(
            continued_swap.bytes.data(), continued_swap.bytes.size());
        if (!rejecting_continued_swap.initialize())
            self_test_fail("continued-SWAP fixture init failed");
        if (rejecting_continued_swap.poll() != PollResult::Fault ||
            continued_swap.header->consumer_sequence != 0 ||
            rejecting_continued_swap.events_applied() != 0 ||
            (continued_swap.header->hps_fault_bits & FaultBadFrame) == 0)
            self_test_fail("continuation packet accepted SWAP_BUFFERS");
    }

    {
        Fixture followed_swap(Session + 12);
        followed_swap.publish(
            1, 1, frame_packet::FlagFrameEnd,
            {
                packet_record(
                    frame_packet::RecordKind::GxCommand, 0x50, 0, 0, 0),
                packet_record(
                    frame_packet::RecordKind::GxCommand, 0x10, 0, 0, 0),
            });
        Hybrid3DService rejecting_followed_swap(
            followed_swap.bytes.data(), followed_swap.bytes.size());
        if (!rejecting_followed_swap.initialize())
            self_test_fail("followed-SWAP fixture init failed");
        if (rejecting_followed_swap.poll() != PollResult::Fault ||
            followed_swap.header->consumer_sequence != 0 ||
            rejecting_followed_swap.events_applied() != 0 ||
            (followed_swap.header->hps_fault_bits & FaultBadFrame) == 0)
            self_test_fail("FRAME_END accepted a record after SWAP_BUFFERS");
    }

    // The production loop may immediately iterate after Applied because the
    // next poll begins with the full session/quiesce check. Prove a lifecycle
    // change between two busy iterations is rejected before another event can
    // be consumed or any batched consumer credit can be published.
    Fixture applied_session_fixture(Session + 3);
    applied_session_fixture.publish(
        1, 1, frame_packet::FlagContinuation,
        {packet_record(
            frame_packet::RecordKind::GxCommand, 0x10, 0, 0, 0)});
    Hybrid3DService applied_session_service(
        applied_session_fixture.bytes.data(),
        applied_session_fixture.bytes.size());
    if (!applied_session_service.initialize() ||
        applied_session_service.poll() != PollResult::Applied ||
        applied_session_fixture.header->consumer_sequence != 1)
        self_test_fail("applied-session fixture did not enter its busy path");
    applied_session_fixture.header->quiesce_request = Session + 4;
    if (applied_session_service.poll() != PollResult::Fault ||
        applied_session_fixture.header->consumer_sequence != 1)
        self_test_fail("next busy poll crossed a session boundary");

    // A busy event stream must not turn the liveness word into two ordered
    // Device-memory writes plus barriers for every event.  Session start is
    // published immediately; ordinary polls refresh only at the bounded
    // interval used by the production loop.
    Fixture heartbeat_fixture(Session + 2);
    Hybrid3DService heartbeat_service(
        heartbeat_fixture.bytes.data(), heartbeat_fixture.bytes.size());
    if (!heartbeat_service.initialize() ||
        heartbeat_fixture.header->hps_heartbeat != 1)
        self_test_fail("initial heartbeat was not published");
    for (std::uint32_t poll = 1;
         poll < Hybrid3DService::HeartbeatPollInterval; ++poll) {
        if (heartbeat_service.poll() != PollResult::Empty ||
            heartbeat_fixture.header->hps_heartbeat != 1)
            self_test_fail("heartbeat was not throttled between intervals");
    }
    if (heartbeat_service.poll() != PollResult::Empty ||
        heartbeat_fixture.header->hps_heartbeat != 2)
        self_test_fail("heartbeat interval did not refresh liveness");

    // Reproduce the board's frame-903 failure shape: one terminal packet with
    // 1,799 contiguous halfword VRAM writes and one prior plane outstanding.
    // Record progress refreshes liveness and the derived frame is dropped so
    // the authoritative packet can retire without waiting on display output.
    {
        Fixture busy_packet(Session + 14);
        std::vector<frame_packet::Record> writes(1799);
        for (std::size_t index = 0; index < writes.size(); ++index) {
            const bool upper_half = (index & 1u) != 0;
            writes[index] = packet_record(
                frame_packet::RecordKind::VramWrite,
                static_cast<std::uint8_t>(AccessWidth::Half),
                upper_half ? 0x0c : 0x03,
                0x0600c000u + static_cast<std::uint32_t>(index * 2),
                static_cast<std::uint32_t>(index) <<
                    (upper_half ? 16 : 0));
        }
        busy_packet.publish(
            1, 903, frame_packet::FlagFrameEnd, writes);
        busy_packet.header->frame_publish_sequence = 2;
        busy_packet.header->frame_ack_sequence = 0;
        Hybrid3DService busy_service(
            busy_packet.bytes.data(), busy_packet.bytes.size());
        if (!busy_service.initialize())
            self_test_fail("busy-packet fixture init failed");
        const auto busy_result = busy_service.poll();
        if (busy_result != PollResult::Applied)
            throw std::runtime_error(
                "self-test: busy packet did not retire: " +
                busy_service.error());
        if (busy_packet.header->consumer_sequence != 1 ||
            busy_packet.header->frame_publish_sequence != 2 ||
            busy_service.frames_published() != 0 ||
            busy_service.frames_rendered() != 0)
            self_test_fail("busy packet changed the outstanding plane");
        if (busy_service.events_applied() != writes.size())
            self_test_fail("busy packet did not apply every VRAM write");
        if (busy_packet.header->service_state !=
            static_cast<std::uint32_t>(ServiceState::Ready))
            self_test_fail("busy packet left Ready state");
        if (busy_packet.header->hps_heartbeat <= 1)
            self_test_fail("busy packet did not refresh heartbeat before ACK");
    }

    // Only one validated outstanding descriptor is a droppable busy state.
    // A larger or malformed gap remains fail-closed and cannot publish packet
    // credit across corrupted return-plane ownership.
    {
        Fixture bad_frame_gap(Session + 15);
        bad_frame_gap.publish(1, 904, frame_packet::FlagFrameEnd, {});
        bad_frame_gap.header->frame_publish_sequence = 4;
        bad_frame_gap.header->frame_ack_sequence = 0;
        Hybrid3DService bad_gap_service(
            bad_frame_gap.bytes.data(), bad_frame_gap.bytes.size());
        if (!bad_gap_service.initialize())
            self_test_fail("bad-frame-gap fixture init failed");
        if (bad_gap_service.poll() != PollResult::Fault ||
            bad_frame_gap.header->consumer_sequence != 0 ||
            bad_gap_service.frames_rendered() != 0 ||
            (bad_frame_gap.header->hps_fault_bits & FaultBadFrame) == 0)
            self_test_fail("invalid frame gap did not fail closed");
    }

    // Production no longer pays for the completed H3V1 diagnostic harness.
    // A stale/corrupt diagnostic mailbox must not block authoritative H3B1
    // records when no explicit trace was armed.
    {
        Fixture bad_verifier(Session + 16);
        bad_verifier.publish(
            1, 905, frame_packet::FlagFrameEnd,
            {packet_record(
                frame_packet::RecordKind::VramWrite,
                static_cast<std::uint8_t>(AccessWidth::Word), 0x0f,
                0x06000000, 0x12345678)});
        bad_verifier.diagnostic(1)->crc32c ^= 1u;
        Hybrid3DService bad_verifier_service(
            bad_verifier.bytes.data(), bad_verifier.bytes.size());
        if (!bad_verifier_service.initialize())
            self_test_fail("bad-verifier fixture init failed");
        if (bad_verifier_service.poll() != PollResult::Applied ||
            bad_verifier.header->consumer_sequence != 1 ||
            bad_verifier_service.events_applied() != 1 ||
            bad_verifier.header->hps_fault_bits != 0)
            self_test_fail("inactive H3V1 diagnostic blocked production");
    }

    // The optional postmortem writes once, at destruction, after a fully
    // verified terminal packet. Its 64-byte H3T1 header and selected records
    // are exact little-endian bytes and include the CONT prefix in order.
    {
        std::array<char, 64> trace_pattern{};
        std::strcpy(trace_pattern.data(), "/tmp/h3d-trace-test.XXXXXX");
        const int placeholder = mkstemp(trace_pattern.data());
        if (placeholder < 0) self_test_fail("trace mkstemp failed");
        close(placeholder);
        unlink(trace_pattern.data());
        const std::string trace_path(trace_pattern.data());

        Fixture trace_fixture(Session + 17);
        const std::vector<frame_packet::Record> trace_cont {
            packet_record(
                frame_packet::RecordKind::VramMap,
                static_cast<std::uint8_t>(AccessWidth::Byte), 0x01,
                0x04000240, 0x80),
            packet_record(
                frame_packet::RecordKind::VramWrite,
                static_cast<std::uint8_t>(AccessWidth::Word), 0x0f,
                0x06000000, 0x89abcdef),
            packet_record(
                frame_packet::RecordKind::GxRegister,
                static_cast<std::uint8_t>(AccessWidth::Half), 0x03,
                0x04000060, 1),
        };
        const std::vector<frame_packet::Record> trace_terminal {
            packet_record(
                frame_packet::RecordKind::GxCommand, 0x2a, 0,
                0, 0x00112233),
            packet_record(
                frame_packet::RecordKind::GxCommand, 0x50, 0,
                0, 0),
        };
        trace_fixture.publish(
            1, 906, frame_packet::FlagContinuation, trace_cont);
        trace_fixture.publish(
            2, 906, frame_packet::FlagFrameEnd, trace_terminal);
        {
            Hybrid3DService trace_service(
                trace_fixture.bytes.data(), trace_fixture.bytes.size(),
                trace_path);
            if (!trace_service.initialize() ||
                trace_service.poll() != PollResult::Applied ||
                trace_service.poll() != PollResult::Applied ||
                trace_fixture.header->consumer_sequence != 2)
                self_test_fail("trace fixture did not complete");
        }

        std::vector<std::byte> dump;
        const int trace_fd = open(trace_path.c_str(), O_RDONLY | O_CLOEXEC);
        if (trace_fd < 0) self_test_fail("trace dump missing");
        struct stat trace_status {};
        if (fstat(trace_fd, &trace_status) != 0 ||
            trace_status.st_size < 0) {
            close(trace_fd);
            self_test_fail("trace dump stat failed");
        }
        dump.resize(static_cast<std::size_t>(trace_status.st_size));
        std::size_t loaded = 0;
        while (loaded < dump.size()) {
            const auto amount = read(
                trace_fd, dump.data() + loaded, dump.size() - loaded);
            if (amount <= 0) {
                close(trace_fd);
                self_test_fail("trace dump read failed");
            }
            loaded += static_cast<std::size_t>(amount);
        }
        close(trace_fd);
        unlink(trace_path.c_str());

        const auto load_le16 = [&dump](std::size_t offset) {
            return static_cast<std::uint16_t>(
                std::to_integer<std::uint8_t>(dump[offset]) |
                (std::uint16_t {
                     std::to_integer<std::uint8_t>(dump[offset + 1])}
                 << 8));
        };
        const auto load_le32 = [&dump](std::size_t offset) {
            std::uint32_t value = 0;
            for (unsigned byte = 0; byte < 4; ++byte)
                value |= std::uint32_t {
                             std::to_integer<std::uint8_t>(
                                 dump[offset + byte])}
                    << (byte * 8);
            return value;
        };
        std::vector<frame_packet::Record> expected_trace = trace_cont;
        expected_trace.insert(
            expected_trace.end(), trace_terminal.begin(),
            trace_terminal.end());
        if (dump.size() != 64 +
                expected_trace.size() * frame_packet::RecordBytes ||
            load_le32(0) != 0x31543348u || load_le16(4) != 1 ||
            load_le16(6) != 64 || load_le32(8) != Session + 17 ||
            load_le32(12) != 2 || load_le32(16) != 906 ||
            load_le32(20) != expected_trace.size() ||
            load_le32(24) != trace_fixture.diagnostic(2)->crc32c ||
            load_le32(28) !=
                expected_trace.size() * frame_packet::RecordBytes ||
            load_le32(32) != frame_packet::RecordBytes)
            self_test_fail("trace dump header is invalid");
        for (std::size_t offset = 36; offset < 64; ++offset) {
            if (dump[offset] != std::byte {0})
                self_test_fail("trace dump reserved word is nonzero");
        }
        for (std::size_t index = 0; index < expected_trace.size(); ++index) {
            const auto offset = 64 + index * frame_packet::RecordBytes;
            if (load_le32(offset) != expected_trace[index].metadata ||
                load_le32(offset + 4) !=
                    expected_trace[index].address_or_aux ||
                load_le32(offset + 8) !=
                    static_cast<std::uint32_t>(expected_trace[index].data) ||
                load_le32(offset + 12) !=
                    static_cast<std::uint32_t>(
                        expected_trace[index].data >> 32))
                self_test_fail("trace dump record order changed");
        }
    }

    // Production uses both ARM workers: terminal input starts melonDS's
    // rasterizer, an input-idle poll collects that render into local memory,
    // and the publication worker alone packs and publishes the plane.
    {
        Fixture asynchronous_fixture(Session + 20);
        asynchronous_fixture.publish(
            1, 1001, frame_packet::FlagFrameEnd, {});
        asynchronous_fixture.publish(
            2, 1002, frame_packet::FlagContinuation, {});
        Hybrid3DService asynchronous_service(
            asynchronous_fixture.bytes.data(),
            asynchronous_fixture.bytes.size(), {}, true);
        if (!asynchronous_service.initialize() ||
            asynchronous_service.poll() != PollResult::Applied ||
            asynchronous_fixture.header->consumer_sequence != 1)
            self_test_fail("asynchronous publication did not retire input");
        if (asynchronous_service.poll() != PollResult::Applied ||
            asynchronous_fixture.header->consumer_sequence != 2)
            self_test_fail("packet input did not overlap ARM rendering");
        if (asynchronous_service.poll() != PollResult::Applied)
            self_test_fail("asynchronous ARM render did not complete");
        for (unsigned attempt = 0;
             attempt < 250 && asynchronous_service.frames_published() == 0;
             ++attempt)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (asynchronous_service.frames_published() != 1 ||
            asynchronous_fixture.header->frame_publish_sequence != 2 ||
            asynchronous_fixture.header->frame.sequence != 2 ||
            asynchronous_fixture.header->frame.frame != 1001)
            self_test_fail("asynchronous publication worker did not publish");

        // Once that descriptor is acknowledged, a melonDS-identical frame
        // still needs a fresh architectural frame number for the FPGA line
        // reader, but it must not recopy or rescan the unchanged plane.
        asynchronous_fixture.header->frame_ack_sequence = 2;
        asynchronous_fixture.publish(
            3, 1002, frame_packet::FlagFrameEnd, {});
        if (asynchronous_service.poll() != PollResult::Applied ||
            asynchronous_fixture.header->consumer_sequence != 3 ||
            asynchronous_service.poll() != PollResult::Applied)
            self_test_fail("identical asynchronous frame did not complete");
        for (unsigned attempt = 0;
             attempt < 250 && asynchronous_service.frames_published() != 2;
             ++attempt)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (asynchronous_service.frames_published() != 2 ||
            asynchronous_service.identical_plane_republications() != 1 ||
            asynchronous_fixture.header->frame_publish_sequence != 4 ||
            asynchronous_fixture.header->frame.sequence != 4 ||
            asynchronous_fixture.header->frame.frame != 1002 ||
            asynchronous_fixture.header->frame.bank != 0)
            self_test_fail("identical plane was not republished in place");
    }

    // Asynchronous production has a private cached ARM output FIFO. A shared
    // plane awaiting FPGA adoption must not suppress the next raster job: the
    // publication worker waits for ACK, then commits from private memory.
    {
        Fixture pipelined_busy_plane(Session + 22);
        pipelined_busy_plane.publish(
            1, 1003, frame_packet::FlagFrameEnd, {});
        pipelined_busy_plane.header->frame_publish_sequence = 2;
        pipelined_busy_plane.header->frame_ack_sequence = 0;
        Hybrid3DService pipelined_service(
            pipelined_busy_plane.bytes.data(),
            pipelined_busy_plane.bytes.size(), {}, true);
        if (!pipelined_service.initialize() ||
            pipelined_service.poll() != PollResult::Applied ||
            pipelined_busy_plane.header->consumer_sequence != 1)
            self_test_fail("pipelined busy-plane input did not retire");
        if (pipelined_service.poll() != PollResult::Applied ||
            pipelined_service.frames_rendered() != 1 ||
            pipelined_service.frames_published() != 0 ||
            pipelined_busy_plane.header->frame_publish_sequence != 2)
            self_test_fail("pipelined busy-plane render did not stay private");
        pipelined_busy_plane.header->frame_ack_sequence = 2;
        for (unsigned attempt = 0;
             attempt < 250 && pipelined_service.frames_published() == 0;
             ++attempt)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        if (pipelined_service.frames_published() != 1 ||
            pipelined_busy_plane.header->frame_publish_sequence != 4 ||
            pipelined_busy_plane.header->frame.sequence != 4 ||
            pipelined_busy_plane.header->frame.frame != 1003)
            self_test_fail("pipelined busy-plane render did not publish after ACK");
    }

    // A temporarily busy FPGA plane must keep the in-flight buffer immutable
    // while retaining a shallow smoothing FIFO and replacing only its oldest
    // pending result when that FIFO is full.
    {
        Fixture publication_burst(Session + 23);
        publication_burst.header->frame_publish_sequence = 2;
        publication_burst.header->frame_ack_sequence = 0;
        Hybrid3DService burst_service(
            publication_burst.bytes.data(), publication_burst.bytes.size(),
            {}, true);
        if (!burst_service.initialize())
            self_test_fail("publication-burst service did not initialize");
        constexpr std::uint32_t BurstFrames = 10;
        for (std::uint32_t sequence = 1; sequence <= BurstFrames;
             ++sequence) {
            publication_burst.publish(
                sequence, 1100 + sequence,
                frame_packet::FlagFrameEnd, {});
            if (burst_service.poll() != PollResult::Applied ||
                publication_burst.header->consumer_sequence != sequence)
                self_test_fail("publication burst did not retire input");
            if (sequence == 1)
                std::this_thread::sleep_for(std::chrono::milliseconds(10));
        }
        if (burst_service.poll() != PollResult::Applied ||
            burst_service.frames_rendered() != BurstFrames ||
            burst_service.frames_published() != 0 ||
            burst_service.publication_queue_replacements() !=
                BurstFrames - 1 - Hybrid3DService::PendingPublicationLimit ||
            burst_service.publication_queue_high_water() !=
                Hybrid3DService::PendingPublicationLimit)
            self_test_fail("publication burst did not bound smoothing queue");

        for (unsigned attempt = 0;
             attempt < 1000 &&
                 burst_service.frames_published() !=
                    1 + Hybrid3DService::PendingPublicationLimit;
             ++attempt) {
            publication_burst.header->frame_ack_sequence =
                publication_burst.header->frame_publish_sequence;
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        if (burst_service.frames_published() !=
                1 + Hybrid3DService::PendingPublicationLimit ||
            burst_service.publication_queue_replacements() !=
                BurstFrames - 1 - Hybrid3DService::PendingPublicationLimit ||
            publication_burst.header->frame.frame != 1100 + BurstFrames)
            self_test_fail("publication burst did not publish shallow FIFO");
    }

    // Production profiling is postmortem-only: it writes one bounded record
    // after all workers have joined. Prove the file is atomically materialized
    // and carries the queue/timing schema without enabling it in normal tests.
    {
        unlink(PipelineProfilePath);
        Fixture profile_fixture(Session + 21);
        {
            Hybrid3DService profile_service(
                profile_fixture.bytes.data(), profile_fixture.bytes.size(),
                {}, false, false, false, false, true);
            if (!profile_service.initialize())
                self_test_fail("pipeline-profile fixture init failed");
        }
        const int profile_fd =
            open(PipelineProfilePath, O_RDONLY | O_CLOEXEC);
        if (profile_fd < 0)
            self_test_fail("pipeline profile was not materialized");
        std::array<char, 2048> profile_bytes{};
        const auto profile_size =
            read(profile_fd, profile_bytes.data(), profile_bytes.size());
        close(profile_fd);
        unlink(PipelineProfilePath);
        if (profile_size <= 0)
            self_test_fail("pipeline profile was empty");
        const std::string profile(
            profile_bytes.data(), static_cast<std::size_t>(profile_size));
        if (profile.find("H3D_PIPELINE_PROFILE_V1") != 0 ||
            profile.find("queue_capacity=512") == std::string::npos ||
            profile.find("queue_high_water=0") == std::string::npos ||
            profile.find("input_packets=0") == std::string::npos ||
            profile.find("replay_packets=0") == std::string::npos ||
            profile.find("publications=0") == std::string::npos)
            self_test_fail("pipeline profile schema is incomplete");
    }

    // A process restart must never resume the existing event fence with a
    // fresh melonDS instance. It requests a new session, then becomes
    // read-only until the FPGA publishes H3DQ. Quiesce ack is the final old-
    // generation write.
    if (inspect_shared_phase(*fixture.header) !=
            SharedPhase::RestartRequired ||
        !request_fresh_session(*fixture.header) ||
        fixture.header->service_state !=
            static_cast<std::uint32_t>(ServiceState::RestartRequested))
        self_test_fail("same-session restart was not rejected");
    fixture.header->magic = QuiesceMagic;
    fixture.header->quiesce_request = Session + 1;
    if (inspect_shared_phase(*fixture.header) != SharedPhase::Quiesce ||
        !acknowledge_quiesce(*fixture.header) ||
        fixture.header->quiesce_ack != Session + 1)
        self_test_fail("quiesce handshake failed");

    Fixture bad(Session + 1);
    auto unknown = packet_record(
        frame_packet::RecordKind::GxCommand, 0x10, 0, 0, 0);
    unknown.metadata = (unknown.metadata & ~0xffu) | 0xffu;
    bad.publish(1, 1, frame_packet::FlagFrameEnd, {unknown});
    Hybrid3DService rejecting(bad.bytes.data(), bad.bytes.size());
    if (!rejecting.initialize()) self_test_fail("fault fixture init failed");
    if (rejecting.poll() != PollResult::Fault ||
        bad.header->service_state !=
            static_cast<std::uint32_t>(ServiceState::Fault) ||
        (bad.header->hps_fault_bits & FaultBadEvent) == 0)
        self_test_fail("unknown packet record did not fail closed");

    std::cout << "H3D_SERVICE_SELF_TEST_PASS\n";
}

void usage()
{
    std::cerr <<
        "usage: nds_hybrid_3d_service [--memory FILE] [--max-events N]\n"
        "       nds_hybrid_3d_service --self-test\n";
}

} // namespace

int main(int argc, char** argv)
try {
    std::string memory_path = "/dev/mem";
    std::uint64_t max_events = 0;
    bool self_test = false;

    for (int index = 1; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        if (argument == "--self-test") {
            self_test = true;
        } else if (argument == "--memory" && index + 1 < argc) {
            memory_path = argv[++index];
        } else if (argument == "--max-events" && index + 1 < argc) {
            max_events = parse_count(argv[++index], "event limit");
        } else {
            usage();
            return 2;
        }
    }

    if (self_test) {
        if (argc != 2) {
            usage();
            return 2;
        }
        run_self_test();
        return 0;
    }

    if (!nds4mister::crash::install_arm_crash_handler())
        throw std::runtime_error("could not install ARM crash handlers");
    Mapping mapping(memory_path);
    WriteCombinedPublicationMapping publication_mapping(
        memory_path == "/dev/mem");
    SingletonLock singleton;
    auto& header = *static_cast<Header*>(mapping.data());
    CrashHeaderRegistration crash_header(header);
    nds4mister::crash::FpgaRuntimeTelemetry runtime_telemetry;
    nds4mister::crash::FpgaCrashMonitor crash_monitor(
        &header, memory_path == "/dev/mem", &runtime_telemetry);
    std::unique_ptr<Hybrid3DService> service;
    std::uint64_t total_events = 0;
    std::uint64_t total_frames = 0;

    std::signal(SIGINT, request_stop);
    std::signal(SIGTERM, request_stop);
    while (!stop_requested && (!max_events || total_events < max_events)) {
        if (service) {
            const auto before_events = service->events_applied();
            const auto before_frames = service->frames_published();
            const auto result = service->poll();
            total_events += service->events_applied() - before_events;
            total_frames += service->frames_published() - before_frames;
            if (result == PollResult::Fault) {
                std::cerr << "H3D_SERVICE_FAULT " << service->error() << '\n';
                service.reset();
            } else if (result == PollResult::Applied) {
                // poll() already performed the complete session/quiesce gate,
                // and the next busy iteration starts with the same gate. Avoid
                // repeating seven Device-memory barriers between two events.
                continue;
            } else if (!service->session_current()) {
                // Empty and frame-ack waits sleep below, so retain the explicit
                // post-poll lifecycle check before becoming idle.
                service.reset();
            }
            if (service) {
                std::this_thread::sleep_for(HpsQueuePollInterval);
                continue;
            }
        }

        const auto phase = inspect_shared_phase(header);
        if (phase == SharedPhase::Quiesce) {
            // Renderer destruction above is the quiesce point.  Never touch
            // any other HPS-owned word after this acknowledgement.
            acknowledge_quiesce(header);
        } else if (phase == SharedPhase::FreshSession) {
            const char* trace_requested =
                std::getenv("NDS4MISTER_H3D_TEXTURE_TRACE");
            const char* diagnostics_requested =
                std::getenv("NDS4MISTER_H3D_DIAGNOSTICS");
            const bool diagnostics =
                memory_path == "/dev/mem" && diagnostics_requested &&
                std::strcmp(diagnostics_requested, "0") != 0;
            // Construct melonDS on CPU0 so its software renderer and display
            // publisher inherit that affinity. Replay and intake are the
            // ordered transport side and run on CPU1 at the supervisor's
            // higher nice priority, ahead of MiSTer's continuously runnable
            // main loop. This keeps the two expensive H3D stages on separate
            // CPUs instead of allowing Linux to co-locate both on CPU0 under
            // map-scene pressure.
            if (memory_path == "/dev/mem")
                bind_current_thread_to_cpu(0);
            auto candidate = std::make_unique<Hybrid3DService>(
                mapping.data(), MappingBytes,
                memory_path == "/dev/mem" && trace_requested &&
                        std::strcmp(trace_requested, "0") != 0 ?
                    "/tmp/nds-h3d-texture-roundtrip.h3t" : "",
                memory_path == "/dev/mem",
                diagnostics,
                false,
                memory_path == "/dev/mem",
                diagnostics,
                memory_path == "/dev/mem",
                &runtime_telemetry,
                publication_mapping.data(),
                publication_mapping.active());
            const bool initialized = candidate->initialize();
            if (memory_path == "/dev/mem")
                bind_current_thread_to_cpu(1);
            if (initialized)
                service = std::move(candidate);
            else
                request_fresh_session(header);
        } else if (phase == SharedPhase::RestartRequired) {
            request_fresh_session(header);
        }
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }

    service.reset();
    std::cout << "events_applied: " << total_events
              << "\nframes_published: " << total_frames
              << '\n';
    return 0;
} catch (const std::exception& error) {
    std::cerr << "nds_hybrid_3d_service: " << error.what() << '\n';
    return 1;
}
