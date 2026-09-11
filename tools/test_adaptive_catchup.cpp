#include "replay/AdaptiveCatchup.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iostream>

using nds4mister::h3d::AdaptiveCatchupBudget;
using nds4mister::h3d::SmoothCatchupPacer;

static void check(bool value, const char* message)
{
    if (!value) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}

static unsigned original(unsigned lead, std::size_t packets)
{
    if (lead >= 16 || packets >= 256) return 12;
    if (lead >= 12 || packets >= 128) return 9;
    if (lead >= 8 || packets >= 64) return 6;
    return lead >= 2 ? 2 : 0;
}

struct Result { double mean_age; unsigned max_lead, renders, changes, variation, max_gap; };

// Deliberately a controller stress model, NOT an emulator/FPS benchmark. Input
// arrives every 1 time unit. Authoritative replay costs .08; optional raster
// costs vary with the specified workload. No claim about real core overlap,
// cancellation, input latency, or gameplay speed can follow from these numbers.
static Result model(bool adaptive, unsigned workload)
{
    AdaptiveCatchupBudget budget;
    SmoothCatchupPacer pacer;
    double clock = 0, age = 0;
    unsigned max_lead = 0, renders = 0, changes = 0, prev_rate = 0;
    unsigned variation = 0;
    unsigned gap = 0, max_gap = 0;
    constexpr unsigned Frames = 3600;
    for (unsigned frame = 0; frame < Frames; ++frame) {
        clock = std::max(clock, double(frame));
        if (workload == 3 && frame == 900) clock += 200; // producer burst
        const unsigned lead = unsigned(clock) - frame;
        // Two packets/source frame, used only to exercise the safety floors.
        const auto rate = adaptive ? budget.update(lead, 2 * lead) : original(lead, 2 * lead);
        changes += rate != prev_rate;
        variation += unsigned(std::abs(int(rate) - int(prev_rate)));
        prev_rate = rate;
        max_lead = std::max(lead, max_lead);
        double raster = .75;
        if (workload == 1) raster = 1.10; // mild sustained deficit
        if (workload == 2) raster = (frame / 180) % 2 ? 2.2 : .65;
        if (workload == 3) raster = 1.45;
        if (workload == 4) raster = (frame / 7) % 2 ? 1.5 : .75;
        clock += .08;
        ++gap;
        if (!pacer.should_skip(rate)) {
            clock += raster;
            age += clock - frame;
            ++renders;
            max_gap = std::max(gap, max_gap);
            gap = 0;
        }
        if (workload == 3 && frame > 1200)
            check(lead < 16, "failed to drain injected 200-frame burst");
        if (workload != 3)
            check(lead < 16, "ordinary load reached emergency frame age");
    }
    return {age / renders, max_lead, renders, changes, variation, max_gap};
}

int main()
{
    static constexpr unsigned targets[] = {0,0,2,4,6,7,8,9,9,10,10,11,11,11,11,11,12};
    for (unsigned lead = 0; lead <= 16; ++lead) {
        AdaptiveCatchupBudget b;
        for (unsigned i = 0; i < 60; ++i) b.update(lead, 0);
        SmoothCatchupPacer p;
        unsigned skipped = 0;
        for (unsigned i = 0; i < 120; ++i) {
            const auto rate = b.update(lead, 0);
            check(rate == targets[lead], "steady age target incorrect");
            skipped += p.should_skip(rate);
        }
        check(skipped == 10 * targets[lead], "evenly spaced skip fraction incorrect");
    }
    for (unsigned lead = 0; lead < 40; ++lead) {
        for (unsigned packets = 0; packets <= 512; ++packets) {
            AdaptiveCatchupBudget b;
            for (unsigned previous : {0u, 8u, 16u, 0xffffffffu}) {
                b.update(previous, 0);
                const auto rate = b.update(lead, packets);
                check(rate <= 12, "out of range rate");
                if (lead >= 16 || packets >= 256)
                    check(rate == 12, "emergency response was delayed");
                else if (packets >= 128) check(rate >= 9, "medium packet safety floor lost");
                else if (packets >= 64) check(rate >= 6, "mild packet safety floor lost");
                else if (lead < 2) check(rate == 0, "skips persisted after catching up");
                b.reset();
                check(b.update(0, 0) == 0, "session reset failed");
            }
        }
    }
    AdaptiveCatchupBudget b;
    check(b.update(2, 0) == 2, "light-load rate should remain one in six");
    check(b.update(8, 0) == 3, "normal increase should be one step");
    for (unsigned i = 0; i < 20; ++i) b.update(7, 0);
    check(b.update(6, 0) == 9 && b.update(6, 0) == 9 && b.update(6, 0) == 8,
          "three-frame release hysteresis incorrect");
    b.reset();
    for (unsigned i = 0; i < 20; ++i) b.update(7, 0);
    for (unsigned i = 0; i < 120; ++i)
        check(b.update(i % 2 ? 7 : 6, 0) == 9, "rate oscillates at threshold");
    check(b.update(16, 0) == 12 && b.update(15, 0) < 12,
          "all-render suppression persisted outside emergency");
    check(b.update(0, 0) == 0 && b.update(2, 0) == 2,
          "recovery did not clear history");

    // Exercise rapidly changing observations against an exact integral oracle
    // for the retained phase accumulator (including zero-rate phase resets).
    SmoothCatchupPacer pacer;
    unsigned phase = 0, state = 0x51ace;
    for (unsigned i = 0; i < 1000000; ++i) {
        state = state * 1664525u + 1013904223u;
        const unsigned rate = (state >> 16) % 13;
        bool skip = false;
        if (!rate) phase = 0;
        else if (rate == 12) skip = true;
        else { phase += rate; skip = phase >= 12; phase %= 12; }
        check(pacer.should_skip(rate) == skip, "phase accumulator drift");
    }
    std::cout << "PASS: age/rate table, 82080 safety/reset transitions, hysteresis, 1000000 phase checks\n";
    std::cout << "MODEL ONLY: scenario,policy,mean_render_age_source_frames,max_replay_lead,renders,rate_changes,rate_total_variation,max_source_frame_gap\n";
    for (unsigned scenario = 0; scenario < 5; ++scenario) {
        for (bool adaptive : {false, true}) {
            const auto r = model(adaptive, scenario);
            std::cout << scenario << ',' << (adaptive ? "adaptive" : "baseline") << ','
                      << r.mean_age << ',' << r.max_lead << ',' << r.renders << ','
                      << r.changes << ',' << r.variation << ',' << r.max_gap << '\n';
        }
    }
}
