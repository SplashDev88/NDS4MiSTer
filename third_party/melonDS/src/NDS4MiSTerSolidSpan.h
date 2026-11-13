// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstddef>
#include <cstdint>
#if defined(__arm__) && defined(__ARM_NEON)
#include <arm_neon.h>
#endif
#ifdef NDS4MISTER_SOLID_SPAN_TEST
#include <atomic>
#endif

namespace melonDS {
#ifdef NDS4MISTER_SOLID_SPAN_TEST
inline std::atomic<uint64_t> SolidSpanTestPixels{0};
inline std::atomic<uint64_t> SolidSpanTestVectorStores{0};
inline std::atomic<uint64_t> SolidSpanTestVectorRejects{0};
#endif

// Caller proves opaque, constant color/depth, front-facing less-than depth,
// no AA backing layer, and exact clipped edge/interior attribute bits.
// Equal depth still admits an opaque back-facing destination.
[[gnu::noinline]] inline void NDS4MiSTerDrawSolidSpan(
    uint32_t* colors, uint32_t* depths, uint32_t* attrs, size_t count,
    int32_t z, uint32_t color, uint32_t attr) noexcept
{
#ifdef NDS4MISTER_SOLID_SPAN_TEST
    SolidSpanTestPixels.fetch_add(count, std::memory_order_relaxed);
#endif
    while (count)
    {
        const size_t lanes = count >= 4 ? 4 : count;
#if defined(__arm__) && defined(__ARM_NEON)
        if (lanes == 4)
        {
            const int32x4_t previous = vreinterpretq_s32_u32(vld1q_u32(depths));
            const int32x4_t incoming = vdupq_n_s32(z);
            const uint32x4_t pass = vcgtq_s32(previous, incoming);
            uint32x2_t all = vand_u32(vget_low_u32(pass), vget_high_u32(pass));
            all = vand_u32(all, vrev64_u32(all));
            if (vget_lane_u32(all, 0) == 0xffffffffu)
            {
                vst1q_u32(colors, vdupq_n_u32(color));
                vst1q_u32(depths, vreinterpretq_u32_s32(incoming));
                vst1q_u32(attrs, vdupq_n_u32(attr));
#ifdef NDS4MISTER_SOLID_SPAN_TEST
                ++SolidSpanTestVectorStores;
#endif
                colors += 4; depths += 4; attrs += 4; count -= 4;
                continue;
            }
            // Only strictly nearer destinations can be rejected without
            // loading attributes: equal-depth back faces remain eligible.
            const uint32x4_t fail = vcltq_s32(previous, incoming);
            all = vand_u32(vget_low_u32(fail), vget_high_u32(fail));
            all = vand_u32(all, vrev64_u32(all));
            if (vget_lane_u32(all, 0) == 0xffffffffu)
            {
#ifdef NDS4MISTER_SOLID_SPAN_TEST
                ++SolidSpanTestVectorRejects;
#endif
                colors += 4; depths += 4; attrs += 4; count -= 4;
                continue;
            }
        }
#endif
        for (size_t lane = 0; lane < lanes; ++lane)
        {
            const int32_t previous = static_cast<int32_t>(depths[lane]);
            if (z < previous ||
                (z == previous && (attrs[lane] & 0x00400010u) == 0x10u))
            {
                colors[lane] = color;
                depths[lane] = static_cast<uint32_t>(z);
                attrs[lane] = attr;
            }
        }
        colors += lanes; depths += lanes; attrs += lanes; count -= lanes;
    }
}
}
