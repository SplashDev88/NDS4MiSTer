// SPDX-License-Identifier: GPL-3.0-only
// Exercise the real renderer against its raw-palette path, including both
// layer planes. Test-only access does not change production object layout.
#include <bits/stdc++.h>
#define private public
#include "NDS.h"
#include "GPU_Soft.h"
#include "GPU2D_Soft.h"
#undef private
using namespace melonDS;
static uint32_t seed = 0x5719a3c5u;
static uint32_t random32() { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return seed; }
int main() try
{
    unsetenv("NDS4MISTER_DUAL_CORE_3D");
    NDSArgs args; args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args)); nds->Reset();
    auto& gpu = nds->GPU;
    auto& parent = static_cast<SoftRenderer&>(nds->GetRenderer());
    unsigned cases = 0, changed = 0, text8 = 0, affine8 = 0;
    u64 hash = 1469598103934665603ULL;
    for (unsigned engine = 0; engine < 2; ++engine)
    {
        auto& e = engine ? gpu.GPU2D_B : gpu.GPU2D_A;
        SoftRenderer2D r(e, parent);
        u8* vram; u32 mask; e.GetBGVRAM(vram, mask);
        for (u32 i = 0; i <= mask; ++i) vram[i] = random32();
        for (auto& x : gpu.Palette) x = random32();
        for (unsigned slot = 0; slot < 4; ++slot)
            for (unsigned pal = 0; pal < 16; ++pal)
            {
                auto* colors = e.GetBGExtPal(slot, pal);
                for (unsigned i = 0; i < 256; ++i) colors[i] = random32();
            }
        std::array<u32, 512> initial, reference;
        std::array<u8, 256> mosaic;
        for (unsigned test = 0; test < 16384; ++test)
        {
            const unsigned bg = 2 + (test & 1);
            const bool extended = test & 2, extpal = test & 4;
            const bool useMosaic = test & 8, eightBit = test & 16;
            e.DispCnt = (u32(extpal) << 30) | ((random32() & 7) << 24) | ((random32() & 7) << 27);
            e.BGCnt[bg] = (random32() & 0xff7c) | (u32(eightBit) << 7);
            e.BGXPos[bg] = random32(); e.BGYPos[bg] = random32();
            e.BGMosaicLine = random32() % 192;
            const int boundary[] = {-257, -1, 0, 7, 127, 255, 511, 1023};
            e.BGXRefInternal[bg-2] = boundary[(test >> 5) & 7] * 256 + (random32() & 255);
            e.BGYRefInternal[bg-2] = int(random32() % 1026 - 1) * 256;
            e.BGRotA[bg-2] = test % 3 ? 256 : s16(random32());
            e.BGRotC[bg-2] = test % 3 ? 0 : s16(random32());
            const unsigned mosaicSize = 1 + random32() % 16;
            for (unsigned i = 0; i < 256; ++i)
            {
                mosaic[i] = i % mosaicSize;
                r.WindowMask[i] = test % 3 == 0 ? 0x3f : test % 3 == 1 ? 0 : random32();
            }
            r.CurBGXMosaicTable = mosaic.data();
            r.AffineTileCache = test & 256;
            for (auto& x : initial) x = random32();
            // Raw writes with no epoch hint must be visible on the next line.
            vram[random32() & mask] = random32();
            gpu.Palette[random32() % sizeof(gpu.Palette)] = random32();
            const auto draw = [&] {
                if (extended)
                {
                    if (useMosaic) r.DrawBG_Extended<true>(test % 192, bg);
                    else r.DrawBG_Extended<false>(test % 192, bg);
                }
                else
                {
                    if (useMosaic) r.DrawBG_Text<true>(test % 192, bg);
                    else r.DrawBG_Text<false>(test % 192, bg);
                }
            };
            std::copy(initial.begin(), initial.end(), r.BGOBJLine);
            r.StandardPaletteCache = false; r.StandardPaletteChecked = false; draw();
            std::copy(std::begin(r.BGOBJLine), std::end(r.BGOBJLine), reference.begin());
            std::copy(initial.begin(), initial.end(), r.BGOBJLine);
            r.StandardPaletteCache = true; r.StandardPaletteChecked = false; draw();
            if (std::memcmp(reference.data(), r.BGOBJLine, sizeof(r.BGOBJLine)))
                throw std::runtime_error("palette mismatch engine=" + std::to_string(engine) + " case=" + std::to_string(test));
            changed += reference != initial;
            text8 += !extended && eightBit && !extpal && !useMosaic;
            affine8 += extended && !eightBit && !extpal;
            for (u32 value : reference) { hash ^= value; hash *= 1099511628211ULL; }
            ++cases;
        }
    }
    if (changed < 6000 || text8 < 1000 || affine8 < 1000)
        throw std::runtime_error("insufficient exercised cases");
    std::cout << "BACKGROUND_PALETTE_ORACLE_PASS cases=" << cases << " changed=" << changed
              << " text8=" << text8 << " affine8=" << affine8 << " hash=" << hash << '\n';
}
catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
