#include "NDS4MiSTer_GXClipMath.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>

namespace
{

struct Input
{
    std::uint32_t NumeratorX;
    std::uint32_t NumeratorY;
    std::uint32_t Denominator;
};

struct Quotients
{
    std::uint32_t X;
    std::uint32_t Y;
};

constexpr std::size_t InputCount = 1u << 15;
constexpr unsigned Passes = 64;
std::array<Input, InputCount> Inputs {};
volatile std::uint64_t Sink = 0;

extern "C" __attribute__((noinline)) Quotients oldViewportDivide(
    std::uint32_t numeratorX,
    std::uint32_t numeratorY,
    std::uint32_t denominator)
{
    return {numeratorX / denominator, numeratorY / denominator};
}

extern "C" __attribute__((noinline)) Quotients fastViewportDivide(
    std::uint32_t numeratorX,
    std::uint32_t numeratorY,
    std::uint32_t denominator)
{
    const auto result = melonDS::NDS4MiSTerGXDivideViewportPair(
        numeratorX, numeratorY, denominator);
    return {result.X, result.Y};
}

void makeInputs()
{
    std::uint32_t state = 0x243f6a88u;
    const auto randomWord = [&state]() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    };

    for (auto& input : Inputs)
    {
        const std::uint32_t w = 1u + randomWord() % 0x00FFFFFFu;
        std::uint32_t coordinateX = randomWord() % (2u * w + 1u);
        std::uint32_t coordinateY = randomWord() % (2u * w + 1u);
        std::uint32_t denominator = w;
        if (w > 0xFFFFu)
        {
            coordinateX >>= 1;
            coordinateY >>= 1;
            denominator >>= 1;
        }
        denominator <<= 1;
        const std::uint32_t viewportWidth = randomWord() % 512u;
        const std::uint32_t viewportHeight = randomWord() % 256u;
        input = {
            coordinateX * viewportWidth,
            coordinateY * viewportHeight,
            denominator};
    }
}

template<typename Divider>
std::uint64_t measure(Divider divider)
{
    std::uint64_t checksum = 0;
    const auto begin = std::chrono::steady_clock::now();
    for (unsigned pass = 0; pass < Passes; ++pass)
    {
        for (const auto& input : Inputs)
        {
            const auto result = divider(
                input.NumeratorX, input.NumeratorY, input.Denominator);
            checksum += result.X + 3u * result.Y;
        }
    }
    const auto end = std::chrono::steady_clock::now();
    Sink = checksum;
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(end - begin)
            .count());
}

} // namespace

int main()
{
    makeInputs();
    for (const auto& input : Inputs)
    {
        const auto oldResult = oldViewportDivide(
            input.NumeratorX, input.NumeratorY, input.Denominator);
        const auto fastResult = fastViewportDivide(
            input.NumeratorX, input.NumeratorY, input.Denominator);
        if (oldResult.X != fastResult.X || oldResult.Y != fastResult.Y)
            return 1;
    }

    // Warm both instruction/data paths before taking alternating samples.
    measure(oldViewportDivide);
    measure(fastViewportDivide);
    std::array<std::uint64_t, 7> oldSamples {};
    std::array<std::uint64_t, 7> fastSamples {};
    for (std::size_t sample = 0; sample < oldSamples.size(); ++sample)
    {
        if ((sample & 1u) == 0)
        {
            oldSamples[sample] = measure(oldViewportDivide);
            fastSamples[sample] = measure(fastViewportDivide);
        }
        else
        {
            fastSamples[sample] = measure(fastViewportDivide);
            oldSamples[sample] = measure(oldViewportDivide);
        }
    }
    std::sort(oldSamples.begin(), oldSamples.end());
    std::sort(fastSamples.begin(), fastSamples.end());
    const auto oldMedian = oldSamples[oldSamples.size() / 2];
    const auto fastMedian = fastSamples[fastSamples.size() / 2];
    const double speedup = static_cast<double>(oldMedian) / fastMedian;
    std::printf(
        "viewport_pair_calls=%zu old_median_ns=%llu "
        "fast_median_ns=%llu speedup=%.3fx checksum=%llu\n",
        InputCount * static_cast<std::size_t>(Passes),
        static_cast<unsigned long long>(oldMedian),
        static_cast<unsigned long long>(fastMedian),
        speedup,
        static_cast<unsigned long long>(Sink));
    return 0;
}
