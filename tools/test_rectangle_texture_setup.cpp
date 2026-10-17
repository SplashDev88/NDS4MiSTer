#include "GPU3D_Soft.h"
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

using namespace melonDS;
static uint64_t checks = 0;
static void require(bool value)
{
    ++checks;
    if (!value) std::abort();
}

// Independent DS endpoint formula; deliberately uses widened division rather
// than the prepared reciprocal or recurrence used by the production renderer.
static s32 interpolate(s32 a, s32 b, s32 position, s32 length)
{
    return a < b ? a + s64(b - a) * position / length :
        b + s64(a - b) * (length - position) / length;
}

static void rectangle(s16 tl, s16 bl, s16 tr, s16 br, s32 width, s32 height)
{
    s32 step = 0x12345678;
    const bool expected = width > 0 && s32(tr) - tl == s32(br) - bl &&
        (s32(tr) - tl) % width == 0;
    const bool accepted = NDS4MiSTerPrepareRectangleTextureStep(
        tl, bl, tr, br, width, step);
    require(accepted == expected);
    if (!accepted) return;
    for (s32 y : {0, 1, height / 2, height - 1, height})
    {
        const s32 left = interpolate(tl, bl, y, height);
        const s32 right = interpolate(tr, br, y, height);
        for (s32 x : {0, 1, width / 2, width - 1, width})
            require(left + step * x == interpolate(left, right, x, width));
    }
}

int main()
{
    for (s32 width = 1; width <= 512; ++width)
        for (s32 step = -64; step <= 64; ++step)
            for (s32 vertical : {-1025, -65, -1, 0, 1, 65, 1025})
            {
                const s32 tl = -16000, tr = tl + step * width;
                if (tr < -32768 || tr > 32767 ||
                    tr + vertical < -32768 || tr + vertical > 32767) continue;
                rectangle(tl, tl + vertical, tr, tr + vertical, width, 191);
                rectangle(tl, tl + vertical, tr, tr + vertical + 1, width, 191);
            }
    uint32_t random = 0x4e445331;
    const auto next = [&]() { random ^= random << 13; random ^= random >> 17;
        random ^= random << 5; return random; };
    for (unsigned i = 0; i < 100000; ++i)
    {
        const s16 tl = next(), bl = next(), tr = next(), br = next();
        rectangle(tl, bl, tr, br, 1 + next() % 512, 1 + next() % 192);
    }
    for (s32 width : {-1, 0, 1, 2, 3, 255, 256, 511, 512})
        for (s16 a : {s16(-32768), s16(-1), s16(0), s16(32767)})
            for (s16 b : {s16(-32768), s16(-1), s16(0), s16(32767)})
                rectangle(a, a, b, b, width, 192);
    std::printf("PASS rectangle setup: %llu independent checks\n",
        static_cast<unsigned long long>(checks));
}
