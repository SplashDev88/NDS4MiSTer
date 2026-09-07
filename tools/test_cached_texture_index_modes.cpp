#include "GPU3D_Soft.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

extern "C" __attribute__((noinline)) std::uint32_t
nds_test_cached_texture_index_modes(
    std::int16_t textureS, std::int16_t textureT,
    std::int32_t width, std::int32_t height,
    std::uint32_t wrapFlags)
{
    return melonDS::NDS4MiSTerCachedTextureIndex(
        textureS, textureT, width, height, width - 1, height - 1,
        static_cast<std::uint8_t>(wrapFlags),
        static_cast<std::uint32_t>(__builtin_ctz(width)));
}

extern "C" __attribute__((noinline)) std::uint32_t
nds_test_cached_texture_index_mode0(
    std::int16_t textureS, std::int16_t textureT,
    std::int32_t width, std::int32_t height)
{
    return melonDS::NDS4MiSTerCachedTextureIndexForMode<0x0u>(
        textureS, textureT, width, height, width - 1, height - 1, 0,
        static_cast<std::uint32_t>(__builtin_ctz(width)));
}

extern "C" __attribute__((noinline)) std::uint32_t
nds_test_cached_texture_index_mode3(
    std::int16_t textureS, std::int16_t textureT,
    std::int32_t width, std::int32_t height)
{
    return melonDS::NDS4MiSTerCachedTextureIndexForMode<0x3u>(
        textureS, textureT, width, height, width - 1, height - 1, 3,
        static_cast<std::uint32_t>(__builtin_ctz(width)));
}

extern "C" __attribute__((noinline)) std::uint32_t
nds_test_cached_texture_index_generic(
    std::int16_t textureS, std::int16_t textureT,
    std::int32_t width, std::int32_t height,
    std::uint32_t wrapFlags)
{
    return melonDS::NDS4MiSTerCachedTextureIndexForMode<0xFFu>(
        textureS, textureT, width, height, width - 1, height - 1,
        static_cast<std::uint8_t>(wrapFlags),
        static_cast<std::uint32_t>(__builtin_ctz(width)));
}

static std::uint32_t referenceTextureIndex(
    std::int16_t textureS, std::int16_t textureT,
    std::int32_t width, std::int32_t height,
    std::uint32_t wrapFlags)
{
    const std::int32_t widthMask = width - 1;
    const std::int32_t heightMask = height - 1;
    std::int32_t s = textureS >> 4;
    std::int32_t t = textureT >> 4;

    if (wrapFlags & 0x1u)
    {
        if (wrapFlags & 0x4u)
            s = (s & width) ? widthMask - (s & widthMask) :
                (s & widthMask);
        else
            s &= widthMask;
    }
    else
        s = std::min(std::max(s, 0), widthMask);

    if (wrapFlags & 0x2u)
    {
        if (wrapFlags & 0x8u)
            t = (t & height) ? heightMask - (t & heightMask) :
                (t & heightMask);
        else
            t &= heightMask;
    }
    else
        t = std::min(std::max(t, 0), heightMask);

    return (static_cast<std::uint32_t>(t) << __builtin_ctz(width)) +
        static_cast<std::uint32_t>(s);
}

static bool compareOne(
    std::int16_t textureS, std::int16_t textureT,
    std::int32_t width, std::int32_t height,
    std::uint32_t wrapFlags, std::uint64_t& hash)
{
    const std::uint32_t expected = referenceTextureIndex(
        textureS, textureT, width, height, wrapFlags);
    const std::uint32_t actual = nds_test_cached_texture_index_modes(
        textureS, textureT, width, height, wrapFlags);
    const std::uint32_t dispatched = wrapFlags == 0 ?
        nds_test_cached_texture_index_mode0(
            textureS, textureT, width, height) :
        wrapFlags == 3 ?
            nds_test_cached_texture_index_mode3(
                textureS, textureT, width, height) :
            nds_test_cached_texture_index_generic(
                textureS, textureT, width, height, wrapFlags);
    if (actual != expected || dispatched != expected ||
        actual >= static_cast<std::uint32_t>(width * height))
    {
        std::fprintf(stderr,
            "FAIL s=%d t=%d width=%d height=%d flags=%u "
            "actual=%u dispatched=%u expected=%u\n",
            textureS, textureT, width, height, wrapFlags,
            actual, dispatched, expected);
        return false;
    }
    hash ^= actual;
    hash *= UINT64_C(1099511628211);
    return true;
}

int main()
{
    constexpr std::array<std::int16_t, 22> boundaries {{
        INT16_MIN, -32767, -16385, -16384, -16383, -1025, -1024,
        -1023, -129, -128, -127, -17, -16, -15, -1, 0, 1, 15,
        16, 17, 16383, INT16_MAX
    }};
    std::uint64_t comparisons = 0;
    std::uint64_t hash = UINT64_C(1469598103934665603);

    // Exhaust every signed 16-bit coordinate for both common combined
    // modes and every legal DS texture dimension. Exercise each axis
    // independently so no sampled value can hide a normalization mismatch.
    for (std::int32_t size = 8; size <= 1024; size <<= 1)
        for (const std::uint32_t flags : {0u, 3u})
            for (std::int32_t source = INT16_MIN;
                 source <= INT16_MAX; ++source)
            {
                if (!compareOne(
                        static_cast<std::int16_t>(source), 0,
                        size, size, flags, hash) ||
                    !compareOne(
                        0, static_cast<std::int16_t>(source),
                        size, size, flags, hash))
                    return EXIT_FAILURE;
                comparisons += 2;
            }

    // Cover every mixed/flip mode at signed and texture-boundary values.
    for (std::int32_t width = 8; width <= 1024; width <<= 1)
        for (std::int32_t height = 8; height <= 1024; height <<= 1)
            for (std::uint32_t flags = 0; flags < 16; ++flags)
                for (const std::int16_t s : boundaries)
                    for (const std::int16_t t : boundaries)
                    {
                        if (!compareOne(s, t, width, height, flags, hash))
                            return EXIT_FAILURE;
                        ++comparisons;
                    }

    std::uint32_t randomState = 0x243f6a88u;
    const auto randomWord = [&randomState]() {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return randomState;
    };
    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        const std::int32_t width = 1 << (3 + randomWord() % 8);
        const std::int32_t height = 1 << (3 + randomWord() % 8);
        const auto s = static_cast<std::int16_t>(randomWord());
        const auto t = static_cast<std::int16_t>(randomWord());
        const std::uint32_t flags = randomWord() & 0xFu;
        if (!compareOne(s, t, width, height, flags, hash))
            return EXIT_FAILURE;
        ++comparisons;
    }

    std::printf(
        "H3D_CACHED_TEXTURE_INDEX_MODES_PASS comparisons=%llu "
        "hash=%016llx\n",
        static_cast<unsigned long long>(comparisons),
        static_cast<unsigned long long>(hash));
    return EXIT_SUCCESS;
}
