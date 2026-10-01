#include "replay/MatchedDisplayAdmission.h"
#include <algorithm>
#include <cstdint>
#include <iostream>
#include <stdexcept>

using nds4mister::replay::matched_display_can_draw;

void require(bool value, const char* message)
{
    if (!value) throw std::runtime_error(message);
}

// A deterministic producer/consumer load model, not a hardware FPS benchmark.
// Input continues at 60 Hz; replay has unavoidable state work, and selected
// pictures add raster/composition cost. The old fixed cadence must saturate.
struct Result { unsigned maximum_queue = 0, rendered = 0; };
Result simulate(bool admission, unsigned draw_us, unsigned state_us,
                bool bursts, bool full_rate = false, unsigned packet_limit = 4)
{
    constexpr std::uint64_t Period = 16667;
    std::uint64_t now = 0;
    unsigned skipped = 1;
    Result result;
    for (unsigned frame = 1; frame <= 6000; ++frame) {
        now = std::max(now, (frame - 1) * Period);
        const auto latest = static_cast<unsigned>(now / Period + 1);
        const auto queued = latest - frame;
        result.maximum_queue = std::max(result.maximum_queue, queued);
        if (queued >= 512) break;
        const bool draw = (full_rate || skipped != 0) &&
            (!admission || matched_display_can_draw(frame, latest, queued, packet_limit));
        const auto cost = bursts && (frame % 211 < 8) ? draw_us * 3 : draw_us;
        now += state_us + (draw ? cost : 0);
        if (draw) { skipped = 0; ++result.rendered; }
        else skipped = 1;
    }
    return result;
}

int main()
{
    require(matched_display_can_draw(10, 11, 4), "near-head picture rejected");
    require(!matched_display_can_draw(10, 12, 0), "old frame admitted");
    require(!matched_display_can_draw(10, 10, 5), "continuation backlog admitted");
    require(matched_display_can_draw(UINT32_MAX, 0, 1), "frame wrap rejected");
    require(!matched_display_can_draw(UINT32_MAX - 1, 0, 1), "old wrapped frame admitted");
    for (unsigned packets = 0; packets <= 32; ++packets) {
        require(matched_display_can_draw(10, 11, packets, 16) == (packets <= 16),
                "16-packet cutoff not enforced");
        require(!matched_display_can_draw(10, 12, packets, 16), "experiment admitted old frame");
        require(!matched_display_can_draw(11, 10, packets, 16), "experiment admitted future frame");
        require(matched_display_can_draw(UINT32_MAX, 0, packets, 16) == (packets <= 16),
                "experimental wrap bound changed");
    }
    const auto failed = simulate(false, 45000, 2000, false);
    require(failed.maximum_queue >= 512, "model does not expose MATCH1 failure");
    for (unsigned packet_limit : {4u, 16u}) {
      for (bool full_rate : {false, true}) {
        for (const auto cost : {12000u, 45000u, 70000u}) {
            for (const auto state_cost : {1000u, 5000u}) {
                for (const bool bursts : {false, true}) {
                    const auto result = simulate(true, cost, state_cost, bursts, full_rate, packet_limit);
                    require(result.maximum_queue < 16, "queue grew under drawable overload");
                    require(result.rendered > 200, "drawing did not recover during overload");
                    if (full_rate && cost == 12000 && state_cost == 1000 && !bursts)
                        require(result.rendered == 6000, "full-rate headroom left unused");
                    std::cout << "MATCHED_MODEL packet_limit=" << packet_limit << " full_rate=" << full_rate << " cost_us=" << cost
                              << " state_us=" << state_cost << " bursts=" << bursts
                              << " maximum_queue=" << result.maximum_queue
                              << " rendered=" << result.rendered << '\n';
                }
            }
        }
        const auto impossible = simulate(true, 45000, 20000, false, full_rate, packet_limit);
        require(impossible.maximum_queue >= 512,
                "model concealed state-only replay slower than input");
    }
    }
    std::cout << "MATCHED_ADMISSION_PASS scenarios=48 old_fixed_cadence_saturates=1"
                 " state_only_overload_detected=1\n";
}
