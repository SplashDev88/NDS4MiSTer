// SPDX-License-Identifier: GPL-3.0-only
// Synthetic controller and full-buffer range/transition coverage only.
// Synthetic geometry only. No ROMs, saves, FPGA mappings or CPU emulation.
#include "GPU_Soft.h"
#define main ExistingRasterBenchmarkMain
#include "benchmark_raster_batch.cpp"
#undef main

extern void C49SetDelayedSemaphore(void* semaphore);
extern unsigned C49DelayedWakeups();

static std::unique_ptr<NDS> parallelMachine(bool delayed)
{
    setenv("NDS4MISTER_DUAL_CORE_3D", "1", 1);
    setenv("NDS4MISTER_ADAPTIVE_RASTER_SPLIT", "1", 1);
    setenv("NDS4MISTER_RASTER_BAND_QUEUE", "1", 1);
    setenv("NDS4MISTER_WEIGHTED_RASTER_BANDS", "1", 1);
    setenv("NDS4MISTER_RASTER_X_PARTITION", "1", 1);
    setenv("NDS4MISTER_RASTER_BAND_TEST_DELAY_WORKER", "0", 1);
    unsetenv("NDS4MISTER_DISABLE_SOFT_TEXTURE_CACHE");
    NDSArgs args;
    args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args), nullptr);
    nds->Reset();
    auto& g = nds->GPU.GPU3D;
    g.SetEnabled(true, true);
    g.SetExternalCommandReplay(true);
    g.SetHighResolutionCoordinatesEnabled(false);
    RendererSettings settings{};
    settings.ScaleFactor = 1;
    settings.Threaded = true;
    settings.FullFrame3D = true;
    settings.PackedOutput = false;
    settings.StageProfile = true;
    auto& renderer = nds->GetRenderer();
    renderer.SetRenderSettings(settings);
    renderer.Finish3DRendering();
    auto* soft = static_cast<SoftRenderer3D*>(
        static_cast<SoftRenderer&>(renderer).Rend3D.get());
    C49SetDelayedSemaphore(delayed ? soft->Sema_ParallelRasterStart : nullptr);
    nds->GPU.MapVRAM_AB(0, 0x83);
    nds->GPU.MapVRAM_E(4, 0x83);
    for (u32 i = 0; i < 256; ++i)
    {
        const u16 color = ((i * 3 + 1) & 31) |
            (((i * 5 + 7) & 31) << 5) | (((i * 7 + 11) & 31) << 10);
        std::memcpy(nds->GPU.VRAM_E + i * 2, &color, 2);
    }
    return nds;
}



static void controllerChecks()
{
    using C = NDS4MiSTerRasterBalanceController;
    C c;
    auto force = [&](bool primarySlow, u32 expected) {
        for (unsigned i = 0; i < 192; ++i) {
            const auto before = c.PrimaryPermille();
            c.Observe(primarySlow ? 10000000 : 1000000,
                      primarySlow ? 1000000 : 10000000);
            const auto after = c.PrimaryPermille();
            require(after <= before + C::MaximumCorrectionPermille &&
                    before <= after + C::MaximumCorrectionPermille,
                    "correction step exceeded");
        }
        require(c.PrimaryPermille() == expected, "controller bound wrong");
    };
    force(true, 440);
    c.SetCastlevaniaProfile(true);
    require(c.PrimaryPermille() == 500, "profile entry did not reset");
    require(!c.Observe(10000000, 1000000), "profile entry kept old EMA");
    force(true, 400);
    c.SetCastlevaniaProfile(true);
    require(c.PrimaryPermille() == 400, "same profile reset adaptation");
    force(false, 800);
    c.SetCastlevaniaProfile(false);
    require(c.PrimaryPermille() == 500, "profile exit did not reset");
    require(!c.Observe(10000000, 1000000), "profile exit kept old EMA");
    force(true, 440);
    c.SetCastlevaniaProfile(true);
    c.Reset();
    require(!c.Observe(100000, 150000), "tiny sample moved controller");
    force(true, 400);
    // Model the observed cave workers as share-dependent costs. The extended
    // range should find their balance without relying on actual host timing.
    c.Reset();
    for (unsigned i = 0; i < 128; ++i) {
        const u64 p = c.PrimaryPermille();
        c.Observe(14000000 * p / 440,
                  11100000 * (1000 - p) / 560);
    }
    require(c.PrimaryPermille() >= 375 && c.PrimaryPermille() <= 410,
            "observed-cost model did not converge below old floor");
}

int main() try
{
    controllerChecks();
    unsigned comparisons = 0, forcedLower = 0, forcedUpper = 0;
    for (bool queue : {false, true}) {
        auto serial = machine(true);
        auto parallel = parallelMachine(false);
        auto* soft = static_cast<SoftRenderer3D*>(
            static_cast<SoftRenderer&>(parallel->GetRenderer()).Rend3D.get());
        soft->RasterBandQueue = queue;
        for (unsigned scenario : {0u, 1u, 2u, 8u, 16u, 32u, 48u, 65u}) {
            for (bool profile : {false, true, true, false, true, false}) {
                for (NDS* nds : {serial.get(), parallel.get()}) {
                    auto& g = nds->GPU.GPU3D;
                    g.SetIntegralTextureSpansEnabled(profile);
                    frame(*nds, scenario | 65536u | 32768u | 16384u | 8192u);
                    for (unsigned i = 10; i < 30; ++i)
                        g.RenderPolygonRAM[i] = g.RenderPolygonRAM[i % 10];
                    g.RenderNumPolygons = 30;
                }
                // Finish one frame to apply the cartridge policy, then drive
                // both extremes before real workers render the same geometry.
                render(*parallel);
                for (bool lower : {true, false}) {
                    for (unsigned i = 0; i < 192; ++i)
                        soft->RasterBalance.Observe(
                            lower ? 10000000 : 1000000,
                            lower ? 1000000 : 10000000);
                    require(soft->RasterBalance.PrimaryPermille() ==
                            (lower ? (profile ? 400u : 440u) : 800u),
                            "renderer failed to apply profile-specific range");
                    lower ? ++forcedLower : ++forcedUpper;
                    for (unsigned repeat = 0; repeat < 2; ++repeat) {
                        render(*serial);render(*parallel);
                        u64 expected[3]{}, actual[3]{};
                        require(serial->GetRenderer().Get3DNativeBufferHashes(expected),
                                "serial buffers unavailable");
                        require(parallel->GetRenderer().Get3DNativeBufferHashes(actual),
                                "parallel buffers unavailable");
                        require(!std::memcmp(expected, actual, sizeof(actual)),
                                "extended range changed complete buffers");
                        ++comparisons;
                    }
                }
            }
        }
    }
    require(comparisons == 384 && forcedLower == 96 && forcedUpper == 96,
            "range coverage incomplete");
    std::printf("CASTLEVANIA_RANGE_PASS buffers=384 lower=96 upper=96 transitions=96\n");
    return 0;
}
catch (const std::exception& e) { std::fprintf(stderr,"FAIL %s\n",e.what());return 1; }
