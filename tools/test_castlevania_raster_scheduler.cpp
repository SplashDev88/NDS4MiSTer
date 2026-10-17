// SPDX-License-Identifier: GPL-3.0-only
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

int main() try
{
    unsigned comparisons = 0, queued = 0, adaptive = 0;
    for (bool delayed : {false, true})
    {
        auto serial = machine(true);
        auto parallel = parallelMachine(delayed);
        for (unsigned scenario : {0u, 1u, 2u, 8u, 16u, 32u, 48u, 65u})
        {
            // Exercise profile changes on the same renderer, including
            // returning to ordinary-game queue hysteresis after adaptive use.
            for (bool profile : {false, true, true, false, true, false})
            {
                for (NDS* nds : {serial.get(), parallel.get()})
                {
                    auto& g = nds->GPU.GPU3D;
                    g.SetIntegralTextureSpansEnabled(profile);
                    frame(*nds, scenario | 65536u | 32768u | 16384u | 8192u);
                    // Repeat the existing ten synthetic polygons in order to
                    // cross the production heavy-scene admission threshold.
                    for (unsigned i = 10; i < 30; ++i)
                        g.RenderPolygonRAM[i] = g.RenderPolygonRAM[i % 10];
                    g.RenderNumPolygons = 30;
                }
                for (unsigned repeat = 0; repeat < 4; ++repeat)
                {
                    render(*serial);
                    render(*parallel);
                    u64 expected[3]{}, actual[3]{};
                    require(serial->GetRenderer().Get3DNativeBufferHashes(expected),
                        "serial buffers unavailable");
                    require(parallel->GetRenderer().Get3DNativeBufferHashes(actual),
                        "parallel buffers unavailable");
                    require(!std::memcmp(expected, actual, sizeof(actual)),
                        "scheduler changed complete color/depth/attribute buffers");
                    ++comparisons;
                }
                const auto* soft = static_cast<SoftRenderer3D*>(
                    static_cast<SoftRenderer&>(parallel->GetRenderer()).Rend3D.get());
                require(soft->DualCoreRaster && soft->AdaptiveRasterSplit &&
                    soft->RasterBandQueue, "configured scheduler flags missing");
                require(soft->CurrentPolygonCount > 24, "heavy fixture not exercised");
                const bool actualQueue = soft->ParallelRasterBandQueueFrame_.load();
                require(actualQueue == !profile, "wrong cartridge-specific scheduler");
                if (actualQueue) ++queued;
                else ++adaptive;
            }
        }
        C49SetDelayedSemaphore(nullptr);
    }
    require(C49DelayedWakeups() == 192, "two-way/queued worker delay coverage missing");
    require(comparisons == 384 && queued == 48 && adaptive == 48,
        "scheduler coverage incomplete");
    std::printf("CASTLEVANIA_SCHEDULER_PASS buffers=%u queued=%u adaptive=%u delayed_wakeups=192\n",
        comparisons, queued, adaptive);
    return 0;
}
catch (const std::exception& error)
{
    std::fprintf(stderr, "FAIL %s\n", error.what());
    return 1;
}
