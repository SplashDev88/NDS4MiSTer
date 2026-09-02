#include "replay/FpgaCrashMonitor.h"

#include "replay/ArmCrashDump.h"
#include "replay/Hybrid3DAbi.h"

#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sstream>
#include <string>
#include <thread>
#include <unistd.h>

#if defined(__linux__)
#include <pthread.h>
#include <sched.h>
#endif

namespace nds4mister::crash {
namespace {

using Clock = std::chrono::steady_clock;
constexpr auto SampleInterval = std::chrono::milliseconds(100);
constexpr auto DefaultStallThreshold = std::chrono::milliseconds(2000);
constexpr auto ManualBurstInterval = std::chrono::milliseconds(2);
constexpr std::size_t ManualBurstSamples = 40;
constexpr std::size_t HistorySamples = 128;

struct FlightSample {
    std::uint64_t elapsed_ms = 0;
    std::uint32_t magic = 0;
    std::uint32_t session = 0;
    std::uint32_t producer = 0;
    std::uint32_t consumer = 0;
    std::uint32_t fpga_faults = 0;
    std::uint32_t hps_faults = 0;
    std::uint32_t service_state = 0;
    std::uint32_t accepted_session = 0;
    std::uint32_t frame_publish = 0;
    std::uint32_t frame_ack = 0;
    std::uint32_t frame_sequence = 0;
    std::uint32_t frame_session = 0;
    std::uint32_t frame_number = 0;
    std::uint32_t frame_bank = 0;
    std::uint32_t frame_format = 0;
    std::uint32_t fpga_pc9 = 0;
    std::uint32_t fpga_telemetry = 0;
    std::uint32_t hps_heartbeat = 0;
    std::uint32_t hps_diagnostic_token = 0;
    std::uint32_t quiesce_request = 0;
    std::uint32_t quiesce_ack = 0;
    std::uint32_t runtime_session = 0;
    std::uint32_t replay_backlog = 0;
    std::uint32_t replay_queue_high_water = 0;
    std::uint32_t latest_input_frame = 0;
    std::uint32_t latest_replay_frame = 0;
    std::uint64_t input_packets = 0;
    std::uint64_t replay_packets = 0;
    std::uint64_t replay_queue_full_polls = 0;
    std::uint64_t frames_rendered = 0;
    std::uint64_t frames_published = 0;
    std::uint64_t replay_budget_drops = 0;
    std::uint64_t publication_replacements = 0;
    std::uint32_t publication_queue_high_water = 0;
};

bool write_all(int fd, const char* data, std::size_t size)
{
    while (size != 0) {
        const auto count = write(fd, data, size);
        if (count > 0) {
            data += count;
            size -= static_cast<std::size_t>(count);
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            return false;
        }
    }
    return true;
}

std::chrono::milliseconds stall_threshold()
{
    const char* text = std::getenv("NDS4MISTER_FPGA_STALL_MS");
    if (!text || !*text) return DefaultStallThreshold;
    char* end = nullptr;
    errno = 0;
    const auto parsed = std::strtoul(text, &end, 10);
    if (errno || end == text || *end || parsed < 10 || parsed > 60000)
        return DefaultStallThreshold;
    return std::chrono::milliseconds(parsed);
}

const char* report_directory()
{
    const char* requested = std::getenv("NDS4MISTER_CRASH_REPORT_DIR");
    return requested && *requested ? requested : "/media/fat";
}

} // namespace

std::uint32_t fpga_diagnostic_request_token() noexcept
{
    // The beta93 FPGA diagnostic-token path can latch BAD_HEADER while a
    // healthy game is running. Keep public manual reports read-only until the
    // HDL handshake is corrected; the flight recorder still captures FPGA
    // telemetry, frame state, and replay state without disturbing gameplay.
    return 0;
}

void FpgaRuntimeTelemetry::reset(std::uint32_t new_session) noexcept
{
    replay_backlog.store(0, std::memory_order_relaxed);
    replay_queue_high_water.store(0, std::memory_order_relaxed);
    latest_input_frame.store(0, std::memory_order_relaxed);
    latest_replay_frame.store(0, std::memory_order_relaxed);
    input_packets.store(0, std::memory_order_relaxed);
    replay_packets.store(0, std::memory_order_relaxed);
    replay_queue_full_polls.store(0, std::memory_order_relaxed);
    frames_rendered.store(0, std::memory_order_relaxed);
    frames_published.store(0, std::memory_order_relaxed);
    replay_budget_drops.store(0, std::memory_order_relaxed);
    publication_replacements.store(0, std::memory_order_relaxed);
    publication_queue_high_water.store(0, std::memory_order_relaxed);
    session.store(new_session, std::memory_order_release);
}

struct FpgaCrashMonitor::Impl {
    Impl(
        volatile h3d::Header* shared_header, bool start,
        const FpgaRuntimeTelemetry* runtime)
        : header(shared_header), telemetry(runtime),
          threshold(stall_threshold()), started(Clock::now())
    {
        if (start && header) worker = std::thread([this] { run(); });
    }

    ~Impl()
    {
        stop.store(true, std::memory_order_release);
        if (worker.joinable()) worker.join();
    }

    FlightSample sample() const
    {
        FlightSample result;
        h3d::device_barrier();
        result.elapsed_ms = static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                Clock::now() - started).count());
        result.magic = header->magic;
        result.session = header->fpga_session;
        result.producer = header->producer_sequence;
        result.consumer = header->consumer_sequence;
        result.fpga_faults = header->fpga_fault_bits;
        result.hps_faults = header->hps_fault_bits;
        result.service_state = header->service_state;
        result.accepted_session = header->accepted_session;
        result.frame_publish = header->frame_publish_sequence;
        result.frame_ack = header->frame_ack_sequence;
        result.frame_sequence = header->frame.sequence;
        result.frame_session = header->frame.session;
        result.frame_number = header->frame.frame;
        result.frame_bank = header->frame.bank;
        result.frame_format = header->frame.format;
        result.fpga_pc9 = header->fpga_heartbeat;
        result.fpga_telemetry = header->fpga_heartbeat_reserved;
        result.hps_heartbeat = header->hps_heartbeat;
        result.hps_diagnostic_token = header->hps_heartbeat_reserved;
        result.quiesce_request = header->quiesce_request;
        result.quiesce_ack = header->quiesce_ack;
        h3d::device_barrier();
        if (telemetry) {
            result.runtime_session =
                telemetry->session.load(std::memory_order_acquire);
            result.replay_backlog =
                telemetry->replay_backlog.load(std::memory_order_relaxed);
            result.replay_queue_high_water = telemetry->replay_queue_high_water
                .load(std::memory_order_relaxed);
            result.latest_input_frame = telemetry->latest_input_frame.load(
                std::memory_order_relaxed);
            result.latest_replay_frame = telemetry->latest_replay_frame.load(
                std::memory_order_relaxed);
            result.input_packets =
                telemetry->input_packets.load(std::memory_order_relaxed);
            result.replay_packets =
                telemetry->replay_packets.load(std::memory_order_relaxed);
            result.replay_queue_full_polls = telemetry->replay_queue_full_polls
                .load(std::memory_order_relaxed);
            result.frames_rendered =
                telemetry->frames_rendered.load(std::memory_order_relaxed);
            result.frames_published =
                telemetry->frames_published.load(std::memory_order_relaxed);
            result.replay_budget_drops = telemetry->replay_budget_drops.load(
                std::memory_order_relaxed);
            result.publication_replacements =
                telemetry->publication_replacements.load(
                    std::memory_order_relaxed);
            result.publication_queue_high_water =
                telemetry->publication_queue_high_water.load(
                    std::memory_order_relaxed);
        }
        return result;
    }

    void retain(const FlightSample& current)
    {
        history[history_next] = current;
        history_next = (history_next + 1) % history.size();
        if (history_count != history.size()) ++history_count;
    }

    std::string report_contents(
        const char* reason, const FlightSample& trigger) const
    {
        std::ostringstream output;
        output << "NDS4MISTER_FPGA_CRASH_V2\n"
               << "reason=" << reason << '\n'
               << "pid=" << getpid() << '\n'
               << "session=" << trigger.session << '\n'
               << "sample_interval_ms=" << SampleInterval.count() << '\n'
               << "stall_threshold_ms=" << threshold.count() << '\n'
               << "sample_encoding=elapsed_ms_decimal,remaining_fields_hex\n"
               << "telemetry_tags="
                  "1:arm7_pc_low28,2:arm9_r0_low28,3:arm9_lr_low28,"
                  "4:arm9_cpsr_compact,5:cpu_gpu_status,6:h3d_status,"
                  "7:ddr_fabric,8:display_fault_counts\n"
               << "samples_csv="
                  "elapsed_ms,magic,session,producer,consumer,fpga_faults,"
                  "hps_faults,service,accepted,frame_pub,frame_ack,frame_seq,"
                  "frame_session,frame,bank,format,pc9,telemetry,hps_hb,"
                  "diag_token,quiesce_req,quiesce_ack,runtime_session,"
                  "replay_backlog,replay_high_water,input_frame,replay_frame,"
                  "input_packets,replay_packets,replay_full_polls,"
                  "frames_rendered,frames_published,replay_budget_drops,"
                  "publication_replacements,publication_high_water\n";
        const auto first = (history_next + history.size() - history_count) %
            history.size();
        output << std::hex;
        for (std::size_t count = 0; count < history_count; ++count) {
            const auto& item = history[(first + count) % history.size()];
            output << std::dec << item.elapsed_ms << std::hex
                   << ',' << item.magic
                   << ',' << item.session
                   << ',' << item.producer
                   << ',' << item.consumer
                   << ',' << item.fpga_faults
                   << ',' << item.hps_faults
                   << ',' << item.service_state
                   << ',' << item.accepted_session
                   << ',' << item.frame_publish
                   << ',' << item.frame_ack
                   << ',' << item.frame_sequence
                   << ',' << item.frame_session
                   << ',' << item.frame_number
                   << ',' << item.frame_bank
                   << ',' << item.frame_format
                   << ',' << item.fpga_pc9
                   << ',' << item.fpga_telemetry
                   << ',' << item.hps_heartbeat
                   << ',' << item.hps_diagnostic_token
                   << ',' << item.quiesce_request
                   << ',' << item.quiesce_ack
                   << ',' << item.runtime_session
                   << ',' << item.replay_backlog
                   << ',' << item.replay_queue_high_water
                   << ',' << item.latest_input_frame
                   << ',' << item.latest_replay_frame
                   << ',' << item.input_packets
                   << ',' << item.replay_packets
                   << ',' << item.replay_queue_full_polls
                   << ',' << item.frames_rendered
                   << ',' << item.frames_published
                   << ',' << item.replay_budget_drops
                   << ',' << item.publication_replacements
                   << ',' << item.publication_queue_high_water << '\n';
        }
        return output.str();
    }

    void write_report(const char* reason, const FlightSample& trigger)
    {
        char path[384];
        const auto index = ++report_sequence;
        const int length = std::snprintf(
            path, sizeof(path), "%s/NDS4MiSTer_crash_%ld_s%u_%u.txt",
            report_directory(), static_cast<long>(getpid()),
            trigger.session, index);
        if (length <= 0 || static_cast<std::size_t>(length) >= sizeof(path))
            return;
        const auto contents = report_contents(reason, trigger);
        const int fd = open(
            path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
        if (fd < 0) return;
        bool ok = write_all(fd, contents.data(), contents.size());
        if (ok) ok = fsync(fd) == 0;
        if (close(fd) != 0) ok = false;
        if (!ok) {
            unlink(path);
            return;
        }
        std::fprintf(stderr, "NDS4MISTER_CRASH_REPORT %s\n", path);
    }

    void manual_capture()
    {
        // A manual report must be observational. The beta93 diagnostic-token
        // handshake itself was measured latching FPGA BAD_HEADER with a zero
        // replay backlog, so retain a short read-only burst instead of asking
        // the core to halt its CPUs.
        for (std::size_t index = 0;
             index < ManualBurstSamples &&
             !stop.load(std::memory_order_acquire); ++index) {
            std::this_thread::sleep_for(ManualBurstInterval);
            retain(sample());
        }
        const auto trigger = sample();
        retain(trigger);
        write_report("manual_state_dump", trigger);
    }

    void evaluate(const FlightSample& current, Clock::time_point now)
    {
        if (current.magic != h3d::Magic || current.session == 0 ||
            current.accepted_session != current.session ||
            current.service_state !=
                static_cast<std::uint32_t>(h3d::ServiceState::Ready)) {
            observed_session = 0;
            packet_stall_reported = false;
            plane_stall_reported = false;
            return;
        }
        if (current.session != observed_session) {
            observed_session = current.session;
            last_consumer = current.consumer;
            last_frame_ack = current.frame_ack;
            last_fpga_faults = current.fpga_faults;
            consumer_progress = now;
            frame_ack_progress = now;
            packet_stall_reported = false;
            plane_stall_reported = false;
            fault_reported = false;
        }

        if (current.consumer != last_consumer ||
            current.producer == current.consumer) {
            last_consumer = current.consumer;
            consumer_progress = now;
            packet_stall_reported = false;
        } else if (!packet_stall_reported &&
                   now - consumer_progress >= threshold) {
            write_report("packet_consumer_stalled", current);
            packet_stall_reported = true;
        }

        if (current.frame_ack != last_frame_ack ||
            current.frame_publish == current.frame_ack) {
            last_frame_ack = current.frame_ack;
            frame_ack_progress = now;
            plane_stall_reported = false;
        } else if (!plane_stall_reported &&
                   now - frame_ack_progress >= threshold) {
            write_report("frame_acknowledgement_stalled", current);
            plane_stall_reported = true;
        }

        if (current.fpga_faults != 0 &&
            (!fault_reported || current.fpga_faults != last_fpga_faults)) {
            write_report("fpga_fault_latched", current);
            fault_reported = true;
        }
        last_fpga_faults = current.fpga_faults;
    }

    void run()
    {
#if defined(__linux__)
        // SCHED_IDLE keeps public diagnostics behind both renderer workers.
        sched_param parameters {};
        pthread_setschedparam(pthread_self(), SCHED_IDLE, &parameters);
#endif
        while (!stop.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(SampleInterval);
            if (stop.load(std::memory_order_acquire)) break;
            if (consume_manual_fpga_snapshot_request()) {
                manual_capture();
                continue;
            }
            const auto current = sample();
            retain(current);
            evaluate(current, Clock::now());
        }
    }

    volatile h3d::Header* header;
    const FpgaRuntimeTelemetry* telemetry;
    const std::chrono::milliseconds threshold;
    const Clock::time_point started;
    std::atomic<bool> stop {false};
    std::thread worker;
    std::array<FlightSample, HistorySamples> history {};
    std::size_t history_next = 0;
    std::size_t history_count = 0;
    std::uint32_t report_sequence = 0;
    std::uint32_t observed_session = 0;
    std::uint32_t last_consumer = 0;
    std::uint32_t last_frame_ack = 0;
    std::uint32_t last_fpga_faults = 0;
    Clock::time_point consumer_progress {started};
    Clock::time_point frame_ack_progress {started};
    bool packet_stall_reported = false;
    bool plane_stall_reported = false;
    bool fault_reported = false;
};

FpgaCrashMonitor::FpgaCrashMonitor(
    volatile h3d::Header* header, bool enabled,
    const FpgaRuntimeTelemetry* runtime_telemetry)
    : impl_(std::make_unique<Impl>(header, enabled, runtime_telemetry))
{
}

FpgaCrashMonitor::~FpgaCrashMonitor() = default;

} // namespace nds4mister::crash
