#include "GPU3D_Soft.h"

#include <array>
#include <climits>
#include <cstdint>
#include <cstdio>

using melonDS::s32;
using melonDS::u32;

namespace
{

struct Result
{
    bool Passed;
    u32 PixelAddress;
    bool PlotLower;
};

constexpr bool referenceDepthPass(
    s32 destinationZ, s32 sourceZ, u32 destinationAttr) noexcept
{
    return sourceZ < destinationZ ||
        (sourceZ == destinationZ &&
         (destinationAttr & 0x00400010u) == 0x00000010u);
}

Result referenceResult(
    const std::array<u32, 4>& depths,
    const std::array<u32, 4>& attributes,
    u32 bufferSize, u32 initialAddress, s32 sourceZ,
    u32 alpha, u32 alphaRef) noexcept
{
    u32 pixelAddress = initialAddress;
    u32 destinationAttr = attributes[pixelAddress];
    if (!referenceDepthPass(
            static_cast<s32>(depths[pixelAddress]),
            sourceZ, destinationAttr))
    {
        if (!(destinationAttr & 0xFu) || pixelAddress >= bufferSize)
            return {false, pixelAddress, false};

        pixelAddress += bufferSize;
        destinationAttr = attributes[pixelAddress];
        if (!referenceDepthPass(
                static_cast<s32>(depths[pixelAddress]),
                sourceZ, destinationAttr))
            return {false, pixelAddress, false};
    }

    const bool visible = alpha > alphaRef;
    const bool plotLower = visible && alpha != 31 &&
        (destinationAttr & 0xFu) && pixelAddress < bufferSize;
    return {true, pixelAddress, plotLower};
}

Result candidateResult(
    const std::array<u32, 4>& depths,
    const std::array<u32, 4>& attributes,
    u32 bufferSize, u32 initialAddress, s32 sourceZ,
    u32 alpha, u32 alphaRef) noexcept
{
    u32 pixelAddress = initialAddress;
    if (!melonDS::NDS4MiSTerSelectCachedDepthPixel(
            depths.data(), attributes.data(), bufferSize,
            sourceZ, pixelAddress))
        return {false, pixelAddress, false};

    const bool visible = alpha > alphaRef;
    const bool plotLower = visible && alpha != 31 &&
        melonDS::NDS4MiSTerCachedPixelHasLowerLayer(
            attributes.data(), bufferSize, pixelAddress);
    return {true, pixelAddress, plotLower};
}

bool sameResult(const Result& lhs, const Result& rhs) noexcept
{
    return lhs.Passed == rhs.Passed &&
        lhs.PixelAddress == rhs.PixelAddress &&
        lhs.PlotLower == rhs.PlotLower;
}

extern "C" __attribute__((noinline)) bool
nds_test_cached_depth_select(
    const u32* depths, const u32* attributes, u32 bufferSize,
    s32 sourceZ, u32* pixelAddress) noexcept
{
    return melonDS::NDS4MiSTerSelectCachedDepthPixel(
        depths, attributes, bufferSize, sourceZ, *pixelAddress);
}

bool proveStrictNearerSkipsAttributes(std::uint64_t& comparisons)
{
    const std::array<u32, 1> depths = {1};
    u32 pixelAddress = 0;
    ++comparisons;
    // A null attribute pointer is intentional: the strict-nearer result is
    // independent of every attribute bit and must return before any load.
    return nds_test_cached_depth_select(
        depths.data(), nullptr, 1, 0, &pixelAddress) &&
        pixelAddress == 0;
}

bool exhaustiveBoundaryDomain(std::uint64_t& comparisons)
{
    constexpr s32 depthValues[] = {
        INT_MIN, -0x100, -1, 0, 1, 0x100, INT_MAX};
    constexpr u32 attributeValues[] = {
        0x00000000u,
        0x00000001u,
        0x0000000Fu,
        0x00000010u,
        0x00000011u,
        0x00400000u,
        0x0040000Fu,
        0x00400010u,
        0x0040001Fu,
        0xFFFFFFFFu,
    };
    constexpr u32 alphaValues[] = {0, 1, 15, 30, 31};
    constexpr u32 alphaReferences[] = {0, 15, 30, 31};

    for (u32 initialAddress = 0; initialAddress < 4; ++initialAddress)
    for (s32 sourceZ : depthValues)
    for (s32 topZ : depthValues)
    for (s32 lowerZ : depthValues)
    for (u32 topAttr : attributeValues)
    for (u32 lowerAttr : attributeValues)
    for (u32 alpha : alphaValues)
    for (u32 alphaRef : alphaReferences)
    {
        std::array<u32, 4> depths = {
            static_cast<u32>(topZ),
            static_cast<u32>(topZ) ^ 0x55u,
            static_cast<u32>(lowerZ),
            static_cast<u32>(lowerZ) ^ 0xAAu};
        std::array<u32, 4> attributes = {
            topAttr, topAttr ^ 0x00A50005u,
            lowerAttr, lowerAttr ^ 0x005A000Au};
        // Make the selected address carry the exact top/lower pair under test.
        depths[initialAddress] = static_cast<u32>(topZ);
        attributes[initialAddress] = topAttr;
        if (initialAddress < 2)
        {
            depths[initialAddress + 2] = static_cast<u32>(lowerZ);
            attributes[initialAddress + 2] = lowerAttr;
        }

        const Result expected = referenceResult(
            depths, attributes, 2, initialAddress, sourceZ,
            alpha, alphaRef);
        const Result actual = candidateResult(
            depths, attributes, 2, initialAddress, sourceZ,
            alpha, alphaRef);
        ++comparisons;
        if (!sameResult(expected, actual))
        {
            std::fprintf(stderr,
                "FAIL boundary addr=%u src=%d topz=%d lowerz=%d "
                "topattr=%08x lowerattr=%08x alpha=%u ref=%u "
                "expected=%u/%u/%u actual=%u/%u/%u\n",
                initialAddress, sourceZ, topZ, lowerZ,
                topAttr, lowerAttr, alpha, alphaRef,
                expected.Passed, expected.PixelAddress,
                expected.PlotLower, actual.Passed,
                actual.PixelAddress, actual.PlotLower);
            return false;
        }
    }
    return true;
}

bool randomDomain(std::uint64_t& comparisons)
{
    u32 randomState = 0xD37A9E51u;
    const auto randomWord = [&randomState]() {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return randomState;
    };

    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        std::array<u32, 4> depths;
        std::array<u32, 4> attributes;
        for (unsigned layer = 0; layer < 4; ++layer)
        {
            depths[layer] = randomWord();
            attributes[layer] = randomWord();
        }
        const u32 initialAddress = randomWord() & 3u;
        const s32 sourceZ = static_cast<s32>(randomWord());
        const u32 alpha = randomWord() & 31u;
        const u32 alphaRef = randomWord() & 31u;
        const Result expected = referenceResult(
            depths, attributes, 2, initialAddress, sourceZ,
            alpha, alphaRef);
        const Result actual = candidateResult(
            depths, attributes, 2, initialAddress, sourceZ,
            alpha, alphaRef);
        ++comparisons;
        if (!sameResult(expected, actual))
        {
            std::fprintf(stderr,
                "FAIL random iteration=%u addr=%u src=%d "
                "expected=%u/%u/%u actual=%u/%u/%u\n",
                iteration, initialAddress, sourceZ,
                expected.Passed, expected.PixelAddress,
                expected.PlotLower, actual.Passed,
                actual.PixelAddress, actual.PlotLower);
            return false;
        }
    }
    return true;
}

} // namespace

int main()
{
    std::uint64_t comparisons = 0;
    if (!proveStrictNearerSkipsAttributes(comparisons)) return 1;
    if (!exhaustiveBoundaryDomain(comparisons)) return 2;
    if (!randomDomain(comparisons)) return 3;
    std::printf(
        "PASS: cached depth lazy-attribute oracle comparisons=%llu "
        "strict-nearer-null-attr=1\n",
        static_cast<unsigned long long>(comparisons));
    return 0;
}
