// Test-only -fno-access-control exposes the production interpolator. Compare
// its optimized span state with the original per-value interpolation, without
// adding public renderer APIs or copying the candidate math into the oracle.
#include "GPU3D_Soft.h"
#include <array>
#include <cstdio>
#include <new>

using namespace melonDS;
using Interp = SoftRenderer3D::Interpolator<0>;
using Span = Interp::SpanInterpolator;

#if defined(__arm__) && defined(__ARM_NEON)
static bool CheckFourFactors(u32 x, u32 width, u32 w0, u32 w1)
{
    u32 factors[4];
    NDS4MiSTerPerspectiveFactors4(x, width, w0, w1, factors);
    for (u32 lane = 0; lane < 4; ++lane)
    {
        const u64 left = u64(x + lane) * w0;
        const u64 denominator = left + u64(width - x - lane) * w1;
        const u32 expected = denominator ? (left << 8) / denominator : 0;
        if (factors[lane] != expected)
        {
            std::fprintf(stderr, "FAIL four-factor x=%u width=%u w0=%u w1=%u lane=%u got=%u expected=%u\n",
                x, width, w0, w1, lane, factors[lane], expected);
            return false;
        }
    }
    return true;
}
#endif

extern "C" [[gnu::noinline]] void nds_test_span_setup(
    Span* result, const Interp* parent, const s32* a, const s32* b)
{
    new (result) Span(*parent, a[0], b[0], a[1], b[1], a[2], b[2],
                     a[3], b[3], a[4], b[4]);
}

int main()
{
    const s32 widths[] = {0, 1, 2, 3, 7, 16, 31, 64, 127, 192, 255, 256};
    const s32 weights[][2] = {
        {0, 0}, {0, 512}, {512, 0}, {2048, 2048}, {2049, 2049},
        {2048, 4096}, {65535, 1}, {1, 65535}};
    u32 random = 0x71bc8325;
    auto next = [&]() {
        random ^= random << 13; random ^= random >> 17;
        random ^= random << 5; return random;
    };
    u64 values = 0, pixels = 0, batches = 0, constantBatches = 0;
    u64 specializedPixels = 0, coefficientValues = 0, scalarFlatPixels = 0;
    u64 constantDepthPixels = 0;
    for (s32 width : widths)
    for (const auto& weight : weights)
    for (bool wbuffer : {false, true})
    for (unsigned trial = 0; trial < 32; ++trial)
    {
        Interp parent(13, 13 + width, weight[0], weight[1], wbuffer);
        std::array<s32, 5> a, b;
        for (unsigned i = 0; i < 5; ++i)
        {
            a[i] = i < 3 ? next() % 512 : s32(next() & 65535) - 32768;
            b[i] = i < 3 ? next() % 512 : s32(next() & 65535) - 32768;
            if (trial & (1u << i)) b[i] = a[i];
            if (trial < 4)
            {
                a[i] = i < 3 ? 0 : -32768;
                b[i] = i < 3 ? 511 : 32767;
                if (trial & 1) std::swap(a[i], b[i]);
                if (trial & 2) b[i] = a[i];
            }
        }
        Span span(parent, a[0], b[0], a[1], b[1], a[2], b[2],
                  a[3], b[3], a[4], b[4]);
        Span mixed = span;
        u32 packedSpanColor = 0;
        const bool flat = mixed.GetConstantColor(packedSpanColor);
        if (flat != (a[0] == b[0] && a[1] == b[1] && a[2] == b[2]))
            return std::fprintf(stderr, "FAIL constant-color classification\n"), 1;
        const auto coefficients = span.PreparePerspectiveBatch();
        for (u32 factor = 0; factor <= 256; ++factor)
        for (unsigned i = 0; i < 5; ++i)
        {
            if (coefficients.Origin256[i] != a[i] * 256 ||
                coefficients.SignedDelta[i] != b[i] - a[i])
                return std::fprintf(stderr, "FAIL prepared coefficients\n"), 1;
            // Exercise the production s32 coefficients under sanitizers.
            // Explicit floor is independent of signed-right-shift semantics.
            const s32 numerator = coefficients.Origin256[i] +
                coefficients.SignedDelta[i] * s32(factor);
            const s32 actual = numerator / 256 -
                (numerator < 0 && numerator % 256 != 0);
            const s64 delta = std::abs(s64(b[i]) - a[i]);
            const s32 expected = std::min(a[i], b[i]) +
                ((delta * (a[i] < b[i] ? factor : 256 - factor)) >> 8);
            if (actual != expected)
                return std::fprintf(stderr, "FAIL prepared signed interpolation\n"), 1;
            ++coefficientValues;
        }
        Interp fast = parent, specialized = parent;
        const s32 z0 = next() & 0xffffff, z1 = next() & 0xffffff;
        Interp::SpanDepthInterpolator depth(parent, z0, z1);
        Interp noFactor = parent;
        Span noFactorSpan(noFactor, a[0], b[0], a[1], b[1], a[2], b[2],
                          a[3], b[3], a[4], b[4]);
        Interp::SpanDepthInterpolator noFactorDepth(noFactor, z0, z0);
        s32 constantZ = -1;
        const bool constantDepth = noFactorDepth.GetLinearConstantDepth(constantZ);
        if (constantDepth != (parent.linear && width > 0) ||
            (constantDepth && constantZ != z0))
            return std::fprintf(stderr, "FAIL constant-depth guard\n"), 1;
        s32 checkedZ = -1;
        if (depth.GetLinearConstantDepth(checkedZ) !=
            (parent.linear && width > 0 && z0 == z1))
            return std::fprintf(stderr, "FAIL varying-depth guard\n"), 1;
        // Consecutive pixels, then deliberate resynchronization in both
        // directions. Endpoints, empty spans and equal W are included.
        for (s32 iteration = 0; iteration < width + 4; ++iteration)
        {
            const s32 x = iteration <= width ? iteration :
                iteration == width + 1 ? 0 :
                iteration == width + 2 ? width : width / 2;
            parent.SetX(x + 13);
            if (span.IsPerspective())
            {
                fast.SetXFast(x + 13);
                specialized.SetXFast<true>(x + 13);
                if (specialized.x != fast.x ||
                    specialized.yfactor != fast.yfactor ||
                    specialized.factor_valid != fast.factor_valid ||
                    (specialized.factor_valid &&
                     (specialized.factor_x != fast.factor_x ||
                      specialized.factor_denominator != fast.factor_denominator ||
                      specialized.factor_remainder != fast.factor_remainder)) ||
                    specialized.PerspectiveFactor() != parent.PerspectiveFactor())
                {
                    std::fprintf(stderr, "FAIL perspective specialization width=%d x=%d W=%u\n", width, x, wbuffer);
                    return 1;
                }
                ++specializedPixels;
            }
            s32 actual[5]; span.Interpolate(actual);
            for (unsigned i = 0; i < 5; ++i)
            {
                // The accepted span implementation returns Base (the lower
                // endpoint) for zero width; preserve that existing contract.
                const s32 expected = width == 0 ? std::min(a[i], b[i]) :
                    parent.Interpolate(a[i], b[i]);
                if (actual[i] != expected)
                {
                    std::fprintf(stderr, "FAIL attribute width=%d x=%d i=%u\n", width, x, i);
                    return 1;
                }
                ++values;
            }
            // Alternate generic edge pixels with the constant-color interior
            if (flat && constantDepth)
            {
                if (iteration % 4 != 0)
                {
                    noFactor.SetLinearX(x + 13);
                    if (noFactor.factor_valid)
                        return std::fprintf(stderr, "FAIL skipped factor not invalidated\n"), 1;
                }
                else
                {
                    noFactor.SetXFast(x + 13);
                    if (wbuffer && noFactor.yfactor != parent.yfactor)
                        return std::fprintf(stderr, "FAIL factor resync after skipped interior\n"), 1;
                }
                u32 color;
                s16 s, t;
                noFactorSpan.InterpolateCachedPixel<true>(color, s, t, packedSpanColor);
                const u32 expected = (u32(actual[0]) >> 3) |
                    ((u32(actual[1]) >> 3) << 8) | ((u32(actual[2]) >> 3) << 16);
                if (color != expected || s != s16(actual[3]) || t != s16(actual[4]) ||
                    noFactorDepth.Interpolate() != constantZ || constantZ != parent.InterpolateZ(z0, z0))
                    return std::fprintf(stderr, "FAIL constant-depth pixel width=%d x=%d\n", width, x), 1;
                ++constantDepthPixels;
            }
            // Alternate generic edge pixels with the constant-color interior
            // on the SAME state. Jumps, repeats, zero width and descending
            // texture coordinates exercise depth-rejection resynchronization.
            if (flat && iteration % 4 != 0)
            {
                u32 color;
                s16 s, t;
                mixed.InterpolateCachedPixel<true>(color, s, t, packedSpanColor);
                const u32 expectedColor = (u32(actual[0]) >> 3) |
                    ((u32(actual[1]) >> 3) << 8) |
                    ((u32(actual[2]) >> 3) << 16);
                if (color != expectedColor || s != s16(actual[3]) || t != s16(actual[4]))
                    return std::fprintf(stderr, "FAIL scalar flat pixel width=%d x=%d\n", width, x), 1;
                ++scalarFlatPixels;
            }
            else
            {
                s32 edge[5];
                mixed.Interpolate(edge);
                for (unsigned i = 0; i < 5; ++i)
                    if (edge[i] != actual[i])
                        return std::fprintf(stderr, "FAIL mixed edge state width=%d x=%d i=%u\n", width, x, i), 1;
            }
            if (depth.Interpolate() != parent.InterpolateZ(z0, z1))
            {
                std::fprintf(stderr, "FAIL depth width=%d x=%d W=%u\n", width, x, wbuffer);
                return 1;
            }
            ++pixels;
        }
#if defined(__arm__) && defined(__ARM_NEON)
        if (span.IsPerspective())
        {
            Interp batched(13, 13 + width, weight[0], weight[1], wbuffer);
            Interp reference = batched;
            Interp::SpanDepthInterpolator batchDepth(batched, z0, z1);
            if (batched.CanBatchPerspectiveFactors(13, 14 + width))
            {
                s32 base = 0;
                for (; base + 3 <= width; base += 4)
                {
                    u32 factors[4];
                    batched.GetPerspectiveFactors4(base + 13, factors);
                    for (unsigned lane = 0; lane < 4; ++lane)
                    {
                        batched.SetPerspectiveBatchX(base + lane + 13, factors[lane]);
                        reference.SetX(base + lane + 13);
                        if (batched.PerspectiveFactor() != reference.PerspectiveFactor() ||
                            batchDepth.Interpolate() != reference.InterpolateZ(z0, z1))
                            return std::fprintf(stderr, "FAIL vector-factor depth\n"), 1;
                    }
                }
                batched.FinishPerspectiveBatch();
                // A tail or a jump must resume from exact scalar state.
                for (s32 x : {std::min(base, width), 0, width, width / 2})
                {
                    batched.SetXFast<true>(x + 13);
                    reference.SetX(x + 13);
                    if (batched.PerspectiveFactor() != reference.PerspectiveFactor() ||
                        batchDepth.Interpolate() != reference.InterpolateZ(z0, z1))
                        return std::fprintf(stderr, "FAIL vector-factor tail\n"), 1;
                }
            }
            u32 packed = 0;
            const bool constant = span.GetConstantColor(packed);
            for (u32 base = 0; base <= 256; ++base)
            {
                alignas(16) u32 factors[4], colors[4];
                s16 s[4], t[4];
                for (unsigned lane = 0; lane < 4; ++lane)
                    factors[lane] = (base + lane * 73) % 257;
                if (depth.CanBatchPerspectiveDepth4())
                {
                    s32 actualDepth[4];
                    depth.InterpolatePerspectiveDepthBatch4(factors, actualDepth);
                    for (unsigned lane = 0; lane < 4; ++lane)
                    {
                        const u64 delta = z0 < z1 ? z1 - z0 : z0 - z1;
                        const u32 factor = z0 < z1 ? factors[lane] : 256 - factors[lane];
                        const s32 expected = std::min(z0, z1) + ((delta * factor) >> 8);
                        if (actualDepth[lane] != expected)
                            return std::fprintf(stderr, "FAIL batched W-depth\n"), 1;
                    }
                }
                span.InterpolatePerspectiveBatch4(
                    factors, colors, s, t, constant, packed, coefficients);
                for (unsigned lane = 0; lane < 4; ++lane)
                {
                    s32 expected[5];
                    for (unsigned i = 0; i < 5; ++i)
                    {
                        const bool ascending = a[i] < b[i];
                        const u32 delta = ascending ? b[i] - a[i] : a[i] - b[i];
                        expected[i] = std::min(a[i], b[i]) + s32(
                            (delta * (ascending ? factors[lane] : 256 - factors[lane])) >> 8);
                    }
                    const u32 rgb = (u32(expected[0]) >> 3) |
                        ((u32(expected[1]) >> 3) << 8) |
                        ((u32(expected[2]) >> 3) << 16);
                    if (colors[lane] != rgb || s[lane] != s16(expected[3]) || t[lane] != s16(expected[4]))
                        return std::fprintf(stderr, "FAIL batch interpolation\n"), 1;
                }
                ++batches; constantBatches += constant;
            }
        }
#endif
    }
    u64 fourFactorVectors = 0;
    u64 depthBoundaryVectors = 0;
#if defined(__arm__) && defined(__ARM_NEON)
    for (s32 z0 : {0, 1, 0xFFFFFF})
    for (s32 z1 : {0, 1, 0xFFFFFF})
    {
        Interp parent(0, 256, 123, 65432, true);
        Interp::SpanDepthInterpolator depth(parent, z0, z1);
        if (!depth.CanBatchPerspectiveDepth4()) return 1;
        const u32 factors[4] = {0, 1, 255, 256};
        s32 actual[4];
        depth.InterpolatePerspectiveDepthBatch4(factors, actual);
        for (unsigned lane = 0; lane < 4; ++lane)
        {
            const u64 delta = z0 < z1 ? z1 - z0 : z0 - z1;
            const u32 f = z0 < z1 ? factors[lane] : 256 - factors[lane];
            if (actual[lane] != s32(std::min(z0, z1) + ((delta * f) >> 8)))
                return std::fprintf(stderr, "FAIL boundary W-depth\n"), 1;
        }
        ++depthBoundaryVectors;
    }
    for (s32 invalid : {-1, 0x1000000})
    {
        Interp parent(0, 256, 123, 65432, true);
        Interp::SpanDepthInterpolator depth(parent, invalid, 123);
        if (depth.CanBatchPerspectiveDepth4())
            return std::fprintf(stderr, "FAIL W-depth fallback bound\n"), 1;
    }
    std::printf("W_DEPTH_BOUNDARY_PASS vectors=%llu\n", (unsigned long long)depthBoundaryVectors);
#endif
#if defined(__arm__) && defined(__ARM_NEON)
    const u32 edgeWeights[] = {0, 1, 2, 127, 128, 255, 256, 511, 512,
                              1023, 1024, 32767, 32768, 65534, 65535};
    for (u32 width = 3; width <= 256; ++width)
    for (u32 w0 : edgeWeights)
    for (u32 w1 : edgeWeights)
    for (u32 x : {0u, (width - 3) / 2, width - 3})
    {
        if (!CheckFourFactors(x, width, w0, w1)) return 1;
        ++fourFactorVectors;
    }
    for (unsigned trial = 0; trial < 500000; ++trial)
    {
        const u32 width = 3 + next() % 254;
        const u32 x = next() % (width - 2);
        if (!CheckFourFactors(x, width, next() & 65535, next() & 65535)) return 1;
        ++fourFactorVectors;
    }
#endif
    std::printf("SCALAR_FLAT_MIXED_STATE_PASS pixels=%llu\n",
        (unsigned long long)scalarFlatPixels);
    std::printf("LINEAR_CONSTANT_DEPTH_PASS pixels=%llu\n",
        (unsigned long long)constantDepthPixels);
    std::printf("PREPARED_COEFFICIENTS_PASS values=%llu\n",
        (unsigned long long)coefficientValues);
    std::printf("SPAN_SETUP_ORACLE_PASS attributes=%llu depth=%llu batches=%llu constant_batches=%llu specialized_pixels=%llu four_factor_vectors=%llu\n",
        (unsigned long long)values, (unsigned long long)pixels,
        (unsigned long long)batches, (unsigned long long)constantBatches,
        (unsigned long long)specializedPixels, (unsigned long long)fourFactorVectors);
}
