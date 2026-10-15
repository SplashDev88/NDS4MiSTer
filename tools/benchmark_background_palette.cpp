// SPDX-License-Identifier: GPL-3.0-only
// ROM-free timing fixture for real 8bpp background drawing. Build with the
// same core library and LTO options as the service. No FPGA or device access.
#include <bits/stdc++.h>
#define private public
#include "NDS.h"
#include "GPU_Soft.h"
#include "GPU2D_Soft.h"
#undef private
using namespace melonDS;
int main(int argc, char** argv) try
{
    const unsigned lines = argc > 1 ? std::stoul(argv[1]) : 100000;
    if (lines < 1000 || lines > 1000000) throw std::runtime_error("invalid line count");
    unsetenv("NDS4MISTER_DUAL_CORE_3D");
    NDSArgs args; args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args)); nds->Reset();
    auto& gpu = nds->GPU;
    auto& e = gpu.GPU2D_A;
    auto& parent = static_cast<SoftRenderer&>(nds->GetRenderer());
    SoftRenderer2D r(e, parent);
    u8* vram; u32 mask; e.GetBGVRAM(vram, mask);
    for (u32 i = 0; i <= mask; ++i) vram[i] = (i * 73 + i / 256 + 1) & 255;
    for (u32 i = 0; i < sizeof(gpu.Palette); ++i) gpu.Palette[i] = i * 37 + 11;
    std::fill(std::begin(r.WindowMask), std::end(r.WindowMask), 0x3f);
    std::array<u8, 256> mosaic;
    for (unsigned i = 0; i < 256; ++i) mosaic[i] = i % 3;
    r.CurBGXMosaicTable = mosaic.data();
    r.StandardPaletteCache = true;
    r.AffineTileCache = true;
    e.DispCnt = 0;
    e.BGXPos[2] = 3; e.BGYPos[2] = 17;
    for (unsigned scenario = 0; scenario < 4; ++scenario)
    {
        std::fill(std::begin(r.BGOBJLine), std::end(r.BGOBJLine), 0);
        const bool text = scenario == 0;
        e.BGCnt[2] = (1u << 13) | (1u << 8) | (1u << 2) | (text ? 1u << 7 : 0);
        e.BGXRefInternal[0] = 17 * 256;
        e.BGYRefInternal[0] = 13 * 256;
        e.BGRotA[0] = scenario == 2 ? 233 : 256;
        e.BGRotC[0] = scenario == 2 ? 71 : 0;
        const auto draw = [&](unsigned line) {
            r.StandardPaletteChecked = false; // Real once-per-line validation.
            if (text) r.DrawBG_Text<false>(line % 192, 2);
            else if (scenario == 3) r.DrawBG_Extended<true>(line % 192, 2);
            else r.DrawBG_Extended<false>(line % 192, 2);
        };
        for (unsigned i = 0; i < 1000; ++i) draw(i);
        for (unsigned sample = 0; sample < 3; ++sample)
        {
            const auto begin = std::chrono::steady_clock::now();
            for (unsigned i = 0; i < lines; ++i) draw(i);
            const double ns = std::chrono::duration<double, std::nano>(
                std::chrono::steady_clock::now() - begin).count() / lines;
            u64 hash = 1469598103934665603ULL;
            for (auto pixel : r.BGOBJLine) { hash ^= pixel; hash *= 1099511628211ULL; }
            std::cout << "BG_TIMING scenario=" << scenario << " sample=" << sample
                      << " ns_per_line=" << ns << " hash=" << hash << '\n';
        }
    }
}
catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
