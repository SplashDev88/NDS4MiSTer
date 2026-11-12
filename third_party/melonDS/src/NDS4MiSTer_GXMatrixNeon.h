// SPDX-License-Identifier: GPL-3.0-or-later
// Exact fixed-point kernels. The caller retains scalar behavior on overlap.
// Widening sums and narrowing reproduce the ARM scalar result without saturation.
#pragma once
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#include <cstdint>

namespace matrix_neon {
inline bool overlaps(const std::int32_t* m, const std::int32_t* s, unsigned words) {
    const auto a = reinterpret_cast<std::uintptr_t>(m);
    const auto b = reinterpret_cast<std::uintptr_t>(s);
    return a <= b ? b-a < 64 : a-b < words*4;
}

inline int32x4_t dot3(int32x4_t a, int32x4_t b, int32x4_t c,
                     const std::int32_t* s) {
    auto lo = vmull_n_s32(vget_low_s32(a), s[0]);
    auto hi = vmull_n_s32(vget_high_s32(a), s[0]);
    lo = vmlal_n_s32(lo, vget_low_s32(b), s[1]);
    hi = vmlal_n_s32(hi, vget_high_s32(b), s[1]);
    lo = vmlal_n_s32(lo, vget_low_s32(c), s[2]);
    hi = vmlal_n_s32(hi, vget_high_s32(c), s[2]);
    return vcombine_s32(vshrn_n_s64(lo, 12), vshrn_n_s64(hi, 12));
}

inline void mult4x4(std::int32_t* m, const std::int32_t* s) {
    const auto a = vld1q_s32(m), b = vld1q_s32(m+4);
    const auto c = vld1q_s32(m+8), d = vld1q_s32(m+12);
    for (unsigned row=0; row<4; ++row) {
        const auto p = s + 4*row;
        auto lo = vmull_n_s32(vget_low_s32(a), p[0]);
        auto hi = vmull_n_s32(vget_high_s32(a), p[0]);
        lo = vmlal_n_s32(lo, vget_low_s32(b), p[1]);
        hi = vmlal_n_s32(hi, vget_high_s32(b), p[1]);
        lo = vmlal_n_s32(lo, vget_low_s32(c), p[2]);
        hi = vmlal_n_s32(hi, vget_high_s32(c), p[2]);
        lo = vmlal_n_s32(lo, vget_low_s32(d), p[3]);
        hi = vmlal_n_s32(hi, vget_high_s32(d), p[3]);
        vst1q_s32(m+4*row, vcombine_s32(vshrn_n_s64(lo,12), vshrn_n_s64(hi,12)));
    }
}

inline void mult4x3(std::int32_t* m, const std::int32_t* s) {
    const auto a = vld1q_s32(m), b = vld1q_s32(m+4);
    const auto c = vld1q_s32(m+8), d = vld1q_s32(m+12);
    for (unsigned row=0; row<3; ++row)
        vst1q_s32(m+4*row, dot3(a,b,c,s+3*row));
    vst1q_s32(m+12, vaddq_s32(d, dot3(a,b,c,s+9)));
}

inline void mult3x3(std::int32_t* m, const std::int32_t* s) {
    const auto a = vld1q_s32(m), b = vld1q_s32(m+4), c = vld1q_s32(m+8);
    for (unsigned row=0; row<3; ++row)
        vst1q_s32(m+4*row, dot3(a,b,c,s+3*row));
}

inline void scale(std::int32_t* m, const std::int32_t* s) {
    for (unsigned row=0; row<3; ++row) {
        const auto a = vld1q_s32(m+4*row);
        const auto lo = vmull_n_s32(vget_low_s32(a), s[row]);
        const auto hi = vmull_n_s32(vget_high_s32(a), s[row]);
        vst1q_s32(m+4*row, vcombine_s32(vshrn_n_s64(lo,12),vshrn_n_s64(hi,12)));
    }
}

inline void translate(std::int32_t* m, const std::int32_t* s) {
    const auto a=vld1q_s32(m), b=vld1q_s32(m+4), c=vld1q_s32(m+8);
    vst1q_s32(m+12, vaddq_s32(vld1q_s32(m+12),dot3(a,b,c,s)));
}
}

#endif
