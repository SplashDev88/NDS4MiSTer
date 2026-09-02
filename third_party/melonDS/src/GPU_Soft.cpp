/*
    Copyright 2016-2026 melonDS team

    This file is part of melonDS.

    melonDS is free software: you can redistribute it and/or modify it under
    the terms of the GNU General Public License as published by the Free
    Software Foundation, either version 3 of the License, or (at your option)
    any later version.

    melonDS is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with melonDS. If not, see http://www.gnu.org/licenses/.
*/

#include "NDS.h"
#include "GPU_Soft.h"
#include "GPU_ColorOp.h"
#include "NDS4MiSTer_2DTrace.h"

#include <algorithm>
#include <chrono>

namespace melonDS
{

namespace
{
using ProfileClock = std::chrono::steady_clock;

u64 profileElapsedNs(ProfileClock::time_point started)
{
    return static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        ProfileClock::now() - started).count());
}

ProfileClock::time_point profileStarted(bool enabled)
{
    return enabled ? ProfileClock::now() : ProfileClock::time_point {};
}
}

SoftRenderer::SoftRenderer(melonDS::NDS& nds)
    : Renderer(nds.GPU)
{
    const size_t len = 256 * 192;
    Framebuffer[0][0] = new u32[len];
    Framebuffer[0][1] = new u32[len];
    Framebuffer[1][0] = new u32[len];
    Framebuffer[1][1] = new u32[len];
    BackBuffer = 0;

    Rend2D_A = std::make_unique<SoftRenderer2D>(GPU.GPU2D_A, *this);
    Rend2D_B = std::make_unique<SoftRenderer2D>(GPU.GPU2D_B, *this);
    Rend3D = std::make_unique<SoftRenderer3D>(GPU.GPU3D, *this);
}

SoftRenderer::~SoftRenderer()
{
    SetParallel2D(false);
    delete[] Framebuffer[0][0];
    delete[] Framebuffer[0][1];
    delete[] Framebuffer[1][0];
    delete[] Framebuffer[1][1];
}

void SoftRenderer::Reset()
{
    const size_t len = 256 * 192 * sizeof(u32);
    memset(Framebuffer[0][0], 0, len);
    memset(Framebuffer[0][1], 0, len);
    memset(Framebuffer[1][0], 0, len);
    memset(Framebuffer[1][1], 0, len);

    Rend2D_A->Reset();
    Rend2D_B->Reset();
    Rend3D->Reset();
    memset(ExternalLineCacheValid, 0, sizeof(ExternalLineCacheValid));
    memset(ExternalLineCache3DValid, 0, sizeof(ExternalLineCache3DValid));
    memset(LineCacheStateValid, 0, sizeof(LineCacheStateValid));
    ExternalLineCacheReuse[0] = false;
    ExternalLineCacheReuse[1] = false;
    LastExternalLineCacheReuse[0] = false;
    LastExternalLineCacheReuse[1] = false;
    ExternalLineCacheLine = ~0u;
    Prepared3DLine = ~0u;
    PreparedLineStateLine = ~0u;
    SpriteCacheLine = ~0u;
    SpriteDrawSkipped[0] = false;
    SpriteDrawSkipped[1] = false;
    StageProfile = {};
}

void SoftRenderer::Stop()
{
    // clear framebuffers to black
    const size_t len = 256 * 192 * sizeof(u32);
    memset(Framebuffer[0][0], 0, len);
    memset(Framebuffer[0][1], 0, len);
    memset(Framebuffer[1][0], 0, len);
    memset(Framebuffer[1][1], 0, len);
}


void SoftRenderer::PreSavestate()
{
    auto rend3d = dynamic_cast<SoftRenderer3D*>(Rend3D.get());
    if (rend3d->IsThreaded())
        rend3d->SetupRenderThread();
}

void SoftRenderer::PostSavestate()
{
    auto rend3d = dynamic_cast<SoftRenderer3D*>(Rend3D.get());
    if (rend3d->IsThreaded())
        rend3d->EnableRenderThread();
}


void SoftRenderer::SetRenderSettings(RendererSettings& settings)
{
    PackedOutput = settings.PackedOutput;
    StageProfileEnabled = settings.StageProfile;
    if (LineCache != settings.LineCache)
    {
        LineCache = settings.LineCache;
        memset(LineCacheStateValid, 0, sizeof(LineCacheStateValid));
        memset(ExternalLineCacheValid, 0, sizeof(ExternalLineCacheValid));
        memset(ExternalLineCache3DValid, 0,
               sizeof(ExternalLineCache3DValid));
    }
    SetParallel2D(settings.Parallel2D);
    auto rend3d = dynamic_cast<SoftRenderer3D*>(Rend3D.get());
    rend3d->SetFullFrameCompletion(settings.FullFrame3D);
    rend3d->SetThreaded(settings.Threaded);
}

void SoftRenderer::SetParallel2D(bool enabled)
{
    if (enabled == Parallel2D) return;

    if (enabled)
    {
        Parallel2D = true;
        ParallelThread = std::thread(&SoftRenderer::Parallel2DThreadFunc, this);
        return;
    }

    WaitParallel2DTask();
    {
        std::lock_guard<std::mutex> lock(ParallelMutex);
        ParallelTask.store(Parallel2DTask::Stop, std::memory_order_release);
    }
    ParallelCondition.notify_one();
    if (ParallelThread.joinable()) ParallelThread.join();
    ParallelTask.store(Parallel2DTask::None, std::memory_order_relaxed);
    Parallel2D = false;
}

void SoftRenderer::Parallel2DThreadFunc()
{
    // Adjacent scanline tasks arrive only a few microseconds apart. Stay hot
    // for that bounded interval instead of paying two futex wakeups for every
    // line; skipped frames and VBlank gaps still fall back to a real sleep.
    constexpr u32 SpinPolls = 32768;
    for (;;)
    {
        Parallel2DTask task = ParallelTask.load(std::memory_order_acquire);
        for (u32 spin = 0;
             task == Parallel2DTask::None && spin < SpinPolls; ++spin)
            task = ParallelTask.load(std::memory_order_acquire);
        {
            if (task == Parallel2DTask::None)
            {
                if (StageProfileEnabled)
                    ++StageProfile.ParallelWorkerSleeps;
                std::unique_lock<std::mutex> lock(ParallelMutex);
                ParallelCondition.wait(lock, [this] {
                    return ParallelTask.load(std::memory_order_acquire) !=
                        Parallel2DTask::None;
                });
                task = ParallelTask.load(std::memory_order_acquire);
            }
        }

        const u32 line = ParallelLine;
        u32* const destination = ParallelDestination;

        if (task == Parallel2DTask::Stop) return;
        if (StageProfileEnabled) ++StageProfile.ParallelTasks;
        if (task == Parallel2DTask::Scanline)
        {
            const auto engineStarted = profileStarted(StageProfileEnabled);
            Rend2D_B->DrawScanline(line);
            if (StageProfileEnabled)
            {
                const u64 elapsed = profileElapsedNs(engineStarted);
                StageProfile.EngineBNs += elapsed;
                StageProfile.EngineBMaxNs = std::max(
                    StageProfile.EngineBMaxNs, elapsed);
            }
            const auto compositeStarted = profileStarted(StageProfileEnabled);
            DrawScanlineB(line, destination);
            if (StageProfileEnabled)
                StageProfile.CompositeBNs += profileElapsedNs(compositeStarted);
        }
        else
        {
            const auto spritesStarted = profileStarted(StageProfileEnabled);
            Rend2D_B->DrawSprites(line);
            if (StageProfileEnabled)
            {
                const u64 elapsed = profileElapsedNs(spritesStarted);
                StageProfile.SpritesBNs += elapsed;
                StageProfile.SpritesBMaxNs = std::max(
                    StageProfile.SpritesBMaxNs, elapsed);
            }
        }

        {
            std::lock_guard<std::mutex> lock(ParallelMutex);
            ParallelTask.store(Parallel2DTask::None, std::memory_order_release);
        }
        ParallelDone.notify_one();
    }
}

void SoftRenderer::StartParallel2DTask(
    Parallel2DTask task, u32 line, u32* destination)
{
    {
        std::lock_guard<std::mutex> lock(ParallelMutex);
        ParallelLine = line;
        ParallelDestination = destination;
        ParallelTask.store(task, std::memory_order_release);
    }
    ParallelCondition.notify_one();
}

void SoftRenderer::WaitParallel2DTask()
{
    constexpr u32 SpinPolls = 32768;
    for (u32 spin = 0; spin < SpinPolls; ++spin)
        if (ParallelTask.load(std::memory_order_acquire) ==
            Parallel2DTask::None)
        {
            if (StageProfileEnabled)
                ++StageProfile.ParallelSpinCompletions;
            return;
        }
    if (StageProfileEnabled) ++StageProfile.ParallelSleepFallbacks;
    std::unique_lock<std::mutex> lock(ParallelMutex);
    ParallelDone.wait(lock, [this] {
        return ParallelTask.load(std::memory_order_acquire) ==
            Parallel2DTask::None;
    });
}

void SoftRenderer::SetExternalLineCacheReuse(
    u32 line, bool engineA, bool engineB)
{
    ExternalLineCacheLine = line;
    ExternalLineCacheReuse[0] = engineA;
    ExternalLineCacheReuse[1] = engineB;
}

SoftRenderer::EngineLineState SoftRenderer::CaptureLineState(
    u32 engine) const
{
    EngineLineState state{};
    const GPU2D& source = engine == 0 ? GPU.GPU2D_A : GPU.GPU2D_B;
    state.DispCnt = source.DispCnt;
    memcpy(state.DispCntLatch, source.DispCntLatch,
           sizeof(state.DispCntLatch));
    memcpy(state.BGCnt, source.BGCnt, sizeof(state.BGCnt));
    memcpy(state.BGXPos, source.BGXPos, sizeof(state.BGXPos));
    memcpy(state.BGYPos, source.BGYPos, sizeof(state.BGYPos));
    memcpy(state.BGXRef, source.BGXRef, sizeof(state.BGXRef));
    memcpy(state.BGYRef, source.BGYRef, sizeof(state.BGYRef));
    memcpy(state.BGXRefInternal, source.BGXRefInternal,
           sizeof(state.BGXRefInternal));
    memcpy(state.BGYRefInternal, source.BGYRefInternal,
           sizeof(state.BGYRefInternal));
    memcpy(state.BGXRefReload, source.BGXRefReload,
           sizeof(state.BGXRefReload));
    memcpy(state.BGYRefReload, source.BGYRefReload,
           sizeof(state.BGYRefReload));
    memcpy(state.BGRotA, source.BGRotA, sizeof(state.BGRotA));
    memcpy(state.BGRotB, source.BGRotB, sizeof(state.BGRotB));
    memcpy(state.BGRotC, source.BGRotC, sizeof(state.BGRotC));
    memcpy(state.BGRotD, source.BGRotD, sizeof(state.BGRotD));
    memcpy(state.Win0Coords, source.Win0Coords, sizeof(state.Win0Coords));
    memcpy(state.Win1Coords, source.Win1Coords, sizeof(state.Win1Coords));
    memcpy(state.WinCnt, source.WinCnt, sizeof(state.WinCnt));
    memcpy(state.BGMosaicSize, source.BGMosaicSize,
           sizeof(state.BGMosaicSize));
    memcpy(state.OBJMosaicSize, source.OBJMosaicSize,
           sizeof(state.OBJMosaicSize));
    state.BGMosaicLine = source.BGMosaicLine;
    state.OBJMosaicLine = source.OBJMosaicLine;
    state.BlendCnt = source.BlendCnt;
    state.BlendAlpha = source.BlendAlpha;
    state.LayerEnable = source.LayerEnable;
    state.OBJEnable = source.OBJEnable;
    state.ForcedBlank = source.ForcedBlank;
    state.Win0Active = source.Win0Active;
    state.Win1Active = source.Win1Active;
    state.BGMosaicY = source.BGMosaicY;
    state.BGMosaicYMax = source.BGMosaicYMax;
    state.OBJMosaicY = source.OBJMosaicY;
    state.EVA = source.EVA;
    state.EVB = source.EVB;
    state.EVY = source.EVY;
    state.BGMosaicLatch = source.BGMosaicLatch;
    state.OBJMosaicLatch = source.OBJMosaicLatch;
    state.Enabled = source.Enabled;

    u32 bankMask = 0;
    if (engine == 0)
    {
        for (u32 i = 0; i < 32; ++i)
            state.BGMap[i] = static_cast<u16>(GPU.VRAMMap_ABG[i]);
        for (u32 i = 0; i < 16; ++i)
            state.OBJMap[i] = static_cast<u16>(GPU.VRAMMap_AOBJ[i]);
        for (u32 i = 0; i < 4; ++i)
            state.BGExtMap[i] =
                static_cast<u16>(GPU.VRAMMap_ABGExtPal[i]);
        state.OBJExtMap = GPU.VRAMMap_AOBJExtPal;
        state.MasterBrightness = GPU.MasterBrightnessA;
        for (u32 mapping : GPU.VRAMMap_ABG) bankMask |= mapping;
        for (u32 mapping : GPU.VRAMMap_AOBJ) bankMask |= mapping;
        for (u32 mapping : GPU.VRAMMap_ABGExtPal) bankMask |= mapping;
        bankMask |= GPU.VRAMMap_AOBJExtPal;
    }
    else
    {
        for (u32 i = 0; i < 8; ++i)
            state.BGMap[i] = static_cast<u16>(GPU.VRAMMap_BBG[i]);
        for (u32 i = 0; i < 8; ++i)
            state.OBJMap[i] = static_cast<u16>(GPU.VRAMMap_BOBJ[i]);
        for (u32 i = 0; i < 4; ++i)
            state.BGExtMap[i] =
                static_cast<u16>(GPU.VRAMMap_BBGExtPal[i]);
        state.OBJExtMap = GPU.VRAMMap_BOBJExtPal;
        state.MasterBrightness = GPU.MasterBrightnessB;
        for (u32 mapping : GPU.VRAMMap_BBG) bankMask |= mapping;
        for (u32 mapping : GPU.VRAMMap_BOBJ) bankMask |= mapping;
        for (u32 mapping : GPU.VRAMMap_BBGExtPal) bankMask |= mapping;
        bankMask |= GPU.VRAMMap_BOBJExtPal;
    }
    state.LCDCMap = GPU.VRAMMap_LCDC;
    const u32 firstPage = engine * 2;
    for (u32 page=firstPage; page<firstPage+2; ++page)
    {
        state.MemoryRevision = std::max(
            state.MemoryRevision, GPU.ExternalRenderPaletteRevision[page]);
        state.MemoryRevision = std::max(
            state.MemoryRevision, GPU.ExternalRenderOAMRevision[page]);
    }
    if (engine == 0 && ((source.DispCnt >> 16) & 3u) == 2u)
        bankMask |= GPU.VRAMMap_LCDC;
    for (u32 bank=0; bank<9; ++bank)
        if (bankMask & (1u << bank))
            state.MemoryRevision = std::max(
                state.MemoryRevision, GPU.ExternalRenderVRAMRevision[bank]);
    return state;
}

void SoftRenderer::DrawScanline(u32 line)
{
    const auto scanlineStarted = profileStarted(StageProfileEnabled);
    u32 *dstA, *dstB;
    u32 dstoffset = 256 * line;
    if (GPU.ScreenSwap)
    {
        dstA = &Framebuffer[BackBuffer][0][dstoffset];
        dstB = &Framebuffer[BackBuffer][1][dstoffset];
    }
    else
    {
        dstA = &Framebuffer[BackBuffer][1][dstoffset];
        dstB = &Framebuffer[BackBuffer][0][dstoffset];
    }

    // the position used for drawing operations is based on VCOUNT
    line = GPU.VCount;
    if (line < 192)
    {
        // retrieve 3D output. DrawSprites may already have waited for this
        // line while deciding whether all sprite work can be skipped.
        const auto output3DStarted = profileStarted(StageProfileEnabled);
        if (Prepared3DLine != line)
            Output3D = Rend3D->GetLine(line);
        Prepared3DLine = ~0u;
        if (StageProfileEnabled)
            StageProfile.Output3DNs += profileElapsedNs(output3DStarted);

        const auto cacheDecisionStarted = profileStarted(StageProfileEnabled);
        const bool cacheCommon =
            PackedOutput && GPU.ScreensEnabled &&
            !GPU.CaptureEnable && !NDS4MiSTer::Trace2DEnabled() &&
            !NDS4MiSTer::CompositeLineEnabled();
        const bool externalCacheLine = ExternalLineCacheLine == line;
        const bool cacheEligible = cacheCommon &&
            (LineCache || externalCacheLine);
        EngineLineState currentLineState[2] {};
        bool automaticReuse[2] {};
        if (cacheCommon && LineCache)
        {
            if (PreparedLineStateLine == line)
            {
                currentLineState[0] = PreparedLineState[0];
                currentLineState[1] = PreparedLineState[1];
            }
            else
            {
                currentLineState[0] = CaptureLineState(0);
                currentLineState[1] = CaptureLineState(1);
            }
            automaticReuse[0] =
                ((GPU.GPU2D_A.DispCnt >> 16) & 3u) == 1u &&
                LineCacheStateValid[0][line] &&
                memcmp(&LineCacheState[0][line], &currentLineState[0],
                       sizeof(EngineLineState)) == 0;
            automaticReuse[1] =
                ((GPU.GPU2D_B.DispCnt >> 16) & 1u) == 1u &&
                LineCacheStateValid[1][line] &&
                memcmp(&LineCacheState[1][line], &currentLineState[1],
                       sizeof(EngineLineState)) == 0;
        }
        const bool reuseA = cacheEligible &&
            (automaticReuse[0] ||
             (externalCacheLine && ExternalLineCacheReuse[0])) &&
            ExternalLineCacheValid[0][line] &&
            (!((GPU.GPU2D_A.DispCnt & (1u<<3)) &&
               (GPU.GPU2D_A.LayerEnable & 1u)) ||
             (ExternalLineCache3DValid[line] &&
              memcmp(ExternalLineCache3D[line],Output3D,
                     256*sizeof(u32))==0));
        const bool reuseB = cacheEligible &&
            (automaticReuse[1] ||
             (externalCacheLine && ExternalLineCacheReuse[1])) &&
            ExternalLineCacheValid[1][line];

        // A cache decision made before DrawSprites is revalidated here. If
        // any input changed between the two calls, rebuild the sprite line
        // before normal composition instead of observing stale OBJ buffers.
        if (SpriteCacheLine == line)
        {
            if (SpriteDrawSkipped[0] && !reuseA)
                Rend2D_A->DrawSprites(line);
            if (SpriteDrawSkipped[1] && !reuseB)
                Rend2D_B->DrawSprites(line);
        }
        SpriteCacheLine = ~0u;
        PreparedLineStateLine = ~0u;
        SpriteDrawSkipped[0] = false;
        SpriteDrawSkipped[1] = false;
        if (StageProfileEnabled)
            StageProfile.CacheDecisionNs +=
                profileElapsedNs(cacheDecisionStarted);

        LastExternalLineCacheReuse[0] = reuseA;
        LastExternalLineCacheReuse[1] = reuseB;
        // Coherency tracking is a renderer state transition, not pixel work.
        // It must run even when an externally proven-identical engine line is
        // reused, otherwise a later cache miss can observe stale flat VRAM.
        if (reuseA && GPU.GPU2D_A.Enabled && !GPU.GPU2D_A.ForcedBlank)
            static_cast<SoftRenderer2D*>(Rend2D_A.get())
                ->AdvanceLineCacheState();
        if (reuseB && GPU.GPU2D_B.Enabled && !GPU.GPU2D_B.ForcedBlank)
            static_cast<SoftRenderer2D*>(Rend2D_B.get())
                ->AdvanceLineCacheState();

        // draw BG/OBJ layers
        if (Parallel2D && !reuseA && !reuseB)
        {
            StartParallel2DTask(Parallel2DTask::Scanline, line, dstB);
            const auto engineStarted = profileStarted(StageProfileEnabled);
            Rend2D_A->DrawScanline(line);
            if (StageProfileEnabled)
                StageProfile.EngineANs += profileElapsedNs(engineStarted);
            const auto compositeStarted = profileStarted(StageProfileEnabled);
            DrawScanlineA(line, dstA);
            if (StageProfileEnabled)
                StageProfile.CompositeANs += profileElapsedNs(compositeStarted);
            const auto waitStarted = profileStarted(StageProfileEnabled);
            WaitParallel2DTask();
            if (StageProfileEnabled)
            {
                const u64 elapsed = profileElapsedNs(waitStarted);
                StageProfile.ParallelWaitNs += elapsed;
                StageProfile.ParallelWaitMaxNs = std::max(
                    StageProfile.ParallelWaitMaxNs, elapsed);
            }
        }
        else
        {
            if (!reuseA)
            {
                const auto started = profileStarted(StageProfileEnabled);
                Rend2D_A->DrawScanline(line);
                if (StageProfileEnabled)
                    StageProfile.EngineANs += profileElapsedNs(started);
            }
            if (!reuseB)
            {
                const auto started = profileStarted(StageProfileEnabled);
                Rend2D_B->DrawScanline(line);
                if (StageProfileEnabled)
                    StageProfile.EngineBNs += profileElapsedNs(started);
            }

            // draw the final screen output
            if (reuseA)
                memcpy(dstA, ExternalLineCache[0][line], 256*sizeof(u32));
            else
            {
                const auto started = profileStarted(StageProfileEnabled);
                DrawScanlineA(line, dstA);
                if (StageProfileEnabled)
                    StageProfile.CompositeANs += profileElapsedNs(started);
            }
            if (reuseB)
                memcpy(dstB, ExternalLineCache[1][line], 256*sizeof(u32));
            else
            {
                const auto started = profileStarted(StageProfileEnabled);
                DrawScanlineB(line, dstB);
                if (StageProfileEnabled)
                    StageProfile.CompositeBNs += profileElapsedNs(started);
            }
        }

        const auto cacheCommitStarted = profileStarted(StageProfileEnabled);
        if (cacheEligible)
        {
            if (!reuseA)
            {
                memcpy(ExternalLineCache[0][line], dstA, 256*sizeof(u32));
                ExternalLineCacheValid[0][line] = true;
            }
            if (!reuseB)
            {
                memcpy(ExternalLineCache[1][line], dstB, 256*sizeof(u32));
                ExternalLineCacheValid[1][line] = true;
            }
            if ((GPU.GPU2D_A.DispCnt & (1u<<3)) &&
                (GPU.GPU2D_A.LayerEnable & 1u))
            {
                memcpy(ExternalLineCache3D[line],Output3D,
                       256*sizeof(u32));
                ExternalLineCache3DValid[line] = true;
            }
            else
                ExternalLineCache3DValid[line] = false;
            if (LineCache)
            {
                LineCacheState[0][line] = currentLineState[0];
                LineCacheState[1][line] = currentLineState[1];
                LineCacheStateValid[0][line] = true;
                LineCacheStateValid[1][line] = true;
            }
        }
        else
        {
            ExternalLineCacheValid[0][line] = false;
            ExternalLineCacheValid[1][line] = false;
            ExternalLineCache3DValid[line] = false;
            LineCacheStateValid[0][line] = false;
            LineCacheStateValid[1][line] = false;
        }
        if (StageProfileEnabled)
            StageProfile.CacheCommitNs += profileElapsedNs(cacheCommitStarted);

        // perform display capture if enabled
        if (GPU.CaptureEnable)
            DoCapture(line);
    }
    else
    {
        // if scanlines outside VCOUNT range 0..191 were to be visible, fill them white
        // this may happen if VCOUNT is written to during active display
        // the actual hardware behavior depends on the screen model, and suggests that
        // no video signal is output for such scanlines

        for (int i = 0; i < 256; i++)
        {
            dstA[i] = 0x3F3F3F;
            dstB[i] = 0x3F3F3F;
        }
    }

    ExternalLineCacheReuse[0] = false;
    ExternalLineCacheReuse[1] = false;
    ExternalLineCacheLine = ~0u;

    if (GPU.ScreensEnabled)
    {
        NDS4MiSTer::EmitOutputLine(GPU.NDS.NumFrames, static_cast<u16>(line),
            GPU.ScreenSwap ? dstA : dstB, GPU.ScreenSwap ? dstB : dstA);
        // MiSTer's full-frame scanout can repack the renderer's native 6-bit
        // channel words directly. Avoid expanding every pixel only for that
        // explicit mode; ordinary melonDS frontends retain BGRA8888 output.
        if (!PackedOutput)
        {
            ExpandColor(dstA);
            ExpandColor(dstB);
        }
    }
    else
    {
        // if the screens are disabled: fill the framebuffer black
        for (int i = 0; i < 256; i++)
        {
            dstA[i] = 0xFF000000;
            dstB[i] = 0xFF000000;
        }
        NDS4MiSTer::EmitOutputLine(GPU.NDS.NumFrames, static_cast<u16>(line),
            GPU.ScreenSwap ? dstA : dstB, GPU.ScreenSwap ? dstB : dstA);
    }

    if (NDS4MiSTer::Trace2DEnabled() && line < 192)
        NDS4MiSTer::EmitTraceFramebufferScanline(GPU.NDS.NumFrames, static_cast<u16>(line),
            GPU.ScreenSwap ? dstA : dstB, GPU.ScreenSwap ? dstB : dstA);

    if (StageProfileEnabled)
    {
        ++StageProfile.Scanlines;
        StageProfile.ScanlineTotalNs += profileElapsedNs(scanlineStarted);
    }
}

void SoftRenderer::DrawSprites(u32 line)
{
    SpriteCacheLine = ~0u;
    PreparedLineStateLine = ~0u;
    SpriteDrawSkipped[0] = false;
    SpriteDrawSkipped[1] = false;

    const bool cacheCommon =
        LineCache && PackedOutput && line < 192 &&
        GPU.ScreensEnabled && !GPU.CaptureEnable &&
        !NDS4MiSTer::Trace2DEnabled() &&
        !NDS4MiSTer::CompositeLineEnabled();
    if (cacheCommon)
    {
        PreparedLineState[0] = CaptureLineState(0);
        PreparedLineState[1] = CaptureLineState(1);
        PreparedLineStateLine = line;
        const EngineLineState& stateA = PreparedLineState[0];
        const EngineLineState& stateB = PreparedLineState[1];
        Output3D = Rend3D->GetLine(line);
        Prepared3DLine = line;
        SpriteCacheLine = line;
        SpriteDrawSkipped[0] =
            ((GPU.GPU2D_A.DispCnt >> 16) & 3u) == 1u &&
            LineCacheStateValid[0][line] &&
            ExternalLineCacheValid[0][line] &&
            memcmp(&LineCacheState[0][line], &stateA,
                   sizeof(EngineLineState)) == 0 &&
            (!((GPU.GPU2D_A.DispCnt & (1u << 3)) &&
               (GPU.GPU2D_A.LayerEnable & 1u)) ||
             (ExternalLineCache3DValid[line] &&
              memcmp(ExternalLineCache3D[line], Output3D,
                     256 * sizeof(u32)) == 0));
        SpriteDrawSkipped[1] =
            ((GPU.GPU2D_B.DispCnt >> 16) & 1u) == 1u &&
            LineCacheStateValid[1][line] &&
            ExternalLineCacheValid[1][line] &&
            memcmp(&LineCacheState[1][line], &stateB,
                   sizeof(EngineLineState)) == 0;
    }

    if (Parallel2D && !SpriteDrawSkipped[0] && !SpriteDrawSkipped[1])
    {
        StartParallel2DTask(Parallel2DTask::Sprites, line);
        const auto spritesStarted = profileStarted(StageProfileEnabled);
        Rend2D_A->DrawSprites(line);
        if (StageProfileEnabled)
            StageProfile.SpritesANs += profileElapsedNs(spritesStarted);
        const auto waitStarted = profileStarted(StageProfileEnabled);
        WaitParallel2DTask();
        if (StageProfileEnabled)
        {
            const u64 elapsed = profileElapsedNs(waitStarted);
            StageProfile.ParallelWaitNs += elapsed;
            StageProfile.ParallelWaitMaxNs = std::max(
                StageProfile.ParallelWaitMaxNs, elapsed);
        }
    }
    else
    {
        if (!SpriteDrawSkipped[0])
        {
            const auto started = profileStarted(StageProfileEnabled);
            Rend2D_A->DrawSprites(line);
            if (StageProfileEnabled)
                StageProfile.SpritesANs += profileElapsedNs(started);
        }
        if (!SpriteDrawSkipped[1])
        {
            const auto started = profileStarted(StageProfileEnabled);
            Rend2D_B->DrawSprites(line);
            if (StageProfileEnabled)
                StageProfile.SpritesBNs += profileElapsedNs(started);
        }
    }
}

void SoftRenderer::DrawScanlineA(u32 line, u32* dst)
{
    u32 dispcnt = GPU.GPU2D_A.DispCnt;
    switch ((dispcnt >> 16) & 0x3)
    {
    case 0: // screen off
        {
            for (int i = 0; i < 256; i++)
                dst[i] = 0x3F3F3F;
        }
        return;

    case 1: // regular display
        {
            for (int i = 0; i < 256; i+=2)
                *(u64*)&dst[i] = *(u64*)&Output2D[0][i];
        }
        break;

    case 2: // VRAM display
        {
            u32 vrambank = (dispcnt >> 18) & 0x3;
            if (GPU.VRAMMap_LCDC & (1<<vrambank))
            {
                u16* vram = (u16*)GPU.VRAM[vrambank];
                vram = &vram[line * 256];

                for (int i = 0; i < 256; i++)
                {
                    u16 color = vram[i];
                    u8 r = (color & 0x001F) << 1;
                    u8 g = (color & 0x03E0) >> 4;
                    u8 b = (color & 0x7C00) >> 9;

                    dst[i] = r | (g << 8) | (b << 16);
                }
            }
            else
            {
                for (int i = 0; i < 256; i++)
                    dst[i] = 0;
            }
        }
        break;

    case 3: // FIFO display
        {
            for (int i = 0; i < 256; i++)
            {
                u16 color = GPU.DispFIFOBuffer[i];
                u8 r = (color & 0x001F) << 1;
                u8 g = (color & 0x03E0) >> 4;
                u8 b = (color & 0x7C00) >> 9;

                dst[i] = r | (g << 8) | (b << 16);
            }
        }
        break;
    }

    ApplyMasterBrightness(GPU.MasterBrightnessA, dst);
}

void SoftRenderer::DrawScanlineB(u32 line, u32* dst)
{
    u32 dispcnt = GPU.GPU2D_B.DispCnt;
    switch ((dispcnt >> 16) & 0x1)
    {
    case 0: // screen off
        {
            for (int i = 0; i < 256; i++)
                dst[i] = 0xFF3F3F3F;
        }
        return;

    case 1: // regular display
        {
            for (int i = 0; i < 256; i+=2)
                *(u64*)&dst[i] = *(u64*)&Output2D[1][i];
        }
        break;
    }

    ApplyMasterBrightness(GPU.MasterBrightnessB, dst);
}

void SoftRenderer::DoCapture(u32 line)
{
    u32 captureCnt = GPU.CaptureCnt;

    u32 width, height;
    u32 sz = (captureCnt >> 20) & 0x3;
    if (sz == 0)
    {
        width = 128;
        height = 128;
    }
    else
    {
        width = 256;
        height = 64 * sz;
    }

    if (line >= height)
        return;

    u32 dstvram = (captureCnt >> 16) & 0x3;
    if (!(GPU.VRAMMap_LCDC & (1<<dstvram)))
        return;

    u16* dst = (u16*)GPU.VRAM[dstvram];
    u32 dstaddr = (((captureCnt >> 18) & 0x3) << 14) + (line * width);
    dst += (dstaddr & 0xFFFF);

    u32* srcA;
    if (captureCnt & (1<<24))
        srcA = Output3D;
    else
        srcA = Output2D[0];

    u16* srcB = nullptr;
    if (captureCnt & (1<<25))
        srcB = GPU.DispFIFOBuffer;
    else
    {
        u32 dispcnt = GPU.GPU2D_A.DispCnt;
        u32 srcvram = (dispcnt >> 18) & 0x3;
        if (GPU.VRAMMap_LCDC & (1<<srcvram))
        {
            srcB = (u16*)GPU.VRAM[srcvram];

            u32 offset = line * 256;
            if (((dispcnt >> 16) & 0x3) != 2)
                offset += (((captureCnt >> 26) & 0x3) << 14);

            srcB += (offset & 0xFFFF);
        }
    }

    static_assert(VRAMDirtyGranularity == 512);
    GPU.VRAMDirty[dstvram][(dstaddr * 2) / VRAMDirtyGranularity] = true;

    switch ((captureCnt >> 29) & 0x3)
    {
    case 0: // source A
        {
            for (u32 i = 0; i < width; i++)
            {
                u32 val = srcA[i];

                u32 r = (val >> 1) & 0x1F;
                u32 g = (val >> 9) & 0x1F;
                u32 b = (val >> 17) & 0x1F;
                u32 a = ((val >> 24) != 0) ? 0x8000 : 0;

                dst[i] = r | (g << 5) | (b << 10) | a;
            }
        }
        break;

    case 1: // source B
        {
            if (srcB)
            {
                for (u32 i = 0; i < width; i++)
                    dst[i] = srcB[i];
            }
            else
            {
                for (u32 i = 0; i < width; i++)
                    dst[i] = 0;
            }
        }
        break;

    case 2: // sources A+B
    case 3:
        {
            u32 eva = captureCnt & 0x1F;
            u32 evb = (captureCnt >> 8) & 0x1F;

            // checkme
            if (eva > 16) eva = 16;
            if (evb > 16) evb = 16;

            if (srcB)
            {
                for (u32 i = 0; i < width; i++)
                {
                    u32 val = srcA[i];

                    u32 rA = (val >> 1) & 0x1F;
                    u32 gA = (val >> 9) & 0x1F;
                    u32 bA = (val >> 17) & 0x1F;
                    u32 aA = ((val >> 24) != 0) ? 1 : 0;

                    val = srcB[i];

                    u32 rB = val & 0x1F;
                    u32 gB = (val >> 5) & 0x1F;
                    u32 bB = (val >> 10) & 0x1F;
                    u32 aB = val >> 15;

                    u32 rD = ((rA * aA * eva) + (rB * aB * evb) + 8) >> 4;
                    u32 gD = ((gA * aA * eva) + (gB * aB * evb) + 8) >> 4;
                    u32 bD = ((bA * aA * eva) + (bB * aB * evb) + 8) >> 4;
                    u32 aD = (eva>0 ? aA : 0) | (evb>0 ? aB : 0);

                    if (rD > 0x1F) rD = 0x1F;
                    if (gD > 0x1F) gD = 0x1F;
                    if (bD > 0x1F) bD = 0x1F;

                    dst[i] = rD | (gD << 5) | (bD << 10) | (aD << 15);
                }
            }
            else
            {
                for (u32 i = 0; i < width; i++)
                {
                    u32 val = srcA[i];

                    u32 rA = (val >> 1) & 0x1F;
                    u32 gA = (val >> 9) & 0x1F;
                    u32 bA = (val >> 17) & 0x1F;
                    u32 aA = ((val >> 24) != 0) ? 1 : 0;

                    u32 rD = ((rA * aA * eva) + 8) >> 4;
                    u32 gD = ((gA * aA * eva) + 8) >> 4;
                    u32 bD = ((bA * aA * eva) + 8) >> 4;
                    u32 aD = (eva>0 ? aA : 0);

                    dst[i] = rD | (gD << 5) | (bD << 10) | (aD << 15);
                }
            }
        }
        break;
    }
}

void SoftRenderer::ApplyMasterBrightness(u16 regval, u32* dst)
{
    u16 mode = regval >> 14;
    if (mode == 1)
    {
        // up
        u32 factor = regval & 0x1F;
        if (factor > 16) factor = 16;

        for (int i = 0; i < 256; i++)
            dst[i] = ColorBrightnessUp(dst[i], factor, 0x0);
    }
    else if (mode == 2)
    {
        // down
        u32 factor = regval & 0x1F;
        if (factor > 16) factor = 16;

        for (int i = 0; i < 256; i++)
            dst[i] = ColorBrightnessDown(dst[i], factor, 0xF);
    }
}

void SoftRenderer::ExpandColor(u32* dst)
{
    // convert to 32-bit BGRA
    // note: 32-bit RGBA would be more straightforward, but
    // BGRA seems to be more compatible (Direct2D soft, cairo...)
    for (int i = 0; i < 256; i+=2)
    {
        u64 c = *(u64*)&dst[i];

        u64 r = (c << 18) & 0xFC000000FC0000;
        u64 g = (c << 2) & 0xFC000000FC00;
        u64 b = (c >> 14) & 0xFC000000FC;
        c = r | g | b;

        *(u64*)&dst[i] = c | ((c & 0x00C0C0C000C0C0C0) >> 6) | 0xFF000000FF000000;
    }
}


bool SoftRenderer::GetFramebuffers(void** top, void** bottom)
{
    int frontbuf = BackBuffer ^ 1;
    *top = Framebuffer[frontbuf][0];
    *bottom = Framebuffer[frontbuf][1];
    return true;
}

}
