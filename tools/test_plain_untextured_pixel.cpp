#include "GPU3D_Soft.h"

#include <cstdint>
#include <cstdio>

using melonDS::u8;
using melonDS::u32;

static u32 referencePlainUntexturedPixel(
    u8 vr, u8 vg, u8 vb, u8 polyAlpha, bool wireframe)
{
    // This is the original RenderPixel result after the independently checked
    // no-texture/non-toon branches: RGB passes through and wireframe forces
    // alpha to 31.
    u8 r = vr;
    u8 g = vg;
    u8 b = vb;
    u8 a = polyAlpha;
    if (wireframe)
        a = 31;

    return static_cast<u32>(r) +
        static_cast<u32>(g) * 0x100u +
        static_cast<u32>(b) * 0x10000u +
        static_cast<u32>(a) * 0x1000000u;
}

extern "C" __attribute__((noinline)) u32
nds_test_plain_untextured_pixel(
    u8 vr, u8 vg, u8 vb, u8 polyAlpha, bool wireframe)
{
    return melonDS::NDS4MiSTerRenderPlainUntexturedPixel(
        vr, vg, vb, polyAlpha, wireframe);
}

static bool testEligibility(std::uint64_t& comparisons)
{
    for (unsigned textureEnabled = 0; textureEnabled <= 1;
         ++textureEnabled)
    for (u32 blendMode = 0; blendMode <= 3; ++blendMode)
    {
        // SetupPolygon derives Highlight as (BlendMode == 2 && display-bit),
        // so every legal non-toon/no-texture state is represented here.
        const bool expected = !textureEnabled && blendMode != 2;
        ++comparisons;
        if (melonDS::NDS4MiSTerUsePlainUntexturedPixel(
                textureEnabled != 0, blendMode) != expected)
            return false;
    }
    return true;
}

static bool testEveryDsColorAndAlpha(std::uint64_t& comparisons)
{
    for (u32 polyAlpha = 0; polyAlpha <= 31; ++polyAlpha)
    {
        const bool wireframe = polyAlpha == 0;
        for (u32 vr = 0; vr <= 63; ++vr)
        for (u32 vg = 0; vg <= 63; ++vg)
        for (u32 vb = 0; vb <= 63; ++vb)
        {
            ++comparisons;
            const u32 candidate = nds_test_plain_untextured_pixel(
                static_cast<u8>(vr), static_cast<u8>(vg),
                static_cast<u8>(vb), static_cast<u8>(polyAlpha),
                wireframe);
            const u32 reference = referencePlainUntexturedPixel(
                static_cast<u8>(vr), static_cast<u8>(vg),
                static_cast<u8>(vb), static_cast<u8>(polyAlpha),
                wireframe);
            if (candidate != reference)
                return false;
        }
    }
    return true;
}

static bool testFullByteBoundariesAndRandom(std::uint64_t& comparisons)
{
    constexpr u8 boundary[] = {0, 1, 30, 31, 32, 63, 64, 127, 128, 254, 255};
    for (const u8 vr : boundary)
    for (const u8 vg : boundary)
    for (const u8 vb : boundary)
    for (const u8 alpha : boundary)
    for (unsigned wireframe = 0; wireframe <= 1; ++wireframe)
    {
        ++comparisons;
        if (nds_test_plain_untextured_pixel(
                vr, vg, vb, alpha, wireframe != 0) !=
            referencePlainUntexturedPixel(
                vr, vg, vb, alpha, wireframe != 0))
            return false;
    }

    u32 randomState = 0x694c30e9u;
    const auto randomWord = [&randomState]() {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return randomState;
    };
    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        const u32 word = randomWord();
        const u32 alphaAndFlag = randomWord();
        const u8 vr = static_cast<u8>(word);
        const u8 vg = static_cast<u8>(word >> 8);
        const u8 vb = static_cast<u8>(word >> 16);
        const u8 alpha = static_cast<u8>(alphaAndFlag);
        const bool wireframe = (alphaAndFlag >> 8) & 1;
        ++comparisons;
        if (nds_test_plain_untextured_pixel(
                vr, vg, vb, alpha, wireframe) !=
            referencePlainUntexturedPixel(
                vr, vg, vb, alpha, wireframe))
            return false;
    }
    return true;
}

int main()
{
    std::uint64_t comparisons = 0;
    if (!testEligibility(comparisons)) return 1;
    if (!testEveryDsColorAndAlpha(comparisons)) return 2;
    if (!testFullByteBoundariesAndRandom(comparisons)) return 3;
    std::printf(
        "PASS: plain untextured pixel comparisons=%llu\n",
        static_cast<unsigned long long>(comparisons));
    return 0;
}
