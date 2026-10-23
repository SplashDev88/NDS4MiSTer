// SPDX-License-Identifier: GPL-3.0-only
// Synthetic geometry only; no emulated guest execution, files or hardware.
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#define main ExistingRasterBenchmarkMain
#include "benchmark_raster_batch.cpp"
#undef main
#include "phase_test_hooks.h"
#include <atomic>
#include <thread>

static SoftRenderer3D& soft(NDS& nds)
{
    return *static_cast<SoftRenderer3D*>(
        static_cast<SoftRenderer&>(nds.GetRenderer()).Rend3D.get());
}

struct ScopedTrack
{
    explicit ScopedTrack(NDS& nds) { C58Track(&soft(nds)); }
    ~ScopedTrack() { C58Release();C58Track(nullptr); }
};

static std::unique_ptr<NDS> makeMachine(bool parallel, unsigned options,
                                      int raster, bool sparse, bool full = true)
{
    setenv("NDS4MISTER_DUAL_CORE_3D", parallel ? "1" : "0", 1);
    setenv("NDS4MISTER_ADAPTIVE_RASTER_SPLIT", "1", 1);
    setenv("NDS4MISTER_RASTER_BAND_QUEUE", raster == 1 ? "1" : "0", 1);
    setenv("NDS4MISTER_WEIGHTED_RASTER_BANDS", "1", 1);
    setenv("NDS4MISTER_RASTER_X_PARTITION", raster == 2 ? "1" : "0", 1);
    setenv("NDS4MISTER_RASTER_BAND_TEST_DELAY_WORKER", "0", 1);
    setenv("NDS4MISTER_PARALLEL_CLEAR", options & 1 ? "1" : "0", 1);
    setenv("NDS4MISTER_PARALLEL_FINAL_PASS", options & 2 ? "1" : "0", 1);
    unsetenv("NDS4MISTER_DISABLE_SOFT_TEXTURE_CACHE");
    if (sparse) unsetenv("NDS4MISTER_DISABLE_SPARSE_3D_CLEAR");
    else setenv("NDS4MISTER_DISABLE_SPARSE_3D_CLEAR", "1", 1);
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
    settings.FullFrame3D = full;
    settings.StageProfile = true;
    nds->GetRenderer().SetRenderSettings(settings);
    nds->GetRenderer().Finish3DRendering();
    nds->GPU.MapVRAM_AB(0, 0x83);
    nds->GPU.MapVRAM_E(4, 0x83);
    nds->GPU.MapVRAM_CD(2, 0x93);
    nds->GPU.MapVRAM_CD(3, 0x9b);
    for (u32 i = 0; i < 256; ++i)
    {
        const u16 color = ((i * 3 + 1) & 31) |
            (((i * 5 + 7) & 31) << 5) | (((i * 7 + 11) & 31) << 10);
        std::memcpy(nds->GPU.VRAM_E + i * 2, &color, 2);
    }
    for (u32 i = 0; i < 65536; ++i)
    {
        const u16 color = 0x8000u | ((i * 13u + 17u) & 0x7fffu);
        const u16 depth = ((i * 7u + 3u) & 0x7fffu) | (i & 0x8000u);
        std::memcpy(nds->GPU.VRAM_C + i * 2, &color, 2);
        std::memcpy(nds->GPU.VRAM_D + i * 2, &depth, 2);
    }
    std::memset(nds->GPU.VRAMDirty[2].Data, 255, sizeof(nds->GPU.VRAMDirty[2].Data));
    std::memset(nds->GPU.VRAMDirty[3].Data, 255, sizeof(nds->GPU.VRAMDirty[3].Data));
    return nds;
}

static void fixture(NDS& n, unsigned flags, bool image, bool shadows, bool profile)
{
    n.GPU.GPU3D.SetIntegralTextureSpansEnabled(profile);
    frame(n, 65536u | 32768u | 16384u | 8192u | ((flags & 1) ? 32u : 0u));
    auto& g = n.GPU.GPU3D;
    g.RenderDispCnt = 9u | ((flags & 1) ? 16u : 0u) |
        ((flags & 2) ? 32u : 0u) | ((flags & 4) ? 128u : 0u) |
        (image ? 16384u : 0u);
    g.RenderClearAttr1 |= (flags & 4) ? (1u << 15) : 0u;
    if (image) g.RenderClearAttr2 |= 0x270d0000u;
    g.RenderFogColor = 0x13004d2bu;
    g.RenderFogOffset = 0x00080000u;
    g.RenderFogShift = 1;
    for (u32 i = 0; i < 34; ++i) g.RenderFogDensityTable[i] = (i * 5 + 3) & 127;
    for (u32 i = 0; i < 8; ++i) g.RenderEdgeTable[i] = (i * 733 + 31) & 0x7fff;
    for (u32 i = 0; i < 10; ++i)
        if (flags & 4) g.RenderPolygonRAM[i]->Attr |= 1u << 15;
    if (shadows)
    {
        auto* mask = g.RenderPolygonRAM[1];
        mask->IsShadowMask = true;
        mask->Attr &= 0x00ffffffu;
        mask->Attr |= 0x30u;
        mask->TexParam = 0;
        auto* shadow = g.RenderPolygonRAM[2];
        shadow->IsShadow = true;
        shadow->Attr |= 0x30u;
        shadow->TexParam = 0;
    }
    for (u32 i = 10; i < 30; ++i)
        g.RenderPolygonRAM[i] = g.RenderPolygonRAM[i % 10];
    g.RenderNumPolygons = 30;
}

static void compare(NDS& reference, NDS& candidate)
{
    const auto& a = soft(reference);
    const auto& b = soft(candidate);
    require(!std::memcmp(a.ColorBuffer, b.ColorBuffer, sizeof(a.ColorBuffer)),
        "complete color buffers differ (including hidden AA and borders)");
    require(!std::memcmp(a.DepthBuffer, b.DepthBuffer, sizeof(a.DepthBuffer)),
        "complete depth buffers differ");
    require(!std::memcmp(a.AttrBuffer, b.AttrBuffer, sizeof(a.AttrBuffer)),
        "complete attribute buffers differ");
}

static void begin(NDS& n)
{
    n.GPU.GPU3D.RenderFrameIdentical = false;
    n.GetRenderer().Start3DRendering();
}

int main() try
{
    static_assert(static_cast<int>(SoftRenderer3D::ParallelJob::Raster) == 0);
    static_assert(static_cast<int>(SoftRenderer3D::ParallelJob::Clear) == 1);
    static_assert(static_cast<int>(SoftRenderer3D::ParallelJob::FinalPass) == 2);
    unsigned comparisons = 0, queued = 0, xpartitions = 0, transitions = 0;
    for (unsigned options : {0u, 1u, 2u, 3u})
    for (int raster : {0, 1, 2})
    for (int clear : {0, 1, 2})
    {
        auto reference = makeMachine(false, 0, 0, clear == 1);
        auto candidate = makeMachine(true, options, raster, clear == 1);
        ScopedTrack trackedCandidate(*candidate);
        for (unsigned flags = 0; flags < 8; ++flags)
        for (bool profile : {false, true, false})
        {
            fixture(*reference, flags, clear == 2, raster == 2, profile);
            fixture(*candidate, flags, clear == 2, raster == 2, profile);
            for (unsigned repeat = 0; repeat < 3; ++repeat)
            {
                render(*reference);
                render(*candidate);
                compare(*reference, *candidate);
                ++comparisons;
            }
            auto& r = soft(*candidate);
            require(r.ParallelClear == bool(options & 1) &&
                r.ParallelFinalPass == bool(options & 2), "phase option missing");
            if (raster == 1)
            {
                require(r.ParallelRasterBandQueueFrame_.load() == !profile,
                    "queued/profile transition missing");
                queued += !profile;
            }
            if (raster == 2)
            {
                require(r.ParallelRasterXPartitionFrame_.load() == !(flags & 1),
                    "X shadow/AA fallback coverage missing");
                xpartitions += !(flags & 1);
            }
            ++transitions;
        }
        const auto c = C58Counts();
        require(c.done[0] && bool(c.done[1]) == bool(options & 1) &&
            bool(c.done[2]) == bool(options & 2), "phase jobs were not exercised");
        // Reset and profile mutation obey the renderer's existing drain-first
        // contract. No main-thread GPU state changes overlap a worker job.
        for (auto* n : {reference.get(), candidate.get()})
        {
            n->GetRenderer().Finish3DRendering();
            soft(*n).Reset();
            n->GetRenderer().Finish3DRendering();
            fixture(*n, 7, clear == 2, raster == 2, true);
            render(*n);
        }
        compare(*reference, *candidate);
        ++comparisons;
        C58Track(nullptr);
    }

    // Legacy per-scanline consumers must not use either additional phase.
    for (unsigned options : {1u, 2u, 3u})
    {
        auto reference = makeMachine(false, 0, 0, false, false);
        auto candidate = makeMachine(true, options, 2, false, false);
        ScopedTrack trackedCandidate(*candidate);
        fixture(*reference, 7, true, true, false);
        fixture(*candidate, 7, true, true, false);
        render(*reference);render(*candidate);compare(*reference, *candidate);
        const auto c = C58Counts();
        require(c.done[0] == 1 && !c.done[1] && !c.done[2],
            "parallel phases reached a legacy scanline consumer");
        ++comparisons;
        C58Track(nullptr);
    }

    unsigned cancellations = 0, secondaryFirst = 0, shutdowns = 0;
    for (int job : {1, 0, 2})
    for (bool edge : {false, true})
    {
        auto reference = makeMachine(false, 0, 0, true);
        auto candidate = makeMachine(true, 3, 2, true);
        const unsigned flags = edge ? 7u : 1u;
        fixture(*reference, flags, false, true, true);
        fixture(*candidate, flags, false, true, true);
        render(*reference);
        ScopedTrack trackedCandidate(*candidate);
        C58Hold(job, false);
        begin(*candidate);
        const bool held = C58WaitHeld();
        const bool premature = C58Counts().frames != 0;
        const bool canceled = held && candidate->GetRenderer().Request3DRenderingCancellation();
        C58Release();
        candidate->GetRenderer().Finish3DRendering();
        require(held && !premature && canceled &&
            candidate->GetRenderer().Was3DRenderingCanceled(),
            "held phase failed cancellation or published before its join");
        candidate->GPU.GPU3D.RenderFrameIdentical = true;
        candidate->GetRenderer().Start3DRendering();
        candidate->GetRenderer().Finish3DRendering();
        require(!soft(*candidate).FrameIdentical &&
            !candidate->GetRenderer().Was3DRenderingCanceled(),
            "canceled phase did not force recovery before identical reuse");
        compare(*reference, *candidate);
        ++comparisons;++cancellations;
        C58Track(nullptr);
    }
    for (unsigned flags : {1u, 3u, 7u})
    {
        auto reference = makeMachine(false, 0, 0, false);
        auto candidate = makeMachine(true, 3, 0, false);
        fixture(*reference, flags, true, false, true);
        fixture(*candidate, flags, true, false, true);
        render(*reference);
        ScopedTrack trackedCandidate(*candidate);
        C58Hold(2, true);
        begin(*candidate);
        const bool held = C58WaitHeld();
        const bool peerDone = held && C58WaitJobDone(2, 1);
        const bool premature = C58Counts().frames != 0;
        C58Release();
        candidate->GetRenderer().Finish3DRendering();
        require(held && peerDone && !premature, "secondary-final-first ordering missing");
        compare(*reference, *candidate);
        ++comparisons;++secondaryFirst;
        C58Track(nullptr);
    }
    for (int job : {1, 0, 2})
    {
        auto candidate = makeMachine(true, 3, 0, true);
        fixture(*candidate, 7, false, false, true);
        ScopedTrack trackedCandidate(*candidate);
        C58Hold(job, false);
        begin(*candidate);
        const bool held = C58WaitHeld();
        const unsigned starts = C58Counts().primaryStarts;
        std::atomic_bool stopped{false};
        std::thread stop([&] { soft(*candidate).StopRenderThread();stopped.store(true); });
        const bool stopPosted = C58WaitPrimaryStarts(starts + 1);
        const bool prematurelyStopped = stopped.load();
        C58Release();
        stop.join();
        require(held && stopPosted && !prematurelyStopped && stopped.load(),
            "shutdown failed to join a held secondary phase");
        ++shutdowns;
        C58Track(nullptr);
    }
    require(queued && xpartitions && comparisons == 2640 && transitions == 864 &&
        cancellations == 6 && secondaryFirst == 3 && shutdowns == 3,
        "phase-oracle coverage counts incomplete");
    std::printf("C58_PHASE_ORACLE_PASS full_buffers=%u transitions=%u queued=%u x=%u canceled=%u secondary_first=%u shutdowns=%u\n",
        comparisons, transitions, queued, xpartitions, cancellations, secondaryFirst, shutdowns);
    return 0;
}
catch (const std::exception& error)
{
    C58Release();
    std::fprintf(stderr, "FAIL %s\n", error.what());
    return 1;
}
