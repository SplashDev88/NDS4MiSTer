#include "NDS4MiSTer_GXClipMath.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <limits>

namespace
{

constexpr std::int32_t referenceDivideZ(
    std::int32_t z, std::uint32_t w) noexcept
{
    if (w == 0) return 0;
    return static_cast<std::int32_t>(
        (static_cast<std::int64_t>(z) * 0x4000) / w);
}

bool check(std::int32_t z, std::uint32_t w) noexcept
{
    const auto expected = referenceDivideZ(z, w);
    const auto actual = melonDS::NDS4MiSTerGXDivideZ(z, w);
    if (actual == expected) return true;

    std::fprintf(
        stderr,
        "FAIL: z=%d w=%u expected=%d actual=%d\n",
        z,
        w,
        expected,
        actual);
    return false;
}

} // namespace

int main()
{
    constexpr std::array<std::uint32_t, 20> directedW = {
        0u, 1u, 2u, 3u, 4u, 7u, 8u, 15u, 16u, 31u, 255u,
        256u, 511u, 512u, 1023u, 65535u, 65536u, 0x7FFFFFu,
        0xFFFFFEu, 0xFFFFFFu};
    constexpr std::array<std::int32_t, 15> directedZ = {
        std::numeric_limits<std::int32_t>::min(), -0x01000000, -0x00FFFFFF,
        -0x4000, -2, -1, 0, 1, 2, 0x3FFF, 0x4000, 0x00FFFFFE,
        0x00FFFFFF, 0x01000000, std::numeric_limits<std::int32_t>::max()};

    for (const auto w : directedW)
        for (const auto z : directedZ)
            if (!check(z, w)) return 1;

    // Cover every architectural 24-bit W.  Values around exact-quotient
    // boundaries are the cases where a rounded binary32 estimate can land on
    // the adjacent integer and therefore exercise either correction branch.
    constexpr std::array<std::uint32_t, 8> quotientBoundaries = {
        0u, 1u, 2u, 3u, 8191u, 8192u, 16383u, 16384u};
    for (std::uint32_t w = 1; w <= 0x00FFFFFFu; ++w)
    {
        for (const auto quotient : quotientBoundaries)
        {
            const std::uint64_t product =
                static_cast<std::uint64_t>(quotient) * w;
            const std::uint32_t center = static_cast<std::uint32_t>(
                product >> 14);
            const std::uint32_t magnitudes[] = {
                center > 0 ? center - 1 : 0,
                center,
                center < w ? center + 1 : w};
            for (const auto magnitude : magnitudes)
            {
                if (!check(static_cast<std::int32_t>(magnitude), w) ||
                    !check(-static_cast<std::int32_t>(magnitude), w))
                    return 2;
            }
        }
    }

    // Exercise arbitrary valid and malformed inputs independently of the
    // structured boundary sweep, including the exact signed-division fallback.
    std::uint32_t state = 0x91E10DA5u;
    const auto randomWord = [&state]() noexcept {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    };
    for (unsigned iteration = 0; iteration < 2000000; ++iteration)
    {
        const std::uint32_t w = randomWord() & 0x00FFFFFFu;
        const std::int32_t z = static_cast<std::int32_t>(randomWord());
        if (!check(z, w)) return 3;

        if (w != 0)
        {
            const std::uint32_t magnitude = randomWord() % (w + 1u);
            const std::int32_t validZ = (randomWord() & 1u)
                ? -static_cast<std::int32_t>(magnitude)
                : static_cast<std::int32_t>(magnitude);
            if (!check(validZ, w)) return 4;
        }
    }

    std::puts("PASS: exact GX depth division");
    return 0;
}
