#include "NDS4MiSTer_FastDivide.h"
#include <cstdint>
#include <cstdio>
#include <limits>

int main()
{
    std::uint64_t normalizedCases = 0, factorCases = 0;
    for (std::uint32_t d = 512; d <= 1023; ++d)
    {
        const std::uint32_t reciprocal =
            melonDS::NDS4MiSTerPerspectiveCeilMagic[d - 512];
        for (std::uint32_t n = 0; n < 263168; ++n)
        {
            const auto result = (std::uint64_t(n) * reciprocal) >> 32;
            if (result != n / d) {
                std::printf("FAIL normalized n=%u d=%u result=%llu\n",
                    n, d, (unsigned long long)result);
                return 1;
            }
            ++normalizedCases;
        }
    }
    // Exercise both sides of each quotient transition for every normalized
    // divisor at every supported shift, and both extremes of discarded bits.
    for (std::uint32_t shift = 0; shift <= 14; ++shift)
        for (std::uint32_t normalized = 512; normalized <= 1023; ++normalized)
            for (std::uint32_t low : {0u, (1u << shift) - 1u})
            {
                const std::uint32_t d = (normalized << shift) + low;
                if (d > 0x00FFFF00u) continue;
                for (std::uint32_t q = 0; q <= 256; ++q)
                    for (int delta : {-1, 0, 1})
                    {
                        const auto n64 = std::int64_t(q) * d + delta;
                        if (n64 < 0 || n64 > std::numeric_limits<std::uint32_t>::max())
                            continue;
                        const auto n = static_cast<std::uint32_t>(n64);
                        const auto result = melonDS::NDS4MiSTerDivideFactorDeltaExact(n, d);
                        if (result != n / d) {
                            std::printf("FAIL factor n=%u d=%u result=%u expected=%u\n",
                                n, d, result, n/d);
                            return 2;
                        }
                        ++factorCases;
                    }
            }
    std::printf("FACTOR_CEIL_PASS normalized=%llu factor_boundaries=%llu\n",
        (unsigned long long)normalizedCases, (unsigned long long)factorCases);
}
