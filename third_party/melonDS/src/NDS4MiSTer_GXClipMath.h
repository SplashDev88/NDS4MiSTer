#pragma once

#include <cstdint>

namespace melonDS
{

// Accepted clip-space vertices satisfy -W <= Z <= W.  The native depth
// transform needs trunc((Z * 2^14) / W), but spelling that expression with a
// 64-bit numerator calls the very expensive ARM EABI long-division helper on
// Cortex-A9.  Generate the same fourteen fractional quotient bits with the
// restoring divider used by hardware: each step is only shift, compare and
// subtract, and the result remains bit-exact for both signs.
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

    std::uint32_t remainder = magnitude;
    std::uint32_t quotient = 0;
    for (unsigned bit = 0; bit < 14; ++bit)
    {
        remainder <<= 1;
        quotient <<= 1;
        if (remainder >= w)
        {
            remainder -= w;
            quotient |= 1;
        }
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
