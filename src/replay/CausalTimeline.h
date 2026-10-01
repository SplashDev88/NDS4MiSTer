#pragma once

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <limits>
#include <memory>
#include <vector>

namespace nds4mister::crash {

// Private process-RAM recorder. Each lane has exactly ONE writer. All slot
// words are atomic: overwritten snapshots may be rejected but never data-race.
// Two seqlock fences per event; no allocation, mutex or I/O on the writer path.
struct TimelineRecord {
    std::uint64_t us;
    std::uint32_t session, kind, sequence, frame, a, b;
};
static_assert(sizeof(TimelineRecord) == 32);

enum class TimelineKind : std::uint32_t {
    AcquireBegin=1, AcquireEnd, QueryFastReply, InputQueued, InputSwap,
    InputLcd, ReplayBegin, ReplayEnd, ReplaySwap, LcdAdmission,
    PictureReady, UploadBegin, UploadEnd, VBlankBegin, VBlankEnd,
    QueryOrderedReply
};

class TimelineLane {
public:
    explicit TimelineLane(std::uint32_t capacity)
        : capacity_(capacity), slots_(new Slot[capacity]) {}

    void append(const TimelineRecord& record) noexcept
    {
        // Saturate before stamp wrap. At 10,000 events/s this takes >59 hours.
        if (written_ == 0x7fffffffu) return;
        const auto serial = written_ + 1;
        auto& slot = slots_[written_ % capacity_];
        slot.stamp.store(serial*2-1, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_release);
        const std::array<std::uint32_t,8> words {{
            static_cast<std::uint32_t>(record.us),
            static_cast<std::uint32_t>(record.us >> 32), record.session,
            record.kind, record.sequence, record.frame, record.a, record.b}};
        for (unsigned i=0;i<words.size();++i)
            slot.words[i].store(words[i], std::memory_order_relaxed);
        slot.stamp.store(serial*2, std::memory_order_release);
        written_ = serial;
        published_.store(serial, std::memory_order_release);
    }

    struct Snapshot {
        std::uint32_t published=0, overwritten=0, raced=0;
        std::vector<TimelineRecord> records;
    };

    Snapshot snapshot(std::uint64_t not_after_us) const
    {
        Snapshot out;
        out.published=published_.load(std::memory_order_acquire);
        out.overwritten=out.published>capacity_ ? out.published-capacity_ : 0;
        out.records.reserve(out.published-out.overwritten);
        for (auto i=out.overwritten;i<out.published;++i) {
            const auto& slot=slots_[i%capacity_];
            const auto expected=(i+1)*2;
            if (slot.stamp.load(std::memory_order_acquire)!=expected) {
                ++out.raced; continue;
            }
            std::array<std::uint32_t,8> words{};
            for (unsigned k=0;k<words.size();++k)
                words[k]=slot.words[k].load(std::memory_order_relaxed);
            std::atomic_thread_fence(std::memory_order_acquire);
            if (slot.stamp.load(std::memory_order_relaxed)!=expected) {
                ++out.raced; continue;
            }
            TimelineRecord record{
                std::uint64_t(words[0]) | (std::uint64_t(words[1])<<32),
                words[2],words[3],words[4],words[5],words[6],words[7]};
            if (record.us<=not_after_us) out.records.push_back(record);
        }
        return out;
    }

private:
    static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
    struct Slot {
        std::atomic<std::uint32_t> stamp{0};
        std::array<std::atomic<std::uint32_t>,8> words{};
    };
    const std::uint32_t capacity_;
    std::unique_ptr<Slot[]> slots_;
    std::uint32_t written_=0; // Single writer only.
    alignas(64) std::atomic<std::uint32_t> published_{0};
};

struct CausalTimeline {
    enum class Lane { Intake, Replay, Publication };
    // At measured rates these retain >60 s. Lost/overwritten events are
    // explicit in the binary header; analyses must check actual overlap.
    TimelineLane intake{131072}, replay{131072}, publication{16384};
    static std::uint64_t micros(std::chrono::steady_clock::time_point t) {
        return static_cast<std::uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(t.time_since_epoch()).count());
    }
    static std::uint64_t now_us() { return micros(std::chrono::steady_clock::now()); }
    void record(Lane lane, TimelineKind kind, std::uint32_t session,
                std::uint32_t sequence, std::uint32_t frame,
                std::uint32_t a=0, std::uint32_t b=0, std::uint64_t at_us=0) {
        const TimelineRecord r{at_us ? at_us : now_us(), session,
            static_cast<std::uint32_t>(kind),sequence,frame,a,b};
        switch(lane) {
        case Lane::Intake: intake.append(r); break;
        case Lane::Replay: replay.append(r); break;
        case Lane::Publication: publication.append(r); break;
        }
    }
};

} // namespace nds4mister::crash
