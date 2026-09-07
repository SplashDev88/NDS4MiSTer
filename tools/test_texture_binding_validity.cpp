#include "GPU3D_Soft.h"

#include <array>
#include <cstdint>
#include <cstdio>

using melonDS::u32;

namespace
{

struct Binding
{
    const u32* Pixels = nullptr;
    u32 TexParam = 0;
    u32 TexPalette = 0;
};

bool referenceMatch(
    const Binding& binding, u32 texParam, u32 texPalette) noexcept
{
    return (binding.TexParam == texParam) &
        (binding.TexPalette == texPalette) &
        (binding.Pixels != nullptr);
}

bool candidateMatch(
    const Binding& binding, u32 texParam, u32 texPalette) noexcept
{
    return melonDS::NDS4MiSTerTextureBindingMatches(
        binding.TexParam, binding.TexPalette,
        texParam, texPalette);
}

bool checkValidLookup(
    const Binding& binding, u32 texParam, u32 texPalette,
    std::uint64_t& comparisons) noexcept
{
    // This is the exact production precondition for entering the binding
    // lookup: texture enable is set and format bits 26..28 are nonzero.
    if (((texParam >> 26) & 7u) == 0)
        return true;
    ++comparisons;
    return referenceMatch(binding, texParam, texPalette) ==
        candidateMatch(binding, texParam, texPalette);
}

} // namespace

extern "C" __attribute__((noinline)) bool
nds_test_texture_binding_match(
    u32 cachedTexParam, u32 cachedTexPalette,
    u32 texParam, u32 texPalette)
{
    return melonDS::NDS4MiSTerTextureBindingMatches(
        cachedTexParam, cachedTexPalette, texParam, texPalette);
}

int main()
{
    std::uint64_t comparisons = 0;
    Binding binding;

    // Exhaust every texture format and the fields that GetTexture
    // canonicalizes.  The initial zero sentinel must never match an enabled
    // texture, even when its palette word is also zero.
    for (u32 format = 1; format <= 7; ++format)
    for (u32 coordinateMode = 0; coordinateMode < 4; ++coordinateMode)
    for (u32 wrap = 0; wrap < 16; ++wrap)
    for (u32 base : std::array<u32, 5>{0, 1, 0x7FFF, 0x8000, 0xFFFF})
    for (u32 palette : std::array<u32, 5>{0, 1, 0x1FFF, 0x3FFF, 0xFFFF})
    {
        const u32 texParam = base | (wrap << 16) |
            (coordinateMode << 30) | (format << 26);
        if (!checkValidLookup(binding, texParam, palette, comparisons))
        {
            std::fprintf(stderr,
                "FAIL initial format=%u tex=%08x palette=%08x\n",
                format, texParam, palette);
            return 1;
        }

        // Model the only production transition that makes a binding valid:
        // GetTexture returned an allocated plane and the miss path installed
        // the raw key words.
        static const u32 nonNullPixels[1] = {0};
        binding = {nonNullPixels, texParam, palette};
        for (u32 nextFormat = 1; nextFormat <= 7; ++nextFormat)
        for (u32 texDelta : std::array<u32, 4>{0, 1, 1u << 16, 1u << 29})
        for (u32 paletteDelta : std::array<u32, 3>{0, 1, 0x100})
        {
            const u32 nextTexParam =
                ((texParam ^ texDelta) & ~(7u << 26)) |
                (nextFormat << 26);
            const u32 nextPalette = palette ^ paletteDelta;
            if (!checkValidLookup(
                    binding, nextTexParam, nextPalette, comparisons))
            {
                std::fprintf(stderr,
                    "FAIL installed cached=%08x/%08x next=%08x/%08x\n",
                    texParam, palette, nextTexParam, nextPalette);
                return 1;
            }
        }
    }

    // Deterministic state-machine fuzz: every miss installs a non-null
    // binding before the next lookup, exactly like SetupPolygon.
    std::uint32_t random = 0x9E3779B9u;
    static const u32 nonNullPixels[1] = {0};
    binding = {};
    for (unsigned i = 0; i < 2000000; ++i)
    {
        random = random * 1664525u + 1013904223u;
        u32 texParam = random;
        texParam = (texParam & ~(7u << 26)) |
            (((random >> 16) % 7u + 1u) << 26);
        random = random * 1664525u + 1013904223u;
        const u32 palette = random;
        if (!checkValidLookup(binding, texParam, palette, comparisons))
        {
            std::fprintf(stderr, "FAIL fuzz iteration=%u\n", i);
            return 1;
        }
        if (!candidateMatch(binding, texParam, palette))
            binding = {nonNullPixels, texParam, palette};
    }

    std::printf(
        "H3D_TEXTURE_BINDING_VALIDITY_ORACLE_PASS comparisons=%llu\n",
        static_cast<unsigned long long>(comparisons));
    return 0;
}
