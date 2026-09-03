#include "replay/ArmCrashDump.h"

#include "replay/Hybrid3DAbi.h"

#include <cerrno>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <sys/types.h>
#include <unistd.h>

#if defined(__linux__)
#include <sys/syscall.h>
#include <ucontext.h>
#endif

namespace nds4mister::crash {
namespace {

constexpr std::size_t DumpPathBytes = 256;
constexpr std::size_t StackSnapshotBytes = 256;

char dump_path[DumpPathBytes] {};
volatile h3d::Header* volatile shared_header = nullptr;
volatile std::sig_atomic_t handling_crash = 0;
volatile std::sig_atomic_t manual_fpga_snapshot_requested = 0;
volatile std::sig_atomic_t manual_video_snapshot_requested = 0;

void write_all(int fd, const void* data, std::size_t size)
{
    const auto* bytes = static_cast<const char*>(data);
    while (size != 0) {
        const auto count = write(fd, bytes, size);
        if (count > 0) {
            bytes += count;
            size -= static_cast<std::size_t>(count);
        } else if (count < 0 && errno == EINTR) {
            continue;
        } else {
            return;
        }
    }
}

void write_text(int fd, const char* text)
{
    std::size_t size = 0;
    while (text[size] != '\0') ++size;
    write_all(fd, text, size);
}

void write_hex(int fd, std::uint64_t value)
{
    constexpr char Digits[] = "0123456789abcdef";
    char output[18] = {'0', 'x'};
    for (unsigned index = 0; index < 16; ++index) {
        const auto shift = 60u - index * 4u;
        output[index + 2] = Digits[(value >> shift) & 0x0fu];
    }
    write_all(fd, output, sizeof(output));
}

void write_decimal(int fd, std::uint64_t value)
{
    char reversed[24];
    std::size_t size = 0;
    do {
        reversed[size++] = static_cast<char>('0' + value % 10);
        value /= 10;
    } while (value != 0);
    char output[24];
    for (std::size_t index = 0; index < size; ++index)
        output[index] = reversed[size - index - 1];
    write_all(fd, output, size);
}

void write_hex_field(int fd, const char* key, std::uint64_t value)
{
    write_text(fd, key);
    write_text(fd, "=");
    write_hex(fd, value);
    write_text(fd, "\n");
}

void write_decimal_field(int fd, const char* key, std::uint64_t value)
{
    write_text(fd, key);
    write_text(fd, "=");
    write_decimal(fd, value);
    write_text(fd, "\n");
}

void write_signed_decimal_field(int fd, const char* key, std::int64_t value)
{
    write_text(fd, key);
    write_text(fd, "=");
    if (value < 0) {
        write_text(fd, "-");
        const auto magnitude = static_cast<std::uint64_t>(-(value + 1)) + 1;
        write_decimal(fd, magnitude);
    } else {
        write_decimal(fd, static_cast<std::uint64_t>(value));
    }
    write_text(fd, "\n");
}

std::uintptr_t write_registers(int fd, void* context)
{
#if defined(__linux__) && (defined(__arm__) || defined(__x86_64__))
    const auto* ucontext = static_cast<const ucontext_t*>(context);
#endif
#if defined(__linux__) && defined(__arm__)
    const auto& registers = ucontext->uc_mcontext;
    write_hex_field(fd, "r0", registers.arm_r0);
    write_hex_field(fd, "r1", registers.arm_r1);
    write_hex_field(fd, "r2", registers.arm_r2);
    write_hex_field(fd, "r3", registers.arm_r3);
    write_hex_field(fd, "r4", registers.arm_r4);
    write_hex_field(fd, "r5", registers.arm_r5);
    write_hex_field(fd, "r6", registers.arm_r6);
    write_hex_field(fd, "r7", registers.arm_r7);
    write_hex_field(fd, "r8", registers.arm_r8);
    write_hex_field(fd, "r9", registers.arm_r9);
    write_hex_field(fd, "r10", registers.arm_r10);
    write_hex_field(fd, "fp", registers.arm_fp);
    write_hex_field(fd, "ip", registers.arm_ip);
    write_hex_field(fd, "sp", registers.arm_sp);
    write_hex_field(fd, "lr", registers.arm_lr);
    write_hex_field(fd, "pc", registers.arm_pc);
    write_hex_field(fd, "cpsr", registers.arm_cpsr);
    write_hex_field(fd, "fault_address", registers.fault_address);
    return registers.arm_sp;
#elif defined(__linux__) && defined(__x86_64__)
    const auto& registers = ucontext->uc_mcontext.gregs;
    write_hex_field(fd, "rsp", registers[REG_RSP]);
    write_hex_field(fd, "rbp", registers[REG_RBP]);
    write_hex_field(fd, "rip", registers[REG_RIP]);
    return static_cast<std::uintptr_t>(registers[REG_RSP]);
#else
    (void)context;
    write_text(fd, "registers=unsupported_architecture\n");
    return 0;
#endif
}

std::uint64_t current_thread_id()
{
#if defined(__linux__) && defined(SYS_gettid)
    return static_cast<std::uint64_t>(syscall(SYS_gettid));
#else
    // The production target is Linux/ARM. A process id is sufficient for
    // host-only portability tests on systems without a stable gettid API.
    return static_cast<std::uint64_t>(getpid());
#endif
}

void write_header_snapshot(int fd)
{
    const volatile auto* header = shared_header;
    if (!header) {
        write_text(fd, "shared_header=unavailable\n");
        return;
    }

    write_hex_field(fd, "header.magic", header->magic);
    write_decimal_field(fd, "header.version", header->version);
    write_decimal_field(fd, "header.header_size", header->header_size);
    write_decimal_field(fd, "header.fpga_session", header->fpga_session);
    write_decimal_field(fd, "header.entry_count", header->entry_count);
    write_decimal_field(
        fd, "header.producer_sequence", header->producer_sequence);
    write_decimal_field(
        fd, "header.consumer_sequence", header->consumer_sequence);
    write_hex_field(fd, "header.fpga_fault_bits", header->fpga_fault_bits);
    write_hex_field(fd, "header.hps_fault_bits", header->hps_fault_bits);
    write_decimal_field(fd, "header.service_state", header->service_state);
    write_decimal_field(
        fd, "header.accepted_session", header->accepted_session);
    write_decimal_field(
        fd, "header.frame_publish_sequence",
        header->frame_publish_sequence);
    write_decimal_field(
        fd, "header.frame_ack_sequence", header->frame_ack_sequence);
    write_decimal_field(fd, "frame.sequence", header->frame.sequence);
    write_decimal_field(fd, "frame.session", header->frame.session);
    write_decimal_field(fd, "frame.frame", header->frame.frame);
    write_decimal_field(fd, "frame.bank", header->frame.bank);
    write_decimal_field(fd, "frame.format", header->frame.format);
    write_hex_field(
        fd, "frame.width_height", header->frame.width_height);
    write_decimal_field(fd, "frame.stride", header->frame.stride);
    write_decimal_field(
        fd, "header.fpga_heartbeat", header->fpga_heartbeat);
    write_hex_field(
        fd, "header.fpga_telemetry", header->fpga_heartbeat_reserved);
    write_decimal_field(fd, "header.hps_heartbeat", header->hps_heartbeat);
    write_decimal_field(
        fd, "header.hps_diagnostic_token",
        header->hps_heartbeat_reserved);
    write_decimal_field(
        fd, "header.quiesce_request", header->quiesce_request);
    write_decimal_field(fd, "header.quiesce_ack", header->quiesce_ack);
}

void write_stack_snapshot(int fd, std::uintptr_t stack_pointer)
{
    write_text(fd, "stack_address=");
    write_hex(fd, stack_pointer);
    write_text(fd, "\n");
    if (stack_pointer == 0) {
        write_text(fd, "stack=unavailable\n");
        return;
    }

    const int memory = open("/proc/self/mem", O_RDONLY | O_CLOEXEC);
    if (memory < 0) {
        write_text(fd, "stack=unavailable\n");
        return;
    }
    std::uint8_t bytes[StackSnapshotBytes];
    const auto count = pread(
        memory, bytes, sizeof(bytes), static_cast<off_t>(stack_pointer));
    close(memory);
    if (count <= 0) {
        write_text(fd, "stack=unavailable\n");
        return;
    }

    write_text(fd, "stack=");
    constexpr char Digits[] = "0123456789abcdef";
    char encoded[StackSnapshotBytes * 2];
    for (ssize_t index = 0; index < count; ++index) {
        encoded[index * 2] = Digits[bytes[index] >> 4];
        encoded[index * 2 + 1] = Digits[bytes[index] & 0x0f];
    }
    write_all(fd, encoded, static_cast<std::size_t>(count) * 2);
    write_text(fd, "\n");
}

void mark_transport_fault()
{
    volatile auto* header = shared_header;
    if (!header) return;
    header->hps_fault_bits |= h3d::FaultArmCrash;
    header->service_state = static_cast<std::uint32_t>(
        h3d::ServiceState::Fault);
}

void fatal_signal_handler(int signal, siginfo_t* info, void* context)
{
    if (handling_crash) _exit(255);
    handling_crash = 1;

    const int fd = open(
        dump_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd >= 0) {
        write_text(fd, "NDS4MISTER_ARM_CRASH_V1\n");
        write_decimal_field(fd, "pid", static_cast<std::uint64_t>(getpid()));
        write_decimal_field(fd, "tid", current_thread_id());
        write_decimal_field(fd, "signal", static_cast<unsigned>(signal));
        if (info) {
            write_signed_decimal_field(fd, "signal_code", info->si_code);
            write_hex_field(
                fd, "signal_address",
                reinterpret_cast<std::uintptr_t>(info->si_addr));
        }
        const auto stack_pointer = write_registers(fd, context);
        write_header_snapshot(fd);
        write_stack_snapshot(fd, stack_pointer);
        fsync(fd);
        close(fd);
    }
    mark_transport_fault();
    _exit(128 + signal);
}

void manual_fpga_snapshot_handler(int)
{
    manual_fpga_snapshot_requested = 1;
}

void manual_video_snapshot_handler(int)
{
    manual_video_snapshot_requested = 1;
}

} // namespace

bool install_arm_crash_handler()
{
    const char* requested_path = std::getenv(
        "NDS4MISTER_CRASH_DUMP_PATH");
    if (requested_path && requested_path[0] != '\0') {
        std::snprintf(dump_path, sizeof(dump_path), "%s", requested_path);
    } else {
        std::snprintf(
            dump_path, sizeof(dump_path),
            "/media/fat/nds_crash_%ld.txt", static_cast<long>(getpid()));
    }

    struct sigaction action {};
    sigemptyset(&action.sa_mask);
    action.sa_sigaction = fatal_signal_handler;
    action.sa_flags = SA_SIGINFO | SA_RESETHAND;
    constexpr int FatalSignals[] = {
        SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT,
    };
    for (const auto signal : FatalSignals) {
        if (sigaction(signal, &action, nullptr) != 0) return false;
    }
    struct sigaction manual_action {};
    sigemptyset(&manual_action.sa_mask);
    manual_action.sa_handler = manual_fpga_snapshot_handler;
    if (sigaction(SIGUSR1, &manual_action, nullptr) != 0) return false;
    manual_action.sa_handler = manual_video_snapshot_handler;
    if (sigaction(SIGUSR2, &manual_action, nullptr) != 0) return false;
    return true;
}

bool consume_manual_fpga_snapshot_request()
{
    if (!manual_fpga_snapshot_requested) return false;
    manual_fpga_snapshot_requested = 0;
    return true;
}

bool consume_manual_video_snapshot_request()
{
    if (!manual_video_snapshot_requested) return false;
    manual_video_snapshot_requested = 0;
    return true;
}

void set_arm_crash_shared_header(volatile h3d::Header* header)
{
    shared_header = header;
}

} // namespace nds4mister::crash
