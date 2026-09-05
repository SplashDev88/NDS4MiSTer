/*
    Copyright 2016-2026 melonDS team

    This file is part of melonDS.

    melonDS is free software: you can redistribute it and/or modify it under
    the terms of the GNU General Public License as published by the Free
    Software Foundation, either version 3 of the License, or (at your option)
    any later version.
*/

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace melonDS
{

// Native raster spans never exceed 512 steps. Cortex-A9 has no integer divide
// instruction, so resolve the fixed-numerator edge reciprocals at compile time
// instead of calling __aeabi_idiv/__aeabi_uidiv for every polygon edge.
constexpr std::size_t NDS4MiSTerRasterReciprocalLimit = 512;

constexpr auto NDS4MiSTerMakeRasterReciprocalTable(std::uint32_t numerator)
{
    std::array<std::uint32_t, NDS4MiSTerRasterReciprocalLimit + 1> table {};
    for (std::size_t divisor = 1;
         divisor <= NDS4MiSTerRasterReciprocalLimit; ++divisor)
        table[divisor] = numerator / static_cast<std::uint32_t>(divisor);
    return table;
}

constexpr auto NDS4MiSTerMakeRasterMagicTable()
{
    std::array<std::uint32_t, NDS4MiSTerRasterReciprocalLimit + 1> table {};
    for (std::size_t divisor = 2;
         divisor <= NDS4MiSTerRasterReciprocalLimit; ++divisor)
    {
        const auto d = static_cast<std::uint32_t>(divisor);
        const std::uint32_t quotient = 0xFFFFFFFFu / d;
        const std::uint32_t remainder = 0xFFFFFFFFu - quotient * d;
        table[divisor] = quotient + (remainder == d - 1);
    }
    return table;
}

constexpr std::size_t NDS4MiSTerPerspectiveMagicBase = 512;
constexpr std::size_t NDS4MiSTerPerspectiveMagicLimit = 1023;

constexpr auto NDS4MiSTerMakePerspectiveMagicTable()
{
    std::array<std::uint32_t,
        NDS4MiSTerPerspectiveMagicLimit -
        NDS4MiSTerPerspectiveMagicBase + 1> table {};
    for (std::size_t divisor = NDS4MiSTerPerspectiveMagicBase;
         divisor <= NDS4MiSTerPerspectiveMagicLimit; ++divisor)
    {
        const auto d = static_cast<std::uint32_t>(divisor);
        const std::uint32_t quotient = 0xFFFFFFFFu / d;
        const std::uint32_t remainder = 0xFFFFFFFFu - quotient * d;
        table[divisor - NDS4MiSTerPerspectiveMagicBase] =
            quotient + (remainder == d - 1);
    }
    return table;
}

inline constexpr auto NDS4MiSTerRasterReciprocal22 =
    NDS4MiSTerMakeRasterReciprocalTable(1u << 22);
inline constexpr auto NDS4MiSTerRasterReciprocal18 =
    NDS4MiSTerMakeRasterReciprocalTable(1u << 18);
inline constexpr auto NDS4MiSTerRasterMagic =
    NDS4MiSTerMakeRasterMagicTable();
inline constexpr auto NDS4MiSTerPerspectiveMagic =
    NDS4MiSTerMakePerspectiveMagicTable();

inline std::uint32_t NDS4MiSTerDividePreparedU32(
    std::uint32_t numerator,
    std::uint32_t denominator,
    std::uint32_t reciprocal) noexcept
{
    if (denominator == 1) return numerator;
    std::uint32_t quotient = static_cast<std::uint32_t>(
        (static_cast<std::uint64_t>(numerator) * reciprocal) >> 32);
    const std::uint32_t remainder = numerator - quotient * denominator;
    quotient += remainder >= denominator;
    return quotient;
}

inline std::uint32_t NDS4MiSTerDividePreparedNonUnitU32(
    std::uint32_t numerator,
    std::uint32_t denominator,
    std::uint32_t reciprocal) noexcept
{
    std::uint32_t quotient = static_cast<std::uint32_t>(
        (static_cast<std::uint64_t>(numerator) * reciprocal) >> 32);
    const std::uint32_t remainder = numerator - quotient * denominator;
    quotient += remainder >= denominator;
    return quotient;
}

inline std::uint32_t NDS4MiSTerDivideU32Exact(
    std::uint32_t numerator, std::uint32_t denominator) noexcept
{
    if (denominator == 0) return 0;
    std::uint32_t quotient = static_cast<std::uint32_t>(
        static_cast<double>(numerator) /
        static_cast<double>(denominator));
    std::uint64_t product =
        static_cast<std::uint64_t>(quotient) * denominator;
    // Binary64 holds every u32 operand exactly and its rounded quotient is
    // less than one integer away from truncation. One correction is therefore
    // sufficient; avoid loop backedges in the per-span setup path.
    if (product > numerator)
    {
        --quotient;
    }
    else if (static_cast<std::uint64_t>(numerator) - product >= denominator)
    {
        ++quotient;
    }
    return quotient;
}

inline std::uint32_t NDS4MiSTerDivideFactorDeltaExact(
    std::uint32_t numerator, std::uint32_t denominator) noexcept
{
    // Perspective correction quotients are bounded to 0..256. Normalize a
    // wide divisor to its leading ten bits and divide by that 512..1023 value
    // with a compile-time magic multiplier. If
    //
    //   denominator = normalized * 2^shift + low
    //
    // then floor((numerator >> shift) / normalized) can exceed the exact
    // quotient by at most one: normalized is at least 512 while the quotient
    // is at most 256. One product comparison therefore restores the exact
    // result. This replaces Cortex-A9's VRECPE/VRECPS plus scalar/NEON domain
    // transfers in the hottest measured Mario Kart rasterizer function with
    // CLZ, one cached table load, UMULL, and a single bounded correction.
    if (denominator <= NDS4MiSTerRasterReciprocalLimit)
        return denominator == 1 ? numerator :
            NDS4MiSTerDividePreparedNonUnitU32(
                numerator, denominator,
                NDS4MiSTerRasterMagic[denominator]);

    const std::uint32_t highestBit = 31u - static_cast<std::uint32_t>(
        __builtin_clz(denominator));
    const std::uint32_t shift = highestBit - 9u;
    const std::uint32_t normalizedDenominator = denominator >> shift;
    const std::uint32_t normalizedNumerator = numerator >> shift;
    std::uint32_t quotient = NDS4MiSTerDividePreparedNonUnitU32(
        normalizedNumerator, normalizedDenominator,
        NDS4MiSTerPerspectiveMagic[
            normalizedDenominator - NDS4MiSTerPerspectiveMagicBase]);

    // FinalW is normalized to 16 bits and a native X span is at most 256
    // pixels, so quotient*denominator fits in u32 for the supported
    // <=0x00FFFF00 denominator range.
    quotient -= quotient * denominator > numerator;
    return quotient;
}

} // namespace melonDS
