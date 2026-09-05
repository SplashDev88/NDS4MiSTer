#include "NDS4MiSTer_GXClipMath.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <limits>

namespace
{

volatile std::int32_t normalVinComp = -12;
volatile std::int32_t normalVinW = 4;
volatile std::int32_t normalVoutComp = 2;
volatile std::int32_t normalVoutW = 4;

volatile std::int32_t wrappedVinComp =
    std::numeric_limits<std::int32_t>::min();
volatile std::int32_t wrappedVinW = 0;
volatile std::int32_t wrappedVoutComp =
    std::numeric_limits<std::int32_t>::max();
volatile std::int32_t wrappedVoutW = 1;

volatile std::int64_t extremeNumerator = -4294967295LL;
volatile std::int64_t extremeDenominator = -4294967296LL;
volatile std::int32_t extremeVin =
    std::numeric_limits<std::int32_t>::min();
volatile std::int32_t extremeVout =
    std::numeric_limits<std::int32_t>::max();

}

extern "C" __attribute__((noinline)) std::uint64_t
nds_test_viewport_divide_pair(
    std::uint32_t numeratorX,
    std::uint32_t numeratorY,
    std::uint32_t denominator)
{
    const auto result = melonDS::NDS4MiSTerGXDivideViewportPair(
        numeratorX, numeratorY, denominator);
    return static_cast<std::uint64_t>(result.Y) << 32 | result.X;
}

int main()
{
    const auto normal =
        melonDS::NDS4MiSTerResolveGXClipFactors<-1>(
            normalVinComp, normalVinW, normalVoutComp, normalVoutW);
    if (normal.Widened || normal.Numerator != -8 ||
        normal.Denominator != -14)
        return 1;

    const auto wrapped = melonDS::NDS4MiSTerResolveGXClipFactors<-1>(
        wrappedVinComp, wrappedVinW, wrappedVoutComp, wrappedVoutW);
    if (!wrapped.Widened ||
        wrapped.Numerator != -2147483648LL ||
        wrapped.Denominator != -4294967296LL)
        return 2;

    if (melonDS::NDS4MiSTerGXClipInterpolateWide(0, 1, wrapped) != 0)
        return 3;

    const melonDS::NDS4MiSTerGXClipFactors extreme{
        extremeNumerator, extremeDenominator, true};
    if (melonDS::NDS4MiSTerGXClipInterpolateWide(
            extremeVin,
            extremeVout,
            extreme) != 2147483646)
        return 4;

    if (melonDS::NDS4MiSTerGXDivideZ(0, 1) != 0 ||
        melonDS::NDS4MiSTerGXDivideZ(1, 1) != 0x4000 ||
        melonDS::NDS4MiSTerGXDivideZ(-1, 1) != -0x4000 ||
        melonDS::NDS4MiSTerGXDivideZ(1, 3) != 0x1555 ||
        melonDS::NDS4MiSTerGXDivideZ(-1, 3) != -0x1555)
        return 7;

    constexpr std::uint32_t viewportDenominators[] = {
        1u, 2u, 3u, 511u, 512u, 513u, 1023u, 1024u,
        65534u, 65535u, 65536u, 0x00FFFFFEu,
    };
    for (const auto denominator : viewportDenominators)
    {
        const std::uint32_t maximumQuotient =
            std::min<std::uint32_t>(
                511u, std::numeric_limits<std::uint32_t>::max() /
                    denominator);
        for (std::uint32_t quotient = 0;
             quotient <= maximumQuotient; ++quotient)
        {
            const std::uint64_t base =
                static_cast<std::uint64_t>(quotient) * denominator;
            const std::uint32_t remainders[] = {
                0u,
                denominator > 1 ? 1u : 0u,
                denominator - 1u,
            };
            for (const auto remainderX : remainders)
            {
                if (base + remainderX >
                        std::numeric_limits<std::uint32_t>::max())
                    continue;
                for (const auto remainderY : remainders)
                {
                    if (base + remainderY >
                            std::numeric_limits<std::uint32_t>::max())
                        continue;
                    const auto numeratorX = static_cast<std::uint32_t>(
                        base + remainderX);
                    const auto numeratorY = static_cast<std::uint32_t>(
                        base + remainderY);
                    const auto actual =
                        melonDS::NDS4MiSTerGXDivideViewportPair(
                            numeratorX, numeratorY, denominator);
                    if (actual.X != numeratorX / denominator ||
                        actual.Y != numeratorY / denominator)
                        return 9;
                }
            }
        }
    }

    std::uint32_t viewportRandomState = 0x1b873593u;
    const auto viewportRandomWord = [&viewportRandomState]() {
        viewportRandomState ^= viewportRandomState << 13;
        viewportRandomState ^= viewportRandomState >> 17;
        viewportRandomState ^= viewportRandomState << 5;
        return viewportRandomState;
    };
    for (unsigned iteration = 0; iteration < 500000; ++iteration)
    {
        const std::uint32_t denominator =
            1u + viewportRandomWord() % 0x00FFFFFEu;
        const std::uint32_t maximumQuotient =
            std::min<std::uint32_t>(
                511u, std::numeric_limits<std::uint32_t>::max() /
                    denominator);
        const std::uint32_t quotientX =
            viewportRandomWord() % (maximumQuotient + 1u);
        const std::uint32_t quotientY =
            viewportRandomWord() % (maximumQuotient + 1u);
        const std::uint32_t maximumRemainderX =
            std::numeric_limits<std::uint32_t>::max() -
            quotientX * denominator;
        const std::uint32_t maximumRemainderY =
            std::numeric_limits<std::uint32_t>::max() -
            quotientY * denominator;
        const std::uint32_t remainderX = viewportRandomWord() %
            (std::min(denominator - 1u, maximumRemainderX) + 1u);
        const std::uint32_t remainderY = viewportRandomWord() %
            (std::min(denominator - 1u, maximumRemainderY) + 1u);
        const std::uint32_t numeratorX =
            quotientX * denominator + remainderX;
        const std::uint32_t numeratorY =
            quotientY * denominator + remainderY;
        const auto actual = melonDS::NDS4MiSTerGXDivideViewportPair(
            numeratorX, numeratorY, denominator);
        if (actual.X != numeratorX / denominator ||
            actual.Y != numeratorY / denominator)
            return 10;
    }

    // Cover every architectural native-W denominator, including every CLZ
    // normalization shift and every 512..1023 reciprocal-table bucket. Pair
    // the largest representable quotient with a midrange one, both at their
    // largest non-overflowing remainder.
    for (std::uint32_t denominator = 1u;
         denominator <= 0x00FFFFFEu; ++denominator)
    {
        const std::uint32_t maximumQuotient =
            std::min<std::uint32_t>(
                511u, std::numeric_limits<std::uint32_t>::max() /
                    denominator);
        const std::uint32_t quotientX = maximumQuotient;
        const std::uint32_t quotientY = maximumQuotient / 2u;
        const std::uint32_t remainderX = std::min(
            denominator - 1u,
            std::numeric_limits<std::uint32_t>::max() -
                quotientX * denominator);
        const std::uint32_t remainderY = std::min(
            denominator - 1u,
            std::numeric_limits<std::uint32_t>::max() -
                quotientY * denominator);
        const auto actual = melonDS::NDS4MiSTerGXDivideViewportPair(
            quotientX * denominator + remainderX,
            quotientY * denominator + remainderY,
            denominator);
        if (actual.X != quotientX || actual.Y != quotientY)
            return 12;
    }

    // The helper keeps stock u32 division semantics outside the native
    // post-clipping bound instead of trusting the optimized correction proof.
    const auto fallback = melonDS::NDS4MiSTerGXDivideViewportPair(
        0xFFFFFFFFu, 0xFEDCBA98u, 3u);
    if (fallback.X != 0xFFFFFFFFu / 3u ||
        fallback.Y != 0xFEDCBA98u / 3u)
        return 11;

    const auto positivePlane =
        melonDS::NDS4MiSTerResolveGXClipFactors<1>(
            -normalVinComp,
            normalVinW,
            normalVoutComp,
            normalVoutW);
    if (positivePlane.Widened || positivePlane.Numerator != -8 ||
        positivePlane.Denominator != -10)
        return 5;

#if !defined(__arm__)
    // The VFP estimate is never trusted for rounding. Exercise exact
    // correction across wide products and both denominator signs against the
    // language's signed-division oracle.
    std::uint32_t randomState = 0x6d2b79f5u;
    const auto randomWord = [&randomState]() {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return randomState;
    };
    for (unsigned iteration = 0; iteration < 500000; ++iteration)
    {
        const auto left = static_cast<std::int32_t>(randomWord());
        const auto right = static_cast<std::int32_t>(randomWord());
        auto denominator = static_cast<std::int32_t>(randomWord());
        if (denominator == 0) denominator = 1;
        const std::int64_t numerator =
            static_cast<std::int64_t>(left) * right;
        const std::int64_t expected = numerator / denominator;
        if (expected < std::numeric_limits<std::int32_t>::min() ||
            expected > std::numeric_limits<std::int32_t>::max())
            continue;
        const melonDS::NDS4MiSTerGXClipDivider divider(denominator);
        if (divider.divide(numerator) != expected)
            return 6;
    }

    for (unsigned iteration = 0; iteration < 500000; ++iteration)
    {
        const std::uint32_t w = (randomWord() & 0x00FFFFFFu) + 1;
        const std::uint32_t magnitude = randomWord() % (w + 1);
        const std::int32_t z = (randomWord() & 1)
            ? -static_cast<std::int32_t>(magnitude)
            : static_cast<std::int32_t>(magnitude);
        const auto expected = static_cast<std::int32_t>(
            (static_cast<std::int64_t>(z) * 0x4000) / w);
        if (melonDS::NDS4MiSTerGXDivideZ(z, w) != expected)
            return 8;
    }

#endif

    std::puts(
        "PASS: GX clip math and exact paired viewport division");
    return 0;
}
