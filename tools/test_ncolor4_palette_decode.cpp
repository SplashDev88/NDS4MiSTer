#include "GPU3D_Texcache.h"

#include <array>
#include <cstdint>
#include <cstdio>

using melonDS::u16;
using melonDS::u32;

static constexpr u32 referenceRGB5ToRGB6A5(
    u16 color, bool transparent) noexcept
{
    u32 r = (color & 0x001F) << 1;
    u32 g = (color & 0x03E0) >> 4;
    u32 b = (color & 0x7C00) >> 9;
    if (r) ++r;
    if (g) ++g;
    if (b) ++b;
    return r | (g << 8) | (b << 16) |
        (transparent ? 0u : 0x1F000000u);
}

extern "C" __attribute__((noinline)) void nds_test_ncolor4_decode(
    u16 packed, const u32* palette, u32* output)
{
    melonDS::NDS4MiSTerDecodeNColorWordRGB6A5<4>(
        packed, palette, output);
}

static bool checkWord(
    u16 packed, const std::array<u32, 16>& palette,
    std::uint64_t& comparisons)
{
    std::array<u32, 4> actual{};
    nds_test_ncolor4_decode(packed, palette.data(), actual.data());
    for (unsigned lane = 0; lane < actual.size(); ++lane)
    {
        const u32 expected = palette[(packed >> (lane * 4)) & 0xF];
        ++comparisons;
        if (actual[lane] != expected)
            return false;
    }
    return true;
}

static bool testCompleteTextureDifferential(
    std::uint64_t& comparisons) noexcept
{
    constexpr unsigned pixels = 32 * 32;
    constexpr unsigned words = pixels / 4;
    std::array<u16, 16> sourcePalette{};
    alignas(32) std::array<u32, 16> expandedPalette{};
    std::array<u16, words> source{};
    std::array<u32, pixels> actual{};
    std::array<u32, pixels> expected{};
    u32 random = 0xC8013EA4u;
    const auto nextRandom = [&random]() {
        random ^= random << 13;
        random ^= random >> 17;
        random ^= random << 5;
        return random;
    };

    for (unsigned iteration = 0; iteration < 2000; ++iteration)
    {
        const bool color0Transparent = (iteration & 1u) != 0;
        for (u16& color : sourcePalette)
            color = static_cast<u16>(nextRandom());
        for (u16& packed : source)
            packed = static_cast<u16>(nextRandom());

        for (u32 index = 0; index < sourcePalette.size(); ++index)
        {
            expandedPalette[index] = referenceRGB5ToRGB6A5(
                sourcePalette[index], color0Transparent && index == 0);
        }
        for (unsigned word = 0; word < source.size(); ++word)
        {
            nds_test_ncolor4_decode(
                source[word], expandedPalette.data(),
                actual.data() + word * 4);
            for (unsigned lane = 0; lane < 4; ++lane)
            {
                const u32 index = (source[word] >> (lane * 4)) & 0xF;
                expected[word * 4 + lane] = referenceRGB5ToRGB6A5(
                    sourcePalette[index], color0Transparent && index == 0);
            }
        }
        for (unsigned pixel = 0; pixel < pixels; ++pixel)
        {
            ++comparisons;
            if (actual[pixel] != expected[pixel])
                return false;
        }
    }
    return true;
}

int main()
{
    std::uint64_t comparisons = 0;
    for (unsigned transparent = 0; transparent < 2; ++transparent)
    {
        for (u32 color = 0; color <= 0xFFFFu; ++color)
        {
            const u32 expected = referenceRGB5ToRGB6A5(
                static_cast<u16>(color), transparent != 0);
            // The production palette setup deliberately uses the existing
            // RGB555-to-RGB6 conversion plus this alpha choice.  Exhaust all
            // input colors so the staged representation itself is proven.
            u32 r = (color & 0x001F) << 1;
            u32 g = (color & 0x03E0) >> 4;
            u32 b = (color & 0x7C00) >> 9;
            if (r) ++r;
            if (g) ++g;
            if (b) ++b;
            const u32 actual = r | (g << 8) | (b << 16) |
                (transparent ? 0u : 0x1F000000u);
            ++comparisons;
            if (actual != expected)
                return 1;
        }
    }

    std::array<u32, 16> palette{};
    for (u32 index = 0; index < palette.size(); ++index)
        palette[index] = 0x9E3779B9u * (index + 1u) ^
            (index << 24) ^ (index << 8);

    for (u32 packed = 0; packed <= 0xFFFFu; ++packed)
    {
        if (!checkWord(static_cast<u16>(packed), palette, comparisons))
            return 2;
    }

    if (!testCompleteTextureDifferential(comparisons))
        return 3;

    u32 random = 0xA341316Cu;
    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        random ^= random << 13;
        random ^= random >> 17;
        random ^= random << 5;
        const u16 packed = static_cast<u16>(random);
        for (u32 index = 0; index < palette.size(); ++index)
        {
            random ^= random << 13;
            random ^= random >> 17;
            random ^= random << 5;
            palette[index] = random;
        }
        if (!checkWord(packed, palette, comparisons))
            return 4;
    }

    std::printf(
        "PASS: 4bpp staged-palette decode comparisons=%llu\n",
        static_cast<unsigned long long>(comparisons));
    return 0;
}
