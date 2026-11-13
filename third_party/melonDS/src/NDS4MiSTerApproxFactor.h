// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cassert>
#include <cstdint>
#if defined(__arm__) && defined(__ARM_NEON)
#include <arm_neon.h>
#endif
#ifdef NDS4MISTER_APPROX_FACTOR_TEST
#include <atomic>
#endif

namespace melonDS {
#ifdef NDS4MISTER_APPROX_FACTOR_TEST
inline std::atomic<uint64_t> ApproxFactorTestPixels{0};
#endif
#if defined(__arm__) && defined(__ARM_NEON)
// Deliberately approximate interior factors. Inputs match the bounded native-X
// batch contract; scalar tails and polygon edges must resynchronize exactly.
[[gnu::always_inline]] inline void NDS4MiSTerApproximateFactors4(
    uint32_t firstX, uint32_t width, uint32_t w0, uint32_t w1,
    uint32_t* output) noexcept
{
    assert(firstX + 3 <= width && width <= 256 && w0 <= 65535 && w1 <= 65535);
    alignas(16) static const uint32_t offsets[4] = {0, 1, 2, 3};
    const uint32x4_t x = vaddq_u32(vdupq_n_u32(firstX), vld1q_u32(offsets));
    const uint32x4_t left = vmulq_n_u32(x, w0);
    const uint32x4_t den = vmlaq_n_u32(
        left, vsubq_u32(vdupq_n_u32(width), x), w1);
    const uint32x4_t num = vshlq_n_u32(left, 8);
    const float32x4_t denominator = vcvtq_f32_u32(vmaxq_u32(den, vdupq_n_u32(1)));
    float32x4_t reciprocal = vrecpeq_f32(denominator);
    reciprocal = vmulq_f32(reciprocal, vrecpsq_f32(denominator, reciprocal));
    const uint32x4_t estimate = vminq_u32(vdupq_n_u32(256),
        vcvtq_u32_f32(vmulq_f32(vcvtq_f32_u32(num), reciprocal)));
    vst1q_u32(output, estimate);
}
#endif
}
