#include "GPU3D_Soft.h"

#include <cstdint>
#include <cstdio>

using melonDS::u32;

static u32 referenceModulate(u32 texel, u32 vertexColor, u32 polyAlpha)
{
    const u32 tr = texel & 0x3f;
    const u32 tg = (texel >> 8) & 0x3f;
    const u32 tb = (texel >> 16) & 0x3f;
    const u32 ta = texel >> 24;
    const u32 vr = vertexColor & 0x3f;
    const u32 vg = (vertexColor >> 8) & 0x3f;
    const u32 vb = (vertexColor >> 16) & 0x3f;
    const u32 r = ((tr + 1) * (vr + 1) - 1) >> 6;
    const u32 g = ((tg + 1) * (vg + 1) - 1) >> 6;
    const u32 b = ((tb + 1) * (vb + 1) - 1) >> 6;
    const u32 a = ((ta + 1) * (polyAlpha + 1) - 1) >> 5;
    return r | (g << 8) | (b << 16) | (a << 24);
}

extern "C" __attribute__((noinline)) u32
nds_test_cached_translucent_modulate(
    u32 texel, u32 vertexColor, u32 polyAlpha)
{
    return melonDS::NDS4MiSTerModulateCachedPixel(
        texel, vertexColor, polyAlpha);
}

extern "C" __attribute__((noinline)) bool
nds_test_visible_cached_modulate(
    u32 texel, u32 vertexColor, u32 polyAlpha, u32 alphaRef,
    u32* color)
{
    return melonDS::NDS4MiSTerModulateVisibleCachedPixel(
        texel, vertexColor, polyAlpha, alphaRef, *color);
}

static bool checkVisibleModulate(
    u32 texel, u32 vertexColor, u32 polyAlpha, u32 alphaRef,
    std::uint64_t& comparisons)
{
    const u32 expectedColor = referenceModulate(
        texel, vertexColor, polyAlpha);
    const bool expectedVisible = (expectedColor >> 24) > alphaRef;
    constexpr u32 sentinel = 0xA55AA55Au;
    u32 actualColor = sentinel;
    const bool actualVisible = nds_test_visible_cached_modulate(
        texel, vertexColor, polyAlpha, alphaRef, &actualColor);
    ++comparisons;
    if (actualVisible != expectedVisible)
        return false;
    return expectedVisible ? actualColor == expectedColor :
        actualColor == sentinel;
}

extern "C" __attribute__((noinline)) void
nds_test_pack_cached_span_values(
    const std::int32_t* values, u32* vertexColor,
    std::int16_t* textureS, std::int16_t* textureT)
{
    melonDS::NDS4MiSTerPackCachedSpanValues(
        values, *vertexColor, *textureS, *textureT);
}

static bool testPackCachedSpanValues(std::uint64_t& comparisons)
{
    constexpr std::int32_t edgeValues[] = {
        INT32_MIN, -65536, -32769, -32768, -1, 0, 1, 7, 8,
        63, 64, 255, 511, 32767, 32768, 65535, INT32_MAX,
    };
    const auto check = [&comparisons](const std::int32_t values[5]) {
        const u32 expectedColor =
            (static_cast<u32>(values[0]) >> 3) |
            ((static_cast<u32>(values[1]) >> 3) << 8) |
            ((static_cast<u32>(values[2]) >> 3) << 16);
        const std::int16_t expectedS = static_cast<std::int16_t>(values[3]);
        const std::int16_t expectedT = static_cast<std::int16_t>(values[4]);
        u32 actualColor = 0;
        std::int16_t actualS = 0;
        std::int16_t actualT = 0;
        nds_test_pack_cached_span_values(
            values, &actualColor, &actualS, &actualT);
        ++comparisons;
        return actualColor == expectedColor &&
            actualS == expectedS && actualT == expectedT;
    };

    for (const std::int32_t value : edgeValues)
    {
        const std::int32_t values[5] = {
            value, static_cast<std::int32_t>(~value),
            static_cast<std::int32_t>(value ^ 0x55AA55AA),
            static_cast<std::int16_t>(value),
            static_cast<std::int16_t>(~value),
        };
        if (!check(values))
            return false;
    }

    u32 randomState = 0x13198A2Eu;
    const auto randomWord = [&randomState]() {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return randomState;
    };
    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        std::int32_t values[5];
        for (auto& value : values)
            value = static_cast<std::int32_t>(randomWord());
        if (!check(values))
            return false;
    }
    return true;
}

static bool testEveryChannelAndAlphaPair(std::uint64_t& comparisons)
{
    for (u32 polyAlpha = 1; polyAlpha <= 31; ++polyAlpha)
    {
        for (u32 textureAlpha = 0; textureAlpha <= 31; ++textureAlpha)
        {
            for (u32 textureChannel = 0; textureChannel <= 63;
                 ++textureChannel)
            {
                for (u32 vertexChannel = 0; vertexChannel <= 63;
                     ++vertexChannel)
                {
                    // Rotate the component values so each packed lane also
                    // proves that adjacent bytes cannot contaminate it.
                    const u32 texel = textureChannel |
                        (((textureChannel + 17) & 0x3f) << 8) |
                        (((textureChannel + 43) & 0x3f) << 16) |
                        (textureAlpha << 24);
                    const u32 vertex = vertexChannel |
                        (((vertexChannel + 29) & 0x3f) << 8) |
                        (((vertexChannel + 51) & 0x3f) << 16);
                    ++comparisons;
                    if (nds_test_cached_translucent_modulate(
                            texel, vertex, polyAlpha) !=
                        referenceModulate(texel, vertex, polyAlpha))
                        return false;
                    const u32 alphaRef =
                        (textureChannel + vertexChannel) & 31;
                    if (!checkVisibleModulate(
                            texel, vertex, polyAlpha, alphaRef,
                            comparisons))
                        return false;
                }
            }
        }
    }
    return true;
}

static bool testAlphaReferenceBoundary(std::uint64_t& comparisons)
{
    for (u32 polyAlpha = 1; polyAlpha <= 31; ++polyAlpha)
    {
        for (u32 textureAlpha = 0; textureAlpha <= 31; ++textureAlpha)
        {
            const u32 color = nds_test_cached_translucent_modulate(
                textureAlpha << 24, 0, polyAlpha);
            const u32 expected = referenceModulate(
                textureAlpha << 24, 0, polyAlpha);
            for (u32 alphaRef = 0; alphaRef <= 31; ++alphaRef)
            {
                ++comparisons;
                if (((color >> 24) > alphaRef) !=
                    ((expected >> 24) > alphaRef))
                    return false;
                if (!checkVisibleModulate(
                        textureAlpha << 24, 0, polyAlpha,
                        alphaRef, comparisons))
                    return false;
            }
        }
    }
    return true;
}

static bool testEligibility(std::uint64_t& comparisons)
{
    constexpr int edges[] = {0, 1, 2, 4, 8, 12};
    for (const int edge : edges)
    for (u32 polyAlpha = 0; polyAlpha <= 32; ++polyAlpha)
    for (unsigned flags = 0; flags < 16; ++flags)
    {
        const bool cached = flags & 1;
        const bool shadow = flags & 2;
        const bool shadowMask = flags & 4;
        const bool frontLess = flags & 8;
        const bool expected = edge == 0 && cached &&
            polyAlpha >= 1 && polyAlpha <= 31 &&
            !shadow && !shadowMask && frontLess;
        ++comparisons;
        if (melonDS::NDS4MiSTerUseCachedModulateInterior(
                edge, cached, polyAlpha, shadow, shadowMask, frontLess) !=
            expected)
            return false;
    }
    return true;
}

static bool testIndependentRandomChannels(std::uint64_t& comparisons)
{
    u32 randomState = 0x7f4a7c15u;
    const auto randomWord = [&randomState]() {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return randomState;
    };
    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        const u32 texel = (randomWord() & 0x3f3f3f3fu) & 0x1f3f3f3fu;
        const u32 vertex = randomWord() & 0x003f3f3fu;
        const u32 polyAlpha = 1 + randomWord() % 31;
        ++comparisons;
        if (nds_test_cached_translucent_modulate(
                texel, vertex, polyAlpha) !=
            referenceModulate(texel, vertex, polyAlpha))
            return false;
        const u32 alphaRef = randomWord() & 31;
        if (!checkVisibleModulate(
                texel, vertex, polyAlpha, alphaRef, comparisons))
            return false;
    }
    return true;
}

int main()
{
    std::uint64_t comparisons = 0;
    if (!testPackCachedSpanValues(comparisons)) return 1;
    if (!testEveryChannelAndAlphaPair(comparisons)) return 2;
    if (!testAlphaReferenceBoundary(comparisons)) return 3;
    if (!testEligibility(comparisons)) return 4;
    if (!testIndependentRandomChannels(comparisons)) return 5;
    std::printf(
        "PASS: cached translucent modulation/selection comparisons=%llu\n",
        static_cast<unsigned long long>(comparisons));
    return 0;
}
