#include "GPU3D_Soft.h"

#include <array>
#include <cstdint>
#include <cstdio>

using melonDS::u32;

namespace
{

struct Pixel
{
    u32 Color;
    u32 Depth;
    u32 Attr;
};

struct TwoLayerBuffer
{
    std::array<Pixel, 2> Pixels;
};

constexpr u32 referenceAttr(u32 polyattr, u32 dstattr) noexcept
{
    return (polyattr & 0xE0F0u) |
        ((polyattr >> 8) & 0xFF0000u) | (1u << 22) |
        (dstattr & 0xFF001F0Fu);
}

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

template <bool Candidate>
bool plot(Pixel& pixel, u32 source, u32 z, u32 polyattr,
          bool shadow, bool blend)
{
    const u32 destinationAttr = pixel.Attr;
    u32 attr;
    if constexpr (Candidate)
        attr = melonDS::NDS4MiSTerComposeTranslucentAttr(
            polyattr, destinationAttr);
    else
        attr = referenceAttr(polyattr, destinationAttr);

    if (shadow)
    {
        if (destinationAttr & (1u << 22))
        {
            if ((destinationAttr & 0x007F0000u) ==
                (attr & 0x007F0000u))
                return false;
        }
        else if ((destinationAttr & 0x3F000000u) ==
                 (polyattr & 0x3F000000u))
            return false;
    }
    else if ((destinationAttr & 0x007F0000u) ==
             (attr & 0x007F0000u))
        return false;

    if (!(destinationAttr & (1u << 15)))
        attr &= ~(1u << 15);
    pixel.Color = referenceBlend(
        source, pixel.Color, source >> 24, blend);
    if (z != static_cast<u32>(-1))
        pixel.Depth = z;
    pixel.Attr = attr;
    return true;
}

template <bool Candidate>
u32 renderTwoLayers(TwoLayerBuffer& buffer, u32 source, u32 z,
                    u32 polyattr, bool shadow, bool blend)
{
    const u32 originalTopAttr = buffer.Pixels[0].Attr;
    u32 writeMask = plot<Candidate>(
        buffer.Pixels[0], source, z, polyattr, shadow, blend) ? 1u : 0u;
    // This is the production caller's lower-layer rule: the decision uses
    // the original top attribute, even if plotting the top layer rejects.
    if (originalTopAttr & 0xFu)
    {
        if (plot<Candidate>(
                buffer.Pixels[1], source, z, polyattr, shadow, blend))
            writeMask |= 2u;
    }
    return writeMask;
}

bool sameBuffer(const TwoLayerBuffer& lhs, const TwoLayerBuffer& rhs)
{
    for (unsigned layer = 0; layer < 2; ++layer)
    {
        if (lhs.Pixels[layer].Color != rhs.Pixels[layer].Color ||
            lhs.Pixels[layer].Depth != rhs.Pixels[layer].Depth ||
            lhs.Pixels[layer].Attr != rhs.Pixels[layer].Attr)
            return false;
    }
    return true;
}

bool deterministicAttrDomain(std::uint64_t& comparisons)
{
    constexpr u32 highPatterns[] = {
        0x00000000u, 0x3F000000u, 0x80000000u, 0xFF000000u};
    constexpr u32 middlePatterns[] = {
        0x00000000u, 0x00120000u, 0x00400000u, 0x00FF0000u};

    // Sweep every low-halfword value independently through both inputs. This
    // exhausts every bit selected by the low XOR delta while unrelated bits
    // are deliberately populated in the other operand.
    for (u32 low = 0; low <= 0xFFFFu; ++low)
    {
        for (u32 pattern : highPatterns)
        {
            const u32 polyattr = pattern | low;
            const u32 dstattr = 0xA55A0000u | (low ^ 0x5AA5u);
            const u32 expected = referenceAttr(polyattr, dstattr);
            const u32 actual =
                melonDS::NDS4MiSTerComposeTranslucentAttr(
                    polyattr, dstattr);
            ++comparisons;
            if (actual != expected)
            {
                std::fprintf(stderr,
                    "FAIL: low/poly sweep poly=%08x dst=%08x "
                    "expected=%08x actual=%08x\n",
                    polyattr, dstattr, expected, actual);
                return false;
            }

            const u32 reversePoly = pattern | (low ^ 0xA55Au);
            const u32 reverseDst = 0x5AA50000u | low;
            const u32 reverseExpected =
                referenceAttr(reversePoly, reverseDst);
            const u32 reverseActual =
                melonDS::NDS4MiSTerComposeTranslucentAttr(
                    reversePoly, reverseDst);
            ++comparisons;
            if (reverseActual != reverseExpected)
            {
                std::fprintf(stderr,
                    "FAIL: low/dst sweep poly=%08x dst=%08x "
                    "expected=%08x actual=%08x\n",
                    reversePoly, reverseDst,
                    reverseExpected, reverseActual);
                return false;
            }
        }
    }

    // Exhaust every combination of the two high bytes. The polygon high byte
    // becomes output bits 16..23 and the destination high byte must survive.
    for (u32 polygonByte = 0; polygonByte <= 0xFFu; ++polygonByte)
    for (u32 destinationByte = 0; destinationByte <= 0xFFu;
         ++destinationByte)
    {
        const u32 polyattr = (polygonByte << 24) | 0x0000A5F0u;
        const u32 dstattr = (destinationByte << 24) | 0x005A1A0Fu;
        const u32 expected = referenceAttr(polyattr, dstattr);
        const u32 actual = melonDS::NDS4MiSTerComposeTranslucentAttr(
            polyattr, dstattr);
        ++comparisons;
        if (actual != expected)
        {
            std::fprintf(stderr,
                "FAIL: byte sweep poly=%08x dst=%08x "
                "expected=%08x actual=%08x\n",
                polyattr, dstattr, expected, actual);
            return false;
        }
    }

    for (u32 polyMiddle : middlePatterns)
    for (u32 dstMiddle : middlePatterns)
    {
        const u32 polyattr = 0xC30069D5u ^ polyMiddle;
        const u32 dstattr = 0x7E5A96A3u ^ dstMiddle;
        const u32 expected = referenceAttr(polyattr, dstattr);
        const u32 actual = melonDS::NDS4MiSTerComposeTranslucentAttr(
            polyattr, dstattr);
        ++comparisons;
        if (actual != expected)
            return false;
    }
    return true;
}

bool fullStateDomain(std::uint64_t& comparisons)
{
    constexpr u32 sourceAlphas[] = {0, 1, 15, 30, 31};
    constexpr u32 polygonIds[] = {0, 17, 63};
    constexpr u32 destinationIds[] = {0, 17, 18, 63};
    for (u32 sourceAlpha : sourceAlphas)
    for (u32 polygonId : polygonIds)
    for (u32 destinationId : destinationIds)
    for (unsigned shadow = 0; shadow < 2; ++shadow)
    for (unsigned topTranslucent = 0; topTranslucent < 2;
         ++topTranslucent)
    for (unsigned bottomTranslucent = 0; bottomTranslucent < 2;
         ++bottomTranslucent)
    for (unsigned topHasLower = 0; topHasLower < 2; ++topHasLower)
    for (unsigned sourceFog = 0; sourceFog < 2; ++sourceFog)
    for (unsigned destinationFog = 0; destinationFog < 2;
         ++destinationFog)
    for (unsigned blend = 0; blend < 2; ++blend)
    for (unsigned writeDepth = 0; writeDepth < 2; ++writeDepth)
    {
        const u32 source = 7u | (29u << 8) | (61u << 16) |
            (sourceAlpha << 24);
        const u32 polyattr = (polygonId << 24) | 0x20F0u |
            (sourceFog ? (1u << 15) : 0u);
        const u32 topAttr = (destinationId << 16) |
            (topTranslucent ? (1u << 22) : 0u) |
            (destinationFog ? (1u << 15) : 0u) |
            (topHasLower ? 0xBu : 0u) | 0xA5001300u;
        const u32 bottomAttr = ((destinationId ^ 0x15u) << 16) |
            (bottomTranslucent ? (1u << 22) : 0u) |
            ((destinationFog ^ 1u) ? (1u << 15) : 0u) |
            0x3C000507u;
        TwoLayerBuffer reference {};
        reference.Pixels[0] = {
            3u | (41u << 8) | (22u << 16) | (16u << 24),
            0x13572468u, topAttr};
        reference.Pixels[1] = {
            51u | (2u << 8) | (37u << 16) | (7u << 24),
            0x24681357u, bottomAttr};
        TwoLayerBuffer candidate = reference;
        const u32 z = writeDepth ? 0x00ABCDEFu :
            static_cast<u32>(-1);
        const u32 expectedMask = renderTwoLayers<false>(
            reference, source, z, polyattr, shadow != 0, blend != 0);
        const u32 actualMask = renderTwoLayers<true>(
            candidate, source, z, polyattr, shadow != 0, blend != 0);
        ++comparisons;
        if (actualMask != expectedMask ||
            !sameBuffer(reference, candidate))
        {
            std::fprintf(stderr,
                "FAIL: state sa=%u pid=%u did=%u shadow=%u topT=%u "
                "bottomT=%u lower=%u sf=%u df=%u blend=%u depth=%u\n",
                sourceAlpha, polygonId, destinationId, shadow,
                topTranslucent, bottomTranslucent, topHasLower,
                sourceFog, destinationFog, blend, writeDepth);
            return false;
        }
    }
    return true;
}

bool randomFullBuffers(std::uint64_t& comparisons)
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
        TwoLayerBuffer reference {};
        reference.Pixels[0] = {
            (randomWord() & 0x003F3F3Fu) |
                ((randomWord() & 31u) << 24),
            randomWord(), randomWord()};
        reference.Pixels[1] = {
            (randomWord() & 0x003F3F3Fu) |
                ((randomWord() & 31u) << 24),
            randomWord(), randomWord()};
        TwoLayerBuffer candidate = reference;
        const u32 polyattr = randomWord();
        const u32 z = (randomWord() & 1u) ? randomWord() :
            static_cast<u32>(-1);
        const bool shadow = randomWord() & 1u;
        const bool blend = randomWord() & 1u;
        const u32 expectedMask = renderTwoLayers<false>(
            reference, source, z, polyattr, shadow, blend);
        const u32 actualMask = renderTwoLayers<true>(
            candidate, source, z, polyattr, shadow, blend);
        ++comparisons;
        if (actualMask != expectedMask ||
            !sameBuffer(reference, candidate))
        {
            std::fprintf(stderr, "FAIL: random iteration=%u\n", iteration);
            return false;
        }
    }
    return true;
}

} // namespace

extern "C" __attribute__((noinline)) u32 nds_test_translucent_attr_compose(
    u32 polyattr, u32 dstattr)
{
    return melonDS::NDS4MiSTerComposeTranslucentAttr(polyattr, dstattr);
}

int main()
{
    std::uint64_t comparisons = 0;
    if (!deterministicAttrDomain(comparisons)) return 1;
    if (!fullStateDomain(comparisons)) return 2;
    if (!randomFullBuffers(comparisons)) return 3;
    std::printf("PASS: translucent attribute comparisons=%llu\n",
        static_cast<unsigned long long>(comparisons));
    return 0;
}
