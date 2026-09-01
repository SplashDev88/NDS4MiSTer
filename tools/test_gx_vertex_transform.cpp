#include "NDS4MiSTer_GXVertexTransform.h"

#include <array>
#include <cstdint>
#include <cstdio>
#include <random>

namespace
{

bool Verify(
    const std::array<std::int32_t, 4>& vertex,
    const std::array<std::int32_t, 16>& matrix)
{
    std::array<std::int32_t, 4> expected{};
    std::array<std::int32_t, 4> actual{};
    melonDS::NDS4MiSTerGXTransformVertex4Scalar(
        vertex.data(), matrix.data(), expected.data());
    melonDS::NDS4MiSTerGXTransformVertex4(
        vertex.data(), matrix.data(), actual.data());
    if (actual == expected) return true;

    std::fprintf(stderr,
        "mismatch: got {%d,%d,%d,%d}, expected {%d,%d,%d,%d}\n",
        actual[0], actual[1], actual[2], actual[3],
        expected[0], expected[1], expected[2], expected[3]);
    return false;
}

}

int main()
{
    const std::array<std::array<std::int32_t, 4>, 5> vertices = {{
        {{0, 0, 0, 0x1000}},
        {{1, -1, 1, 0x1000}},
        {{32767, 32767, 32767, 0x1000}},
        {{-32768, -32768, -32768, 0x1000}},
        {{32767, -32768, 12345, 0x1000}},
    }};
    const std::array<std::array<std::int32_t, 16>, 3> matrices = {{
        {{0x1000, 0, 0, 0, 0, 0x1000, 0, 0,
          0, 0, 0x1000, 0, 0, 0, 0, 0x1000}},
        {{-0x1000, 0x1000, -0x1000, 0x1000,
          0x2000, -0x2000, 0x2000, -0x2000,
          0x4000, 0x4000, -0x4000, -0x4000,
          0x100000, -0x100000, 0x7ffff, -0x7ffff}},
        {{0x7fffff, -0x7fffff, 0x555555, -0x555555,
          -0x400000, 0x400000, -0x333333, 0x333333,
          0x111111, -0x111111, 0x222222, -0x222222,
          0x1000, 0x1000, -0x1000, -0x1000}},
    }};
    for (const auto& vertex : vertices)
        for (const auto& matrix : matrices)
            if (!Verify(vertex, matrix)) return 1;

    std::mt19937 generator(0x4e445334U);
    std::uniform_int_distribution<std::int32_t> vertexValue(-32768, 32767);
    std::uniform_int_distribution<std::int32_t> matrixValue(
        -0x00ffffff, 0x00ffffff);
    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        std::array<std::int32_t, 4> vertex = {{
            vertexValue(generator), vertexValue(generator),
            vertexValue(generator), 0x1000}};
        std::array<std::int32_t, 16> matrix{};
        for (auto& value : matrix) value = matrixValue(generator);
        if (!Verify(vertex, matrix)) return 1;
    }

    std::puts("PASS: 1,000,015 exact GX vertex transforms");
    return 0;
}
