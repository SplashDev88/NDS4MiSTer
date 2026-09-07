#include "NDS4MiSTer_GXClipFastPath.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <random>

namespace
{

struct TestVertex
{
    std::int32_t Position[4];
    std::int32_t Color[3];
    std::uint8_t Other[36];
};

constexpr void normalizeColors(TestVertex& vertex) noexcept
{
    for (auto& color : vertex.Color)
        color = (color & ~0xFFF) + 0xFFF;
}

bool referenceUnchanged(
    std::array<TestVertex, 10>& vertices,
    int nverts,
    int clipstart) noexcept
{
    if (clipstart < 0 || clipstart > nverts)
        return false;

    // Model the observable result of the stock three-plane clipper only for
    // the case its vertex count and every non-color byte remain unchanged.
    for (int i = clipstart; i < nverts; ++i)
    {
        const std::int32_t w = vertices[i].Position[3];
        if (w == std::numeric_limits<std::int32_t>::min())
            return false;
        const std::int32_t negativeW = -w;
        for (int component = 2; component >= 0; --component)
        {
            if (vertices[i].Position[component] > w ||
                vertices[i].Position[component] < negativeW)
                return false;
        }
    }

    const auto before = vertices;
    for (int plane = 0; plane < 3; ++plane)
        for (int i = 0; i < nverts; ++i)
            normalizeColors(vertices[i]);
    return std::memcmp(before.data(), vertices.data(), sizeof(vertices)) == 0;
}

bool checkCase(
    const std::array<TestVertex, 10>& input,
    int nverts,
    int clipstart) noexcept
{
    auto referenceVertices = input;
    const bool expected = referenceUnchanged(
        referenceVertices, nverts, clipstart);
    const bool actual = melonDS::NDS4MiSTerGXClipPolygonIsUnchanged(
        input.data(), nverts, clipstart);
    if (expected != actual)
    {
        std::fprintf(
            stderr,
            "clip fast-path mismatch: nverts=%d clipstart=%d expected=%d actual=%d\n",
            nverts,
            clipstart,
            expected,
            actual);
        return false;
    }
    return true;
}

}

extern "C" __attribute__((noinline)) bool nds_test_clip_fast_path(
    const TestVertex* vertices,
    int nverts,
    int clipstart) noexcept
{
    return melonDS::NDS4MiSTerGXClipPolygonIsUnchanged(
        vertices, nverts, clipstart);
}

int main()
{
    std::array<TestVertex, 10> vertices{};
    for (auto& vertex : vertices)
    {
        vertex.Position[3] = 0x1000;
        vertex.Color[0] = 0x123FFF;
        vertex.Color[1] = -1;
        vertex.Color[2] = 0xFFF;
    }
    if (!checkCase(vertices, 3, 0) ||
        !checkCase(vertices, 4, 0) ||
        !checkCase(vertices, 4, 2))
        return 1;

    vertices[2].Position[0] = 0x1001;
    if (!checkCase(vertices, 3, 0)) return 2;
    vertices[2].Position[0] = 0;
    vertices[1].Color[1] &= ~1;
    if (!checkCase(vertices, 3, 0)) return 3;
    vertices[1].Color[1] |= 0xFFF;
    vertices[2].Position[3] = std::numeric_limits<std::int32_t>::min();
    if (!checkCase(vertices, 3, 0)) return 4;

    std::mt19937 random(0x51A7C11Fu);
    std::uint64_t cases = 0;
    for (int nverts = 0; nverts <= 10; ++nverts)
    {
        for (int clipstart = 0; clipstart <= nverts; ++clipstart)
        {
            for (unsigned iteration = 0; iteration < 100000; ++iteration)
            {
                for (auto& vertex : vertices)
                {
                    for (auto& position : vertex.Position)
                        position = static_cast<std::int32_t>(random());
                    for (auto& color : vertex.Color)
                        color = static_cast<std::int32_t>(random());
                    for (auto& byte : vertex.Other)
                        byte = static_cast<std::uint8_t>(random());

                    // Cover the real hot invariant on half the cases while
                    // retaining arbitrary colors/positions on the rest.
                    if (iteration & 1)
                    {
                        const std::int32_t w = static_cast<std::int32_t>(
                            1u + random() % 0x00FFFFFFu);
                        vertex.Position[3] = w;
                        for (int component = 0; component < 3; ++component)
                            vertex.Position[component] =
                                static_cast<std::int32_t>(random() %
                                    (2u * static_cast<std::uint32_t>(w) + 1u)) - w;
                        normalizeColors(vertex);
                    }
                }

                if (!checkCase(vertices, nverts, clipstart))
                    return 5;
                ++cases;
            }
        }
    }

    std::printf("PASS: %llu clip fast-path oracle cases\n",
        static_cast<unsigned long long>(cases));
    return 0;
}
