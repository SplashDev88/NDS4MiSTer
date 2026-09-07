#pragma once

#include "NDS4MiSTer_FastDivide.h"

#include <cstdint>

namespace melonDS
{

struct NDS4MiSTerGXViewportQuotients
{
    std::uint32_t X;
    std::uint32_t Y;
};

// Polygon W normalization rounds the widest vertex W up to a four-bit
// boundary.  The original loop advanced one nibble at a time and compiled to
// a variable shift plus several conditionals per step on Cortex-A9.  CLZ gives
// the same bit width directly; the zero case is kept separate because CLZ(0)
// is undefined.
inline std::uint32_t NDS4MiSTerGXNormalizedWSize(
    std::uint32_t w) noexcept
{
    if (w == 0) return 0;
    const auto bitWidth = 32u - static_cast<std::uint32_t>(__builtin_clz(w));
    return (bitWidth + 3u) & ~3u;
}

// A native viewport transform divides two screen-coordinate numerators by the
// same positive W denominator. Post-clipping coordinates guarantee both
// quotients are in 0..511. Normalize the denominator once, reuse one cached
// magic reciprocal for X and Y, then correct the one possible overestimate
// against each original numerator. This is exact integer division, not a
// floating-point approximation.
inline NDS4MiSTerGXViewportQuotients
NDS4MiSTerGXDivideViewportPair(
    std::uint32_t numeratorX,
    std::uint32_t numeratorY,
    std::uint32_t denominator) noexcept
{
    constexpr std::uint32_t MaximumDenominator = 0x00FFFFFEu;
    constexpr std::uint32_t QuotientRange = 512u;
    const std::uint64_t numeratorLimit =
        static_cast<std::uint64_t>(denominator) * QuotientRange;

    // Preserve the general u32 operation if malformed state violates the
    // post-clipping/native-W contract. Normal rendering never takes this path.
    if (__builtin_expect(
            denominator == 0 || denominator > MaximumDenominator ||
            numeratorX >= numeratorLimit || numeratorY >= numeratorLimit,
            false))
    {
        if (denominator == 0) return {0, 0};
        return {numeratorX / denominator, numeratorY / denominator};
    }

    if (denominator <= NDS4MiSTerRasterReciprocalLimit)
    {
        if (denominator == 1) return {numeratorX, numeratorY};
        const std::uint32_t reciprocal =
            NDS4MiSTerRasterMagic[denominator];
        return {
            NDS4MiSTerDividePreparedNonUnitU32(
                numeratorX, denominator, reciprocal),
            NDS4MiSTerDividePreparedNonUnitU32(
                numeratorY, denominator, reciprocal)};
    }

    const std::uint32_t highestBit = 31u - static_cast<std::uint32_t>(
        __builtin_clz(denominator));
    const std::uint32_t shift = highestBit - 9u;
    const std::uint32_t normalizedDenominator = denominator >> shift;
    const std::uint32_t reciprocal = NDS4MiSTerPerspectiveMagic[
        normalizedDenominator - NDS4MiSTerPerspectiveMagicBase];
    std::uint32_t quotientX = NDS4MiSTerDividePreparedNonUnitU32(
        numeratorX >> shift, normalizedDenominator, reciprocal);
    std::uint32_t quotientY = NDS4MiSTerDividePreparedNonUnitU32(
        numeratorY >> shift, normalizedDenominator, reciprocal);

    // With quotient < 512 and a ten-bit normalized denominator, the estimate
    // is exact or one high. Use widened products so the correction also stays
    // exact at the upper 24-bit W boundary.
    quotientX -= static_cast<std::uint64_t>(quotientX) * denominator >
        numeratorX;
    quotientY -= static_cast<std::uint64_t>(quotientY) * denominator >
        numeratorY;
    return {quotientX, quotientY};
}

// Accepted clip-space vertices satisfy -W <= Z <= W.  The native depth
// transform needs trunc((Z * 2^14) / W), but spelling that expression with a
// 64-bit numerator calls the very expensive ARM EABI long-division helper on
// Cortex-A9.  Every 24-bit input is represented exactly by binary32, and the
// scaled quotient is bounded below 2^14, so the rounded estimate is far closer
// than one integer to the exact result.  Correct that estimate against the
// original integer numerator so the result remains bit-exact for both signs
// without fourteen restoring-divider steps.
constexpr std::int32_t NDS4MiSTerGXDivideZ(
    std::int32_t z, std::uint32_t w) noexcept
{
    if (w == 0) return 0;

    const bool negative = z < 0;
    const std::uint32_t magnitude = negative
        ? static_cast<std::uint32_t>(-static_cast<std::int64_t>(z))
        : static_cast<std::uint32_t>(z);

    // The exact zero result needs none of the fourteen restoring steps.
    if (magnitude == 0) return 0;

    // Preserve the general melonDS behavior for malformed state outside the
    // post-clipping invariant. Normal rendering never takes this fallback.
    if (magnitude > w)
        return static_cast<std::int32_t>(
            (static_cast<std::int64_t>(z) * 0x4000) / w);

    if (magnitude == w) return negative ? -0x4000 : 0x4000;

    const std::uint64_t numerator =
        static_cast<std::uint64_t>(magnitude) << 14;
    std::uint32_t quotient = static_cast<std::uint32_t>(
        (static_cast<float>(magnitude) * 16384.0f) /
        static_cast<float>(w));
    const std::uint64_t product =
        static_cast<std::uint64_t>(quotient) * w;
    if (product > numerator)
    {
        --quotient;
    }
    else if (numerator - product >= w)
    {
        ++quotient;
    }

    return negative
        ? -static_cast<std::int32_t>(quotient)
        : static_cast<std::int32_t>(quotient);
}

struct NDS4MiSTerGXClipFactors
{
    std::int64_t Numerator;
    std::int64_t Denominator;
    bool Widened;
};

// A clipped edge uses one variable denominator for up to eight attributes.
// Cortex-A9 has no integer divide instruction, so calculate its reciprocal
// once with VFP and turn each quotient into multiply-plus-exact-correction.
// The correction makes the result identical to signed integer division; the
// floating-point value is only an initial quotient estimate.
class NDS4MiSTerGXClipDivider
{
public:
    explicit NDS4MiSTerGXClipDivider(std::int32_t denominator) noexcept
        : Denominator(denominator),
          Magnitude(denominator < 0
              ? static_cast<std::uint32_t>(
                    -static_cast<std::int64_t>(denominator))
              : static_cast<std::uint32_t>(denominator)),
          Reciprocal(1.0 / static_cast<double>(Magnitude))
    {
    }

    std::int32_t divide(std::int64_t numerator) const noexcept
    {
        const bool negative = (numerator < 0) != (Denominator < 0);
        const std::uint64_t magnitude = numerator < 0
            ? static_cast<std::uint64_t>(-(numerator + 1)) + 1
            : static_cast<std::uint64_t>(numerator);
        const double magnitudeAsDouble =
            static_cast<double>(static_cast<std::uint32_t>(magnitude >> 32)) *
                4294967296.0 +
            static_cast<double>(static_cast<std::uint32_t>(magnitude));
        const double estimate = magnitudeAsDouble * Reciprocal;

        // Valid clipped interpolation is bounded by its two s32 endpoints.
        // Retain the original general operation for malformed state outside
        // that architectural range.
        if (estimate > 2147483648.0)
            return static_cast<std::int32_t>(numerator / Denominator);

        std::uint32_t quotient = static_cast<std::uint32_t>(estimate);
        std::uint64_t product =
            static_cast<std::uint64_t>(quotient) * Magnitude;
        while (product > magnitude)
        {
            --quotient;
            product -= Magnitude;
        }
        while (magnitude - product >= Magnitude)
        {
            ++quotient;
            product += Magnitude;
        }
        const std::int64_t signedQuotient = negative
            ? -static_cast<std::int64_t>(quotient)
            : static_cast<std::int64_t>(quotient);
        return static_cast<std::int32_t>(signedQuotient);
    }

private:
    std::int32_t Denominator;
    std::uint32_t Magnitude;
    double Reciprocal;
};

constexpr std::int32_t NDS4MiSTerGXClipInterpolateWide(
    std::int32_t vin,
    std::int32_t vout,
    const NDS4MiSTerGXClipFactors& factors)
{
    // A nonzero difference between equal wrapped int32 distances is exactly
    // +/-2^32. Multiply magnitudes in uint64 and divide by that power of two
    // with a shift, avoiding signed overflow and unavailable ARM __int128.
    const auto magnitude = [](std::int64_t value) {
        return value < 0
            ? static_cast<std::uint64_t>(-(value + 1)) + 1
            : static_cast<std::uint64_t>(value);
    };
    const std::int64_t delta =
        static_cast<std::int64_t>(vout) -
        static_cast<std::int64_t>(vin);
    const std::uint64_t product =
        magnitude(delta) * magnitude(factors.Numerator);
    const std::uint64_t scaledMagnitude = product >> 32;
    const bool scaledNegative =
        ((delta < 0) != (factors.Numerator < 0)) !=
        (factors.Denominator < 0);
    const std::int64_t scaled = scaledNegative
        ? -static_cast<std::int64_t>(scaledMagnitude)
        : static_cast<std::int64_t>(scaledMagnitude);
    return static_cast<std::int32_t>(
        static_cast<std::int64_t>(vin) + scaled);
}

// Preserve melonDS's legacy 32-bit plane-distance arithmetic for every
// ordinary edge. If two opposite-side distances alias after 32-bit wrapping,
// recover their true 64-bit values instead of passing a zero denominator to
// the ARM EABI division helper.
template<int plane>
constexpr NDS4MiSTerGXClipFactors NDS4MiSTerResolveGXClipFactors(
    std::int32_t vinComp,
    std::int32_t vinW,
    std::int32_t voutComp,
    std::int32_t voutW)
{
    static_assert(plane == -1 || plane == 1);

    const auto wrappedDistance = [](std::int32_t comp, std::int32_t w) {
        const std::uint32_t wBits = static_cast<std::uint32_t>(w);
        const std::uint32_t compBits = static_cast<std::uint32_t>(comp);
        return plane == 1 ? wBits - compBits : wBits + compBits;
    };

    const std::uint32_t vinWrapped = wrappedDistance(vinComp, vinW);
    const std::uint32_t voutWrapped = wrappedDistance(voutComp, voutW);
    const auto legacyNumerator = static_cast<std::int32_t>(vinWrapped);
    const auto legacyDenominator =
        static_cast<std::int32_t>(vinWrapped - voutWrapped);

    if (legacyDenominator != 0)
    {
        return {
            static_cast<std::int64_t>(legacyNumerator),
            static_cast<std::int64_t>(legacyDenominator),
            false};
    }

    const std::int64_t vinWide =
        static_cast<std::int64_t>(vinW) -
        static_cast<std::int64_t>(plane) *
            static_cast<std::int64_t>(vinComp);
    const std::int64_t voutWide =
        static_cast<std::int64_t>(voutW) -
        static_cast<std::int64_t>(plane) *
            static_cast<std::int64_t>(voutComp);
    return {vinWide, vinWide - voutWide, true};
}

}
