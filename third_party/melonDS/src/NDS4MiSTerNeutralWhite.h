// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#if defined(__arm__) && defined(__ARM_NEON)
#include <arm_neon.h>
#endif
#ifdef NDS4MISTER_NEUTRAL_WHITE_TEST
#include <atomic>
#include <cstdint>
#endif
namespace melonDS {
#ifdef NDS4MISTER_NEUTRAL_WHITE_TEST
inline std::atomic<uint64_t> NeutralWhiteConsideredPixels{0};
inline std::atomic<uint64_t> NeutralWhiteBypassedPixels{0};
#endif
#if defined(__arm__) && defined(__ARM_NEON)
// At vertex RGB=63 and polygon alpha=31, modulate preserves each texture
// channel and alpha. Clear unused RGB bits exactly like the general kernel.
[[gnu::always_inline]] inline uint32x4_t
NDS4MiSTerNeutralWhiteModulate4(uint32x4_t texels) noexcept
{
    return vandq_u32(texels, vdupq_n_u32(0xff3f3f3fu));
}
#endif
}
