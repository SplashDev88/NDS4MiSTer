#include "GPU3D_Soft.h"

#include <array>
#include <iostream>
#include <stdexcept>

using namespace melonDS;

static void require(bool value, const char* message)
{
    if (!value) throw std::runtime_error(message);
}

static u32 randomWord(u32& state)
{
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}

// Keep the original per-channel fog equations as the independent oracle.
static u32 originalFogPixel(u32 source, u32 density, u32 fogColor, bool color)
{
    u32 r = source & 63, g = (source >> 8) & 63;
    u32 b = (source >> 16) & 63, a = (source >> 24) & 31;
    u32 fr = (fogColor << 1) & 62; if (fr) ++fr;
    u32 fg = (fogColor >> 4) & 62; if (fg) ++fg;
    u32 fb = (fogColor >> 9) & 62; if (fb) ++fb;
    const u32 fa = (fogColor >> 16) & 31;
    if (color)
    {
        r = (fr * density + r * (128 - density)) >> 7;
        g = (fg * density + g * (128 - density)) >> 7;
        b = (fb * density + b * (128 - density)) >> 7;
    }
    a = (fa * density + a * (128 - density)) >> 7;
    return r | (g << 8) | (b << 16) | (a << 24);
}

int main() try
{
    u8 table[34] {};
    u64 predicates = 1, rows = 0, pixels = 0;
    u32 random = 0xc0f6d193;
    require(NDS4MiSTerFogDensityTableIsZero(table), "zero table not recognized");
    for (unsigned entry = 0; entry < 34; ++entry)
    {
        for (unsigned value = 1; value < 256; ++value)
        {
            table[entry] = value;
            require(!NDS4MiSTerFogDensityTableIsZero(table), "nonzero fog table accepted");
            table[entry] = 0;
            ++predicates;
        }
    }

    std::array<u32, 1024> expected, actual, attrs;
    for (unsigned trial = 0; trial < 4096; ++trial)
    {
        for (bool lower : {false, true})
        {
            for (bool color : {false, true})
            {
                for (unsigned i = 0; i < actual.size(); ++i)
                {
                    expected[i] = actual[i] = randomWord(random);
                    attrs[i] = randomWord(random);
                }
                const unsigned start = trial % 16, count = trial % 257;
                const u32 fogColor = randomWord(random);
                for (unsigned i = start; i < start + count; ++i)
                {
                    if (attrs[i] & (1u << 15))
                        expected[i] = originalFogPixel(expected[i], 0, fogColor, color);
                    if (lower && (attrs[i] & 15) && (attrs[i + 512] & (1u << 15)))
                        expected[i + 512] = originalFogPixel(expected[i + 512], 0, fogColor, color);
                }
                NDS4MiSTerApplyZeroFogScanline(
                    actual.data() + start, attrs.data() + start, 512, lower, count);
                require(actual == expected, "zero fog changed guarded pixels or channel bits");
                ++rows;
                pixels += count;
            }
        }
    }
    std::cout << "NDS4MISTER_ZERO_FOG_EDGE_PASS predicates=" << predicates
              << " rows=" << rows << " pixels=" << pixels
              << " unused_bits=1 lower_layers=1 unaligned_tails=1\n";
    return 0;
}
catch (const std::exception& error)
{
    std::cerr << error.what() << '\n';
    return 1;
}
