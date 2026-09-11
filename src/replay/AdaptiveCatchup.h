#pragma once

#include <cstddef>
#include <cstdint>

namespace nds4mister::h3d {

// This controls derived raster admissions only. Every GX command must still be
// executed, and an omitted raster must retain the last complete visible plane.
class AdaptiveCatchupBudget {
public:
    static constexpr std::uint32_t Denominator = 12;
    static constexpr std::uint32_t MildFrames = 2;
    static constexpr std::uint32_t EmergencyFrames = 16;
    static constexpr std::size_t MildPackets = 64;
    static constexpr std::size_t MediumPackets = 128;
    static constexpr std::size_t EmergencyPackets = 256;
    static constexpr unsigned ReleaseFrames = 3;

    void reset() noexcept { numerator_ = 0; lower_frames_ = 0; }

    std::uint32_t update(std::uint32_t lead, std::size_t packets) noexcept
    {
        // Preserve the original emergency thresholds: smoothing cannot delay
        // recovery from an old replay or a nearly full packet queue.
        if (lead >= EmergencyFrames || packets >= EmergencyPackets) {
            numerator_ = Denominator;
            lower_frames_ = 0;
            return numerator_;
        }

        // Age is measured in source frames, not variable-sized GX packets.
        // Packet thresholds remain hard safety floors, not the normal clock.
        // Responsiveness profile: live Castlevania samples showed a sustained
        // 3–6 source-frame replay age despite a small, non-full packet queue.
        // Spend less time rasterizing already old state in precisely that
        // range; do not wait for the 8/12/16-frame emergency tiers. Caught-up
        // and 2-frame light-load behavior, hysteresis and spacing are unchanged.
        static constexpr std::uint8_t ByAge[EmergencyFrames] = {
            0, 0, 2, 4, 6, 7, 8, 9, 9, 10, 10, 11, 11, 11, 11, 11
        };
        const std::uint32_t floor = packets >= MediumPackets ? 9 :
                                    packets >= MildPackets ? 6 : 0;
        const std::uint32_t target = ByAge[lead] > floor ? ByAge[lead] : floor;
        if (target == 0) {
            // Once caught up, stop skipping immediately. Never spend frames
            // paying off hysteresis after a scene has become cheap.
            reset();
            return 0;
        }

        // Outside an actual emergency always allow some raster admissions.
        if (numerator_ == Denominator) --numerator_;
        // Keep the proven 1-in-6 light-load response. Halving it let a mild
        // sustained deficit settle one source frame further behind in the
        // controller stress model, without increasing delivered frames.
        if (numerator_ < 2) numerator_ = 2;
        if (numerator_ < floor) numerator_ = floor;
        if (numerator_ < target) {
            ++numerator_;
            lower_frames_ = 0;
        } else if (numerator_ > target) {
            // A brief improvement must not flip the rate back and forth at
            // the old 2/8/12-frame boundaries. Release one step after three
            // consecutive lower-pressure source frames.
            if (++lower_frames_ == ReleaseFrames) {
                --numerator_;
                lower_frames_ = 0;
            }
        } else {
            lower_frames_ = 0;
        }
        return numerator_;
    }

private:
    std::uint32_t numerator_ = 0;
    unsigned lower_frames_ = 0;
};

// Retained phase accumulator: distribute omissions instead of dropping one
// contiguous group at the beginning or end of every fixed-size frame block.
class SmoothCatchupPacer {
public:
    static constexpr std::uint32_t Denominator = AdaptiveCatchupBudget::Denominator;
    void reset() noexcept { phase_ = 0; }
    bool should_skip(std::uint32_t numerator) noexcept
    {
        if (numerator == 0) { reset(); return false; }
        if (numerator >= Denominator) return true;
        phase_ += numerator;
        if (phase_ < Denominator) return false;
        phase_ -= Denominator;
        return true;
    }
private:
    std::uint32_t phase_ = 0;
};

} // namespace nds4mister::h3d
