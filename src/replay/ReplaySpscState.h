#pragma once

#include <atomic>
#include <cstdint>

namespace nds4mister::replay {

// Event generation and waiter registration share one atomic modification order.
// A queue-depth snapshot cannot safely decide whether a consumer is asleep:
// the consumer can drain it between that snapshot and publication.
class ReplayWakeEvent {
public:
    void reset() noexcept { event_.store(0, std::memory_order_relaxed); }

    std::uint32_t prepare_wait() noexcept
    {
        // Acquire any notification preceding registration, then recheck the
        // queue/stop predicate before entering the kernel.
        return event_.fetch_or(1u, std::memory_order_acquire) | 1u;
    }

    void cancel_wait() noexcept
    {
        event_.fetch_and(~1u, std::memory_order_relaxed);
    }

    bool notify() noexcept
    {
        // Publication/stop precedes this release. If registration came first,
        // the changed generation makes FUTEX_WAIT fail or the wake releases
        // its sleeper. If notification came first, prepare_wait acquires it.
        // Backlogged work does not enter the kernel without a registered waiter.
        return (event_.fetch_add(2u, std::memory_order_release) & 1u) != 0;
    }

    std::atomic<std::uint32_t>& word() noexcept { return event_; }

private:
    alignas(64) std::atomic<std::uint32_t> event_ {0};
};

// One producer publishes immutable replay slots and one consumer claims them.
// The two monotonic indices are the only queue-depth authority: mirroring the
// depth in another atomic would give that value two writers and permit an old
// producer store to overwrite a newer consumer store.
class ReplaySpscState {
public:
    struct ProducerPublication {
        std::uint32_t published = 0;
        std::uint32_t claimed = 0;

        std::uint32_t count() const noexcept { return published - claimed; }
    };

    struct ConsumerSnapshot {
        std::uint32_t published = 0;
        std::uint32_t claimed = 0;

        std::uint32_t count() const noexcept { return published - claimed; }
    };

    void reset() noexcept
    {
        published_.store(0, std::memory_order_relaxed);
        claimed_.store(0, std::memory_order_relaxed);
        latest_input_frame_.store(0, std::memory_order_relaxed);
    }

    ProducerPublication publish(std::uint32_t frame) noexcept
    {
        const auto claimed = claimed_.load(std::memory_order_acquire);
        const auto published =
            published_.load(std::memory_order_relaxed) + 1;

        // This metadata describes the slot being published. Store it first;
        // the consumer's acquire-load of published_ then observes both the
        // complete slot and its frame metadata as one release sequence.
        latest_input_frame_.store(frame, std::memory_order_relaxed);
        published_.store(published, std::memory_order_release);
        return {published, claimed};
    }

    ConsumerSnapshot consumer_snapshot() const noexcept
    {
        const auto claimed = claimed_.load(std::memory_order_relaxed);
        const auto published = published_.load(std::memory_order_acquire);
        return {published, claimed};
    }

    void claim(std::uint32_t claimed) noexcept
    {
        claimed_.store(claimed, std::memory_order_release);
    }

    std::uint32_t count() const noexcept
    {
        // Observing claimed_ also observes the publication acquire that
        // preceded that claim. Loading published_ afterwards therefore cannot
        // yield an index older than the claimed slot.
        const auto claimed = claimed_.load(std::memory_order_acquire);
        const auto published = published_.load(std::memory_order_acquire);
        return published - claimed;
    }

    std::uint32_t latest_input_frame() const noexcept
    {
        // latest_input_frame_ is producer-owned metadata published by the
        // release-store to published_. Acquire that publication before
        // reading the relaxed metadata word it covers.
        (void)published_.load(std::memory_order_acquire);
        return latest_input_frame_.load(std::memory_order_relaxed);
    }

    std::atomic<std::uint32_t>& published_word() noexcept
    {
        return published_;
    }

    std::atomic<std::uint32_t>& claimed_word() noexcept
    {
        return claimed_;
    }

private:
    // Keep both producer-owned words together and isolate the consumer-owned
    // claim word. This preserves DreamSTer's one-writer-per-cache-line gain.
    alignas(64) std::atomic<std::uint32_t> published_ {0};
    std::atomic<std::uint32_t> latest_input_frame_ {0};
    alignas(64) std::atomic<std::uint32_t> claimed_ {0};
};

} // namespace nds4mister::replay
