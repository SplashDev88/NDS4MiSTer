#include <arm_neon.h>

#include <array>
#include <cstdint>
#include <iostream>

namespace {

using s16 = std::int16_t;
using s32 = std::int32_t;
using u32 = std::uint32_t;

int32x4_t interpolate_attribute(
    s32 base, u32 delta, bool ascending,
    uint32x4_t ascending_factors,
    uint32x4_t descending_factors)
{
    const uint32x4_t factors = ascending ?
        ascending_factors : descending_factors;
    const uint32x4_t progress = vshrq_n_u32(
        vmulq_u32(factors, vdupq_n_u32(delta)), 8);
    return vaddq_s32(
        vdupq_n_s32(base), vreinterpretq_s32_u32(progress));
}

bool check_case(
    const std::array<u32, 4>& factors,
    const std::array<s32, 5>& base,
    const std::array<u32, 5>& delta,
    u32 ascending_bits)
{
    const uint32x4_t ascending_factors = vld1q_u32(factors.data());
    const uint32x4_t descending_factors = vsubq_u32(
        vdupq_n_u32(256), ascending_factors);

    const int32x4_t red = interpolate_attribute(
        base[0], delta[0], ascending_bits & 1u,
        ascending_factors, descending_factors);
    const int32x4_t green = interpolate_attribute(
        base[1], delta[1], ascending_bits & 2u,
        ascending_factors, descending_factors);
    const int32x4_t blue = interpolate_attribute(
        base[2], delta[2], ascending_bits & 4u,
        ascending_factors, descending_factors);
    const int32x4_t tex_s = interpolate_attribute(
        base[3], delta[3], ascending_bits & 8u,
        ascending_factors, descending_factors);
    const int32x4_t tex_t = interpolate_attribute(
        base[4], delta[4], ascending_bits & 16u,
        ascending_factors, descending_factors);

    std::array<u32, 4> actual_color {};
    std::array<s16, 4> actual_s {};
    std::array<s16, 4> actual_t {};
    const uint32x4_t packed_color = vorrq_u32(
        vshrq_n_u32(vreinterpretq_u32_s32(red), 3),
        vorrq_u32(
            vshlq_n_u32(vshrq_n_u32(
                vreinterpretq_u32_s32(green), 3), 8),
            vshlq_n_u32(vshrq_n_u32(
                vreinterpretq_u32_s32(blue), 3), 16)));
    vst1q_u32(actual_color.data(), packed_color);
    vst1_s16(actual_s.data(), vmovn_s32(tex_s));
    vst1_s16(actual_t.data(), vmovn_s32(tex_t));

    for (u32 lane = 0; lane < 4; ++lane)
    {
        std::array<s32, 5> expected {};
        for (u32 attribute = 0; attribute < 5; ++attribute)
        {
            const bool ascending =
                (ascending_bits & (1u << attribute)) != 0;
            const u32 factor = ascending ?
                factors[lane] : 256u - factors[lane];
            expected[attribute] = base[attribute] +
                static_cast<s32>((delta[attribute] * factor) >> 8);
        }
        const u32 expected_color =
            (static_cast<u32>(expected[0]) >> 3) |
            ((static_cast<u32>(expected[1]) >> 3) << 8) |
            ((static_cast<u32>(expected[2]) >> 3) << 16);
        if (actual_color[lane] != expected_color ||
            actual_s[lane] != static_cast<s16>(expected[3]) ||
            actual_t[lane] != static_cast<s16>(expected[4]))
            return false;
    }
    return true;
}

} // namespace

int main()
{
    constexpr std::array<u32, 8> factor_seed = {
        0u, 1u, 31u, 127u, 128u, 225u, 255u, 256u};
    constexpr std::array<u32, 8> delta_seed = {
        0u, 1u, 31u, 255u, 256u, 1023u, 32767u, 65535u};
    std::uint64_t cases = 0;
    for (u32 direction = 0; direction < 32; ++direction)
    {
        for (u32 factor_index = 0; factor_index < factor_seed.size();
             ++factor_index)
        {
            for (u32 delta_index = 0; delta_index < delta_seed.size();
                 ++delta_index)
            {
                std::array<u32, 4> factors {};
                std::array<s32, 5> base {};
                std::array<u32, 5> delta {};
                for (u32 lane = 0; lane < 4; ++lane)
                    factors[lane] = factor_seed[
                        (factor_index + lane * 3u) % factor_seed.size()];
                for (u32 attribute = 0; attribute < 5; ++attribute)
                {
                    base[attribute] = attribute < 3 ?
                        static_cast<s32>(attribute * 89u + delta_index) :
                        -32768 + static_cast<s32>(
                            attribute * 137u + factor_index);
                    delta[attribute] = delta_seed[
                        (delta_index + attribute * 5u) % delta_seed.size()];
                }
                if (!check_case(factors, base, delta, direction))
                {
                    std::cerr << "FAIL direction=" << direction
                              << " factor_index=" << factor_index
                              << " delta_index=" << delta_index << '\n';
                    return 1;
                }
                ++cases;
            }
        }
    }
    std::cout << "H3D_SPAN_PERSPECTIVE_BATCH_NEON_ORACLE_PASS cases="
              << cases << '\n';
    return 0;
}
