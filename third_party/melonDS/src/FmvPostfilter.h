// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <cstdlib>

namespace melonDS::ExperimentalFmv {
// Exact fixed-size filter used by the guarded private movie experiment.
// The lookup table points at index zero, with 64 valid preceding bytes.
inline void PostfilterPlane(std::uint8_t* plane, unsigned width, unsigned height,
                            unsigned thresholds, unsigned mode,
                            const std::uint8_t* clamp, bool luma) {
    const int low = thresholds & 255, high = thresholds >> 8;
    auto edge = [&](std::uint8_t* p, unsigned step) {
        const int a = p[0], b = p[step], c = p[2 * step], d = p[3 * step];
        if (std::abs(b - c) >= low || std::abs(a - b) >= high ||
            std::abs(d - c) >= high) return;
        const int average = (b + c + 1) / 2;
        const int numerator = a - d + 4;
        const int delta = numerator >= 0 ? numerator / 8 : -((-numerator + 7) / 8);
        if (luma) {
            const int before = p[-int(step)], after = p[4 * step];
            if (std::abs(before - b) < high) p[0] = (before + average + 1) / 2;
            if (std::abs(after - c) < high) p[3 * step] = (after + average + 1) / 2;
        }
        p[step] = clamp[average + delta];
        p[2 * step] = clamp[average - delta];
    };
    for (unsigned y = 0; y < height; ++y)
        for (unsigned x = 8; x < width; x += 8)
            edge(plane + y * 256 + x - 2, 1);
    if (mode != 1)
        for (unsigned y = 8; y < height; y += 8)
            for (unsigned x = 0; x < width; ++x)
                edge(plane + (y - 2) * 256 + x, 256);
}

inline void Postfilter(std::uint8_t* y, std::uint8_t* uv, unsigned thresholds,
                       unsigned mode, const std::uint8_t* clamp) {
    PostfilterPlane(y, 256, 192, thresholds, mode, clamp, true);
    PostfilterPlane(uv, 128, 96, thresholds, mode, clamp, false);
    PostfilterPlane(uv + 128, 128, 96, thresholds, mode, clamp, false);
}
}
