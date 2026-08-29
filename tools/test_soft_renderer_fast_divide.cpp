#include "GPU3D_Soft.h"

#include <cstdint>
#include <cstdio>

extern "C" __attribute__((noinline)) std::uint32_t
nds_test_div_u32_exact(std::uint32_t numerator, std::uint32_t denominator)
{
    return melonDS::NDS4MiSTerDivideU32Exact(numerator, denominator);
}

int main()
{
    constexpr std::uint32_t edgeCases[][2] = {
        {0u, 1u},
        {1u, 1u},
        {0xFFFFFFFFu, 1u},
        {0xFFFFFFFFu, 2u},
        {0xFFFFFFFFu, 3u},
        {0xFFFFFFFFu, 0x7FFFFFFFu},
        {0xFFFFFFFFu, 0x80000000u},
        {0xFFFFFFFFu, 0xFFFFFFFEu},
        {0xFFFFFFFFu, 0xFFFFFFFFu},
        {0x80000000u, 3u},
        {0x7FFFFFFFu, 0x80000000u},
    };
    for (const auto& values : edgeCases)
    {
        if (nds_test_div_u32_exact(values[0], values[1]) !=
                values[0] / values[1])
            return 4;
    }

    std::uint32_t state = 0x9e3779b9u;
    const auto randomWord = [&state]() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    };

    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        const auto numerator = randomWord();
        auto denominator = randomWord();
        if (denominator == 0) denominator = 1;
        if (nds_test_div_u32_exact(numerator, denominator) !=
                numerator / denominator)
            return 1;
    }

    for (std::uint32_t divisor = 1;
         divisor <= melonDS::NDS4MiSTerRasterReciprocalLimit; ++divisor)
    {
        if (melonDS::NDS4MiSTerRasterReciprocal22[divisor] !=
                (1u << 22) / divisor ||
            melonDS::NDS4MiSTerRasterReciprocal18[divisor] !=
                (1u << 18) / divisor)
            return 2;
        if (divisor > 1)
        {
            const auto quotient = 0xFFFFFFFFu / divisor;
            const auto remainder = 0xFFFFFFFFu - quotient * divisor;
            const auto expected = quotient + (remainder == divisor - 1);
            if (melonDS::NDS4MiSTerRasterMagic[divisor] != expected)
                return 3;
        }
    }

    std::puts("PASS: exact VFP divide and raster reciprocal tables");
    return 0;
}
