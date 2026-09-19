// Compare the cached auxiliary screen against the ordinary software renderer.
// Synthetic VRAM only; no ROM, device memory, or runtime transport is used.
#include "Args.h"
#include "NDS.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>

using namespace melonDS;

static std::unique_ptr<NDS> fixture(bool cache, bool paired = false)
{
    NDSArgs args;
    args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args));
    nds->Reset();
    auto& gpu = nds->GPU;
    auto* vram = gpu.VRAM[2];
    std::fill_n(vram, 0x20000, u8{0});
    for (unsigned tile = 0; tile < 96; ++tile)
        for (unsigned y = 0; y < 8; ++y)
            for (unsigned x = 0; x < 8; ++x)
                vram[tile*64+y*8+x] = 1 + ((tile*11+y*17+x*23)%255);
    auto* map = reinterpret_cast<u16*>(vram + 0x4000);
    for (unsigned i = 0; i < 1024; ++i) map[i] = i%96;
    for (unsigned i = 0; i < 256; ++i)
        reinterpret_cast<u16*>(gpu.Palette+0x400)[i] =
            (i&31) | (((i*3)&31)<<5) | (((i*7)&31)<<10);
    gpu.MapVRAM_CD(2, 0x84);
    gpu.MapVRAM_CD(3, 0x84);
    for (unsigned i = 0; i < 512; ++i) gpu.VRAM[3][i] = 1 + i%255;
    for (unsigned i = 0; i < 128; ++i)
        reinterpret_cast<u16*>(gpu.OAM+0x400)[i*4] = 0x0200;
    reinterpret_cast<u16*>(gpu.OAM+0x400)[0] = 0x2014;
    reinterpret_cast<u16*>(gpu.OAM+0x400)[1] = 0x4011;
    reinterpret_cast<u16*>(gpu.OAM+0x400)[2] = 0;
    for (unsigned i = 0; i < 256; ++i)
        reinterpret_cast<u16*>(gpu.Palette+0x600)[i] = (i*173)&0x7fff;
    nds->ARM9Write16(0x04000304, 0x020f);
    nds->ARM9Write32(0x04001000, 0x00011100);
    nds->ARM9Write16(0x04001008, 0x0881);
    RendererSettings settings {};
    settings.ScaleFactor = 1;
    settings.PackedOutput = true;
    settings.EngineBOnly = !paired;
    settings.LineCache = cache && !paired;
    settings.PairedBCache = cache && paired;
    if (paired) nds->ARM9Write32(0x04000000, 0x00010000);
    gpu.GetRenderer().SetRenderSettings(settings);
    return nds;
}

static void edit(NDS& nds, unsigned frame, unsigned line)
{
    auto& gpu = nds.GPU;
    // Each change is followed by stable frames so the cache must miss and
    // subsequently recover. Changes during a line are applied before HBlank.
    if (line == 50) switch (frame) {
    case 3:
        nds.ARM9Write16(0x05000422, 0x7c1f);
        gpu.MarkExternalRenderPalette(0x422, 2); break;
    case 6:
        nds.ARM9Write32(0x06200020, 0x08070605);
        gpu.MarkExternalRenderVRAM(2); break;
    case 9: nds.ARM9Write16(0x04001010, 13); break;
    case 12: nds.ARM9Write16(0x0400106c, 0x4008); break;
    case 15: nds.ARM9Write16(0x0400106c, 0); break;
    case 18: nds.ARM9Write32(0x04001000, 0x00010180); break;
    case 21: nds.ARM9Write32(0x04001000, 0x00010100); break;
    case 24: nds.ARM9Write16(0x04000304, 0x820f); break;
    case 27: nds.ARM9Write16(0x04000304, 0x820e); break;
    case 30: nds.ARM9Write16(0x04000304, 0x820f); break;
    case 33:
        nds.ARM9Write32(0x04001000, 0x00012100);
        nds.ARM9Write16(0x04001040, 0x30c0);
        nds.ARM9Write16(0x04001044, 0x10a0);
        nds.ARM9Write16(0x04001048, 0x003f);
        nds.ARM9Write16(0x0400104a, 0x0000); break;
    case 36:
        nds.ARM9Write16(0x04001008, 0x08c0);
        nds.ARM9Write16(0x0400104c, 0x0033); break;
    case 39: gpu.MapVRAM_CD(2, 0x80); break;
    case 42: gpu.MapVRAM_CD(2, 0x84); break;
    case 45:
        nds.ARM9Write32(0x04001000, 0x00010000); break;
    case 48:
        nds.ARM9Write32(0x04001000, 0x00010100); break;
    case 51:
        nds.ARM9Write32(0x04001000, 0x00011100);
        nds.ARM9Write16(0x07000402, 0x4040);
        gpu.MarkExternalRenderOAM(0x402, 2); break;
    case 54:
        nds.ARM9Write16(0x05000622, 0x001f);
        gpu.MarkExternalRenderPalette(0x622, 2); break;
    case 57:
        nds.ARM9Write32(0x06600020, 0x090a0b0c);
        gpu.MarkExternalRenderVRAM(3); break;
    case 60:
        nds.ARM9Write16(0x07000402, 0x5040);
        gpu.MarkExternalRenderOAM(0x402, 2); break;
    case 63:
        nds.ARM9Write32(0x04001000, 0x00011402);
        nds.ARM9Write16(0x0400100c, 0x0881);
        nds.ARM9Write16(0x04001020, 0x0100);
        nds.ARM9Write16(0x04001026, 0x0100); break;
    case 66:
        nds.ARM9Write16(0x04001022, 0x0011);
        nds.ARM9Write32(0x04001028, 0x00001200); break;
    default: break;
    }
}

static void phase(NDS& nds, unsigned frame, unsigned line, unsigned kind)
{
    const unsigned vb = line >= 192 && line < 262 ? 1 : 0;
    if (!nds.GPU.ApplyExternalRendererPhase(kind, line, line,
            vb | (kind == 1 ? 2 : 0), vb | (kind == 1 ? 2 : 0),
            frame, true, frame == 0 && line == 0 && kind == 2, true))
        throw std::runtime_error("phase rejected");
}

static const u32* pixels(NDS& nds, unsigned line)
{
    u32* top = nullptr;
    u32* bottom = nullptr;
    if (!nds.GPU.GetRenderer().GetRenderedScanlines(line, &top, &bottom))
        throw std::runtime_error("scanline unavailable");
    return nds.GPU.ScreenSwap ? bottom : top;
}

int main(int argc, char** argv)
try {
    bool paired = false, benchmark = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--paired") == 0) paired = true;
        else if (std::strcmp(argv[i], "--benchmark") == 0) benchmark = true;
        else throw std::runtime_error("unknown test option");
    }
    if (benchmark) {
        for (bool cache : {false, true, true, false}) {
            auto nds = fixture(cache, paired);
            const auto start = std::chrono::steady_clock::now();
            for (unsigned f = 0; f < 240; ++f)
                for (unsigned y = 0; y < 263; ++y) {
                    phase(*nds, f, y, y == 0 ? 2 : 0);
                    phase(*nds, f, y, 1);
                }
            const auto us = std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now()-start).count();
            std::cout << "ENGINE_B_CACHE_BENCH paired=" << paired << " cache=" << cache
                      << " frames=240 us=" << us << '\n';
        }
        return 0;
    }
    auto plain = fixture(false, paired);
    auto cached = fixture(true, paired);
    unsigned hits = 0;
    unsigned misses = 0;
    for (unsigned f = 0; f < 72; ++f)
        for (unsigned y = 0; y < 263; ++y) {
            for (auto* nds : {plain.get(), cached.get()}) {
                phase(*nds, f, y, y == 0 ? 2 : 0);
                edit(*nds, f, y);
                if (paired && y < 192) {
                    // A changes independently while B can hit its cache.
                    // Do not accidentally reuse a physical screen or A row.
                    nds->ARM9Write16(0x05000000, (f * 31 + y) & 0x7fff);
                    nds->GPU.MarkExternalRenderPalette(0, 2);
                }
                phase(*nds, f, y, 1);
            }
            if (y >= 192) continue;
            if (f == 0 && y == 128) {
                const auto* row = pixels(*plain, y);
                if (std::all_of(row+1, row+256, [=](u32 v) { return v==row[0]; }))
                    throw std::runtime_error("fixture rendered a flat line");
            }
            if (std::memcmp(pixels(*plain, y), pixels(*cached, y),
                            256*sizeof(u32)) != 0) {
                std::cerr << "pixel mismatch frame=" << f << " line=" << y << '\n';
                return 1;
            }
            if (paired) {
                u32 *a[2], *b[2];
                plain->GPU.GetRenderer().GetRenderedScanlines(y, &a[0], &a[1]);
                cached->GPU.GetRenderer().GetRenderedScanlines(y, &b[0], &b[1]);
                for (unsigned s = 0; s < 2; ++s)
                    if (std::memcmp(a[s], b[s], 256 * sizeof(u32)) != 0)
                        throw std::runtime_error("paired screen differs from uncached reference");
            }
            bool a = false, b = false;
            cached->GPU.GetRenderer().GetExternalLineCacheResult(a, b);
            if (a) throw std::runtime_error("auxiliary cache touched engine A");
            if (b) ++hits; else ++misses;
        }
    if (hits < 1000 || misses < 1000)
        throw std::runtime_error("fixture did not exercise hits and invalidation");
    std::cout << "ENGINE_B_CACHE_ORACLE_PASS paired=" << paired
              << " pixels=" << 72*192*256*(paired ? 2 : 1)
              << " hits=" << hits << " misses=" << misses << '\n';
    return 0;
} catch (const std::exception& e) {
    std::cerr << e.what() << '\n';
    return 1;
}
