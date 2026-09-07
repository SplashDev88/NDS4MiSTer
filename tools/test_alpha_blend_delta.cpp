#include "GPU3D_Soft.h"

#include <array>
#include <cstdint>
#include <cstdio>

using melonDS::s32;
using melonDS::u32;

namespace
{

struct Pixel
{
    u32 Color;
    u32 Depth;
    u32 Attr;
};

u32 referenceBlend(u32 source, u32 destination, u32 alpha, bool enabled)
{
    u32 destinationAlpha = destination >> 24;
    if (destinationAlpha == 0)
        return source;

    u32 r = source & 0x3Fu;
    u32 g = (source >> 8) & 0x3Fu;
    u32 b = (source >> 16) & 0x3Fu;
    if (enabled)
    {
        const u32 destinationR = destination & 0x3Fu;
        const u32 destinationG = (destination >> 8) & 0x3Fu;
        const u32 destinationB = (destination >> 16) & 0x3Fu;
        ++alpha;
        r = (r * alpha + destinationR * (32u - alpha)) >> 5;
        g = (g * alpha + destinationG * (32u - alpha)) >> 5;
        b = (b * alpha + destinationB * (32u - alpha)) >> 5;
        --alpha;
    }
    if (alpha > destinationAlpha)
        destinationAlpha = alpha;
    return r | (g << 8) | (b << 16) | (destinationAlpha << 24);
}

u32 candidateBlend(u32 source, u32 destination, u32 alpha, bool enabled)
{
    u32 destinationAlpha = destination >> 24;
    if (destinationAlpha == 0)
        return source;

    u32 r = source & 0x3Fu;
    u32 g = (source >> 8) & 0x3Fu;
    u32 b = (source >> 16) & 0x3Fu;
    if (enabled)
    {
        const u32 destinationR = destination & 0x3Fu;
        const u32 destinationG = (destination >> 8) & 0x3Fu;
        const u32 destinationB = (destination >> 16) & 0x3Fu;
        ++alpha;
        r = melonDS::NDS4MiSTerAlphaBlendChannel(r, destinationR, alpha);
        g = melonDS::NDS4MiSTerAlphaBlendChannel(g, destinationG, alpha);
        b = melonDS::NDS4MiSTerAlphaBlendChannel(b, destinationB, alpha);
        --alpha;
    }
    if (alpha > destinationAlpha)
        destinationAlpha = alpha;
    return r | (g << 8) | (b << 16) | (destinationAlpha << 24);
}

bool referencePlot(Pixel& pixel, u32 source, u32 z, u32 polyAttr,
                   bool shadow, bool blend)
{
    const u32 destinationAttr = pixel.Attr;
    u32 attr = (polyAttr & 0xE0F0u) |
        ((polyAttr >> 8) & 0xFF0000u) | (1u << 22) |
        (destinationAttr & 0xFF001F0Fu);
    if (shadow)
    {
        if (destinationAttr & (1u << 22))
        {
            if ((destinationAttr & 0x007F0000u) ==
                (attr & 0x007F0000u))
                return false;
        }
        else if ((destinationAttr & 0x3F000000u) ==
                 (polyAttr & 0x3F000000u))
            return false;
    }
    else if ((destinationAttr & 0x007F0000u) ==
             (attr & 0x007F0000u))
        return false;

    if (!(destinationAttr & (1u << 15)))
        attr &= ~(1u << 15);
    const u32 color = referenceBlend(
        source, pixel.Color, source >> 24, blend);
    if (z != static_cast<u32>(-1))
        pixel.Depth = z;
    pixel.Color = color;
    pixel.Attr = attr;
    return true;
}

bool candidatePlot(Pixel& pixel, u32 source, u32 z, u32 polyAttr,
                   bool shadow, bool blend)
{
    const u32 destinationAttr = pixel.Attr;
    u32 attr = (polyAttr & 0xE0F0u) |
        ((polyAttr >> 8) & 0xFF0000u) | (1u << 22) |
        (destinationAttr & 0xFF001F0Fu);
    if (shadow)
    {
        if (destinationAttr & (1u << 22))
        {
            if ((destinationAttr & 0x007F0000u) ==
                (attr & 0x007F0000u))
                return false;
        }
        else if ((destinationAttr & 0x3F000000u) ==
                 (polyAttr & 0x3F000000u))
            return false;
    }
    else if ((destinationAttr & 0x007F0000u) ==
             (attr & 0x007F0000u))
        return false;

    if (!(destinationAttr & (1u << 15)))
        attr &= ~(1u << 15);
    const u32 color = candidateBlend(
        source, pixel.Color, source >> 24, blend);
    if (z != static_cast<u32>(-1))
        pixel.Depth = z;
    pixel.Color = color;
    pixel.Attr = attr;
    return true;
}

bool samePixel(const Pixel& lhs, const Pixel& rhs)
{
    return lhs.Color == rhs.Color && lhs.Depth == rhs.Depth &&
        lhs.Attr == rhs.Attr;
}

bool exhaustiveChannels(std::uint64_t& comparisons)
{
    for (u32 source = 0; source <= 63; ++source)
    for (u32 destination = 0; destination <= 63; ++destination)
    for (u32 alpha = 1; alpha <= 32; ++alpha)
    {
        const u32 expected =
            (source * alpha + destination * (32u - alpha)) >> 5;
        const u32 actual = melonDS::NDS4MiSTerAlphaBlendChannel(
            source, destination, alpha);
        ++comparisons;
        if (actual != expected)
        {
            std::fprintf(stderr,
                "FAIL: channel source=%u destination=%u alpha=%u "
                "expected=%u actual=%u\n",
                source, destination, alpha, expected, actual);
            return false;
        }
    }
    return true;
}

bool fullPixelState(std::uint64_t& comparisons)
{
    constexpr u32 sourceAlphas[] = {0, 1, 15, 30, 31};
    constexpr u32 destinationAlphas[] = {0, 1, 16, 31};
    constexpr u32 polygonIds[] = {0, 17, 63};
    constexpr u32 destinationIds[] = {0, 17, 18, 63};
    for (u32 sourceAlpha : sourceAlphas)
    for (u32 destinationAlpha : destinationAlphas)
    for (u32 polygonId : polygonIds)
    for (u32 destinationId : destinationIds)
    for (unsigned shadow = 0; shadow < 2; ++shadow)
    for (unsigned destinationTranslucent = 0;
         destinationTranslucent < 2; ++destinationTranslucent)
    for (unsigned sourceFog = 0; sourceFog < 2; ++sourceFog)
    for (unsigned destinationFog = 0; destinationFog < 2;
         ++destinationFog)
    for (unsigned blend = 0; blend < 2; ++blend)
    for (unsigned writeDepth = 0; writeDepth < 2; ++writeDepth)
    {
        const u32 source = 7u | (29u << 8) | (61u << 16) |
            (sourceAlpha << 24);
        const u32 polyAttr = (polygonId << 24) | 0x20F0u |
            (sourceFog ? (1u << 15) : 0u);
        const u32 destinationAttr =
            (destinationId << 16) |
            (destinationTranslucent ? (1u << 22) : 0u) |
            (destinationFog ? (1u << 15) : 0u) |
            0xA500130Fu;
        Pixel reference {
            3u | (41u << 8) | (22u << 16) |
                (destinationAlpha << 24),
            0x13572468u, destinationAttr};
        Pixel candidate = reference;
        const u32 z = writeDepth ? 0x00ABCDEFu :
            static_cast<u32>(-1);
        const bool expectedWrite = referencePlot(
            reference, source, z, polyAttr, shadow != 0, blend != 0);
        const bool actualWrite = candidatePlot(
            candidate, source, z, polyAttr, shadow != 0, blend != 0);
        ++comparisons;
        if (actualWrite != expectedWrite || !samePixel(reference, candidate))
        {
            std::fprintf(stderr,
                "FAIL: pixel sa=%u da=%u pid=%u did=%u shadow=%u "
                "translucent=%u sf=%u df=%u blend=%u depth=%u\n",
                sourceAlpha, destinationAlpha, polygonId, destinationId,
                shadow, destinationTranslucent, sourceFog,
                destinationFog, blend, writeDepth);
            return false;
        }
    }
    return true;
}

bool randomFullWords(std::uint64_t& comparisons)
{
    u32 state = 0x9E3779B9u;
    const auto randomWord = [&state]() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    };
    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        const u32 source = (randomWord() & 0x003F3F3Fu) |
            ((randomWord() & 31u) << 24);
        Pixel reference {
            (randomWord() & 0x003F3F3Fu) |
                ((randomWord() & 31u) << 24),
            randomWord(), randomWord()};
        Pixel candidate = reference;
        const u32 polyAttr = randomWord();
        const u32 z = (randomWord() & 1u) ? randomWord() :
            static_cast<u32>(-1);
        const bool shadow = randomWord() & 1u;
        const bool blend = randomWord() & 1u;
        const bool expectedWrite = referencePlot(
            reference, source, z, polyAttr, shadow, blend);
        const bool actualWrite = candidatePlot(
            candidate, source, z, polyAttr, shadow, blend);
        ++comparisons;
        if (actualWrite != expectedWrite || !samePixel(reference, candidate))
        {
            std::fprintf(stderr, "FAIL: random iteration=%u\n", iteration);
            return false;
        }
    }
    return true;
}

} // namespace

extern "C" __attribute__((noinline)) u32 nds_test_alpha_blend_delta(
    u32 source, u32 destination, u32 alpha)
{
    ++alpha;
    const u32 r = melonDS::NDS4MiSTerAlphaBlendChannel(
        source & 0x3Fu, destination & 0x3Fu, alpha);
    const u32 g = melonDS::NDS4MiSTerAlphaBlendChannel(
        (source >> 8) & 0x3Fu, (destination >> 8) & 0x3Fu, alpha);
    const u32 b = melonDS::NDS4MiSTerAlphaBlendChannel(
        (source >> 16) & 0x3Fu, (destination >> 16) & 0x3Fu, alpha);
    return r | (g << 8) | (b << 16);
}

int main()
{
    std::uint64_t comparisons = 0;
    if (!exhaustiveChannels(comparisons)) return 1;
    if (!fullPixelState(comparisons)) return 2;
    if (!randomFullWords(comparisons)) return 3;
    std::printf("PASS: alpha blend delta comparisons=%llu\n",
        static_cast<unsigned long long>(comparisons));
    return 0;
}
