#include "GPU3D_Soft.h"
#include <cstdio>
#include <cstring>

using namespace melonDS;

extern "C" __attribute__((noinline)) void modulate4(
    const u32* texels, const u32* vertices, u32* output)
{
    NDS4MiSTerModulateCachedOpaquePixels4(texels, vertices, output);
}

static bool check(const u32* texels, const u32* vertices)
{
    u32 expected[4], output[4], inPlace[4], vertexOutput[4];
    for (unsigned i = 0; i < 4; ++i)
        expected[i] = NDS4MiSTerModulateCachedOpaquePixel(texels[i], vertices[i]);
#if defined(__arm__) && defined(__ARM_NEON)
    bool allOpaque = true;
    for (unsigned i = 0; i < 4; ++i)
        allOpaque &= (texels[i] >> 24) == 31;
    if (NDS4MiSTerAllCachedTexelsOpaque4(vld1q_u32(texels)) != allOpaque)
        return false;
#endif
    modulate4(texels, vertices, output);
    if (std::memcmp(output, expected, sizeof(output))) return false;
    std::memcpy(inPlace, texels, sizeof(inPlace));
    modulate4(inPlace, vertices, inPlace);
    if (std::memcmp(inPlace, expected, sizeof(output))) return false;
    std::memcpy(vertexOutput, vertices, sizeof(vertexOutput));
    modulate4(texels, vertexOutput, vertexOutput);
    return !std::memcmp(vertexOutput, expected, sizeof(output));
}

int main()
{
    unsigned long long comparisons = 0;
    for (u32 mask = 0; mask < 16; ++mask)
    for (u32 otherAlpha : {0u, 1u, 30u, 32u, 127u, 255u})
    {
        u32 texels[4], vertices[4];
        for (unsigned lane = 0; lane < 4; ++lane)
        {
            texels[lane] = (((mask & (1u << lane)) ? 31u : otherAlpha) << 24) |
                (0xffffffu - lane);
            vertices[lane] = 0x0021323f;
        }
        if (!check(texels, vertices)) return 1;
        comparisons += 12;
    }
    for (u32 alpha = 0; alpha < 256; ++alpha)
    for (u32 texel = 0; texel < 64; ++texel)
    for (u32 vertex = 0; vertex < 64; ++vertex)
    {
        u32 texels[4], vertices[4];
        for (u32 lane = 0; lane < 4; ++lane)
        {
            texels[lane] = (((alpha + lane) & 255) << 24) | texel |
                (((texel + 17 * lane) & 63) << 8) |
                (((texel + 29 * lane) & 63) << 16);
            vertices[lane] = vertex | (((vertex + 11 * lane) & 63) << 8) |
                (((vertex + 23 * lane) & 63) << 16);
        }
        if (!check(texels, vertices))
        {
            std::puts("FAIL: exhaustive modulation/alpha comparison");
            return 1;
        }
        comparisons += 12;
    }
    u32 state = 0x78384ef1;
    auto random = [&]() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    };
    for (unsigned i = 0; i < 1000000; ++i)
    {
        u32 texels[4], vertices[4];
        for (unsigned lane = 0; lane < 4; ++lane)
        {
            texels[lane] = random();
            vertices[lane] = random();
        }
        if (!check(texels, vertices))
        {
            std::puts("FAIL: random packed input comparison");
            return 1;
        }
        comparisons += 12;
    }
#if defined(__arm__) && defined(__ARM_NEON)
    unsigned long long translucentPixels = 0;
    for (u32 polygonAlpha = 0; polygonAlpha < 31; ++polygonAlpha)
    for (u32 textureAlpha = 0; textureAlpha < 32; ++textureAlpha)
    for (u32 tc = 0; tc < 64; ++tc)
    for (u32 vc = 0; vc < 64; ++vc)
    {
        u32 texels[4], vertices[4], expected[4], actual[4];
        for (u32 lane = 0; lane < 4; ++lane)
        {
            const u32 ta = (textureAlpha + lane) & 31u;
            const u32 tr = (tc + 13 * lane) & 63u;
            const u32 tg = (tc + 29 * lane) & 63u;
            const u32 tb = (tc + 47 * lane) & 63u;
            const u32 vr = (vc + 17 * lane) & 63u;
            const u32 vg = (vc + 31 * lane) & 63u;
            const u32 vb = (vc + 51 * lane) & 63u;
            texels[lane] = tr | (tg << 8) | (tb << 16) | (ta << 24);
            vertices[lane] = vr | (vg << 8) | (vb << 16) | 0xa5000000u;
            expected[lane] = (((tr+1)*(vr+1)-1) >> 6) |
                ((((tg+1)*(vg+1)-1) >> 6) << 8) |
                ((((tb+1)*(vb+1)-1) >> 6) << 16) |
                ((((ta+1)*(polygonAlpha+1)-1) >> 5) << 24);
        }
        vst1q_u32(actual, NDS4MiSTerModulateCachedTranslucentVector4(
            vld1q_u32(texels), vld1q_u32(vertices), polygonAlpha));
        if (std::memcmp(actual, expected, sizeof(actual)))
        {
            std::puts("FAIL: independent translucent RGB/alpha vector oracle");
            return 1;
        }
        translucentPixels += 4;
    }
    std::printf("TRANSLUCENT_VECTOR_PASS pixels=%llu alpha_pairs=992\n",
        translucentPixels);
    for (unsigned trial = 0; trial < 200000; ++trial)
    {
        // Four-byte aligned, deliberately not sixteen-byte aligned texture.
        alignas(16) u32 storage[34];
        u32* texture = storage + 1;
        for (unsigned i = 0; i < 32; ++i) texture[i] = random();
        u32 indices[4], actual[4], expected[4], vertices[4];
        for (unsigned lane = 0; lane < 4; ++lane)
        {
            indices[lane] = random() & 31u;
            if ((trial & 15u) == 0) indices[lane] = lane & 1u ? 31 : 0;
            expected[lane] = texture[indices[lane]];
            vertices[lane] = random();
        }
        vst1q_u32(actual, NDS4MiSTerGatherCachedTexels4(texture, indices));
        if (std::memcmp(actual, expected, sizeof(actual)) || !check(actual, vertices))
            return 1;
        comparisons += 16;
    }
    std::puts("VECTOR_TEXELS_PASS gather_cases=200000 all_alpha_masks=16");
#endif
    std::printf("MODULATE4_PASS comparisons=%llu alias_modes=3\n", comparisons);
}
