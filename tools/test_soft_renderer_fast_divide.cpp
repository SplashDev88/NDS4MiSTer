#include "GPU3D_Soft.h"

#include <cstdint>
#include <cstdio>

static bool testRasterBalanceController()
{
    using Controller = melonDS::NDS4MiSTerRasterBalanceController;
    Controller controller;
    if (controller.PrimaryPermille() != Controller::DefaultPrimaryPermille)
        return false;

    // Tiny frames do not contain a useful scheduling signal.
    if (controller.Observe(100000, 150000) ||
        controller.PrimaryPermille() != Controller::DefaultPrimaryPermille)
        return false;

    // The first real sample seeds the EMA; balanced and sub-hysteresis noise
    // must not move the boundary.
    if (controller.Observe(1000000, 1000000) ||
        controller.Observe(1000000, 1030000) ||
        controller.PrimaryPermille() != Controller::DefaultPrimaryPermille)
        return false;

    // A badly overloaded lower-band worker gives CPU0 more estimated work,
    // but the per-frame change remains tightly bounded.
    const auto beforeSlowSecondary = controller.PrimaryPermille();
    controller.Observe(1000000, 10000000);
    const auto afterSlowSecondary = controller.PrimaryPermille();
    if (afterSlowSecondary <= beforeSlowSecondary ||
        afterSlowSecondary - beforeSlowSecondary > 4)
        return false;
    for (unsigned i = 0; i < 1000; ++i)
        controller.Observe(1000000, 10000000);
    if (controller.PrimaryPermille() != Controller::MaximumPrimaryPermille)
        return false;

    // Reversing the imbalance moves back gradually and respects the lower
    // bound. Reset restores the measured neutral 50/50 starting point.
    auto previous = controller.PrimaryPermille();
    bool movedDown = false;
    for (unsigned i = 0; i < 128; ++i)
    {
        controller.Observe(10000000, 1000000);
        const auto current = controller.PrimaryPermille();
        if (current > previous + 4 || previous > current + 4)
            return false;
        movedDown = movedDown || current < previous;
        previous = current;
    }
    if (!movedDown)
        return false;
    for (unsigned i = 0; i < 1000; ++i)
        controller.Observe(10000000, 1000000);
    if (controller.PrimaryPermille() != Controller::MinimumPrimaryPermille)
        return false;
    controller.Reset();
    return controller.PrimaryPermille() == Controller::DefaultPrimaryPermille;
}

extern "C" __attribute__((noinline)) std::uint32_t
nds_test_div_u32_exact(std::uint32_t numerator, std::uint32_t denominator)
{
    return melonDS::NDS4MiSTerDivideU32Exact(numerator, denominator);
}

extern "C" __attribute__((noinline)) std::uint32_t
nds_test_scale_permille_ceil(std::uint32_t value, std::uint32_t permille)
{
    return melonDS::NDS4MiSTerScalePermilleCeil(value, permille);
}

int main()
{
    using Controller = melonDS::NDS4MiSTerRasterBalanceController;

    if (!testRasterBalanceController())
        return 5;

    constexpr std::uint32_t edgeCases[][2] = {
        {0u, 1u},
        {1u, 1u},
        {0xFFFFFFFFu, 1u},
        {0xFFFFFFFFu, 2u},
        {0xFFFFFFFFu, 3u},
        {0xFFFFFFFFu, 0x7FFFFFFFu},
        {0xFFFFFFFFu, 0x80000000u},
        {0xFFFFFFFFu, 0xFFFFFFFEu},
        {0xFFFFFFFFu, 0xFFFFFFFFu},
        {0x80000000u, 3u},
        {0x7FFFFFFFu, 0x80000000u},
    };
    for (const auto& values : edgeCases)
    {
        if (nds_test_div_u32_exact(values[0], values[1]) !=
                values[0] / values[1])
            return 4;
    }

    std::uint32_t state = 0x9e3779b9u;
    const auto randomWord = [&state]() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    };

    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        const auto numerator = randomWord();
        auto denominator = randomWord();
        if (denominator == 0) denominator = 1;
        if (nds_test_div_u32_exact(numerator, denominator) !=
                numerator / denominator)
            return 1;
    }

    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        const auto value = randomWord() % 100663297u;
        const auto permille = Controller::MinimumPrimaryPermille +
            randomWord() % (Controller::MaximumPrimaryPermille -
                Controller::MinimumPrimaryPermille + 1u);
        const auto expected = static_cast<std::uint32_t>(
            (static_cast<std::uint64_t>(value) * permille + 999u) / 1000u);
        if (nds_test_scale_permille_ceil(value, permille) != expected)
            return 6;
    }

    for (std::uint32_t divisor = 1;
         divisor <= melonDS::NDS4MiSTerRasterReciprocalLimit; ++divisor)
    {
        if (melonDS::NDS4MiSTerRasterReciprocal22[divisor] !=
                (1u << 22) / divisor ||
            melonDS::NDS4MiSTerRasterReciprocal18[divisor] !=
                (1u << 18) / divisor)
            return 2;
        if (divisor > 1)
        {
            const auto quotient = 0xFFFFFFFFu / divisor;
            const auto remainder = 0xFFFFFFFFu - quotient * divisor;
            const auto expected = quotient + (remainder == divisor - 1);
            if (melonDS::NDS4MiSTerRasterMagic[divisor] != expected)
                return 3;
        }
    }

    std::puts("PASS: exact VFP divide, raster tables, and balance controller");
    return 0;
}
