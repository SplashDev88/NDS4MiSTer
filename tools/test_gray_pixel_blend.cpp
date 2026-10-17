#include "GPU3D_Soft.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>

using namespace melonDS;
static u64 checks = 0;

static void check(u32 gray, u32 destination, u32 alpha)
{
    // Independent original weighted-sum formula, not the packed-lane form.
    const u32 destinationAlpha = destination >> 24;
    u32 expected = gray * 0x010101u | (alpha << 24);
    if (destinationAlpha)
    {
        expected = std::max(alpha, destinationAlpha) << 24;
        for (unsigned shift : {0u, 8u, 16u})
        {
            const u32 channel = (destination >> shift) & 63;
            expected |= ((gray * (alpha + 1) + channel * (31 - alpha)) >> 5) << shift;
        }
    }
    const u32 actual = NDS4MiSTerBlendGrayPixel(gray, destination, alpha);
    ++checks;
    if (actual != expected)
    {
        std::fprintf(stderr, "gray=%u dst=%08x alpha=%u: %08x != %08x\n",
            gray, destination, alpha, actual, expected);
        std::abort();
    }
}

int main()
{
    // Exhaust every pair of red/blue lanes, source gray and source alpha.
    // Green varies independently in the same sample; the second sweep covers
    // every gray/channel/alpha combination with every destination alpha.
    for (u32 alpha = 0; alpha < 32; ++alpha)
        for (u32 gray = 0; gray < 64; ++gray)
            for (u32 red = 0; red < 64; ++red)
                for (u32 blue = 0; blue < 64; ++blue)
                {
                    const u32 green = (red * 13 + blue * 7 + gray) & 63;
                    check(gray, red | (green << 8) | (blue << 16) | 0x1F000000u, alpha);
                }
    for (u32 alpha = 0; alpha < 32; ++alpha)
        for (u32 destinationAlpha = 0; destinationAlpha < 32; ++destinationAlpha)
            for (u32 gray = 0; gray < 64; ++gray)
                for (u32 channel = 0; channel < 64; ++channel)
                    check(gray, channel * 0x010101u | (destinationAlpha << 24), alpha);
    // Unused color bits must not contaminate the packed lanes.
    for (u32 alpha = 0; alpha < 32; ++alpha)
        for (u32 gray = 0; gray < 64; ++gray)
            for (u32 channel = 0; channel < 64; ++channel)
                check(gray, channel * 0x010101u | 0x1FC0C0C0u, alpha);
    std::printf("PASS gray pixel blend: %llu independent checks\n",
        static_cast<unsigned long long>(checks));
}
