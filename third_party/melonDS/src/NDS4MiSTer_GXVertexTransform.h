#pragma once

#include <cstdint>

#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#endif

namespace melonDS
{

inline void NDS4MiSTerGXTransformVertex4Scalar(
    const std::int32_t* vertex,
    const std::int32_t* matrix,
    std::int32_t* output) noexcept
{
    for (unsigned column = 0; column < 4; ++column)
    {
        const std::int64_t sum =
            static_cast<std::int64_t>(vertex[0]) * matrix[column] +
            static_cast<std::int64_t>(vertex[1]) * matrix[4 + column] +
            static_cast<std::int64_t>(vertex[2]) * matrix[8 + column] +
            static_cast<std::int64_t>(vertex[3]) * matrix[12 + column];
        output[column] = static_cast<std::int32_t>(sum >> 12);
    }
}

inline void NDS4MiSTerGXTransformVertex4(
    const std::int32_t* vertex,
    const std::int32_t* matrix,
    std::int32_t* output) noexcept
{
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
    // The matrix is stored as four consecutive rows. Accumulate two result
    // columns per NEON register so each instruction advances two of the four
    // clip-space dot products while retaining the original signed 64-bit
    // intermediate precision and arithmetic >> 12 result.
    const int32x4_t row0 = vld1q_s32(matrix);
    int64x2_t low = vmull_n_s32(vget_low_s32(row0), vertex[0]);
    int64x2_t high = vmull_n_s32(vget_high_s32(row0), vertex[0]);

    const int32x4_t row1 = vld1q_s32(matrix + 4);
    low = vmlal_n_s32(low, vget_low_s32(row1), vertex[1]);
    high = vmlal_n_s32(high, vget_high_s32(row1), vertex[1]);

    const int32x4_t row2 = vld1q_s32(matrix + 8);
    low = vmlal_n_s32(low, vget_low_s32(row2), vertex[2]);
    high = vmlal_n_s32(high, vget_high_s32(row2), vertex[2]);

    const int32x4_t row3 = vld1q_s32(matrix + 12);
    low = vmlal_n_s32(low, vget_low_s32(row3), vertex[3]);
    high = vmlal_n_s32(high, vget_high_s32(row3), vertex[3]);

    const int32x2_t resultLow = vshrn_n_s64(low, 12);
    const int32x2_t resultHigh = vshrn_n_s64(high, 12);
    vst1q_s32(output, vcombine_s32(resultLow, resultHigh));
#else
    NDS4MiSTerGXTransformVertex4Scalar(vertex, matrix, output);
#endif
}

}
