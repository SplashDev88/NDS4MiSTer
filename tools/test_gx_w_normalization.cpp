#include "NDS4MiSTer_GXClipMath.h"

#include <cstdint>
#include <cstdio>
#include <limits>

namespace {

std::uint32_t legacy_w_size(std::uint32_t w)
{
    std::uint32_t size = 0;
    while (size < 32 && (w >> size) != 0)
        size += 4;
    return size;
}

bool check(std::uint32_t w)
{
    const auto expected = legacy_w_size(w);
    const auto actual = melonDS::NDS4MiSTerGXNormalizedWSize(w);
    if (actual == expected) return true;
    std::fprintf(
        stderr, "FAIL w=%08x expected=%u actual=%u\n",
        w, expected, actual);
    return false;
}

} // namespace

int main()
{
    // SubmitPolygon truncates W to 24 bits before normalization.  Exhaust the
    // entire production domain, then cover full-width boundary values too.
    for (std::uint32_t w = 0; w <= 0x00ffffffu; ++w)
    {
        if (!check(w)) return 1;
    }

    constexpr std::uint32_t edges[] = {
        0x01000000u, 0x0fffffffu, 0x10000000u, 0x7fffffffu,
        0x80000000u, 0xffffffffu,
    };
    for (const auto w : edges)
    {
        if (!check(w)) return 1;
    }

    std::uint32_t state = 0x6d2b79f5u;
    for (std::uint32_t index = 0; index < 1000000u; ++index)
    {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        if (!check(state)) return 1;
    }

    std::puts("PASS gx_w_normalization exact_cases=17777222");
    return 0;
}
