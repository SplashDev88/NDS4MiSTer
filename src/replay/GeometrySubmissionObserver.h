#pragma once

#include <cstdint>
#include <vector>

namespace nds4mister::replay {

// Diagnostic only. Equal command streams are necessary, not sufficient, for
// command-replay reuse: starting matrices, stacks, queries and other state can
// differ. Never use this observer's result to skip guest-visible work.
class GeometrySubmissionObserver {
public:
    struct Counters {
        std::uint64_t submissions = 0, compared = 0, identical = 0;
        std::uint64_t commands = 0, identical_commands = 0, overflow = 0;
    } counts;
    static constexpr std::size_t Capacity = 131072;

    void reset() {
        current_.clear(); previous_.clear();
        synchronized_ = false; overflow_ = false; previous_valid_ = false;
        counts = {};
    }

    bool command(std::uint8_t op, std::uint32_t value) {
        if (current_.size() < Capacity)
            current_.push_back((std::uint64_t(op) << 32) | value);
        else overflow_ = true;
        if (op != 0x50) return false;
        // The first SWAP may terminate a partial stream after reset.
        if (synchronized_) {
            ++counts.submissions;
            counts.commands += current_.size();
            if (overflow_) ++counts.overflow;
            if (!overflow_ && previous_valid_ && current_.size() > 1) {
                ++counts.compared;
                // Full comparison, with no hash-collision or padding issue.
                if (current_ == previous_) {
                    ++counts.identical;
                    counts.identical_commands += current_.size();
                }
            }
        }
        previous_valid_ = synchronized_ && !overflow_;
        synchronized_ = true;
        previous_.swap(current_);
        current_.clear(); overflow_ = false;
        return true;
    }

private:
    std::vector<std::uint64_t> current_, previous_;
    bool synchronized_ = false, overflow_ = false, previous_valid_ = false;
};
}
