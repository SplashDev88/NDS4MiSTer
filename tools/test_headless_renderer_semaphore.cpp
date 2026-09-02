#include "Platform.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <thread>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/resource.h>
#endif
#if defined(__linux__)
#include <pthread.h>
#include <sched.h>
#endif

namespace {

[[noreturn]] void fail(const char* message)
{
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
}

std::uint64_t elapsed_ns(
    std::chrono::steady_clock::time_point started)
{
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now() - started).count());
}

std::uint64_t process_cpu_ns()
{
#if defined(__unix__) || defined(__APPLE__)
    rusage usage {};
    if (getrusage(RUSAGE_SELF, &usage) != 0)
        return 0;
    const auto user = std::uint64_t(usage.ru_utime.tv_sec) * 1000000000u +
        std::uint64_t(usage.ru_utime.tv_usec) * 1000u;
    const auto system = std::uint64_t(usage.ru_stime.tv_sec) * 1000000000u +
        std::uint64_t(usage.ru_stime.tv_usec) * 1000u;
    return user + system;
#else
    return 0;
#endif
}

struct CpuPair {
    int first = -1;
    int second = -1;
};

CpuPair available_cpu_pair()
{
    CpuPair result;
#if defined(__linux__)
    cpu_set_t available;
    CPU_ZERO(&available);
    if (sched_getaffinity(0, sizeof(available), &available) != 0)
        return result;
    for (int cpu = 0; cpu < CPU_SETSIZE; ++cpu) {
        if (!CPU_ISSET(cpu, &available))
            continue;
        if (result.first < 0)
            result.first = cpu;
        else {
            result.second = cpu;
            break;
        }
    }
#endif
    return result;
}

void bind_to_cpu(int cpu)
{
#if defined(__linux__)
    if (cpu < 0)
        return;
    cpu_set_t affinity;
    CPU_ZERO(&affinity);
    CPU_SET(cpu, &affinity);
    if (pthread_setaffinity_np(
            pthread_self(), sizeof(affinity), &affinity) != 0)
        fail("could not bind benchmark thread");
#else
    (void)cpu;
#endif
}

} // namespace

int main()
{
    using namespace melonDS::Platform;

    auto* work = Semaphore_Create();
    auto* done = Semaphore_Create();
    if (!work || !done) fail("semaphore allocation failed");

    constexpr std::uint32_t Iterations = 200000;
    const auto cpus = available_cpu_pair();
    bind_to_cpu(cpus.first);
    std::atomic<std::uint32_t> consumed {0};
    std::thread worker([&] {
        bind_to_cpu(cpus.second);
        for (std::uint32_t iteration = 0; iteration < Iterations;
             ++iteration) {
            Semaphore_Wait(work);
            consumed.fetch_add(1, std::memory_order_relaxed);
            Semaphore_Post(done);
        }
    });

    const auto ping_cpu_started = process_cpu_ns();
    const auto ping_started = std::chrono::steady_clock::now();
    for (std::uint32_t iteration = 0; iteration < Iterations; ++iteration) {
        Semaphore_Post(work);
        Semaphore_Wait(done);
    }
    const auto ping_ns = elapsed_ns(ping_started);
    const auto ping_cpu_ns = process_cpu_ns() - ping_cpu_started;
    worker.join();
    if (consumed.load(std::memory_order_relaxed) != Iterations)
        fail("ping-pong lost a hand-off");

    Semaphore_Reset(work);
    Semaphore_Post(work, 192);
    for (unsigned token = 0; token < 192; ++token)
        if (!Semaphore_TryWait(work))
            fail("counted post lost a token");
    if (Semaphore_TryWait(work))
        fail("counted semaphore retained an extra token");

    Semaphore_Post(work, 3);
    Semaphore_Reset(work);
    if (Semaphore_TryWait(work))
        fail("reset did not clear queued tokens");

    const auto timeout_started = std::chrono::steady_clock::now();
    if (Semaphore_TryWait(work, 5))
        fail("timed wait consumed a nonexistent token");
    const auto timeout_ns = elapsed_ns(timeout_started);
    if (timeout_ns < 3000000u || timeout_ns > 100000000u)
        fail("timed wait duration is outside its scheduling tolerance");

    constexpr std::uint32_t BurstTokens = 100000;
    std::atomic<std::uint64_t> checksum {0};
    std::thread burst_worker([&] {
        bind_to_cpu(cpus.second);
        for (std::uint32_t token = 1; token <= BurstTokens; ++token) {
            Semaphore_Wait(work);
            checksum.fetch_add(token, std::memory_order_relaxed);
        }
    });
    const auto burst_started = std::chrono::steady_clock::now();
    Semaphore_Post(work, static_cast<int>(BurstTokens));
    burst_worker.join();
    const auto burst_ns = elapsed_ns(burst_started);
    const auto expected_checksum =
        std::uint64_t(BurstTokens) * (BurstTokens + 1u) / 2u;
    if (checksum.load(std::memory_order_relaxed) != expected_checksum)
        fail("burst consumption lost or duplicated a token");

    Semaphore_Free(done);
    Semaphore_Free(work);
    std::cout << "HEADLESS_SEMAPHORE_BENCH iterations=" << Iterations
              << " ping_pong_ns=" << ping_ns
              << " ns_per_handoff=" << ping_ns / Iterations
              << " ping_cpu_ns=" << ping_cpu_ns
              << " cpu_ns_per_handoff=" << ping_cpu_ns / Iterations
              << " burst_tokens=" << BurstTokens
              << " burst_ns=" << burst_ns
              << " timeout_ns=" << timeout_ns << '\n';
    return 0;
}
