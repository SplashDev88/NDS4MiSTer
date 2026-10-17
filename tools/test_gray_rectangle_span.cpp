#include "GPU3D_Soft.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>

using namespace melonDS;
static u64 checks = 0;

static void check(s32 left, s32 right, u32 width, u32 first, u32 last)
{
    NDS4MiSTerGraySpan span(left, right, width, first);
    for (u32 x = first; x <= last; ++x, span.Advance())
    {
        // Independent endpoint formula, including descending DS rounding.
        const s32 expected = left < right ?
            left + s64(right - left) * x / width :
            right + s64(left - right) * (width - x) / width;
        ++checks;
        if (span.Get() != expected)
        {
            std::fprintf(stderr, "%d %d width=%u x=%u: %d != %d\n",
                left, right, width, x, span.Get(), expected);
            std::abort();
        }
    }
}

int main()
{
    // Every pair of native 9-bit colors, both directions, with clipped starts.
    for (s32 left = 0; left <= 511; ++left)
        for (s32 right = 0; right <= 511; ++right)
            for (u32 width : {1u, 3u, 16u, 255u, 256u})
                for (u32 first : {0u, width / 2, width - 1, width})
                    check(left, right, width, first, std::min(width, first + 7));
    // Complete rows cover every native width and representative extremal deltas.
    for (u32 width = 1; width <= 512; ++width)
        for (s32 left : {0, 1, 7, 8, 255, 256, 510, 511})
            for (s32 right : {0, 1, 7, 8, 255, 256, 510, 511})
                check(left, right, width, 0, width);
    std::printf("PASS gray rectangle span: %llu independent checks\n",
        static_cast<unsigned long long>(checks));
}
