#include "replay/ReplaySpscState.h"

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <thread>

namespace {

[[noreturn]] void fail(const char* message)
{
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
}

void require(bool condition, const char* message)
{
    if (!condition) fail(message);
}

// Reproduce the old two-writer replay_backlog_ race with an exact schedule.
// The producer computes depth before the consumer claims a packet, then its
// delayed store overwrites the consumer's newer derived depth.
void test_old_mirrored_backlog_loses_newer_claim()
{
    std::atomic<std::uint32_t> published {2};
    std::atomic<std::uint32_t> claimed {0};
    std::atomic<std::uint32_t> mirrored_backlog {2};

    const auto producer_claimed = claimed.load(std::memory_order_acquire);
    const auto producer_derived =
        published.load(std::memory_order_relaxed) - producer_claimed;

    claimed.store(1, std::memory_order_release);
    mirrored_backlog.store(1, std::memory_order_release);
    mirrored_backlog.store(producer_derived, std::memory_order_release);

    const auto authoritative =
        published.load(std::memory_order_acquire) -
        claimed.load(std::memory_order_acquire);
    require(authoritative == 1, "old-race authoritative depth changed");
    require(mirrored_backlog.load(std::memory_order_acquire) == 2,
        "old mirrored backlog race did not reproduce");
}

void test_indices_are_the_only_depth_authority()
{
    nds4mister::replay::ReplaySpscState state;
    state.reset();
    require(state.publish(100).count() == 1, "first publish depth");
    require(state.publish(101).count() == 2, "second publish depth");
    const auto snapshot = state.consumer_snapshot();
    require(snapshot.count() == 2, "consumer snapshot depth");
    state.claim(snapshot.claimed + 1);
    require(state.count() == 1, "derived depth after claim");
    require(state.latest_input_frame() == 101, "latest frame metadata");
}

void test_frame_metadata_precedes_publication()
{
    constexpr std::uint32_t Iterations = 200000;
    nds4mister::replay::ReplaySpscState state;
    state.reset();
    std::atomic<bool> failed {false};

    std::thread consumer([&] {
        std::uint32_t claimed = 0;
        while (claimed != Iterations) {
            const auto snapshot = state.consumer_snapshot();
            if (snapshot.published == claimed) {
                std::this_thread::yield();
                continue;
            }
            // Producer permits one outstanding publication in this test, so
            // the release/acquire edge must expose this exact frame metadata.
            if (snapshot.published != claimed + 1 ||
                state.latest_input_frame() != snapshot.published)
                failed.store(true, std::memory_order_relaxed);
            claimed = snapshot.published;
            state.claim(claimed);
        }
    });

    for (std::uint32_t frame = 1; frame <= Iterations; ++frame) {
        while (state.count() != 0) std::this_thread::yield();
        state.publish(frame);
    }
    consumer.join();

    require(!failed.load(std::memory_order_relaxed),
        "consumer observed publication without its frame metadata");
    require(state.count() == 0, "threaded test did not drain queue");
}

} // namespace

int main()
{
    test_old_mirrored_backlog_loses_newer_claim();
    test_indices_are_the_only_depth_authority();
    test_frame_metadata_precedes_publication();
    std::cout << "Replay SPSC state tests passed\n";
    return 0;
}
