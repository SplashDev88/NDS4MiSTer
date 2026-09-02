#include "NDS4MiSTer_GXClipMath.h"

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
        "PASS: GX clip wrap alias widens the exact -2^32 denominator");
    return 0;
}
