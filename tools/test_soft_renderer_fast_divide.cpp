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
    // but the per-frame correction remains tightly bounded.
    const auto beforeSlowSecondary = controller.PrimaryPermille();
    controller.Observe(1000000, 10000000);
    const auto afterSlowSecondary = controller.PrimaryPermille();
    if (afterSlowSecondary <= beforeSlowSecondary ||
        afterSlowSecondary - beforeSlowSecondary >
            Controller::MaximumCorrectionPermille)
        return false;
    // The old one-to-four-permille nudger needed at least 75 badly imbalanced
    // frames to cross this range. The ratio controller must converge within
    // about one second at 60 Hz.
    for (unsigned i = 0; i < 64; ++i)
        controller.Observe(1000000, 10000000);
    if (controller.PrimaryPermille() != Controller::MaximumPrimaryPermille)
        return false;

    // Reversing the imbalance moves back promptly but monotonically and
    // respects the lower bound. Reset restores the measured neutral 50/50
    // starting point.
    auto previous = controller.PrimaryPermille();
    bool movedDown = false;
    for (unsigned i = 0; i < 128; ++i)
    {
        controller.Observe(10000000, 1000000);
        const auto current = controller.PrimaryPermille();
        if (current > previous + Controller::MaximumCorrectionPermille ||
            previous > current + Controller::MaximumCorrectionPermille)
            return false;
        movedDown = movedDown || current < previous;
        previous = current;
    }
    if (!movedDown)
        return false;
    for (unsigned i = 0; i < 64; ++i)
        controller.Observe(10000000, 1000000);
    if (controller.PrimaryPermille() != Controller::MinimumPrimaryPermille)
        return false;
    controller.Reset();
    return controller.PrimaryPermille() == Controller::DefaultPrimaryPermille;
}

static std::int32_t referenceZSpan(
    std::int32_t z0, std::int32_t z1,
    std::int32_t x, std::int32_t xdiff,
    std::int32_t reciprocal)
{
    if (xdiff == 0 || z0 == z1) return z0;
    const bool ascending = z0 < z1;
    const std::int32_t base = ascending ? z0 : z1;
    std::int32_t displacement = ascending ? z1 - z0 : z0 - z1;
    const std::int32_t factor = ascending ? x : xdiff - x;
    displacement >>= 9;
    return base + static_cast<std::int32_t>(
        (static_cast<std::int64_t>(displacement) * factor * reciprocal) >> 13);
}

static bool testZSpanInterpolator()
{
    constexpr std::int32_t depths[] = {
        0, 1, 0x1FF, 0x200, 0x201, 0x123456, 0x7FFFFF, 0xFFFFFF,
    };
    for (std::int32_t xdiff = 0; xdiff <= 256; ++xdiff)
    {
        const std::int32_t reciprocal = xdiff == 0 ? 0 :
            static_cast<std::int32_t>(
                melonDS::NDS4MiSTerRasterReciprocal22[xdiff]);
        for (const auto z0 : depths)
        {
            for (const auto z1 : depths)
            {
                melonDS::NDS4MiSTerZSpanInterpolator span(
                    z0, z1, xdiff, reciprocal);
                for (std::int32_t x = 0; x <= xdiff; ++x)
                {
                    if (span.Interpolate(x, xdiff) !=
                            referenceZSpan(z0, z1, x, xdiff, reciprocal))
                        return false;
                }

                // Exercise clipped starts and holes, which must reinitialize
                // rather than incorrectly applying the consecutive update.
                if (xdiff > 2)
                {
                    const std::int32_t probes[] = {
                        xdiff / 2, 0, xdiff, 1, xdiff / 2 + 1,
                    };
                    for (const auto x : probes)
                    {
                        if (span.Interpolate(x, xdiff) !=
                                referenceZSpan(
                                    z0, z1, x, xdiff, reciprocal))
                            return false;
                    }
                }
            }
        }
    }

    std::uint32_t randomState = 0x6d2b79f5u;
    const auto randomWord = [&randomState]() {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return randomState;
    };
    for (unsigned iteration = 0; iteration < 100000; ++iteration)
    {
        const std::int32_t xdiff = 1 + randomWord() % 256;
        const std::int32_t reciprocal = static_cast<std::int32_t>(
            melonDS::NDS4MiSTerRasterReciprocal22[xdiff]);
        const std::int32_t z0 = randomWord() & 0xFFFFFF;
        const std::int32_t z1 = randomWord() & 0xFFFFFF;
        melonDS::NDS4MiSTerZSpanInterpolator span(
            z0, z1, xdiff, reciprocal);
        std::int32_t x = randomWord() % (xdiff + 1);
        for (unsigned probe = 0; probe < 8; ++probe)
        {
            if (span.Interpolate(x, xdiff) !=
                    referenceZSpan(z0, z1, x, xdiff, reciprocal))
                return false;
            x = (probe & 1) && x < xdiff ? x + 1 :
                static_cast<std::int32_t>(randomWord() % (xdiff + 1));
        }
    }
    return true;
}

static bool referenceAdvancePerspectiveFactor(
    std::uint32_t& factor, std::int32_t& denominator,
    std::int32_t& remainder, std::int32_t numeratorStep,
    std::int32_t denominatorStep)
{
    denominator += denominatorStep;
    if (denominator == 0)
    {
        factor = 0;
        remainder = 0;
        return false;
    }

    remainder += numeratorStep -
        static_cast<std::int32_t>(factor) * denominatorStep;
    while (remainder >= denominator)
    {
        ++factor;
        remainder -= denominator;
    }
    while (remainder < 0 && factor != 0)
    {
        --factor;
        remainder += denominator;
    }
    return true;
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

extern "C" __attribute__((noinline)) std::uint32_t
nds_test_div_prepared_u32(
    std::uint32_t numerator, std::uint32_t denominator)
{
    return melonDS::NDS4MiSTerDividePreparedU32(
        numerator, denominator,
        denominator == 1 ? 0u :
            melonDS::NDS4MiSTerRasterMagic[denominator]);
}

int main()
{
    using Controller = melonDS::NDS4MiSTerRasterBalanceController;

    if (!testRasterBalanceController())
        return 5;
    if (!testZSpanInterpolator())
        return 9;

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
        const std::uint32_t denominator = 1u + randomWord() % 512u;
        const std::uint32_t numerator = randomWord() & 0x00FFFFFFu;
        if (nds_test_div_prepared_u32(numerator, denominator) !=
                numerator / denominator)
            return 14;
    }

    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        const std::uint32_t denominator =
            1u + randomWord() % 16000000u;
        const std::uint32_t quotient = randomWord() % 257u;
        const std::uint32_t remainder = randomWord() % denominator;
        const std::uint32_t numerator = static_cast<std::uint32_t>(
            static_cast<std::uint64_t>(quotient) * denominator +
            remainder);
        if (melonDS::NDS4MiSTerDivideFactorDeltaExact(
                numerator, denominator) != numerator / denominator)
            return 12;
    }

    constexpr std::uint32_t perspectiveDenominators[] = {
        1u, 255u, 256u, 65535u, 65536u, 0x00FFFF00u,
    };
    for (const auto denominator : perspectiveDenominators)
    {
        const std::uint32_t exactEndpoint = 256u * denominator;
        const std::uint32_t justBelowEndpoint = exactEndpoint - 1u;
        if (melonDS::NDS4MiSTerDivideFactorDeltaExact(
                exactEndpoint, denominator) != 256u ||
            melonDS::NDS4MiSTerDivideFactorDeltaExact(
                justBelowEndpoint, denominator) != 255u)
            return 13;
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

    // Mario 64 DS reaches a degenerate perspective edge whose incremental
    // denominator transitions from nonzero to zero. It must use melonDS's
    // defined zero factor instead of entering a non-progressing correction
    // loop. Also verify an ordinary incremental step remains exact.
    std::uint32_t factor = 10;
    std::int32_t denominator = 5;
    std::int32_t remainder = 3;
    if (melonDS::NDS4MiSTerAdvancePerspectiveFactor(
            factor, denominator, remainder, 100, -5) ||
        factor != 0 || denominator != 0 || remainder != 0)
        return 7;
    factor = 10;
    denominator = 100;
    remainder = 0;
    if (!melonDS::NDS4MiSTerAdvancePerspectiveFactor(
            factor, denominator, remainder, 1000, 10) ||
        factor != 18 || denominator != 110 || remainder != 20)
        return 8;
    factor = 18;
    denominator = 100;
    remainder = 0;
    if (!melonDS::NDS4MiSTerAdvancePerspectiveFactorFast(
            factor, denominator, remainder, -1000, 10) ||
        factor != 7 || denominator != 110 || remainder != 30)
        return 9;
    factor = 10;
    denominator = 100;
    remainder = 0;
    if (!melonDS::NDS4MiSTerAdvancePerspectiveFactorFast(
            factor, denominator, remainder, 1000, 10) ||
        factor != 18 || denominator != 110 || remainder != 20)
        return 10;

    std::uint32_t perspectiveRandom = 0x9e3779b9u;
    const auto nextPerspectiveRandom = [&perspectiveRandom]() {
        perspectiveRandom ^= perspectiveRandom << 13;
        perspectiveRandom ^= perspectiveRandom >> 17;
        perspectiveRandom ^= perspectiveRandom << 5;
        return perspectiveRandom;
    };
    for (unsigned iteration = 0; iteration < 10000; ++iteration)
    {
        const std::int32_t initialDenominator =
            1 + static_cast<std::int32_t>(
                nextPerspectiveRandom() % 1000000u);
        const std::int32_t stepBound = std::min<std::int32_t>(
            initialDenominator - 1, 4096);
        const std::int32_t denominatorStep = stepBound == 0 ? 0 :
            static_cast<std::int32_t>(
                nextPerspectiveRandom() %
                    static_cast<std::uint32_t>(stepBound * 2 + 1)) -
                stepBound;
        const std::int32_t nextDenominator =
            initialDenominator + denominatorStep;
        const std::uint32_t initialFactor =
            nextPerspectiveRandom() % 257u;
        const std::int32_t initialRemainder =
            static_cast<std::int32_t>(
                nextPerspectiveRandom() %
                    static_cast<std::uint32_t>(initialDenominator));
        const std::int32_t quotientDelta =
            static_cast<std::int32_t>(nextPerspectiveRandom() % 129u) - 64;
        const std::int32_t targetRemainder =
            quotientDelta * nextDenominator +
            static_cast<std::int32_t>(
                nextPerspectiveRandom() %
                    static_cast<std::uint32_t>(nextDenominator));
        const std::int32_t numeratorStep = targetRemainder -
            initialRemainder +
            static_cast<std::int32_t>(initialFactor) * denominatorStep;

        std::uint32_t referenceFactor = initialFactor;
        std::int32_t referenceDenominator = initialDenominator;
        std::int32_t referenceRemainder = initialRemainder;
        std::uint32_t fastFactor = initialFactor;
        std::int32_t fastDenominator = initialDenominator;
        std::int32_t fastRemainder = initialRemainder;
        const bool referenceResult =
            referenceAdvancePerspectiveFactor(
                referenceFactor, referenceDenominator, referenceRemainder,
                numeratorStep, denominatorStep);
        const bool fastResult =
            melonDS::NDS4MiSTerAdvancePerspectiveFactorFast(
                fastFactor, fastDenominator, fastRemainder,
                numeratorStep, denominatorStep);
        if (referenceResult != fastResult ||
            referenceFactor != fastFactor ||
            referenceDenominator != fastDenominator ||
            referenceRemainder != fastRemainder)
            return 11;
    }

    std::puts("PASS: exact VFP divide, raster tables, and balance controller");
    return 0;
}
