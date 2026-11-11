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

#include "GPU3D_Soft.h"
#include "GPU3D_Diagnostic.h"
#include <ctime>

#include <algorithm>
#include <cassert>
#include <chrono>
#include <cstdlib>
#include <sstream>
#include <stdio.h>
#include <string.h>
#include <thread>
#if defined(__linux__)
#include <pthread.h>
#include <sched.h>
#endif
#include "NDS.h"
#include "GPU.h"
#include "GPU_Soft.h"

namespace melonDS
{

namespace
{
using Renderer3DProfileClock = std::chrono::steady_clock;

Renderer3DProfileClock::time_point renderer3DProfileStarted(bool enabled)
{
    return enabled ? Renderer3DProfileClock::now() :
        Renderer3DProfileClock::time_point {};
}

u64 renderer3DProfileElapsedNs(
    Renderer3DProfileClock::time_point started)
{
    return static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        Renderer3DProfileClock::now() - started).count());
}

u64 renderer3DClockNowNs()
{
    return static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(
        Renderer3DProfileClock::now().time_since_epoch()).count());
}

void bindParallelRasterToSecondCpu()
{
#if defined(__linux__)
    cpu_set_t affinity;
    CPU_ZERO(&affinity);
    CPU_SET(1, &affinity);
    // Affinity is an optimization, not a correctness requirement. Desktop
    // tests and unusual Linux hosts may expose only one CPU; let their normal
    // scheduler run the deterministic worker instead of failing startup.
    (void)pthread_setaffinity_np(
        pthread_self(), sizeof(affinity), &affinity);
#endif
}

// FPGA command preparation does not use the parallel software raster worker.
// Let it use CPU1 while CPU0 services the guest and packet intake. Restore the
// caller's placement before returning to software rendering or waiting for a
// new frame; otherwise software fallback would put both raster workers on CPU1.
class FpgaPreparationAffinity
{
public:
    FpgaPreparationAffinity()
    {
#if defined(__linux__) && defined(__arm__)
        if (pthread_getaffinity_np(pthread_self(), sizeof(previous), &previous))
            return;
        cpu_set_t target;
        CPU_ZERO(&target);
        CPU_SET(1, &target);
        changed = !CPU_EQUAL(&previous, &target) &&
            pthread_setaffinity_np(pthread_self(), sizeof(target), &target) == 0;
#endif
    }
    ~FpgaPreparationAffinity()
    {
#if defined(__linux__) && defined(__arm__)
        if (changed)
            (void)pthread_setaffinity_np(pthread_self(), sizeof(previous), &previous);
#endif
    }
    FpgaPreparationAffinity(const FpgaPreparationAffinity&) = delete;
    FpgaPreparationAffinity& operator=(const FpgaPreparationAffinity&) = delete;
private:
#if defined(__linux__) && defined(__arm__)
    cpu_set_t previous;
    bool changed = false;
#endif
};
}

void RenderThreadFunc();


void SoftRenderer3D::StopRenderThread()
{
    if (RenderThreadRunning.load(std::memory_order_relaxed))
    {
        // Tell the render thread to stop drawing new frames, and finish up the current one.
        RenderThreadRunning = false;

        Platform::Semaphore_Post(Sema_RenderStart);

        Platform::Thread_Wait(RenderThread);
        Platform::Thread_Free(RenderThread);
        RenderThread = nullptr;
    }

    // Keep the band worker alive until the primary renderer has completed or
    // abandoned its current frame. The primary may be waiting for this exact
    // worker at the raster join when shutdown is requested.
    if (ParallelRasterThreadRunning.load(std::memory_order_relaxed))
    {
        ParallelRasterThreadRunning = false;
        Platform::Semaphore_Post(Sema_ParallelRasterStart);
        Platform::Thread_Wait(ParallelRasterThread);
        Platform::Thread_Free(ParallelRasterThread);
        ParallelRasterThread = nullptr;
    }
}

void SoftRenderer3D::SetupRenderThread()
{
    if (Threaded)
    {
        if (DualCoreRaster &&
            !ParallelRasterThreadRunning.load(std::memory_order_relaxed))
        {
            ParallelRasterThreadRunning = true;
            ParallelRasterThread = Platform::Thread_Create([this]() {
                ParallelRasterThreadFunc();
            });
        }
        if (!RenderThreadRunning.load(std::memory_order_relaxed))
        { // If the render thread isn't already running...
            RenderThreadRunning = true; // "Time for work, render thread!"
            RenderThread = Platform::Thread_Create([this]() {
                RenderThreadFunc();
            });
        }

        // "Be on standby, but don't start rendering until I tell you to!"
        Platform::Semaphore_Reset(Sema_RenderStart);

        // "Oh, sorry, were you already in the middle of a frame from the last iteration?"
        if (RenderThreadRendering)
            // "Tell me when you're done, I'll wait here."
            Platform::Semaphore_Wait(Sema_RenderDone);

        // "All good? Okay, let me give you your training."
        // "(Maybe you're still the same thread, but I have to tell you this stuff anyway.)"

        // "This is the signal you'll send when you're done with a frame."
        // "I'll listen for it when I need to show something to the frontend."
        Platform::Semaphore_Reset(Sema_RenderDone);

        // "This is the signal I'll send when I want you to start rendering."
        // "Don't do anything until you get the message."
        Platform::Semaphore_Reset(Sema_RenderStart);

        // "This is the signal you'll send every time you finish drawing a line."
        // "I might need some of your scanlines before you finish the whole buffer,"
        // "so let me know as soon as you're done with each one."
        Platform::Semaphore_Reset(Sema_ScanlineCount);
        if (DualCoreRaster)
        {
            Platform::Semaphore_Reset(Sema_ParallelRasterStart);
            Platform::Semaphore_Reset(Sema_ParallelRasterDone);
        }
    }
    else
    {
        StopRenderThread();
    }
}

void SoftRenderer3D::EnableRenderThread()
{
    if (Threaded && Sema_RenderStart)
    {
        RenderFrameFinished = false;
        Platform::Semaphore_Post(Sema_RenderStart);
    }
}

SoftRenderer3D::SoftRenderer3D(melonDS::GPU3D& gpu3D, SoftRenderer& parent) noexcept
    : Renderer3D(gpu3D), Parent(parent),
      TextureCache(gpu3D.GPU, SoftTexcacheLoader())
{
    if(const char* v=std::getenv("NDS4MISTER_TEXTURE_HISTORY"))
        TextureHistoryEnabled=std::strcmp(v,"1")==0;
    // Opt-in quality experiments affect only the software renderer. Keep the
    // guest register and latched geometry state intact (including reuse checks).
    const auto enabled = [](const char* name) {
        const char* value = std::getenv(name);
        return value && std::strcmp(value, "1") == 0;
    };
    DisabledEffectBits =
        (enabled("NDS4MISTER_DISABLE_3D_AA") ? (1u << 4) : 0) |
        (enabled("NDS4MISTER_DISABLE_3D_EDGE") ? (1u << 5) : 0) |
        (enabled("NDS4MISTER_DISABLE_3D_FOG") ? (1u << 7) : 0);
    DropShadows = enabled("NDS4MISTER_DISABLE_3D_SHADOWS");
    AlternateRowsRequested = enabled("NDS4MISTER_ALTERNATE_3D_ROWS");
    Sema_RenderStart = Platform::Semaphore_Create();
    Sema_RenderDone = Platform::Semaphore_Create();
    Sema_ScanlineCount = Platform::Semaphore_Create();
    Sema_ParallelRasterStart = Platform::Semaphore_Create();
    Sema_ParallelRasterDone = Platform::Semaphore_Create();

    RenderThreadRunning = false;
    RenderThreadRendering = false;
    RenderThread = nullptr;
    ParallelRasterThreadRunning = false;
    ParallelRasterThread = nullptr;
    const char* dualCoreRaster = std::getenv("NDS4MISTER_DUAL_CORE_3D");
    DualCoreRaster = dualCoreRaster && strcmp(dualCoreRaster, "0") != 0;
    const char* parallelClear = std::getenv("NDS4MISTER_PARALLEL_CLEAR");
    ParallelClear = parallelClear && strcmp(parallelClear, "1") == 0;
    const char* parallelFinal = std::getenv("NDS4MISTER_PARALLEL_FINAL_PASS");
    ParallelFinalPass = parallelFinal && strcmp(parallelFinal, "1") == 0;
    const char* adaptiveRasterSplit =
        std::getenv("NDS4MISTER_ADAPTIVE_RASTER_SPLIT");
    AdaptiveRasterSplit = DualCoreRaster && adaptiveRasterSplit &&
        strcmp(adaptiveRasterSplit, "0") != 0;
    const char* rasterBandQueue =
        std::getenv("NDS4MISTER_RASTER_BAND_QUEUE");
    RasterBandQueue = DualCoreRaster && rasterBandQueue &&
        strcmp(rasterBandQueue, "0") != 0;
    const char* weightedRasterBands =
        std::getenv("NDS4MISTER_WEIGHTED_RASTER_BANDS");
    WeightedRasterBands = RasterBandQueue && weightedRasterBands &&
        strcmp(weightedRasterBands, "1") == 0;
    const char* rasterXPartition =
        std::getenv("NDS4MISTER_RASTER_X_PARTITION");
    RasterXPartition = DualCoreRaster &&
        rasterXPartition && strcmp(rasterXPartition, "0") != 0;
    const char* rasterBandQueueTestDelay =
        std::getenv("NDS4MISTER_RASTER_BAND_TEST_DELAY_WORKER");
    RasterBandQueueTestDelayWorker = RasterBandQueue &&
        rasterBandQueueTestDelay &&
        strcmp(rasterBandQueueTestDelay, "1") == 0;
    if (DualCoreRaster)
        ParallelPolygonList = std::make_unique<RendererPolygon[]>(
            MaxRendererPolygons);
    UseTextureCache = std::getenv("NDS4MISTER_DISABLE_SOFT_TEXTURE_CACHE") == nullptr;
    const char* uploadSnapshot = std::getenv("NDS4MISTER_H3D_UPLOAD_SNAPSHOT");
    PreserveUploadSnapshot = uploadSnapshot && strcmp(uploadSnapshot, "1") == 0;
    const char* uploadTrace = std::getenv("NDS4MISTER_BLACK_EVENT_TRACE");
    UploadTraceEnabled = uploadTrace && strcmp(uploadTrace, "1") == 0;
    SparseClearEnabled =
        std::getenv("NDS4MISTER_DISABLE_SPARSE_3D_CLEAR") == nullptr;
}

void SoftRenderer3D::GetNativeBufferHashes(u64 hashes[3]) const noexcept
{
    const auto hashWords = [](const u32* words, size_t count) {
        u64 hash = 1469598103934665603ULL;
        for (size_t index = 0; index < count; ++index)
        {
            hash ^= words[index];
            hash *= 1099511628211ULL;
        }
        return hash;
    };
    hashes[0] = hashWords(ColorBuffer, BufferSize * 2);
    hashes[1] = hashWords(DepthBuffer, BufferSize * 2);
    hashes[2] = hashWords(AttrBuffer, BufferSize * 2);
}

SoftRenderer3D::~SoftRenderer3D()
{
    StopRenderThread();
    const char* report=std::getenv("NDS4MISTER_RENDER_CACHE_STATS");
    if(report && std::strcmp(report,"1")==0 && TextureHistoryFrames)
        if(FILE* f=std::fopen("/tmp/nds-render-cache-stats.jsonl","a"))
        {
            std::fprintf(f,"{\"render_frames\":%llu,\"texture_hits\":%llu,\"texture_misses\":%llu}\n",
                (unsigned long long)TextureHistoryFrames,
                (unsigned long long)TextureCache.ContentHistoryHits,
                (unsigned long long)TextureCache.ContentHistoryMisses);
            std::fclose(f);
        }

    TextureCache.Reset();

    Platform::Semaphore_Free(Sema_RenderStart);
    Platform::Semaphore_Free(Sema_RenderDone);
    Platform::Semaphore_Free(Sema_ScanlineCount);
    Platform::Semaphore_Free(Sema_ParallelRasterStart);
    Platform::Semaphore_Free(Sema_ParallelRasterDone);
}

void SoftRenderer3D::Reset()
{
    RasterTileHistoryValid = false;
    CollectRasterTileCosts = false;
    TextureCache.Reset();

    memset(ColorBuffer, 0, BufferSize * 2 * 4);
    memset(DepthBuffer, 0, BufferSize * 2 * 4);
    memset(AttrBuffer, 0, BufferSize * 2 * 4);

    SparseClearStateValid = false;

    PrevIsShadowMask = false;

    SetupRenderThread();
    EffectiveDispCnt = GPU3D.RenderDispCnt & ~CurrentEffectMask();
    UpdateAlternateRows();
    // SetupRenderThread joins any prior job before controller state is
    // rewritten, keeping reset free of a worker-thread data race.
    FpgaAdmission.reset();
    FpgaProfile.reset();
    RasterBalance.Reset();
    RasterBandQueueActive = false;
    RasterBandHeavyFrames = 0;
    RasterBandLightFrames = 0;
    RenderCancelRequested.store(false, std::memory_order_relaxed);
    RenderFrameCanceled.store(false, std::memory_order_relaxed);
    RenderForceNextFrame.store(false, std::memory_order_relaxed);
    EnableRenderThread();
}

bool SoftRenderer3D::RequestFrameCancellation() noexcept
{
    // The hybrid service consumes only complete 3D planes. Ordinary melonDS
    // scanline consumers cannot abandon a frame because they may already be
    // waiting on its per-line semaphore tokens.
    if (!FullFrameCompletion ||
        !RenderThreadRunning.load(std::memory_order_acquire) ||
        RenderFrameFinished)
        return false;

    RenderCancelRequested.store(true, std::memory_order_relaxed);
    if (Parent.StageProfileEnabled)
        ++Parent.StageProfile.ThreeDRasterCancelRequests;
    return true;
}

bool SoftRenderer3D::CancelRasterIfRequested() noexcept
{
    if (!RenderCancelRequested.load(std::memory_order_relaxed)) return false;
    RenderFrameCanceled.store(true, std::memory_order_relaxed);
    // GPU3D may classify the successor as identical to this architectural
    // frame. Because this frame's pixels will not be published, one complete
    // recovery raster is mandatory before identical-plane reuse is safe.
    RenderForceNextFrame.store(true, std::memory_order_relaxed);
    return true;
}

u32* SoftTexcacheLoader::GenerateTexture(
    u32 width, u32 height, u32 layers)
{
    // Each decoded layer owns one maximum-alpha word per texture row.
    // It is refreshed with the pixels by the existing cache invalidation.
    return new u32[(static_cast<size_t>(width) * height + height) * layers];
}

void SoftTexcacheLoader::UploadTexture(
    u32* handle, u32 width, u32 height, u32 layer, void* data)
{
    const size_t pixels = static_cast<size_t>(width) * height;
    u32* destination = handle + (pixels + height) * layer;
    memcpy(destination, data, pixels * sizeof(u32));
    for (u32 y = 0; y < height; ++y)
    {
        u32 maximum = 0;
        for (u32 x = 0; x < width; ++x)
            maximum = std::max(maximum, destination[y * width + x] >> 24);
        destination[pixels + y] = maximum;
    }
}

void SoftTexcacheLoader::DeleteTexture(u32* handle)
{
    delete[] handle;
}

void SoftRenderer3D::SetThreaded(bool threaded) noexcept
{
    if (Threaded != threaded)
    {
        Threaded = threaded;
        SetupRenderThread();
        const u32 next = GPU3D.RenderDispCnt & ~CurrentEffectMask();
        if (next != EffectiveDispCnt) FrameIdentical = false;
        EffectiveDispCnt = next;
        UpdateAlternateRows();
        EnableRenderThread();
    }
}

void SoftRenderer3D::TextureLookup(
    const RendererPolygon::PixelShaderState& state,
    s16 s, s16 t, u16* color, u8* alpha) const
{
    // TODO: consider using texture cache
    // however, I like the idea of having a "hardware accurate" path

    u32 vramaddr = state.TextureBase;
    const s32 width = state.TextureWidth;
    const s32 height = state.TextureHeight;

    s >>= 4;
    t >>= 4;

    // texture wrapping
    // TODO: optimize this somehow
    // testing shows that it's hardly worth optimizing, actually

    if (state.TextureWrapFlags & 0x1)
    {
        if (state.TextureWrapFlags & 0x4)
        {
            if (s & width) s = (width-1) - (s & (width-1));
            else           s = (s & (width-1));
        }
        else
            s &= width-1;
    }
    else
    {
        if (s < 0) s = 0;
        else if (s >= width) s = width-1;
    }

    if (state.TextureWrapFlags & 0x2)
    {
        if (state.TextureWrapFlags & 0x8)
        {
            if (t & height) t = (height-1) - (t & (height-1));
            else            t = (t & (height-1));
        }
        else
            t &= height-1;
    }
    else
    {
        if (t < 0) t = 0;
        else if (t >= height) t = height-1;
    }

    const u8 alpha0 = state.Alpha0;

    switch (state.TextureFormat)
    {
    case 1: // A3I5
        {
            vramaddr += ((t * width) + s);
            u8 pixel = GPU.ReadVRAMFlat_Texture<u8>(vramaddr);

            *color = GPU.ReadVRAMFlat_TexPal<u16>(
                state.TexturePaletteBase + ((pixel&0x1F)<<1));
            *alpha = ((pixel >> 3) & 0x1C) + (pixel >> 6);
        }
        break;

    case 2: // 4-color
        {
            vramaddr += (((t * width) + s) >> 2);
            u8 pixel = GPU.ReadVRAMFlat_Texture<u8>(vramaddr);
            pixel >>= ((s & 0x3) << 1);
            pixel &= 0x3;

            *color = GPU.ReadVRAMFlat_TexPal<u16>(
                state.TexturePaletteBase + (pixel<<1));
            *alpha = (pixel==0) ? alpha0 : 31;
        }
        break;

    case 3: // 16-color
        {
            vramaddr += (((t * width) + s) >> 1);
            u8 pixel = GPU.ReadVRAMFlat_Texture<u8>(vramaddr);
            if (s & 0x1) pixel >>= 4;
            else         pixel &= 0xF;

            *color = GPU.ReadVRAMFlat_TexPal<u16>(
                state.TexturePaletteBase + (pixel<<1));
            *alpha = (pixel==0) ? alpha0 : 31;
        }
        break;

    case 4: // 256-color
        {
            vramaddr += ((t * width) + s);
            u8 pixel = GPU.ReadVRAMFlat_Texture<u8>(vramaddr);

            *color = GPU.ReadVRAMFlat_TexPal<u16>(
                state.TexturePaletteBase + (pixel<<1));
            *alpha = (pixel==0) ? alpha0 : 31;
        }
        break;

    case 5: // compressed
        {
            vramaddr += ((t & 0x3FC) * (width>>2)) + (s & 0x3FC);
            vramaddr += (t & 0x3);
            vramaddr &= 0x7FFFF; // address used for all calcs wraps around after slot 3

            u32 slot1addr = 0x20000 + ((vramaddr & 0x1FFFC) >> 1);
            if (vramaddr >= 0x40000)
                slot1addr += 0x10000;

            u8 val;
            if (vramaddr >= 0x20000 && vramaddr < 0x40000) // reading slot 1 for texels should always read 0
                val = 0;
            else
            {
                val = GPU.ReadVRAMFlat_Texture<u8>(vramaddr);
                val >>= (2 * (s & 0x3));
            }

            u16 palinfo = GPU.ReadVRAMFlat_Texture<u16>(slot1addr);
            u32 paloffset = (palinfo & 0x3FFF) << 2;
            const u32 texpal = state.TexturePaletteBase;

            switch (val & 0x3)
            {
            case 0:
                *color = GPU.ReadVRAMFlat_TexPal<u16>(texpal + paloffset);
                *alpha = 31;
                break;

            case 1:
                *color = GPU.ReadVRAMFlat_TexPal<u16>(texpal + paloffset + 2);
                *alpha = 31;
                break;

            case 2:
                if ((palinfo >> 14) == 1)
                {
                    u16 color0 = GPU.ReadVRAMFlat_TexPal<u16>(texpal + paloffset);
                    u16 color1 = GPU.ReadVRAMFlat_TexPal<u16>(texpal + paloffset + 2);

                    u32 r0 = color0 & 0x001F;
                    u32 g0 = color0 & 0x03E0;
                    u32 b0 = color0 & 0x7C00;
                    u32 r1 = color1 & 0x001F;
                    u32 g1 = color1 & 0x03E0;
                    u32 b1 = color1 & 0x7C00;

                    u32 r = (r0 + r1) >> 1;
                    u32 g = ((g0 + g1) >> 1) & 0x03E0;
                    u32 b = ((b0 + b1) >> 1) & 0x7C00;

                    *color = r | g | b;
                }
                else if ((palinfo >> 14) == 3)
                {
                    u16 color0 = GPU.ReadVRAMFlat_TexPal<u16>(texpal + paloffset);
                    u16 color1 = GPU.ReadVRAMFlat_TexPal<u16>(texpal + paloffset + 2);

                    u32 r0 = color0 & 0x001F;
                    u32 g0 = color0 & 0x03E0;
                    u32 b0 = color0 & 0x7C00;
                    u32 r1 = color1 & 0x001F;
                    u32 g1 = color1 & 0x03E0;
                    u32 b1 = color1 & 0x7C00;

                    u32 r = (r0*5 + r1*3) >> 3;
                    u32 g = ((g0*5 + g1*3) >> 3) & 0x03E0;
                    u32 b = ((b0*5 + b1*3) >> 3) & 0x7C00;

                    *color = r | g | b;
                }
                else
                    *color = GPU.ReadVRAMFlat_TexPal<u16>(texpal + paloffset + 4);
                *alpha = 31;
                break;

            case 3:
                if ((palinfo >> 14) == 2)
                {
                    *color = GPU.ReadVRAMFlat_TexPal<u16>(texpal + paloffset + 6);
                    *alpha = 31;
                }
                else if ((palinfo >> 14) == 3)
                {
                    u16 color0 = GPU.ReadVRAMFlat_TexPal<u16>(texpal + paloffset);
                    u16 color1 = GPU.ReadVRAMFlat_TexPal<u16>(texpal + paloffset + 2);

                    u32 r0 = color0 & 0x001F;
                    u32 g0 = color0 & 0x03E0;
                    u32 b0 = color0 & 0x7C00;
                    u32 r1 = color1 & 0x001F;
                    u32 g1 = color1 & 0x03E0;
                    u32 b1 = color1 & 0x7C00;

                    u32 r = (r0*3 + r1*5) >> 3;
                    u32 g = ((g0*3 + g1*5) >> 3) & 0x03E0;
                    u32 b = ((b0*3 + b1*5) >> 3) & 0x7C00;

                    *color = r | g | b;
                    *alpha = 31;
                }
                else
                {
                    *color = 0;
                    *alpha = 0;
                }
                break;
            }
        }
        break;

    case 6: // A5I3
        {
            vramaddr += ((t * width) + s);
            u8 pixel = GPU.ReadVRAMFlat_Texture<u8>(vramaddr);

            *color = GPU.ReadVRAMFlat_TexPal<u16>(
                state.TexturePaletteBase + ((pixel&0x7)<<1));
            *alpha = (pixel >> 3);
        }
        break;

    case 7: // direct color
        {
            vramaddr += (((t * width) + s) << 1);
            *color = GPU.ReadVRAMFlat_Texture<u16>(vramaddr);
            *alpha = (*color & 0x8000) ? 31 : 0;
        }
        break;
    }
}

// depth test is 'less or equal' instead of 'less than' under the following conditions:
// * when drawing a front-facing pixel over an opaque back-facing pixel
// * when drawing wireframe edges, under certain conditions (TODO)
//
// range is different based on depth-buffering mode
// Z-buffering: +-0x200
// W-buffering: +-0xFF

bool DepthTest_Equal_Z(s32 dstz, s32 z, u32 dstattr)
{
    s32 diff = dstz - z;
    if ((u32)(diff + 0x200) <= 0x400)
        return true;

    return false;
}

bool DepthTest_Equal_W(s32 dstz, s32 z, u32 dstattr)
{
    s32 diff = dstz - z;
    if ((u32)(diff + 0xFF) <= 0x1FE)
        return true;

    return false;
}

bool DepthTest_LessThan(s32 dstz, s32 z, u32 dstattr)
{
    if (z < dstz)
        return true;

    return false;
}

bool DepthTest_LessThan_FrontFacing(s32 dstz, s32 z, u32 dstattr)
{
    if ((dstattr & 0x00400010) == 0x00000010) // opaque, back facing
    {
        if (z <= dstz)
            return true;
    }
    else
    {
        if (z < dstz)
            return true;
    }

    return false;
}

inline bool RunDepthTest(
    bool (*test)(s32, s32, u32), s32 dstz, s32 z, u32 dstattr)
{
    // Front-facing, less-than depth testing is overwhelmingly the common
    // raster path. Avoid an indirect call for it while retaining the exact
    // specialized functions for the uncommon modes.
    if (test == DepthTest_LessThan_FrontFacing)
        return z < dstz ||
            (z == dstz && (dstattr & 0x00400010) == 0x00000010);
    // Live Mario Kart profiling found ordinary back-facing less-than spans to
    // be the second depth mode (13.8% of polygon scanlines). Keep that exact
    // comparison direct as well; equal-Z/equal-W retain the generic fallback.
    if (test == DepthTest_LessThan)
        return z < dstz;
    return test(dstz, z, dstattr);
}

u32 SoftRenderer3D::AlphaBlend(u32 srccolor, u32 dstcolor, u32 alpha) const noexcept
{
    u32 dstalpha = dstcolor >> 24;

    if (dstalpha == 0)
        return srccolor;

    u32 srcR = srccolor & 0x3F;
    u32 srcG = (srccolor >> 8) & 0x3F;
    u32 srcB = (srccolor >> 16) & 0x3F;

    if (EffectiveDispCnt & (1<<3))
    {
        u32 dstR = dstcolor & 0x3F;
        u32 dstG = (dstcolor >> 8) & 0x3F;
        u32 dstB = (dstcolor >> 16) & 0x3F;

        alpha++;
        srcR = NDS4MiSTerAlphaBlendChannel(srcR, dstR, alpha);
        srcG = NDS4MiSTerAlphaBlendChannel(srcG, dstG, alpha);
        srcB = NDS4MiSTerAlphaBlendChannel(srcB, dstB, alpha);
        alpha--;
    }

    if (alpha > dstalpha)
        dstalpha = alpha;

    return srcR | (srcG << 8) | (srcB << 16) | (dstalpha << 24);
}

u32 SoftRenderer3D::RenderPixelSlow(
    const RendererPolygon::PixelShaderState& state,
    u8 vr, u8 vg, u8 vb, s16 s, s16 t) const
{
    u8 r, g, b, a;

    const u32 blendmode = state.BlendMode;
    const u32 polyalpha = state.PolyAlpha;

    if (blendmode == 2)
    {
        if (state.Highlight)
        {
            // highlight mode: color is calculated normally
            // except all vertex color components are set
            // to the red component
            // the toon color is added to the final color

            vg = vr;
            vb = vr;
        }
        else
        {
            // toon mode: vertex color is replaced by toon color

            u16 tooncolor = GPU3D.RenderToonTable[vr >> 1];

            vr = (tooncolor << 1) & 0x3E; if (vr) vr++;
            vg = (tooncolor >> 4) & 0x3E; if (vg) vg++;
            vb = (tooncolor >> 9) & 0x3E; if (vb) vb++;
        }
    }

    if (state.TextureEnabled)
    {
        u8 tr, tg, tb, talpha;
        if (state.TexturePixels)
        {
            const s32 width = state.TextureWidth;
            const s32 height = state.TextureHeight;
            const s32 widthMask = state.TextureWidthMask;
            const s32 heightMask = state.TextureHeightMask;

            s >>= 4;
            t >>= 4;

            if (state.TextureWrapFlags & 0x1)
            {
                if (state.TextureWrapFlags & 0x4)
                {
                    if (s & width) s = widthMask - (s & widthMask);
                    else           s &= widthMask;
                }
                else
                    s &= widthMask;
            }
            else
            {
                if (s < 0) s = 0;
                else if (s >= width) s = widthMask;
            }

            if (state.TextureWrapFlags & 0x2)
            {
                if (state.TextureWrapFlags & 0x8)
                {
                    if (t & height) t = heightMask - (t & heightMask);
                    else            t &= heightMask;
                }
                else
                    t &= heightMask;
            }
            else
            {
                if (t < 0) t = 0;
                else if (t >= height) t = heightMask;
            }

            const u32 texel = state.TexturePixels[
                (static_cast<u32>(t) << state.TextureWidthShift) +
                    static_cast<u32>(s)];
            tr = texel & 0x3F;
            tg = (texel >> 8) & 0x3F;
            tb = (texel >> 16) & 0x3F;
            talpha = texel >> 24;
        }
        else
        {
            u16 tcolor;
            TextureLookup(state, s, t, &tcolor, &talpha);
            tr = (tcolor << 1) & 0x3E; if (tr) tr++;
            tg = (tcolor >> 4) & 0x3E; if (tg) tg++;
            tb = (tcolor >> 9) & 0x3E; if (tb) tb++;
        }

        if (blendmode & 0x1)
        {
            // decal

            if (talpha == 0)
            {
                r = vr;
                g = vg;
                b = vb;
            }
            else if (talpha == 31)
            {
                r = tr;
                g = tg;
                b = tb;
            }
            else
            {
                r = ((tr * talpha) + (vr * (31-talpha))) >> 5;
                g = ((tg * talpha) + (vg * (31-talpha))) >> 5;
                b = ((tb * talpha) + (vb * (31-talpha))) >> 5;
            }
            a = polyalpha;
        }
        else
        {
            // modulate

            r = ((tr+1) * (vr+1) - 1) >> 6;
            g = ((tg+1) * (vg+1) - 1) >> 6;
            b = ((tb+1) * (vb+1) - 1) >> 6;
            a = ((talpha+1) * (polyalpha+1) - 1) >> 5;
        }
    }
    else
    {
        r = vr;
        g = vg;
        b = vb;
        a = polyalpha;
    }

    if (state.Highlight)
    {
        u16 tooncolor = GPU3D.RenderToonTable[vr >> 1];

        vr = (tooncolor << 1) & 0x3E; if (vr) vr++;
        vg = (tooncolor >> 4) & 0x3E; if (vg) vg++;
        vb = (tooncolor >> 9) & 0x3E; if (vb) vb++;

        r += vr;
        g += vg;
        b += vb;

        if (r > 63) r = 63;
        if (g > 63) g = 63;
        if (b > 63) b = 63;
    }

    // checkme: can wireframe polygons use texture alpha?
    if (state.Wireframe) a = 31;

    return r | (g << 8) | (b << 16) | (a << 24);
}

[[gnu::always_inline, gnu::hot]] inline u32
SoftRenderer3D::LookupCachedTexel(
    const RendererPolygon::PixelShaderState& state,
    s16 s, s16 t)
{
    return state.TexturePixels[NDS4MiSTerCachedTextureIndex(
        s, t, state.TextureWidth, state.TextureHeight,
        state.TextureWidthMask, state.TextureHeightMask,
        state.TextureWrapFlags, state.TextureWidthShift)];
}

[[gnu::always_inline, gnu::hot]] inline u32
SoftRenderer3D::RenderPixelCachedModulate(
    const RendererPolygon::PixelShaderState& state,
    u32 vertexColor, s16 s, s16 t)
{
    static_assert([] {
        for (u32 textureAlpha = 0; textureAlpha <= 31; ++textureAlpha)
            if ((((textureAlpha + 1) * 32 - 1) >> 5) != textureAlpha)
                return false;
        return true;
    }(), "opaque polygon modulation must preserve all DS texture alphas");

    const u32 texel = LookupCachedTexel(state, s, t);
    return NDS4MiSTerModulateCachedPixel(
        texel, vertexColor, state.PolyAlpha);
}

#if defined(__arm__) && defined(__ARM_NEON)
[[gnu::always_inline, gnu::hot]] inline uint32x4_t
SoftRenderer3D::LookupCachedTexels4(
    const RendererPolygon::PixelShaderState& state,
    const s16* textureS, const s16* textureT)
{
    alignas(16) u32 indices[4];
    NDS4MiSTerTextureIndices4(
        textureS, textureT,
        state.TextureWidth, state.TextureHeight,
        state.TextureWidthMask, state.TextureHeightMask,
        state.TextureWrapFlags, state.TextureWidthShift, indices);
    return NDS4MiSTerGatherCachedTexels4(state.TexturePixels, indices);
}
#endif

void SoftRenderer3D::PlotTranslucentPixel(u32 pixeladdr, u32 color, u32 z, u32 polyattr, u32 shadow)
{
    u32 dstattr = AttrBuffer[pixeladdr];
    u32 attr = NDS4MiSTerComposeTranslucentAttr(polyattr, dstattr);

    if (shadow)
    {
        // for shadows, opaque pixels are also checked
        if (dstattr & (1<<22))
        {
            if ((dstattr & 0x007F0000) == (attr & 0x007F0000))
                return;
        }
        else
        {
            if ((dstattr & 0x3F000000) == (polyattr & 0x3F000000))
                return;
        }
    }
    else
    {
        // skip if translucent polygon IDs are equal
        if ((dstattr & 0x007F0000) == (attr & 0x007F0000))
            return;
    }

    // fog flag
    if (!(dstattr & (1<<15)))
        attr &= ~(1<<15);

    color = AlphaBlend(color, ColorBuffer[pixeladdr], color>>24);

    if (z != -1)
        DepthBuffer[pixeladdr] = z;

    ColorBuffer[pixeladdr] = color;
    AttrBuffer[pixeladdr] = attr;
}

void SoftRenderer3D::SetupPolygonLeftEdge(SoftRenderer3D::RendererPolygon* rp, s32 y) const
{
    Polygon* polygon = rp->PolyData;

    while (y >= polygon->Vertices[rp->NextVL]->FinalPosition[1] && rp->CurVL != polygon->VBottom)
    {
        rp->CurVL = rp->NextVL;

        if (polygon->FacingView)
        {
            rp->NextVL = rp->CurVL + 1;
            if (rp->NextVL >= polygon->NumVertices)
                rp->NextVL = 0;
        }
        else
        {
            rp->NextVL = rp->CurVL - 1;
            if ((s32)rp->NextVL < 0)
                rp->NextVL = polygon->NumVertices - 1;
        }
    }

    rp->XL = rp->SlopeL.Setup(RasterX(polygon->Vertices[rp->CurVL]), RasterX(polygon->Vertices[rp->NextVL]),
                              polygon->Vertices[rp->CurVL]->FinalPosition[1], polygon->Vertices[rp->NextVL]->FinalPosition[1],
                              polygon->FinalW[rp->CurVL], polygon->FinalW[rp->NextVL], y, polygon->WBuffer);
}

void SoftRenderer3D::SetupPolygonRightEdge(SoftRenderer3D::RendererPolygon* rp, s32 y) const
{
    Polygon* polygon = rp->PolyData;

    while (y >= polygon->Vertices[rp->NextVR]->FinalPosition[1] && rp->CurVR != polygon->VBottom)
    {
        rp->CurVR = rp->NextVR;

        if (polygon->FacingView)
        {
            rp->NextVR = rp->CurVR - 1;
            if ((s32)rp->NextVR < 0)
                rp->NextVR = polygon->NumVertices - 1;
        }
        else
        {
            rp->NextVR = rp->CurVR + 1;
            if (rp->NextVR >= polygon->NumVertices)
                rp->NextVR = 0;
        }
    }

    rp->XR = rp->SlopeR.Setup(RasterX(polygon->Vertices[rp->CurVR]), RasterX(polygon->Vertices[rp->NextVR]),
                              polygon->Vertices[rp->CurVR]->FinalPosition[1], polygon->Vertices[rp->NextVR]->FinalPosition[1],
                              polygon->FinalW[rp->CurVR], polygon->FinalW[rp->NextVR], y, polygon->WBuffer);
}

void SoftRenderer3D::SetupPolygon(
    SoftRenderer3D::RendererPolygon* rp, Polygon* polygon,
    TextureBindingCache& textureBinding)
{
    u32 nverts = polygon->NumVertices;

    u32 vtop = polygon->VTop, vbot = polygon->VBottom;
    s32 ytop = polygon->YTop, ybot = polygon->YBottom;

    rp->PolyData = polygon;

    const u32 textureFormat = (polygon->TexParam >> 26) & 0x7;
    auto& pixelState = rp->PixelState;
    pixelState.TextureBase = (polygon->TexParam & 0xFFFF) << 3;
    pixelState.TextureWidth = 8 << ((polygon->TexParam >> 20) & 0x7);
    pixelState.TextureHeight = 8 << ((polygon->TexParam >> 23) & 0x7);
    pixelState.TextureWidthMask = pixelState.TextureWidth - 1;
    pixelState.TextureHeightMask = pixelState.TextureHeight - 1;
    pixelState.TextureWidthShift = static_cast<u8>(
        3 + ((polygon->TexParam >> 20) & 0x7));
    pixelState.TextureFormat = static_cast<u8>(textureFormat);
    pixelState.TextureWrapFlags =
        static_cast<u8>((polygon->TexParam >> 16) & 0xF);
    pixelState.TexturePaletteBase = polygon->TexPalette <<
        (textureFormat == 2 ? 3 : 4);
    pixelState.BlendMode = static_cast<u8>((polygon->Attr >> 4) & 0x3);
    pixelState.PolyAlpha = static_cast<u8>((polygon->Attr >> 16) & 0x1F);
    pixelState.Alpha0 = (polygon->TexParam & (1<<29)) ? 0 : 31;
    pixelState.TextureEnabled =
        (EffectiveDispCnt & (1<<0)) && textureFormat != 0;
    pixelState.TexturePixels = nullptr;
    if (pixelState.TextureEnabled && UseTextureCache)
    {
        const u32* cachedPixels = textureBinding.Pixels;
        // These side-effect-free terms are intentionally evaluated together
        // so ARM can overlap both key-word loads before their comparisons.
        const bool bindingMatches = NDS4MiSTerTextureBindingMatches(
            textureBinding.TexParam, textureBinding.TexPalette,
            polygon->TexParam, polygon->TexPalette);
        if (__builtin_expect(bindingMatches, 1))
        {
            pixelState.TexturePixels = cachedPixels;
        }
        else
        {
            u32* textureArray;
            u32 textureLayer;
            u32* textureHelper;
            TextureCache.GetTexture(
                polygon->TexParam, polygon->TexPalette,
                textureArray, textureLayer, textureHelper);
            pixelState.TexturePixels = textureArray +
                static_cast<size_t>(textureLayer) *
                    (pixelState.TextureWidth * pixelState.TextureHeight +
                     pixelState.TextureHeight);
            textureBinding.Pixels = pixelState.TexturePixels;
            textureBinding.TexParam = polygon->TexParam;
            textureBinding.TexPalette = polygon->TexPalette;
        }
    }
    pixelState.Highlight =
        pixelState.BlendMode == 2 && (EffectiveDispCnt & (1<<1));
    pixelState.Wireframe = pixelState.PolyAlpha == 0;
    pixelState.CachedModulate = pixelState.TexturePixels &&
        pixelState.BlendMode == 0 && !pixelState.Highlight &&
        !pixelState.Wireframe;

    // Equal vertex colors stay equal through both edge and span interpolation.
    // Check once per polygon so every covered row can reuse the exact input.
    pixelState.ConstantVertexColor = true;
    const auto* firstColor = polygon->Vertices[0]->FinalColor;
    for (u32 i = 1; i < nverts; ++i)
    {
        const auto* color = polygon->Vertices[i]->FinalColor;
        if (color[0] != firstColor[0] || color[1] != firstColor[1] ||
            color[2] != firstColor[2])
        {
            pixelState.ConstantVertexColor = false;
            break;
        }
    }

    rp->PolyAttr = polygon->Attr & 0x3F008000;
    if (!polygon->FacingView) rp->PolyAttr |= (1<<4);
    if (polygon->Attr & (1<<14))
        rp->DepthTest = polygon->WBuffer ? DepthTest_Equal_W : DepthTest_Equal_Z;
    else if (polygon->FacingView)
        rp->DepthTest = DepthTest_LessThan_FrontFacing;
    else
        rp->DepthTest = DepthTest_LessThan;

    if (Parent.StageProfileEnabled)
    {
        const u64 visibleScanlines = static_cast<u64>(std::max(
            0, std::min(polygon->YBottom, VisibleScanlines) -
                std::max(polygon->YTop, 0)));
        unsigned mode = 0;
        if (polygon->IsShadowMask) mode = 2;
        else if (polygon->IsShadow) mode = 3;
        else if (pixelState.PolyAlpha < 31 || pixelState.Wireframe) mode = 1;
        ++Parent.StageProfile.ThreeDModePolygons[mode];
        Parent.StageProfile.ThreeDModeScanlines[mode] += visibleScanlines;

        ++Parent.StageProfile.ThreeDTextureFormatPolygons[textureFormat];
        Parent.StageProfile.ThreeDTextureFormatScanlines[textureFormat] +=
            visibleScanlines;
        ++Parent.StageProfile.ThreeDBlendModePolygons[pixelState.BlendMode];
        Parent.StageProfile.ThreeDBlendModeScanlines[pixelState.BlendMode] +=
            visibleScanlines;

        unsigned depthMode = 0;
        if (rp->DepthTest == DepthTest_LessThan) depthMode = 1;
        else if (rp->DepthTest == DepthTest_Equal_Z) depthMode = 2;
        else if (rp->DepthTest == DepthTest_Equal_W) depthMode = 3;
        ++Parent.StageProfile.ThreeDDepthModePolygons[depthMode];
        Parent.StageProfile.ThreeDDepthModeScanlines[depthMode] +=
            visibleScanlines;

        if (pixelState.CachedModulate)
        {
            ++Parent.StageProfile.ThreeDCachedModulatePolygons;
            Parent.StageProfile.ThreeDCachedModulateScanlines +=
                visibleScanlines;
        }
        Parent.StageProfile.ThreeDAntiAliasPolygons +=
            (EffectiveDispCnt >> 4) & 1;
        Parent.StageProfile.ThreeDEdgeMarkingPolygons +=
            (EffectiveDispCnt >> 5) & 1;
        Parent.StageProfile.ThreeDFogPolygons +=
            ((EffectiveDispCnt >> 7) & 1) &&
            ((polygon->Attr >> 15) & 1);
    }

    rp->CurVL = vtop;
    rp->CurVR = vtop;

    if (polygon->FacingView)
    {
        rp->NextVL = rp->CurVL + 1;
        if (rp->NextVL >= nverts) rp->NextVL = 0;
        rp->NextVR = rp->CurVR - 1;
        if ((s32)rp->NextVR < 0) rp->NextVR = nverts - 1;
    }
    else
    {
        rp->NextVL = rp->CurVL - 1;
        if ((s32)rp->NextVL < 0) rp->NextVL = nverts - 1;
        rp->NextVR = rp->CurVR + 1;
        if (rp->NextVR >= nverts) rp->NextVR = 0;
    }

    if (ybot == ytop)
    {
        vtop = 0; vbot = 0;
        int i;

        i = 1;
        if (RasterX(polygon->Vertices[i]) < RasterX(polygon->Vertices[vtop])) vtop = i;
        if (RasterX(polygon->Vertices[i]) > RasterX(polygon->Vertices[vbot])) vbot = i;

        i = nverts - 1;
        if (RasterX(polygon->Vertices[i]) < RasterX(polygon->Vertices[vtop])) vtop = i;
        if (RasterX(polygon->Vertices[i]) > RasterX(polygon->Vertices[vbot])) vbot = i;

        rp->CurVL = vtop; rp->NextVL = vtop;
        rp->CurVR = vbot; rp->NextVR = vbot;

        rp->XL = rp->SlopeL.SetupDummy(RasterX(polygon->Vertices[rp->CurVL]), polygon->WBuffer);
        rp->XR = rp->SlopeR.SetupDummy(RasterX(polygon->Vertices[rp->CurVR]), polygon->WBuffer);
    }
    else
    {
        SetupPolygonLeftEdge(rp, ytop);
        SetupPolygonRightEdge(rp, ytop);
    }
    // Prove all corners and their order: a quad bounding box alone also
    // accepts crossed or degenerate polygons. The session policy limits
    // this specialization to the qualified Castlevania cartridge.
    pixelState.FlatRectangle = false;
    pixelState.PreparedRectangle = false;
    pixelState.GrayRectangle = false;
    if (GPU3D.SpriteRasterSpansEnabled() && nverts == 4 &&
        ytop < ybot && rp->XL < rp->XR &&
        pixelState.CachedModulate && pixelState.PolyAlpha == 31 &&
        pixelState.ConstantVertexColor &&
        (firstColor[0] >> 3) == 63 && (firstColor[1] >> 3) == 63 &&
        (firstColor[2] >> 3) == 63 &&
        !polygon->IsShadow && !polygon->IsShadowMask &&
        (rp->DepthTest == DepthTest_LessThan_FrontFacing ||
         rp->DepthTest == DepthTest_LessThan) &&
        !(polygon->FinalW[0] & 0x7F) &&
        rp->SlopeL.Increment == 0 && rp->SlopeR.Increment == 0)
    {
        bool rectangle = true;
        unsigned corners = 0;
        for (u32 i = 0; i < 4; ++i)
        {
            const auto* v = polygon->Vertices[i];
            const auto* next = polygon->Vertices[(i + 1) & 3];
            const s32 x = RasterX(v), y = v->FinalPosition[1];
            rectangle &= (x == rp->XL || x == rp->XR) && (y == ytop || y == ybot);
            rectangle &= (x == RasterX(next)) != (y == next->FinalPosition[1]);
            rectangle &= polygon->FinalW[i] == polygon->FinalW[0] &&
                         polygon->FinalZ[i] == polygon->FinalZ[0];
            corners |= 1u << ((x == rp->XR ? 1 : 0) | (y == ybot ? 2 : 0));
        }
        rectangle &= polygon->Vertices[rp->CurVL]->FinalPosition[1] == ytop &&
                     polygon->Vertices[rp->CurVR]->FinalPosition[1] == ytop &&
                     polygon->Vertices[rp->NextVL]->FinalPosition[1] == ybot &&
                     polygon->Vertices[rp->NextVR]->FinalPosition[1] == ybot;
        pixelState.FlatRectangle = rectangle && corners == 15;
        if (pixelState.FlatRectangle)
        {
            const auto* tl = polygon->Vertices[rp->CurVL]->TexCoords;
            const auto* bl = polygon->Vertices[rp->NextVL]->TexCoords;
            const auto* tr = polygon->Vertices[rp->CurVR]->TexCoords;
            const auto* br = polygon->Vertices[rp->NextVR]->TexCoords;
            // A one-pixel rectangle has overlapping left/right boundaries.
            // The fallback can revisit that pixel through its empty interior
            // dispatch, affecting the hidden AA layer even when visible color
            // is identical. Keep that established ordering unchanged.
            pixelState.PreparedRectangle =
                rp->XR - rp->XL > 1 &&
                NDS4MiSTerPrepareRectangleTextureStep(
                    tl[0], bl[0], tr[0], br[0], rp->XR - rp->XL,
                    rp->RectangleStepS) &&
                NDS4MiSTerPrepareRectangleTextureStep(
                    tl[1], bl[1], tr[1], br[1], rp->XR - rp->XL,
                    rp->RectangleStepT);
        }
    }
    // Dawn of Sorrow's full-screen gray gradient is untextured and
    // translucent. Prove its actual corners, depth and equal RGB channels;
    // a bounding box alone would also accept crossed or slanted quads.
    // Alpha blending guarantees filled edges for this translucent path.
    if (GPU3D.SpriteRasterSpansEnabled() && nverts == 4 &&
        ytop < ybot && rp->XR - rp->XL > 1 &&
        !pixelState.TextureEnabled && pixelState.BlendMode == 0 &&
        pixelState.PolyAlpha > 0 && pixelState.PolyAlpha < 31 &&
        (EffectiveDispCnt & (1 << 3)) &&
        !polygon->IsShadow && !polygon->IsShadowMask &&
        (rp->DepthTest == DepthTest_LessThan_FrontFacing ||
         rp->DepthTest == DepthTest_LessThan) &&
        !(polygon->FinalW[0] & 0x7F) &&
        rp->SlopeL.Increment == 0 && rp->SlopeR.Increment == 0)
    {
        bool rectangle = true;
        unsigned corners = 0;
        for (u32 i = 0; i < 4; ++i)
        {
            const auto* v = polygon->Vertices[i];
            const auto* next = polygon->Vertices[(i + 1) & 3];
            const s32 x = RasterX(v), y = v->FinalPosition[1];
            rectangle &= (x == rp->XL || x == rp->XR) && (y == ytop || y == ybot);
            rectangle &= (x == RasterX(next)) != (y == next->FinalPosition[1]);
            rectangle &= polygon->FinalW[i] == polygon->FinalW[0] &&
                         polygon->FinalZ[i] == polygon->FinalZ[0];
            rectangle &= v->FinalColor[0] >= 0 && v->FinalColor[0] <= 511 &&
                         v->FinalColor[0] == v->FinalColor[1] &&
                         v->FinalColor[0] == v->FinalColor[2];
            corners |= 1u << ((x == rp->XR ? 1 : 0) | (y == ybot ? 2 : 0));
        }
        rectangle &= polygon->Vertices[rp->CurVL]->FinalPosition[1] == ytop &&
                     polygon->Vertices[rp->CurVR]->FinalPosition[1] == ytop &&
                     polygon->Vertices[rp->NextVL]->FinalPosition[1] == ybot &&
                     polygon->Vertices[rp->NextVR]->FinalPosition[1] == ybot;
        pixelState.GrayRectangle = rectangle && corners == 15;
        // Reuse the established rectangle dispatch. Adding a second test to
        // every generic polygon row measurably regressed NSMB on Cortex-A9.
        pixelState.FlatRectangle |= pixelState.GrayRectangle;
    }
}

void SoftRenderer3D::RenderShadowMaskScanline(
    RendererPolygon* rp, s32 y, bool& prevIsShadowMask,
    u8* stencilBuffer, s32 clipStartX, s32 clipEndX)
{
    Polygon* polygon = rp->PolyData;

    const u32 polyattr = rp->PolyAttr;
    u32 polyalpha = rp->PixelState.PolyAlpha;
    const bool wireframe = rp->PixelState.Wireframe;
    const auto fnDepthTest = rp->DepthTest;

    if (!prevIsShadowMask)
    {
        if(FpgaEmitting)FpgaFrame.append(fpga3d::stencilClear(y));
        else memset(&stencilBuffer[256 * (y&0x1)], 0, 256);
    }

    prevIsShadowMask = true;

    if (polygon->YTop != polygon->YBottom)
    {
        if (y >= polygon->Vertices[rp->NextVL]->FinalPosition[1] && rp->CurVL != polygon->VBottom)
        {
            SetupPolygonLeftEdge(rp, y);
        }

        if (y >= polygon->Vertices[rp->NextVR]->FinalPosition[1] && rp->CurVR != polygon->VBottom)
        {
            SetupPolygonRightEdge(rp, y);
        }
    }

    Vertex *vlcur, *vlnext, *vrcur, *vrnext;
    s32 xstart, xend;
    bool l_filledge, r_filledge;
    s32 l_edgelen, r_edgelen;
    s32 l_edgecov, r_edgecov;
    Interpolator<1>* interp_start;
    Interpolator<1>* interp_end;

    xstart = rp->XL;
    xend = rp->XR;

    s32 wl = rp->SlopeL.Interp.Interpolate(polygon->FinalW[rp->CurVL], polygon->FinalW[rp->NextVL]);
    s32 wr = rp->SlopeR.Interp.Interpolate(polygon->FinalW[rp->CurVR], polygon->FinalW[rp->NextVR]);

    s32 zl = rp->SlopeL.Interp.InterpolateZ(polygon->FinalZ[rp->CurVL], polygon->FinalZ[rp->NextVL]);
    s32 zr = rp->SlopeR.Interp.InterpolateZ(polygon->FinalZ[rp->CurVR], polygon->FinalZ[rp->NextVR]);

    // right vertical edges are pushed 1px to the left as long as either:
    // the left edge slope is not 0, or the span is not 0 pixels wide, and it is not at the leftmost pixel of the screen
    if (rp->SlopeR.Increment==0 && (rp->SlopeL.Increment!=0 || xstart != xend) && (xend != 0))
        xend--;

    // if the left and right edges are swapped, render backwards.
    if (xstart > xend)
    {
        vlcur = polygon->Vertices[rp->CurVR];
        vlnext = polygon->Vertices[rp->NextVR];
        vrcur = polygon->Vertices[rp->CurVL];
        vrnext = polygon->Vertices[rp->NextVL];

        interp_start = &rp->SlopeR.Interp;
        interp_end = &rp->SlopeL.Interp;

        rp->SlopeR.EdgeParams<true>(&l_edgelen, &l_edgecov);
        rp->SlopeL.EdgeParams<true>(&r_edgelen, &r_edgecov);

        std::swap(xstart, xend);
        std::swap(wl, wr);
        std::swap(zl, zr);

        // CHECKME: edge fill rules for swapped opaque shadow mask polygons
        if ((EffectiveDispCnt & ((1<<4)|(1<<5))) || ((polyalpha < 31) && (EffectiveDispCnt & (1<<3))) || wireframe)
        {
            l_filledge = true;
            r_filledge = true;
        }
        else
        {
            l_filledge = (rp->SlopeR.Negative || !rp->SlopeR.XMajor)
                || (y == polygon->YBottom-1) && rp->SlopeR.XMajor && (RasterX(vlnext) != RasterX(vrnext));
            r_filledge = (!rp->SlopeL.Negative && rp->SlopeL.XMajor)
                || (!(rp->SlopeL.Negative && rp->SlopeL.XMajor) && rp->SlopeR.Increment==0)
                || (y == polygon->YBottom-1) && rp->SlopeL.XMajor && (RasterX(vlnext) != RasterX(vrnext));
        }
    }
    else
    {
        vlcur = polygon->Vertices[rp->CurVL];
        vlnext = polygon->Vertices[rp->NextVL];
        vrcur = polygon->Vertices[rp->CurVR];
        vrnext = polygon->Vertices[rp->NextVR];

        interp_start = &rp->SlopeL.Interp;
        interp_end = &rp->SlopeR.Interp;

        rp->SlopeL.EdgeParams<false>(&l_edgelen, &l_edgecov);
        rp->SlopeR.EdgeParams<false>(&r_edgelen, &r_edgecov);

        // CHECKME: edge fill rules for unswapped opaque shadow mask polygons
        if ((EffectiveDispCnt & ((1<<4)|(1<<5))) || ((polyalpha < 31) && (EffectiveDispCnt & (1<<3))) || wireframe)
        {
            l_filledge = true;
            r_filledge = true;
        }
        else
        {
            l_filledge = ((rp->SlopeL.Negative || !rp->SlopeL.XMajor)
                || (y == polygon->YBottom-1) && rp->SlopeL.XMajor && (RasterX(vlnext) != RasterX(vrnext)))
                || (rp->SlopeL.Increment == rp->SlopeR.Increment) && (xstart+l_edgelen == xend+1);
            r_filledge = (!rp->SlopeR.Negative && rp->SlopeR.XMajor) || (rp->SlopeR.Increment==0)
                || (y == polygon->YBottom-1) && rp->SlopeR.XMajor && (RasterX(vlnext) != RasterX(vrnext));
        }
    }

    // color/texcoord attributes aren't needed for shadow masks
    // all the pixels are guaranteed to have the same alpha
    // even if a texture is used (decal blending is used for shadows)
    // similarly, we can perform alpha test early (checkme)

    if (wireframe) polyalpha = 31;
    if (polyalpha <= GPU3D.RenderAlphaRef) return;

    if(FpgaEmitting)
    {
        const auto clampX=[](s32 x){return std::clamp(x,0,256);};
        const s32 leftEnd=clampX(std::min(xstart+l_edgelen,xend+1));
        const s32 interiorEnd=clampX(std::min(xend-r_edgelen+1,xend+1));
        const s32 begin=l_filledge?clampX(xstart):leftEnd;
        s32 finish=std::max(begin,interiorEnd);
        if(l_filledge)finish=std::max(finish,leftEnd);
        if(r_filledge)finish=std::max(finish,clampX(xend+1));
        if(begin<finish && FpgaFrame.valid){
            fpga3d::Span sp;sp.first=begin;sp.end=finish;sp.origin=xstart;sp.width=xend+1-xstart;
            sp.w0=wl;sp.w1=wr;sp.z0=zl;sp.z1=zr;sp.mode=2;sp.polyAlpha=polyalpha;sp.alphaRef=GPU3D.RenderAlphaRef;
            sp.flags=((wl==wr && !(wl&127))?fpga3d::Linear:0)|(polygon->WBuffer?fpga3d::WBuffer:0)|
                (rp->DepthTest==DepthTest_LessThan_FrontFacing?fpga3d::Front:0)|((rp->PolyAttr&16)?fpga3d::Back:0)|
                ((rp->DepthTest==DepthTest_Equal_Z || rp->DepthTest==DepthTest_Equal_W)?fpga3d::Equal:0);
            try{FpgaFrame.append(fpga3d::span(sp));}catch(const std::invalid_argument&){FpgaFrame.valid=false;FpgaFrame.failure=fpga3d::Outcome::Span;}
        }
        rp->XL=rp->SlopeL.Step();rp->XR=rp->SlopeR.Step();return;
    }

    // in wireframe mode, there are special rules for equal Z (TODO)

    int yedge = 0;
    if (y == polygon->YTop)           yedge = 0x4;
    else if (y == polygon->YBottom-1) yedge = 0x8;
    int edge;

    s32 x = xstart;
    Interpolator<0> interpX(xstart, xend+1, wl, wr, polygon->WBuffer);

    if (x < clipStartX) x = clipStartX;
    s32 xlimit;

    // for shadow masks: set stencil bits where the depth test fails.
    // draw nothing.

    // part 1: left edge
    edge = yedge | 0x1;
    xlimit = xstart+l_edgelen;
    if (xlimit > xend+1) xlimit = xend+1;
    if (xlimit < clipStartX) xlimit = clipStartX;
    if (xlimit > clipEndX) xlimit = clipEndX;

    if (!l_filledge) x = xlimit;
    else
    for (; x < xlimit; x++)
    {
        u32 pixeladdr = FirstPixelOffset + (y*ScanlineWidth) + x;

        interpX.SetX(x);

        s32 z = interpX.InterpolateZ(zl, zr);
        u32 dstattr = AttrBuffer[pixeladdr];

        if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
            stencilBuffer[256*(y&0x1) + x] = 1;

        if (dstattr & 0xF)
        {
            pixeladdr += BufferSize;
            if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, AttrBuffer[pixeladdr]))
                stencilBuffer[256*(y&0x1) + x] |= 0x2;
        }
    }

    // part 2: polygon inside
    edge = yedge;
    xlimit = xend-r_edgelen+1;
    if (xlimit > xend+1) xlimit = xend+1;
    if (xlimit < clipStartX) xlimit = clipStartX;
    if (xlimit > clipEndX) xlimit = clipEndX;
    if (wireframe && !edge) x = std::max(x, xlimit);
    else for (; x < xlimit; x++)
    {
        u32 pixeladdr = FirstPixelOffset + (y*ScanlineWidth) + x;

        interpX.SetX(x);

        s32 z = interpX.InterpolateZ(zl, zr);
        u32 dstattr = AttrBuffer[pixeladdr];

        if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
            stencilBuffer[256*(y&0x1) + x] = 1;

        if (dstattr & 0xF)
        {
            pixeladdr += BufferSize;
            if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, AttrBuffer[pixeladdr]))
                stencilBuffer[256*(y&0x1) + x] |= 0x2;
        }
    }

    // part 3: right edge
    edge = yedge | 0x2;
    xlimit = xend+1;
    if (xlimit < clipStartX) xlimit = clipStartX;
    if (xlimit > clipEndX) xlimit = clipEndX;

    if (r_filledge)
    for (; x < xlimit; x++)
    {
        u32 pixeladdr = FirstPixelOffset + (y*ScanlineWidth) + x;

        interpX.SetX(x);

        s32 z = interpX.InterpolateZ(zl, zr);
        u32 dstattr = AttrBuffer[pixeladdr];

        if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
            stencilBuffer[256*(y&0x1) + x] = 1;

        if (dstattr & 0xF)
        {
            pixeladdr += BufferSize;
            if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, AttrBuffer[pixeladdr]))
                stencilBuffer[256*(y&0x1) + x] |= 0x2;
        }
    }

    rp->XL = rp->SlopeL.Step();
    rp->XR = rp->SlopeR.Step();
}

#if defined(__arm__) && defined(__ARM_NEON)
// Perspective factors remain scalar and exact. W-depth and attributes can
// batch four pixels. Select W-depth specialization once per span so Z-buffer
// pixels retain the original loop without a runtime batching-mode branch.
// Rendering and writes remain in X order.
template<bool BatchWDepth, bool OpaquePolygon>
[[gnu::hot, gnu::noinline]] s32
SoftRenderer3D::RenderCachedModulatePerspectiveInteriorBatch4(
    RendererPolygon* rp, s32 y, s32 firstX, s32 endX,
    Interpolator<0>& interpX,
    Interpolator<0>::SpanDepthInterpolator& spanDepth,
    Interpolator<0>::SpanInterpolator& spanAttributes)
{
    assert(OpaquePolygon ? rp->PixelState.PolyAlpha == 31 :
        rp->PixelState.PolyAlpha >= 1 && rp->PixelState.PolyAlpha < 31);
    Polygon* polygon = rp->PolyData;
    const auto& pixelState = rp->PixelState;
    const u32 polyattr = rp->PolyAttr;
    const u32 alphaRef = GPU3D.RenderAlphaRef;
    const bool writeTranslucentDepth = polygon->Attr & (1<<11);
    const u32 rowAddress = FirstPixelOffset + y * ScanlineWidth;
    // Classify and pack once per span, not once per lane. Only S/T need
    // perspective interpolation when all three color endpoints agree.
    u32 packedSpanColor = 0;
    const bool constantColor =
        spanAttributes.GetConstantColor(packedSpanColor);
    const auto coefficients = spanAttributes.PreparePerspectiveBatch();

    for (; firstX + 3 < endX; firstX += 4)
    {
        alignas(16) u32 factors[4];
        u32 pixelAddresses[4];
        s32 depths[4];
        u32 passingPixels = 0;
        bool allFront = true;

        if constexpr (BatchWDepth)
        {
            for (unsigned lane = 0; lane < 4; ++lane)
            {
                interpX.SetXFast<true>(firstX + lane);
                factors[lane] = interpX.PerspectiveFactor();
            }
            spanDepth.InterpolatePerspectiveDepthBatch4(factors, depths);
        }

        for (u32 lane = 0; lane < 4; ++lane)
        {
            const s32 x = firstX + static_cast<s32>(lane);
            const u32 frontAddress = rowAddress + x;
            u32 pixeladdr = frontAddress;

            s32 z;
            if constexpr (BatchWDepth)
                z = depths[lane];
            else
            {
                interpX.SetXFast<true>(x);
                z = spanDepth.Interpolate();
                factors[lane] = interpX.PerspectiveFactor();
            }

            // A strictly nearer pixel does not depend on destination
            // attributes. Share the scalar path's exact lazy selection;
            // equal depth and lower-layer fallback still consult them.
            if (!NDS4MiSTerSelectCachedDepthPixel(
                    DepthBuffer, AttrBuffer, LowerLayerBufferSize, z, pixeladdr))
            {
                allFront = false;
                continue;
            }
            if (pixeladdr != frontAddress)
                allFront = false;

            pixelAddresses[lane] = pixeladdr;
            depths[lane] = z;
            passingPixels |= 1u << lane;
        }

        if (passingPixels == 0)
            continue;

        alignas(16) u32 vertexColors[4];
        s16 textureS[4];
        s16 textureT[4];
        spanAttributes.InterpolatePerspectiveBatch4(
            factors, vertexColors, textureS, textureT,
            constantColor, packedSpanColor, coefficients);

        const bool fullDepthPass = passingPixels == 0xFu;
        alignas(16) u32 texels[4];
        if (fullDepthPass)
        {
            const uint32x4_t sourceVector =
                LookupCachedTexels4(pixelState, textureS, textureT);
            uint32x4_t colorVector;
            if constexpr (OpaquePolygon)
                colorVector = NDS4MiSTerModulateCachedOpaqueVector4(
                    sourceVector, vld1q_u32(vertexColors));
            else
                colorVector = NDS4MiSTerModulateCachedTranslucentVector4(
                    sourceVector, vld1q_u32(vertexColors), pixelState.PolyAlpha);
            // Four fully opaque adjacent front-layer pixels have no blend
            // dependencies. Preserve exactly the scalar color/depth/attr
            // writes, but commit each plane as one unaligned-safe vector.
            if (OpaquePolygon && allFront && alphaRef < 31 &&
                NDS4MiSTerAllCachedTexelsOpaque4(colorVector))
            {
                const u32 address = rowAddress + firstX;
                vst1q_u32(DepthBuffer + address,
                    vreinterpretq_u32_s32(vld1q_s32(depths)));
                vst1q_u32(ColorBuffer + address, colorVector);
                vst1q_u32(AttrBuffer + address, vdupq_n_u32(polyattr));
                continue;
            }
            // Only the scalar alpha/blend fallback needs an addressable array.
            vst1q_u32(texels, colorVector);
        }

        for (u32 lane = 0; lane < 4; ++lane)
        {
            if (!(passingPixels & (1u << lane)))
                continue;

            const u32 pixeladdr = pixelAddresses[lane];
            s32 z = depths[lane];
            const u32 color = fullDepthPass ?
                texels[lane] :
                RenderPixelCachedModulate(
                    pixelState, vertexColors[lane],
                    textureS[lane], textureT[lane]);
            const u8 alpha = color >> 24;

            if (alpha <= alphaRef)
                continue;

            if (alpha == 31)
            {
                DepthBuffer[pixeladdr] = z;
                ColorBuffer[pixeladdr] = color;
                AttrBuffer[pixeladdr] = polyattr;
            }
            else
            {
                // Preserve the pre-blend value: PlotTranslucentPixel may
                // update it. Rejected and opaque pixels never need this load.
                const u32 dstattr = AttrBuffer[pixeladdr];
                if (!writeTranslucentDepth)
                    z = -1;
                PlotTranslucentPixel(pixeladdr, color, z, polyattr, 0);

                if ((dstattr & 0xF) && (pixeladdr < LowerLayerBufferSize))
                    PlotTranslucentPixel(
                        pixeladdr + BufferSize, color, z, polyattr, 0);
            }
        }
    }

    return firstX;
}
#endif

[[gnu::hot, gnu::noinline]] void
SoftRenderer3D::RenderCachedModulateInteriorSpan(
    RendererPolygon* rp, s32 y, s32 firstX, s32 endX,
    Interpolator<0>& interpX,
    Interpolator<0>::SpanDepthInterpolator& spanDepth,
    Interpolator<0>::SpanInterpolator& spanAttributes)
{
    s16 constantTextureT;
    const bool constantTextureTSpan = spanAttributes.GetConstantTextureT(constantTextureT);
    if (constantTextureTSpan)
    {
        const auto& state = rp->PixelState;
        const u32 row = NDS4MiSTerCachedTextureIndex(
            0, constantTextureT, state.TextureWidth, state.TextureHeight,
            state.TextureWidthMask, state.TextureHeightMask,
            state.TextureWrapFlags, state.TextureWidthShift) >> state.TextureWidthShift;
        const u32 maximumTextureAlpha = state.TexturePixels[
            state.TextureWidth * state.TextureHeight + row];
        const u32 maximumAlpha =
            ((maximumTextureAlpha + 1) * (state.PolyAlpha + 1) - 1) >> 5;
        // Modulate spans cannot exceed the row's maximum alpha, regardless
        // of S, depth, color or perspective. A wholly rejected row changes
        // none of the color/depth/attribute planes or interpolation history.
        if (maximumAlpha <= GPU3D.RenderAlphaRef) return;
    }
#if defined(__arm__) && defined(__ARM_NEON)
    // Batch independent depth/attributes and shade work. Translucent polygons
    // use the exact polygon*texture alpha kernel; alpha test and framebuffer
    // blending still run in the same X order, including lower-layer writes.
    if (rp->PixelState.PolyAlpha == 31 && spanAttributes.IsPerspective())
    {
        if (spanDepth.CanBatchPerspectiveDepth4())
            firstX = RenderCachedModulatePerspectiveInteriorBatch4<true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes);
        else
            firstX = RenderCachedModulatePerspectiveInteriorBatch4<false>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes);
    }
    else if (spanAttributes.IsPerspective())
    {
        if (spanDepth.CanBatchPerspectiveDepth4())
            firstX = RenderCachedModulatePerspectiveInteriorBatch4<true, false>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes);
        else
            firstX = RenderCachedModulatePerspectiveInteriorBatch4<false, false>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes);
    }
#endif

    // Select once per scalar span, never once per pixel. Equal RGB endpoints
    // imply invariant exact DS color in both linear and perspective modes.
    u32 packedSpanColor = 0;
    const bool constantColor = spanAttributes.GetConstantColor(packedSpanColor);
    s32 constantSpanDepth = 0;
    const bool constantLinearDepth = constantColor &&
        spanDepth.GetLinearConstantDepth(constantSpanDepth);
    const bool neutralOpaque = constantLinearDepth &&
        packedSpanColor == 0x003f3f3fu && rp->PixelState.PolyAlpha == 31;
    switch (rp->PixelState.TextureWrapFlags)
    {
    case 0x0u:
        if (neutralOpaque && GPU3D.SpriteRasterSpansEnabled())
            RenderCachedModulateIntegralTextureDispatch<0x0u>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
                packedSpanColor, constantSpanDepth);
        else if (neutralOpaque)
            RenderCachedModulateInteriorSpanMode<0x0u, true, true, true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
                packedSpanColor, constantSpanDepth);
        else if (constantLinearDepth && constantTextureTSpan)
            RenderCachedModulateInteriorSpanMode<0x0u, true, true, false, true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
                packedSpanColor, constantSpanDepth);
        else if (constantLinearDepth)
            RenderCachedModulateInteriorSpanMode<0x0u, true, true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
                packedSpanColor, constantSpanDepth);
        else if (constantColor)
            RenderCachedModulateInteriorSpanMode<0x0u, true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes, packedSpanColor);
        else
            RenderCachedModulateInteriorSpanMode<0x0u>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes);
        return;
    case 0x3u:
        if (neutralOpaque && GPU3D.SpriteRasterSpansEnabled())
            RenderCachedModulateIntegralTextureDispatch<0x3u>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
                packedSpanColor, constantSpanDepth);
        else if (neutralOpaque)
            RenderCachedModulateInteriorSpanMode<0x3u, true, true, true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
                packedSpanColor, constantSpanDepth);
        else if (constantLinearDepth && constantTextureTSpan)
            RenderCachedModulateInteriorSpanMode<0x3u, true, true, false, true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
                packedSpanColor, constantSpanDepth);
        else if (constantLinearDepth)
            RenderCachedModulateInteriorSpanMode<0x3u, true, true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
                packedSpanColor, constantSpanDepth);
        else if (constantColor)
            RenderCachedModulateInteriorSpanMode<0x3u, true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes, packedSpanColor);
        else
            RenderCachedModulateInteriorSpanMode<0x3u>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes);
        return;
    default:
        if (neutralOpaque && GPU3D.SpriteRasterSpansEnabled())
            RenderCachedModulateIntegralTextureDispatch<0xFFu>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
                packedSpanColor, constantSpanDepth);
        else if (neutralOpaque)
            RenderCachedModulateInteriorSpanMode<0xFFu, true, true, true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
                packedSpanColor, constantSpanDepth);
        else if (constantLinearDepth && constantTextureTSpan)
            RenderCachedModulateInteriorSpanMode<0xFFu, true, true, false, true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
                packedSpanColor, constantSpanDepth);
        else if (constantLinearDepth)
            RenderCachedModulateInteriorSpanMode<0xFFu, true, true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
                packedSpanColor, constantSpanDepth);
        else if (constantColor)
            RenderCachedModulateInteriorSpanMode<0xFFu, true>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes, packedSpanColor);
        else
            RenderCachedModulateInteriorSpanMode<0xFFu>(
                rp, y, firstX, endX, interpX, spanDepth, spanAttributes);
        return;
    }
}

template<u8 WrapMode, bool ConstantColor, bool ConstantLinearDepth, bool NeutralOpaque, bool ConstantTextureT>
[[gnu::hot, gnu::noinline]] void
SoftRenderer3D::RenderCachedModulateInteriorSpanMode(
    RendererPolygon* rp, s32 y, s32 firstX, s32 endX,
    Interpolator<0>& interpX,
    Interpolator<0>::SpanDepthInterpolator& spanDepth,
    Interpolator<0>::SpanInterpolator& spanAttributes,
    u32 packedSpanColor, s32 constantSpanDepth)
{
    Polygon* polygon = rp->PolyData;
    const auto& pixelState = rp->PixelState;
    const u32 polyattr = rp->PolyAttr;
    const u32 polyAlpha = pixelState.PolyAlpha;
    const u32 alphaRef = GPU3D.RenderAlphaRef;
    const bool writeTranslucentDepth = polygon->Attr & (1<<11);
    const u32 rowAddress = FirstPixelOffset + y * ScanlineWidth;

    for (s32 x = firstX; x < endX; ++x)
    {
        u32 pixeladdr = rowAddress + x;

        s32 z;
        if constexpr (ConstantLinearDepth)
        {
            interpX.SetLinearX(x);
            z = constantSpanDepth;
        }
        else
        {
            interpX.SetXFast(x);
            z = spanDepth.Interpolate();
        }

        if (!NDS4MiSTerSelectCachedDepthPixel(
                DepthBuffer, AttrBuffer, LowerLayerBufferSize, z, pixeladdr))
            continue;

        u32 vertexColor;
        s16 textureS;
        s16 textureT;
        spanAttributes.InterpolateCachedPixel<ConstantColor, ConstantLinearDepth, ConstantTextureT>(
            vertexColor, textureS, textureT, packedSpanColor);
        const u32 texel = pixelState.TexturePixels[
            NDS4MiSTerCachedTextureIndexForMode<WrapMode>(
                textureS, textureT,
                pixelState.TextureWidth, pixelState.TextureHeight,
                pixelState.TextureWidthMask, pixelState.TextureHeightMask,
                pixelState.TextureWrapFlags,
                pixelState.TextureWidthShift)];
        u32 color;
        if constexpr (NeutralOpaque)
        {
            static_assert(ConstantColor && ConstantLinearDepth);
            if (!NDS4MiSTerNeutralOpaqueCachedPixel(texel, alphaRef, color))
                continue;
        }
        else if (!NDS4MiSTerModulateVisibleCachedPixel(
                texel, vertexColor, polyAlpha, alphaRef, color))
            continue;
        const u8 alpha = color >> 24;

        if (alpha == 31)
        {
            DepthBuffer[pixeladdr] = z;
            ColorBuffer[pixeladdr] = color;
            AttrBuffer[pixeladdr] = polyattr;
        }
        else
        {
            if (!writeTranslucentDepth) z = -1;
            PlotTranslucentPixel(pixeladdr, color, z, polyattr, 0);

            if (NDS4MiSTerCachedPixelHasLowerLayer(
                    AttrBuffer, LowerLayerBufferSize, pixeladdr))
                PlotTranslucentPixel(
                    pixeladdr + BufferSize, color, z, polyattr, 0);
        }
    }
}

template<bool FrontFacing>
[[gnu::hot, gnu::noinline]] void
SoftRenderer3D::RenderCachedContiguousTextureSpan(
    RendererPolygon* rp, s32 y, s32 firstX, s32 endX,
    const u32* texture, s32 constantSpanDepth)
{
    const u32 polyattr = rp->PolyAttr;
    const u32 alphaRef = GPU3D.RenderAlphaRef;
    const bool writeTranslucentDepth = rp->PolyData->Attr & (1u << 11);
    const u32 rowAddress = FirstPixelOffset + y * ScanlineWidth;
    while (firstX < endX)
    {
        const s32 count = std::min<s32>(4, endX - firstX);
#if defined(__arm__) && defined(__ARM_NEON)
        if (count == 4 && alphaRef < 31)
        {
            const u32 address = rowAddress + firstX;
            const uint32x4_t texels = vld1q_u32(texture);
            const uint32x4_t depthPass = vcgtq_s32(
                vreinterpretq_s32_u32(vld1q_u32(DepthBuffer + address)),
                vdupq_n_s32(constantSpanDepth));
            const uint32x4_t opaque = vceqq_u32(
                vshrq_n_u32(texels, 24), vdupq_n_u32(31));
            const uint32x4_t passing = vandq_u32(depthPass, opaque);
            uint32x2_t all = vand_u32(vget_low_u32(passing), vget_high_u32(passing));
            all = vand_u32(all, vrev64_u32(all));
            if (vget_lane_u32(all, 0) == 0xffffffffu)
            {
                // Every lane writes only its own opaque front pixel. There
                // is no alpha blend or edge push in an interior span.
                vst1q_u32(ColorBuffer + address,
                    vandq_u32(texels, vdupq_n_u32(0xff3f3f3fu)));
                vst1q_u32(DepthBuffer + address,
                    vreinterpretq_u32_s32(vdupq_n_s32(constantSpanDepth)));
                vst1q_u32(AttrBuffer + address, vdupq_n_u32(polyattr));
                firstX += 4;
                texture += 4;
                continue;
            }
        }
#endif
        // Equal depth, transparency and both AA layers retain the exact
        // original selection and blend sequence, in increasing X order.
        for (s32 lane = 0; lane < count; ++lane, ++firstX, ++texture)
        {
            u32 pixeladdr = rowAddress + firstX;
            s32 z = constantSpanDepth;
            if (!NDS4MiSTerSelectIntegralDepthPixel<FrontFacing>(
                    DepthBuffer, AttrBuffer, LowerLayerBufferSize, z, pixeladdr))
                continue;
            u32 color;
            if (!NDS4MiSTerNeutralOpaqueCachedPixel(*texture, alphaRef, color))
                continue;
            if ((color >> 24) == 31)
            {
                DepthBuffer[pixeladdr] = z;
                ColorBuffer[pixeladdr] = color;
                AttrBuffer[pixeladdr] = polyattr;
            }
            else
            {
                if (!writeTranslucentDepth) z = -1;
                PlotTranslucentPixel(pixeladdr, color, z, polyattr, 0);
                if (NDS4MiSTerCachedPixelHasLowerLayer(
                        AttrBuffer, LowerLayerBufferSize, pixeladdr))
                    PlotTranslucentPixel(
                        pixeladdr + BufferSize, color, z, polyattr, 0);
            }
        }
    }
}


template<u8 WrapMode>
[[gnu::hot, gnu::noinline]] void
SoftRenderer3D::RenderCachedModulateIntegralTextureDispatch(
    RendererPolygon* rp, s32 y, s32 firstX, s32 endX,
    Interpolator<0>& interpX,
    Interpolator<0>::SpanDepthInterpolator& spanDepth,
    Interpolator<0>::SpanInterpolator& spanAttributes,
    u32 packedSpanColor, s32 constantSpanDepth)
{
    s32 textureS, textureT, stepS, stepT;
    if (spanAttributes.PrepareIntegralTextureSpan(
            firstX, textureS, textureT, stepS, stepT))
        RenderCachedModulateIntegralTextureSpan<WrapMode>(
            rp, y, firstX, endX, textureS, textureT, stepS, stepT,
            constantSpanDepth);
    else
        RenderCachedModulateInteriorSpanMode<WrapMode, true, true, true>(
            rp, y, firstX, endX, interpX, spanDepth, spanAttributes,
            packedSpanColor, constantSpanDepth);
}

template<u8 WrapMode, bool FrontFacing>
[[gnu::hot, gnu::noinline]] void
SoftRenderer3D::RenderCachedModulateIntegralTextureSpan(
    RendererPolygon* rp, s32 y, s32 firstX, s32 endX,
    s32 textureS, s32 textureT, s32 stepS, s32 stepT,
    s32 constantSpanDepth)
{
    Polygon* polygon = rp->PolyData;
    const auto& pixelState = rp->PixelState;
    const u32 polyattr = rp->PolyAttr;
    const u32 alphaRef = GPU3D.RenderAlphaRef;
    const bool writeTranslucentDepth = polygon->Attr & (1<<11);
    const u32 rowAddress = FirstPixelOffset + y * ScanlineWidth;

    // The qualified game path already proved exact integral S/T steps.
    // An in-bounds, forward unit S step is a contiguous decoded texture row:
    // no wrap/clamp boundary or signed texcoord rollover is crossed.
    const s32 textureX = static_cast<s16>(textureS) >> 4;
    if (stepS == 16 && stepT == 0 && endX - firstX >= 4 &&
        textureX >= 0 && textureX + (endX - firstX) <= pixelState.TextureWidth)
    {
        const u32 textureIndex = NDS4MiSTerCachedTextureIndexForMode<WrapMode>(
            static_cast<s16>(textureS), static_cast<s16>(textureT),
            pixelState.TextureWidth, pixelState.TextureHeight,
            pixelState.TextureWidthMask, pixelState.TextureHeightMask,
            pixelState.TextureWrapFlags, pixelState.TextureWidthShift);
        RenderCachedContiguousTextureSpan<FrontFacing>(
            rp, y, firstX, endX, pixelState.TexturePixels + textureIndex,
            constantSpanDepth);
        return;
    }

    for (s32 x = firstX; x < endX; ++x, textureS += stepS, textureT += stepT)
    {
        u32 pixeladdr = rowAddress + x;

        s32 z = constantSpanDepth;

        if (!NDS4MiSTerSelectIntegralDepthPixel<FrontFacing>(
                DepthBuffer, AttrBuffer, LowerLayerBufferSize, z, pixeladdr))
            continue;

        const u32 texel = pixelState.TexturePixels[
            NDS4MiSTerCachedTextureIndexForMode<WrapMode>(
                static_cast<s16>(textureS), static_cast<s16>(textureT),
                pixelState.TextureWidth, pixelState.TextureHeight,
                pixelState.TextureWidthMask, pixelState.TextureHeightMask,
                pixelState.TextureWrapFlags,
                pixelState.TextureWidthShift)];
        u32 color;
        if (!NDS4MiSTerNeutralOpaqueCachedPixel(texel, alphaRef, color))
            continue;
        const u8 alpha = color >> 24;

        if (alpha == 31)
        {
            DepthBuffer[pixeladdr] = z;
            ColorBuffer[pixeladdr] = color;
            AttrBuffer[pixeladdr] = polyattr;
        }
        else
        {
            if (!writeTranslucentDepth) z = -1;
            PlotTranslucentPixel(pixeladdr, color, z, polyattr, 0);

            if (NDS4MiSTerCachedPixelHasLowerLayer(
                    AttrBuffer, LowerLayerBufferSize, pixeladdr))
                PlotTranslucentPixel(
                    pixeladdr + BufferSize, color, z, polyattr, 0);
        }
    }
}

[[gnu::hot, gnu::noinline]] bool
SoftRenderer3D::TryRenderBackfaceRectangleInterior(
    RendererPolygon* rp, s32 y, s32 firstX, s32 endX,
    Interpolator<0>::SpanInterpolator& spanAttributes)
{
    s32 textureS, textureT, stepS, stepT;
    if (!spanAttributes.PrepareIntegralTextureSpan(
            firstX, textureS, textureT, stepS, stepT))
        return false;
    const auto& state = rp->PixelState;
    if (stepT == 0)
    {
        const u32 row = NDS4MiSTerCachedTextureIndex(
            0, static_cast<s16>(textureT), state.TextureWidth, state.TextureHeight,
            state.TextureWidthMask, state.TextureHeightMask,
            state.TextureWrapFlags, state.TextureWidthShift) >> state.TextureWidthShift;
        if (state.TexturePixels[state.TextureWidth * state.TextureHeight + row] <=
            GPU3D.RenderAlphaRef)
            return true;
    }
    // SetupPolygon proved constant white RGB, alpha 31 and equal depth/W.
    // Nonintegral interpolation and boundary scanlines retain the old loop.
    switch (state.TextureWrapFlags)
    {
    case 0x0u:
        RenderCachedModulateIntegralTextureSpan<0x0u, false>(
            rp, y, firstX, endX, textureS, textureT, stepS, stepT, rp->PolyData->FinalZ[0]);
        break;
    case 0x3u:
        RenderCachedModulateIntegralTextureSpan<0x3u, false>(
            rp, y, firstX, endX, textureS, textureT, stepS, stepT, rp->PolyData->FinalZ[0]);
        break;
    default:
        RenderCachedModulateIntegralTextureSpan<0xFFu, false>(
            rp, y, firstX, endX, textureS, textureT, stepS, stepT, rp->PolyData->FinalZ[0]);
        break;
    }
    return true;
}

void SoftRenderer3D::RenderPolygonScanline(
    RendererPolygon* rp, s32 y, bool& prevIsShadowMask,
    u8* stencilBuffer, s32 clipStartX, s32 clipEndX,
    u16* finalPassMinX, u16* finalPassMaxX)
{
    // Keep the FPGA producer's hot code and stack separate from the software
    // pixel loops, while retaining one source for edge and coverage math.
    if (FpgaEmitting)
        RenderFpgaPolygonScanline(rp,y,prevIsShadowMask,stencilBuffer,
            clipStartX,clipEndX,finalPassMinX,finalPassMaxX);
    else
        RenderPolygonScanlineImpl<false>(rp,y,prevIsShadowMask,stencilBuffer,
            clipStartX,clipEndX,finalPassMinX,finalPassMaxX);
}

template<bool EmitFpga>
void SoftRenderer3D::RenderPolygonScanlineImpl(
    RendererPolygon* rp, s32 y, bool& prevIsShadowMask,
    u8* stencilBuffer, s32 clipStartX, s32 clipEndX,
    u16* finalPassMinX, u16* finalPassMaxX)
{
    if (rp->PixelState.FlatRectangle && !EmitFpga)
    {
        if (rp->DepthTest == DepthTest_LessThan_FrontFacing)
            RenderFlatRectangleScanline<true>(rp, y, prevIsShadowMask, stencilBuffer,
                clipStartX, clipEndX, finalPassMinX, finalPassMaxX);
        else
            RenderFlatRectangleScanline<false>(rp, y, prevIsShadowMask, stencilBuffer,
                clipStartX, clipEndX, finalPassMinX, finalPassMaxX);
        return;
    }
    Polygon* polygon = rp->PolyData;

    const u32 polyattr = rp->PolyAttr;
    const u32 polyalpha = rp->PixelState.PolyAlpha;
    const bool wireframe = rp->PixelState.Wireframe;
    const auto fnDepthTest = rp->DepthTest;

    prevIsShadowMask = false;

    if (polygon->YTop != polygon->YBottom)
    {
        if (y >= polygon->Vertices[rp->NextVL]->FinalPosition[1] && rp->CurVL != polygon->VBottom)
        {
            SetupPolygonLeftEdge(rp, y);
        }

        if (y >= polygon->Vertices[rp->NextVR]->FinalPosition[1] && rp->CurVR != polygon->VBottom)
        {
            SetupPolygonRightEdge(rp, y);
        }
    }

    Vertex *vlcur, *vlnext, *vrcur, *vrnext;
    s32 xstart, xend;
    bool l_filledge, r_filledge;
    s32 l_edgelen, r_edgelen;
    s32 l_edgecov, r_edgecov;
    Interpolator<1>* interp_start;
    Interpolator<1>* interp_end;

    xstart = rp->XL;
    xend = rp->XR;

    s32 wl = rp->SlopeL.Interp.Interpolate(polygon->FinalW[rp->CurVL], polygon->FinalW[rp->NextVL]);
    s32 wr = rp->SlopeR.Interp.Interpolate(polygon->FinalW[rp->CurVR], polygon->FinalW[rp->NextVR]);

    s32 zl = rp->SlopeL.Interp.InterpolateZ(polygon->FinalZ[rp->CurVL], polygon->FinalZ[rp->NextVL]);
    s32 zr = rp->SlopeR.Interp.InterpolateZ(polygon->FinalZ[rp->CurVR], polygon->FinalZ[rp->NextVR]);

    // right vertical edges are pushed 1px to the left as long as either:
    // the left edge slope is not 0, or the span is not 0 pixels wide, and it is not at the leftmost pixel of the screen
    if (rp->SlopeR.Increment==0 && (rp->SlopeL.Increment!=0 || xstart != xend) && (xend != 0))
        xend--;

    // if the left and right edges are swapped, render backwards.
    // on hardware, swapped edges seem to break edge length calculation,
    // causing X-major edges to be rendered wrong when filled,
    // and resulting in buggy looking anti-aliasing on X-major edges

    if (xstart > xend)
    {
        vlcur = polygon->Vertices[rp->CurVR];
        vlnext = polygon->Vertices[rp->NextVR];
        vrcur = polygon->Vertices[rp->CurVL];
        vrnext = polygon->Vertices[rp->NextVL];

        interp_start = &rp->SlopeR.Interp;
        interp_end = &rp->SlopeL.Interp;

        rp->SlopeR.EdgeParams<true>(&l_edgelen, &l_edgecov);
        rp->SlopeL.EdgeParams<true>(&r_edgelen, &r_edgecov);

        std::swap(xstart, xend);
        std::swap(wl, wr);
        std::swap(zl, zr);

        // edge fill rules for swapped opaque edges:
        // * right edge is filled if slope > 1, or if the left edge = 0, but is never filled if it is < -1
        // * left edge is filled if slope <= 1
        // * the bottom-most pixel of negative x-major slopes are filled if they are next to a flat bottom edge
        // edges are always filled if antialiasing/edgemarking are enabled,
        // if the pixels are translucent and alpha blending is enabled, or if the polygon is wireframe
        // checkme: do swapped line polygons exist?
        if ((EffectiveDispCnt & ((1<<4)|(1<<5))) || ((polyalpha < 31) && (EffectiveDispCnt & (1<<3))) || wireframe)
        {
            l_filledge = true;
            r_filledge = true;
        }
        else
        {
            l_filledge = (rp->SlopeR.Negative || !rp->SlopeR.XMajor)
                || (y == polygon->YBottom-1) && rp->SlopeR.XMajor && (RasterX(vlnext) != RasterX(vrnext));
            r_filledge = (!rp->SlopeL.Negative && rp->SlopeL.XMajor)
                || (!(rp->SlopeL.Negative && rp->SlopeL.XMajor) && rp->SlopeR.Increment==0)
                || (y == polygon->YBottom-1) && rp->SlopeL.XMajor && (RasterX(vlnext) != RasterX(vrnext));
        }
    }
    else
    {
        vlcur = polygon->Vertices[rp->CurVL];
        vlnext = polygon->Vertices[rp->NextVL];
        vrcur = polygon->Vertices[rp->CurVR];
        vrnext = polygon->Vertices[rp->NextVR];

        interp_start = &rp->SlopeL.Interp;
        interp_end = &rp->SlopeR.Interp;

        rp->SlopeL.EdgeParams<false>(&l_edgelen, &l_edgecov);
        rp->SlopeR.EdgeParams<false>(&r_edgelen, &r_edgecov);

        // edge fill rules for unswapped opaque edges:
        // * right edge is filled if slope > 1
        // * left edge is filled if slope <= 1
        // * edges with slope = 0 are always filled
        // * the bottom-most pixel of negative x-major slopes are filled if they are next to a flat bottom edge
        // * edges are filled if both sides are identical and fully overlapping
        // edges are always filled if antialiasing/edgemarking are enabled,
        // if the pixels are translucent and alpha blending is enabled, or if the polygon is wireframe
        if ((EffectiveDispCnt & ((1<<4)|(1<<5))) || ((polyalpha < 31) && (EffectiveDispCnt & (1<<3))) || wireframe)
        {
            l_filledge = true;
            r_filledge = true;
        }
        else
        {
            l_filledge = ((rp->SlopeL.Negative || !rp->SlopeL.XMajor)
                || (y == polygon->YBottom-1) && rp->SlopeL.XMajor && (RasterX(vlnext) != RasterX(vrnext)))
                || (rp->SlopeL.Increment == rp->SlopeR.Increment) && (xstart+l_edgelen == xend+1);
            r_filledge = (!rp->SlopeR.Negative && rp->SlopeR.XMajor) || (rp->SlopeR.Increment==0)
                || (y == polygon->YBottom-1) && rp->SlopeR.XMajor && (RasterX(vlnext) != RasterX(vrnext));
        }
    }

    // interpolate attributes along Y

    s32 rl, gl, bl, rr, gr, br;
    if (rp->PixelState.ConstantVertexColor)
    {
        rl = rr = vlcur->FinalColor[0];
        gl = gr = vlcur->FinalColor[1];
        bl = br = vlcur->FinalColor[2];
    }
    else
    {
        rl = interp_start->Interpolate(vlcur->FinalColor[0], vlnext->FinalColor[0]);
        gl = interp_start->Interpolate(vlcur->FinalColor[1], vlnext->FinalColor[1]);
        bl = interp_start->Interpolate(vlcur->FinalColor[2], vlnext->FinalColor[2]);
        rr = interp_end->Interpolate(vrcur->FinalColor[0], vrnext->FinalColor[0]);
        gr = interp_end->Interpolate(vrcur->FinalColor[1], vrnext->FinalColor[1]);
        br = interp_end->Interpolate(vrcur->FinalColor[2], vrnext->FinalColor[2]);
    }

    s32 sl = interp_start->Interpolate(vlcur->TexCoords[0], vlnext->TexCoords[0]);
    s32 tl = interp_start->Interpolate(vlcur->TexCoords[1], vlnext->TexCoords[1]);

    s32 sr = interp_end->Interpolate(vrcur->TexCoords[0], vrnext->TexCoords[0]);
    s32 tr = interp_end->Interpolate(vrcur->TexCoords[1], vrnext->TexCoords[1]);

    if constexpr (EmitFpga)
    {
        const auto clampX = [](s32 x) { return std::clamp(x, 0, 256); };
        const s32 nativeStart=clampX(xstart),nativeEnd=clampX(xend+1);
        if(nativeStart<nativeEnd){
            finalPassMinX[y]=std::min<u16>(finalPassMinX[y],nativeStart);
            finalPassMaxX[y]=std::max<u16>(finalPassMaxX[y],nativeEnd);
        }
        s32 begin = clampX(xstart);
        s32 finish = begin;
        const s32 leftEnd = clampX(std::min(xstart + l_edgelen, xend + 1));
        if (l_filledge) finish = std::max(finish, leftEnd);
        else begin = finish = leftEnd;
        finish = std::max(finish, clampX(std::min(xend-r_edgelen+1, xend+1)));
        if (r_filledge) finish = std::max(finish, clampX(xend+1));
        const s32 interiorEnd=clampX(std::min(xend-r_edgelen+1,xend+1));
        const u32 spanYEdge=y==polygon->YTop?4:y==polygon->YBottom-1?8:0;
        // The cached software interior assigns x=xlimit even when empty.
        // Preserve that revisit on narrow polygons: it changes the AA layer.
        const bool rewindRight=r_filledge && interiorEnd<leftEnd &&
            NDS4MiSTerUseCachedModulateInterior(spanYEdge,rp->PixelState.CachedModulate,
                polyalpha,polygon->IsShadow,polygon->IsShadowMask,
                fnDepthTest==DepthTest_LessThan_FrontFacing);
        if ((begin < finish || rewindRight) && FpgaFrame.valid)
        {
            fpga3d::Span sp;
            sp.first=begin;sp.end=finish;sp.origin=xstart;sp.width=xend+1-xstart;
            sp.w0=wl;sp.w1=wr;sp.z0=zl;sp.z1=zr;
            sp.left={rl,gl,bl,sl,tl};sp.right={rr,gr,br,sr,tr};
            sp.flags=((wl==wr && !(wl&127))?fpga3d::Linear:0) |
                (polygon->WBuffer?fpga3d::WBuffer:0) |
                (rp->DepthTest==DepthTest_LessThan_FrontFacing?fpga3d::Front:0) |
                ((rp->PolyAttr&16)?fpga3d::Back:0) |
                ((rp->DepthTest==DepthTest_Equal_Z || rp->DepthTest==DepthTest_Equal_W)?fpga3d::Equal:0);
            sp.alphaRef=GPU3D.RenderAlphaRef;
            sp.mode=polygon->IsShadow?3:rp->PixelState.BlendMode==2?4:(rp->PixelState.BlendMode&1)?1:0;
            sp.polyAttr=polyattr;sp.polyAlpha=polyalpha;sp.depthWrite=(polygon->Attr&(1u<<11))!=0;
            sp.yEdge=spanYEdge;sp.leftCov=l_edgecov;sp.rightCov=r_edgecov;
            sp.leftEnd=leftEnd;sp.rightBegin=std::max(leftEnd,interiorEnd);
            if(rp->PixelState.TextureEnabled)
            {
                sp.flags|=fpga3d::Textured;
                sp.texture=FpgaFrame.textureOffsets.at(rp->PixelState.TexturePixels);
                sp.shiftS=rp->PixelState.TextureWidthShift;
                sp.shiftT=__builtin_ctz(static_cast<unsigned>(rp->PixelState.TextureHeight));
                sp.wrap=rp->PixelState.TextureWrapFlags;
            }
            try {
                const auto emitSpan=[&](const fpga3d::Span& value){
                    if(value.first>=value.origin && value.end<=value.origin+value.width)
                    {
                        FpgaFrame.append(fpga3d::span(value));return;
                    }
                    // Narrow cached interiors can revisit pixels outside the
                    // perspective denominator. Preserve the native unsigned
                    // factor wrap and signed depth in CPU setup, then let the
                    // FPGA perform texture lookup, depth, blending and coverage.
                    // Coverage continues across these single-pixel descriptors.
                    if(value.width<1 || value.width>512)
                        throw std::invalid_argument("extrapolated span width");
                    Interpolator<0> exact(value.origin,value.origin+value.width,
                        value.w0,value.w1,(value.flags&fpga3d::WBuffer)!=0);
                    for(int pixel=value.first;pixel<value.end && FpgaFrame.valid;pixel++)
                    {
                        exact.SetX(pixel);
                        std::array<int32_t,5> attributes;
                        bool colorOutside=false;
                        for(unsigned k=0;k<5;k++){
                            const auto a=exact.Interpolate(value.left[k],value.right[k]);
                            colorOutside|=k<3 && (a<0 || a>511);
                            attributes[k]=k<3?a:int16_t(a);
                        }
                        if(colorOutside){
                            if(!rp->PixelState.CachedModulate)
                                throw std::invalid_argument("extrapolated vertex color");
                            // The native cached shader packs unsigned shifted
                            // components with OR, then uses each byte's low
                            // six bits. Preserve cross-component overflow too;
                            // independently clamping or masking RGB is wrong.
                            u32 packed; s16 unusedS,unusedT;
                            NDS4MiSTerPackCachedSpanValues(attributes.data(),packed,unusedS,unusedT);
                            for(unsigned k=0;k<3;k++)attributes[k]=((packed>>(8*k))&63u)<<3;
                            ++FpgaFrame.canonicalizedColors;
                        }
                        FpgaFrame.append(fpga3d::literalPixel(value,pixel,
                            exact.InterpolateZ(value.z0,value.z1),attributes,pixel!=value.first));
                    }
                };
                if(rewindRight) {
                    sp.end=leftEnd;
                    if(sp.first<sp.end)emitSpan(sp);
                    sp.first=interiorEnd;sp.end=clampX(xend+1);
                    sp.leftEnd=0;sp.rightBegin=interiorEnd;
                    if(sp.first<sp.end)emitSpan(sp);
                } else emitSpan(sp);
            }
            catch(const std::invalid_argument& error) {
                if(fpga3d::profileEnabled && FpgaProfile.counts[unsigned(fpga3d::Outcome::Span)]<8)
                    std::fprintf(stderr,"FPGA3D_SPAN_REJECT reason=%s first=%d end=%d origin=%d width=%d w0=%d w1=%d z0=%d z1=%d flags=%x\n",
                        error.what(),sp.first,sp.end,sp.origin,sp.width,sp.w0,sp.w1,sp.z0,sp.z1,sp.flags);
                FpgaFrame.valid=false;FpgaFrame.failure=fpga3d::Outcome::Span;
            }
        }
        rp->XL = rp->SlopeL.Step();
        rp->XR = rp->SlopeR.Step();
        return;
    }

    // in wireframe mode, there are special rules for equal Z (TODO)

    int yedge = 0;
    if (y == polygon->YTop)           yedge = 0x4;
    else if (y == polygon->YBottom-1) yedge = 0x8;
    int edge;

    s32 x = xstart;
    Interpolator<0> interpX(xstart, xend+1, wl, wr, polygon->WBuffer);
    Interpolator<0>::SpanDepthInterpolator spanDepth(interpX, zl, zr);
    Interpolator<0>::SpanInterpolator spanAttributes(
        interpX, rl, rr, gl, gr, bl, br, sl, sr, tl, tr);
    // Equal RGB endpoints make color invariant across this entire row,
    // including antialiased edges and the generic/shadow pixel paths. The
    // cached interior already skips these three interpolators; keep the
    // same exact optimization when returning to either edge. RGB recurrence
    // state stays at its constant base, so skipped/depth-rejected pixels and
    // transitions between generic and cached spans need no resynchronizing.
    const bool constantSpanColor = rl == rr && gl == gr && bl == br;
    s32 spanValues[5] = {rl, gl, bl, 0, 0};
    const auto interpolateSpanValues = [&]()
    {
        if (constantSpanColor)
            spanAttributes.Interpolate<3>(spanValues);
        else
            spanAttributes.Interpolate(spanValues);
    };
    s32 constantDepth = 0;
    const bool constantLinearDepth = spanDepth.GetLinearConstantDepth(constantDepth);
    const auto interpolateSpanDepth = [&](s32 pixelX) -> s32
    {
        // Linear attributes and equal depth endpoints never consume the
        // perspective factor, even on antialiased/shadow edge pixels.
        // Invalidate it exactly as the cached interior does, so the next
        // consumer that needs it takes the normal exact resync path.
        if (constantLinearDepth)
        {
            interpX.SetLinearX(pixelX);
            return constantDepth;
        }
        interpX.SetX(pixelX);
        return spanDepth.Interpolate();
    };
    // White constant RGB and opaque polygon alpha leave cached texels
    // unchanged, including their texture alpha. Apply the same identity
    // used by the interior span to generic top/bottom and side-edge pixels.
    // Coverage, alpha rejection, blending and both depth layers below are
    // still handled by the original edge paths.
    const bool neutralCachedSpan = rp->PixelState.CachedModulate &&
        constantSpanColor && polyalpha == 31 &&
        (rl >> 3) == 63 && (gl >> 3) == 63 && (bl >> 3) == 63;
    const auto renderSpanPixel = [this, rp, neutralCachedSpan](
        u32 vr, u32 vg, u32 vb, s16 s, s16 t)
        __attribute__((always_inline)) -> u32
    {
        if (rp->PixelState.CachedModulate)
        {
            if (neutralCachedSpan)
                return LookupCachedTexel(rp->PixelState, s, t) & 0xff3f3f3fu;
            const u32 vertexColor = (vr >> 3) |
                ((vg >> 3) << 8) | ((vb >> 3) << 16);
            return RenderPixelCachedModulate(
                rp->PixelState, vertexColor, s, t);
        }
        return RenderPixel(
            rp->PixelState, vr >> 3, vg >> 3, vb >> 3, s, t);
    };
    const bool cachedModulateInterior =
        NDS4MiSTerUseCachedModulateInterior(
            yedge, rp->PixelState.CachedModulate, polyalpha,
            polygon->IsShadow, polygon->IsShadowMask,
            fnDepthTest == DepthTest_LessThan_FrontFacing);

    const s32 visibleStart = std::max<s32>(xstart, 0);
    const s32 visibleEnd = std::min<s32>(xend + 1, 256);
    if (visibleStart < visibleEnd)
    {
        finalPassMinX[y] = std::min<u16>(
            finalPassMinX[y], static_cast<u16>(visibleStart));
        finalPassMaxX[y] = std::max<u16>(
            finalPassMaxX[y], static_cast<u16>(visibleEnd));
    }

    if (x < clipStartX) x = clipStartX;
    s32 xlimit;

    s32 xcov = 0;

    // part 1: left edge
    edge = yedge | 0x1;
    xlimit = xstart+l_edgelen;
    if (xlimit > xend+1) xlimit = xend+1;
    if (xlimit < clipStartX) xlimit = clipStartX;
    if (xlimit > clipEndX) xlimit = clipEndX;
    if (l_edgecov & (1<<31))
    {
        xcov = (l_edgecov >> 12) & 0x3FF;
        if (xcov == 0x3FF) xcov = 0;
    }

    if (!l_filledge) x = xlimit;
    else
    for (; x < xlimit; x++)
    {
        u32 pixeladdr = FirstPixelOffset + (y*ScanlineWidth) + x;
        u32 dstattr = AttrBuffer[pixeladdr];

        // check stencil buffer for shadows
        if (polygon->IsShadow)
        {
            u8 stencil = stencilBuffer[256*(y&0x1) + x];
            if (!stencil)
                continue;
            if (!(stencil & 0x1))
                pixeladdr += BufferSize;
            if (!(stencil & 0x2))
                dstattr &= ~0xF; // quick way to prevent drawing the shadow under antialiased edges
        }

        s32 z = interpolateSpanDepth(x);

        // if depth test against the topmost pixel fails, test
        // against the pixel underneath
        if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
        {
            if (!(dstattr & 0xF) || pixeladdr >= LowerLayerBufferSize) continue;

            pixeladdr += BufferSize;
            dstattr = AttrBuffer[pixeladdr];
            if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
                continue;
        }

        interpolateSpanValues();
        const u32 vr = spanValues[0];
        const u32 vg = spanValues[1];
        const u32 vb = spanValues[2];
        const s16 s = spanValues[3];
        const s16 t = spanValues[4];

        u32 color = renderSpanPixel(vr, vg, vb, s, t);
        u8 alpha = color >> 24;

        // alpha test
        if (alpha <= GPU3D.RenderAlphaRef) continue;

        if (alpha == 31)
        {
            u32 attr = polyattr | edge;

            if (EffectiveDispCnt & (1<<4))
            {
                // anti-aliasing: all edges are rendered

                // calculate coverage
                s32 cov = l_edgecov;
                if (cov & (1<<31))
                {
                    cov = xcov >> 5;
                    if (cov > 31) cov = 31;
                    xcov += (l_edgecov & 0x3FF);
                }
                attr |= (cov << 8);

                // push old pixel down if needed
                if (pixeladdr < LowerLayerBufferSize)
                {
                    ColorBuffer[pixeladdr+BufferSize] = ColorBuffer[pixeladdr];
                    DepthBuffer[pixeladdr+BufferSize] = DepthBuffer[pixeladdr];
                    AttrBuffer[pixeladdr+BufferSize] = AttrBuffer[pixeladdr];
                }
            }

            DepthBuffer[pixeladdr] = z;
            ColorBuffer[pixeladdr] = color;
            AttrBuffer[pixeladdr] = attr;
        }
        else
        {
            if (!(polygon->Attr & (1<<11))) z = -1;
            PlotTranslucentPixel(pixeladdr, color, z, polyattr, polygon->IsShadow);

            // blend with bottom pixel too, if needed
            if ((dstattr & 0xF) && (pixeladdr < LowerLayerBufferSize))
                PlotTranslucentPixel(pixeladdr+BufferSize, color, z, polyattr, polygon->IsShadow);
        }
    }

    // part 2: polygon inside
    edge = yedge;
    xlimit = xend-r_edgelen+1;
    if (xlimit > xend+1) xlimit = xend+1;
    if (xlimit < clipStartX) xlimit = clipStartX;
    if (xlimit > clipEndX) xlimit = clipEndX;

    if (wireframe && !edge) x = std::max(x, xlimit);
    else if (cachedModulateInterior)
    {
        RenderCachedModulateInteriorSpan(
            rp, y, x, xlimit, interpX, spanDepth,
            spanAttributes);
        x = xlimit;
    }
    else
    for (; x < xlimit; x++)
    {
        u32 pixeladdr = FirstPixelOffset + (y*ScanlineWidth) + x;
        u32 dstattr = AttrBuffer[pixeladdr];

        // check stencil buffer for shadows
        if (polygon->IsShadow)
        {
            u8 stencil = stencilBuffer[256*(y&0x1) + x];
            if (!stencil)
                continue;
            if (!(stencil & 0x1))
                pixeladdr += BufferSize;
            if (!(stencil & 0x2))
                dstattr &= ~0xF; // quick way to prevent drawing the shadow under antialiased edges
        }

        s32 z = interpolateSpanDepth(x);

        // if depth test against the topmost pixel fails, test
        // against the pixel underneath
        if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
        {
            if (!(dstattr & 0xF) || pixeladdr >= LowerLayerBufferSize) continue;

            pixeladdr += BufferSize;
            dstattr = AttrBuffer[pixeladdr];
            if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
                continue;
        }

        interpolateSpanValues();
        const u32 vr = spanValues[0];
        const u32 vg = spanValues[1];
        const u32 vb = spanValues[2];
        const s16 s = spanValues[3];
        const s16 t = spanValues[4];

        u32 color = renderSpanPixel(vr, vg, vb, s, t);
        u8 alpha = color >> 24;

        // alpha test
        if (alpha <= GPU3D.RenderAlphaRef) continue;

        if (alpha == 31)
        {
            u32 attr = polyattr | edge;

            if ((EffectiveDispCnt & (1<<4)) && (attr & 0xF))
            {
                // anti-aliasing: all edges are rendered

                // set coverage to avoid black lines from anti-aliasing
                attr |= (0x1F << 8);

                // push old pixel down if needed
                if (pixeladdr < LowerLayerBufferSize)
                {
                    ColorBuffer[pixeladdr+BufferSize] = ColorBuffer[pixeladdr];
                    DepthBuffer[pixeladdr+BufferSize] = DepthBuffer[pixeladdr];
                    AttrBuffer[pixeladdr+BufferSize] = AttrBuffer[pixeladdr];
                }
            }

            DepthBuffer[pixeladdr] = z;
            ColorBuffer[pixeladdr] = color;
            AttrBuffer[pixeladdr] = attr;
        }
        else
        {
            if (!(polygon->Attr & (1<<11))) z = -1;
            PlotTranslucentPixel(pixeladdr, color, z, polyattr, polygon->IsShadow);

            // blend with bottom pixel too, if needed
            if ((dstattr & 0xF) && (pixeladdr < LowerLayerBufferSize))
                PlotTranslucentPixel(pixeladdr+BufferSize, color, z, polyattr, polygon->IsShadow);
        }
    }

    // part 3: right edge
    edge = yedge | 0x2;
    xlimit = xend+1;
    if (xlimit < clipStartX) xlimit = clipStartX;
    if (xlimit > clipEndX) xlimit = clipEndX;
    if (r_edgecov & (1<<31))
    {
        xcov = (r_edgecov >> 12) & 0x3FF;
        if (xcov == 0x3FF) xcov = 0;
    }

    if (r_filledge)
    for (; x < xlimit; x++)
    {
        u32 pixeladdr = FirstPixelOffset + (y*ScanlineWidth) + x;
        u32 dstattr = AttrBuffer[pixeladdr];

        // check stencil buffer for shadows
        if (polygon->IsShadow)
        {
            u8 stencil = stencilBuffer[256*(y&0x1) + x];
            if (!stencil)
                continue;
            if (!(stencil & 0x1))
                pixeladdr += BufferSize;
            if (!(stencil & 0x2))
                dstattr &= ~0xF; // quick way to prevent drawing the shadow under antialiased edges
        }

        s32 z = interpolateSpanDepth(x);

        // if depth test against the topmost pixel fails, test
        // against the pixel underneath
        if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
        {
            if (!(dstattr & 0xF) || pixeladdr >= LowerLayerBufferSize) continue;

            pixeladdr += BufferSize;
            dstattr = AttrBuffer[pixeladdr];
            if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
                continue;
        }

        interpolateSpanValues();
        const u32 vr = spanValues[0];
        const u32 vg = spanValues[1];
        const u32 vb = spanValues[2];
        const s16 s = spanValues[3];
        const s16 t = spanValues[4];

        u32 color = renderSpanPixel(vr, vg, vb, s, t);
        u8 alpha = color >> 24;

        // alpha test
        if (alpha <= GPU3D.RenderAlphaRef) continue;

        if (alpha == 31)
        {
            u32 attr = polyattr | edge;

            if (EffectiveDispCnt & (1<<4))
            {
                // anti-aliasing: all edges are rendered

                // calculate coverage
                s32 cov = r_edgecov;
                if (cov & (1<<31))
                {
                    cov = 0x1F - (xcov >> 5);
                    if (cov < 0) cov = 0;
                    xcov += (r_edgecov & 0x3FF);
                }
                attr |= (cov << 8);

                // push old pixel down if needed
                if (pixeladdr < LowerLayerBufferSize)
                {
                    ColorBuffer[pixeladdr+BufferSize] = ColorBuffer[pixeladdr];
                    DepthBuffer[pixeladdr+BufferSize] = DepthBuffer[pixeladdr];
                    AttrBuffer[pixeladdr+BufferSize] = AttrBuffer[pixeladdr];
                }
            }

            DepthBuffer[pixeladdr] = z;
            ColorBuffer[pixeladdr] = color;
            AttrBuffer[pixeladdr] = attr;
        }
        else
        {
            if (!(polygon->Attr & (1<<11))) z = -1;
            PlotTranslucentPixel(pixeladdr, color, z, polyattr, polygon->IsShadow);

            // blend with bottom pixel too, if needed
            if ((dstattr & 0xF) && (pixeladdr < LowerLayerBufferSize))
                PlotTranslucentPixel(pixeladdr+BufferSize, color, z, polyattr, polygon->IsShadow);
        }
    }

    rp->XL = rp->SlopeL.Step();
    rp->XR = rp->SlopeR.Step();
}

// A translucent untextured gray rectangle needs one color recurrence and no
// texture or depth interpolation. Keep both original vertical interpolators,
// and retain the existing blend operation and lower-AA-layer ordering.
// Keep the cartridge-specific body out of the explicitly hot function group.
// Its larger blend loop otherwise displaces shared span routines on ARM.
#if defined(__arm__) && defined(__ARM_NEON)
template<bool FrontFacing>
[[gnu::noinline]] void SoftRenderer3D::RenderGrayPowerOfTwoScanline(
    RendererPolygon* rp, s32 y, bool& prevIsShadowMask,
    s32 clipStartX, s32 clipEndX,
    u16* finalPassMinX, u16* finalPassMaxX)
{
    const auto* polygon = rp->PolyData;
    prevIsShadowMask = false;
    const s32 xstart = rp->XL, xend = rp->XR;
    const s32 visibleStart = std::max<s32>(xstart, 0);
    const s32 visibleEnd = std::min<s32>(xend, 256);
    if (visibleStart < visibleEnd)
    {
        finalPassMinX[y] = std::min<u16>(finalPassMinX[y], visibleStart);
        finalPassMaxX[y] = std::max<u16>(finalPassMaxX[y], visibleEnd);
    }
    const s32 first = std::max(xstart, clipStartX);
    const s32 end = std::min(xend, clipEndX);
    const u32 alpha = rp->PixelState.PolyAlpha;
    if (first < end && alpha > GPU3D.RenderAlphaRef)
    {
        const s32 left = rp->SlopeL.Interp.Interpolate(
            polygon->Vertices[rp->CurVL]->FinalColor[0],
            polygon->Vertices[rp->NextVL]->FinalColor[0]);
        const s32 right = rp->SlopeR.Interp.Interpolate(
            polygon->Vertices[rp->CurVR]->FinalColor[0],
            polygon->Vertices[rp->NextVR]->FinalColor[0]);
        NDS4MiSTerGrayPowerOfTwoSpan gray4(left, right, xend - xstart, first - xstart);
        const s32 depth = polygon->FinalZ[0];
        const u32 writeDepth = polygon->Attr & (1 << 11) ? depth : u32(-1);
        const u32 rowAddress = FirstPixelOffset + y * ScanlineWidth;
        const u32 polyattr = rp->PolyAttr;
        const u32 translucentId = ((polyattr >> 8) & 0x003F0000u) | (1u << 22);
        const auto plotGray = [&](u32 address, u32 dstattr, u32 shade)
        {
            // This path's setup proof excludes shadows and disabled blending.
            // Reuse the already-loaded pre-blend attributes for both the ID
            // rejection and the caller's lower-AA-layer decision.
            if ((dstattr & 0x007F0000u) == translucentId)
                return;
            u32 attr = NDS4MiSTerComposeTranslucentAttr(polyattr, dstattr);
            if (!(dstattr & (1u << 15)))
                attr &= ~(1u << 15);
            const u32 color = NDS4MiSTerBlendGrayPixel(
                shade, ColorBuffer[address], alpha);
            if (writeDepth != u32(-1))
                DepthBuffer[address] = writeDepth;
            ColorBuffer[address] = color;
            AttrBuffer[address] = attr;
        };
        for (s32 x = first; x < end; x += 4, gray4.Advance())
        {
            u32 address = rowAddress + x;
            if (x + 3 < end)
            {
                const uint32x4_t destinationAttr = vld1q_u32(AttrBuffer + address);
                const uint32x2_t edgePairs = vorr_u32(vget_low_u32(destinationAttr),
                                                     vget_high_u32(destinationAttr));
                // Edges need ordered lower-layer work only when the frame
                // keeps that backing layer. Native AA-off nonshadow frames
                // consume only the top pixels, so they can stay in SIMD here.
                if (!LowerLayerBufferSize ||
                    !((vget_lane_u32(edgePairs, 0) | vget_lane_u32(edgePairs, 1)) & 15))
                {
                    const int32x4_t sourceDepth = vdupq_n_s32(depth);
                    const uint32x4_t destinationDepth = vld1q_u32(DepthBuffer + address);
                    uint32x4_t passed = vcltq_s32(sourceDepth,
                        vreinterpretq_s32_u32(destinationDepth));
                    if constexpr (FrontFacing)
                        passed = vorrq_u32(passed, vandq_u32(
                            vceqq_s32(sourceDepth, vreinterpretq_s32_u32(destinationDepth)),
                            vceqq_u32(vandq_u32(destinationAttr, vdupq_n_u32(0x00400010)),
                                      vdupq_n_u32(0x10))));
                    passed = vbicq_u32(passed, vceqq_u32(
                        vandq_u32(destinationAttr, vdupq_n_u32(0x007F0000)),
                        vdupq_n_u32(translucentId)));
                    uint32x4_t attr = veorq_u32(destinationAttr, vandq_u32(
                        veorq_u32(destinationAttr, vdupq_n_u32(polyattr)),
                        vdupq_n_u32(0xE0F0)));
                    attr = vorrq_u32(vandq_u32(attr, vdupq_n_u32(0xFF00FFFF)),
                        vdupq_n_u32(((polyattr >> 24) << 16) | (1u << 22)));
                    attr = vandq_u32(attr, vorrq_u32(destinationAttr,
                                                    vdupq_n_u32(~(1u << 15))));
                    const uint32x4_t destinationColor = vld1q_u32(ColorBuffer + address);
                    const uint32x4_t color = NDS4MiSTerBlendGrayPixels4(
                        gray4.Get(), destinationColor, alpha);
                    vst1q_u32(ColorBuffer + address, vbslq_u32(passed, color, destinationColor));
                    vst1q_u32(AttrBuffer + address, vbslq_u32(passed, attr, destinationAttr));
                    if (writeDepth != u32(-1))
                        vst1q_u32(DepthBuffer + address, vbslq_u32(passed,
                            vreinterpretq_u32_s32(sourceDepth), destinationDepth));
                    continue;
                }
            }
            u32 shades[4];
            vst1q_u32(shades, gray4.Get());
            for (s32 lane = 0; lane < std::min<s32>(4, end - x); ++lane)
            {
                address = rowAddress + x + lane;
            if (!NDS4MiSTerSelectIntegralDepthPixel<FrontFacing>(
                    DepthBuffer, AttrBuffer, LowerLayerBufferSize, depth, address))
                continue;
            const u32 dstattr = AttrBuffer[address];
            const u32 shade = shades[lane];
            plotGray(address, dstattr, shade);
            if ((dstattr & 0xF) && address < LowerLayerBufferSize)
                plotGray(address + BufferSize, AttrBuffer[address + BufferSize], shade);
            }
        }
    }
    rp->XL = rp->SlopeL.Step();
    rp->XR = rp->SlopeR.Step();
}

#endif

template<bool FrontFacing>
[[gnu::noinline]] void SoftRenderer3D::RenderGrayRectangleScanline(
    RendererPolygon* rp, s32 y, bool& prevIsShadowMask,
    s32 clipStartX, s32 clipEndX,
    u16* finalPassMinX, u16* finalPassMaxX)
{
#if defined(__arm__) && defined(__ARM_NEON)
    const s32 width = rp->XR - rp->XL;
    if (width >= 16 && width <= 1024 && !(width & (width - 1)))
    {
        RenderGrayPowerOfTwoScanline<FrontFacing>(rp, y, prevIsShadowMask,
            clipStartX, clipEndX, finalPassMinX, finalPassMaxX);
        return;
    }
#endif
    const auto* polygon = rp->PolyData;
    prevIsShadowMask = false;
    const s32 xstart = rp->XL, xend = rp->XR;
    const s32 visibleStart = std::max<s32>(xstart, 0);
    const s32 visibleEnd = std::min<s32>(xend, 256);
    if (visibleStart < visibleEnd)
    {
        finalPassMinX[y] = std::min<u16>(finalPassMinX[y], visibleStart);
        finalPassMaxX[y] = std::max<u16>(finalPassMaxX[y], visibleEnd);
    }
    const s32 first = std::max(xstart, clipStartX);
    const s32 end = std::min(xend, clipEndX);
    const u32 alpha = rp->PixelState.PolyAlpha;
    if (first < end && alpha > GPU3D.RenderAlphaRef)
    {
        const s32 left = rp->SlopeL.Interp.Interpolate(
            polygon->Vertices[rp->CurVL]->FinalColor[0],
            polygon->Vertices[rp->NextVL]->FinalColor[0]);
        const s32 right = rp->SlopeR.Interp.Interpolate(
            polygon->Vertices[rp->CurVR]->FinalColor[0],
            polygon->Vertices[rp->NextVR]->FinalColor[0]);
        NDS4MiSTerGraySpan gray(left, right, xend - xstart, first - xstart);
        const s32 depth = polygon->FinalZ[0];
        const u32 writeDepth = polygon->Attr & (1 << 11) ? depth : u32(-1);
        const u32 rowAddress = FirstPixelOffset + y * ScanlineWidth;
        const u32 polyattr = rp->PolyAttr;
        const u32 translucentId = ((polyattr >> 8) & 0x003F0000u) | (1u << 22);
        const auto plotGray = [&](u32 address, u32 dstattr, u32 shade)
        {
            // This path's setup proof excludes shadows and disabled blending.
            // Reuse the already-loaded pre-blend attributes for both the ID
            // rejection and the caller's lower-AA-layer decision.
            if ((dstattr & 0x007F0000u) == translucentId)
                return;
            u32 attr = NDS4MiSTerComposeTranslucentAttr(polyattr, dstattr);
            if (!(dstattr & (1u << 15)))
                attr &= ~(1u << 15);
            const u32 color = NDS4MiSTerBlendGrayPixel(
                shade, ColorBuffer[address], alpha);
            if (writeDepth != u32(-1))
                DepthBuffer[address] = writeDepth;
            ColorBuffer[address] = color;
            AttrBuffer[address] = attr;
        };
        for (s32 x = first; x < end; ++x, gray.Advance())
        {
            u32 address = rowAddress + x;
#if defined(__arm__) && defined(__ARM_NEON)
            if (x + 3 < end)
            {
                const uint32x4_t destinationAttr = vld1q_u32(AttrBuffer + address);
                const uint32x2_t edgePairs = vorr_u32(vget_low_u32(destinationAttr),
                                                     vget_high_u32(destinationAttr));
                // Edges need ordered lower-layer work only when the frame
                // keeps that backing layer. Native AA-off nonshadow frames
                // consume only the top pixels, so they can stay in SIMD here.
                if (!LowerLayerBufferSize ||
                    !((vget_lane_u32(edgePairs, 0) | vget_lane_u32(edgePairs, 1)) & 15))
                {
                    u32 shades[4];
                    for (unsigned lane = 0; lane < 4; ++lane)
                    {
                        shades[lane] = u32(gray.Get()) >> 3;
                        if (lane != 3) gray.Advance();
                    }
                    const int32x4_t sourceDepth = vdupq_n_s32(depth);
                    const uint32x4_t destinationDepth = vld1q_u32(DepthBuffer + address);
                    uint32x4_t passed = vcltq_s32(sourceDepth,
                        vreinterpretq_s32_u32(destinationDepth));
                    if constexpr (FrontFacing)
                        passed = vorrq_u32(passed, vandq_u32(
                            vceqq_s32(sourceDepth, vreinterpretq_s32_u32(destinationDepth)),
                            vceqq_u32(vandq_u32(destinationAttr, vdupq_n_u32(0x00400010)),
                                      vdupq_n_u32(0x10))));
                    passed = vbicq_u32(passed, vceqq_u32(
                        vandq_u32(destinationAttr, vdupq_n_u32(0x007F0000)),
                        vdupq_n_u32(translucentId)));
                    uint32x4_t attr = veorq_u32(destinationAttr, vandq_u32(
                        veorq_u32(destinationAttr, vdupq_n_u32(polyattr)),
                        vdupq_n_u32(0xE0F0)));
                    attr = vorrq_u32(vandq_u32(attr, vdupq_n_u32(0xFF00FFFF)),
                        vdupq_n_u32(((polyattr >> 24) << 16) | (1u << 22)));
                    attr = vandq_u32(attr, vorrq_u32(destinationAttr,
                                                    vdupq_n_u32(~(1u << 15))));
                    const uint32x4_t destinationColor = vld1q_u32(ColorBuffer + address);
                    const uint32x4_t color = NDS4MiSTerBlendGrayPixels4(
                        vld1q_u32(shades), destinationColor, alpha);
                    vst1q_u32(ColorBuffer + address, vbslq_u32(passed, color, destinationColor));
                    vst1q_u32(AttrBuffer + address, vbslq_u32(passed, attr, destinationAttr));
                    if (writeDepth != u32(-1))
                        vst1q_u32(DepthBuffer + address, vbslq_u32(passed,
                            vreinterpretq_u32_s32(sourceDepth), destinationDepth));
                    x += 3;
                    continue;
                }
            }
#endif
            if (!NDS4MiSTerSelectIntegralDepthPixel<FrontFacing>(
                    DepthBuffer, AttrBuffer, LowerLayerBufferSize, depth, address))
                continue;
            const u32 dstattr = AttrBuffer[address];
            const u32 shade = u32(gray.Get()) >> 3;
            plotGray(address, dstattr, shade);
            if ((dstattr & 0xF) && address < LowerLayerBufferSize)
                plotGray(address + BufferSize, AttrBuffer[address + BufferSize], shade);
        }
    }
    rp->XL = rp->SlopeL.Step();
    rp->XR = rp->SlopeR.Step();
}

// The setup proof fixes both horizontal texture steps for the whole polygon.
// Keep the original vertical interpolator and its signed rounding, but avoid
// rebuilding five attribute recurrences and depth/X interpolators per row.
template<bool FrontFacing>
void SoftRenderer3D::RenderPreparedRectangleScanline(
    RendererPolygon* rp, s32 y, bool& prevIsShadowMask,
    s32 clipStartX, s32 clipEndX,
    u16* finalPassMinX, u16* finalPassMaxX)
{
    const auto* polygon = rp->PolyData;
    const auto& state = rp->PixelState;
    prevIsShadowMask = false;
    const s32 xstart = rp->XL, xend = rp->XR;
    const s32 visibleStart = std::max<s32>(xstart, 0);
    const s32 visibleEnd = std::min<s32>(xend, 256);
    if (visibleStart < visibleEnd)
    {
        finalPassMinX[y] = std::min<u16>(finalPassMinX[y], visibleStart);
        finalPassMaxX[y] = std::max<u16>(finalPassMaxX[y], visibleEnd);
    }
    const auto* top = polygon->Vertices[rp->CurVL]->TexCoords;
    const auto* bottom = polygon->Vertices[rp->NextVL]->TexCoords;
    const s32 sl = rp->SlopeL.Interp.Interpolate(top[0], bottom[0]);
    const s32 tl = rp->SlopeL.Interp.Interpolate(top[1], bottom[1]);
    const s32 stepS = rp->RectangleStepS, stepT = rp->RectangleStepT;
    const s32 depth = polygon->FinalZ[0];
    const u32 polyattr = rp->PolyAttr;
    const u32 rowAddress = FirstPixelOffset + y * ScanlineWidth;
    const bool antialias = EffectiveDispCnt & (1 << 4);
    const bool writeTranslucentDepth = polygon->Attr & (1 << 11);
    const u32 yedge = y == polygon->YTop ? 4 : y == polygon->YBottom - 1 ? 8 : 0;
    s32 x = std::max(xstart, clipStartX);
    const s32 end = std::min(xend, clipEndX);

    // This is the same full-coverage boundary rule as the rectangle fallback,
    // including the lower layer and translucent polygon-ID/depth semantics.
    const auto edgePixel = [&](s32 pixelX, u32 edge)
    {
        u32 address = rowAddress + pixelX;
        if (!NDS4MiSTerSelectIntegralDepthPixel<FrontFacing>(
                DepthBuffer, AttrBuffer, LowerLayerBufferSize, depth, address))
            return;
        const u32 dstattr = AttrBuffer[address];
        const s16 s = static_cast<s16>(sl + (pixelX - xstart) * stepS);
        const s16 t = static_cast<s16>(tl + (pixelX - xstart) * stepT);
        const u32 color = LookupCachedTexel(state, s, t) & 0xff3f3f3fu;
        const u32 alpha = color >> 24;
        if (alpha <= GPU3D.RenderAlphaRef) return;
        if (alpha == 31)
        {
            u32 attr = polyattr | edge;
            if (antialias)
            {
                attr |= 31 << 8;
                if (address < LowerLayerBufferSize)
                {
                    ColorBuffer[address + BufferSize] = ColorBuffer[address];
                    DepthBuffer[address + BufferSize] = DepthBuffer[address];
                    AttrBuffer[address + BufferSize] = AttrBuffer[address];
                }
            }
            DepthBuffer[address] = depth;
            ColorBuffer[address] = color;
            AttrBuffer[address] = attr;
        }
        else
        {
            const s32 z = writeTranslucentDepth ? depth : -1;
            PlotTranslucentPixel(address, color, z, polyattr, false);
            if ((dstattr & 0xF) && address < LowerLayerBufferSize)
                PlotTranslucentPixel(address + BufferSize, color, z, polyattr, false);
        }
    };

    bool emptyRow = false;
    if (stepT == 0)
    {
        const u32 row = NDS4MiSTerCachedTextureIndex(
            0, static_cast<s16>(tl), state.TextureWidth, state.TextureHeight,
            state.TextureWidthMask, state.TextureHeightMask,
            state.TextureWrapFlags, state.TextureWidthShift) >> state.TextureWidthShift;
        emptyRow = state.TexturePixels[state.TextureWidth * state.TextureHeight + row] <=
            GPU3D.RenderAlphaRef;
    }
    if (!emptyRow)
    {
        if (x < std::min(xstart + 1, end)) edgePixel(x++, yedge | 1);
        const s32 insideEnd = std::min(xend - 1, end);
        if (yedge)
            for (; x < insideEnd; ++x) edgePixel(x, yedge);
        else if (x < insideEnd)
        {
            const s32 s = sl + (x - xstart) * stepS;
            const s32 t = tl + (x - xstart) * stepT;
            switch (state.TextureWrapFlags)
            {
            case 0:
                RenderCachedModulateIntegralTextureSpan<0, FrontFacing>(
                    rp, y, x, insideEnd, s, t, stepS, stepT, depth);
                break;
            case 3:
                RenderCachedModulateIntegralTextureSpan<3, FrontFacing>(
                    rp, y, x, insideEnd, s, t, stepS, stepT, depth);
                break;
            default:
                RenderCachedModulateIntegralTextureSpan<0xFF, FrontFacing>(
                    rp, y, x, insideEnd, s, t, stepS, stepT, depth);
                break;
            }
            x = insideEnd;
        }
        for (; x < end; ++x) edgePixel(x, yedge | 2);
    }
    rp->XL = rp->SlopeL.Step();
    rp->XR = rp->SlopeR.Step();
}

// Only selected for verified linear textured or gray translucent rectangles.
// The three pixel loops below retain the generic edge/layer/blending rules.
// Keep the fallback's compiled body separate: a shared templated body passed
// output tests but regressed NSMB by about 5% on the stock Cortex-A9.
// Changes to these loops require the cross-build full-buffer oracle and the
// live-scene/other-game controls; a synthetic visible-only check is insufficient.
template<bool FrontFacing>
void SoftRenderer3D::RenderFlatRectangleScanline(
    RendererPolygon* rp, s32 y, bool& prevIsShadowMask,
    u8* stencilBuffer, s32 clipStartX, s32 clipEndX,
    u16* finalPassMinX, u16* finalPassMaxX)
{
    if (rp->PixelState.GrayRectangle)
    {
        RenderGrayRectangleScanline<FrontFacing>(rp, y, prevIsShadowMask,
            clipStartX, clipEndX, finalPassMinX, finalPassMaxX);
        return;
    }
    if (rp->PixelState.PreparedRectangle)
    {
        RenderPreparedRectangleScanline<FrontFacing>(
            rp, y, prevIsShadowMask, clipStartX, clipEndX,
            finalPassMinX, finalPassMaxX);
        return;
    }
    Polygon* polygon = rp->PolyData;
    const u32 polyattr = rp->PolyAttr;
    constexpr u32 polyalpha = 31;
    constexpr bool wireframe = false;
    const auto fnDepthTest = FrontFacing ? DepthTest_LessThan_FrontFacing : DepthTest_LessThan;
    prevIsShadowMask = false;
    const s32 xstart = rp->XL, xend = rp->XR - 1;
    constexpr bool l_filledge = true, r_filledge = true;
    constexpr s32 l_edgelen = 1, r_edgelen = 1;
    constexpr s32 l_edgecov = 31, r_edgecov = 31;
    const auto* vlcur = polygon->Vertices[rp->CurVL];
    const auto* vlnext = polygon->Vertices[rp->NextVL];
    const auto* vrcur = polygon->Vertices[rp->CurVR];
    const auto* vrnext = polygon->Vertices[rp->NextVR];
    const auto* interp_start = &rp->SlopeL.Interp;
    const auto* interp_end = &rp->SlopeR.Interp;
    const s32 wl = polygon->FinalW[0], wr = wl;
    const s32 zl = polygon->FinalZ[0], zr = zl;
    const s32 rl = vlcur->FinalColor[0], rr = rl;
    const s32 gl = vlcur->FinalColor[1], gr = gl;
    const s32 bl = vlcur->FinalColor[2], br = bl;
    const s32 sl = interp_start->Interpolate(vlcur->TexCoords[0], vlnext->TexCoords[0]);
    const s32 tl = interp_start->Interpolate(vlcur->TexCoords[1], vlnext->TexCoords[1]);
    const s32 sr = interp_end->Interpolate(vrcur->TexCoords[0], vrnext->TexCoords[0]);
    const s32 tr = interp_end->Interpolate(vrcur->TexCoords[1], vrnext->TexCoords[1]);

    // in wireframe mode, there are special rules for equal Z (TODO)

    int yedge = 0;
    if (y == polygon->YTop)           yedge = 0x4;
    else if (y == polygon->YBottom-1) yedge = 0x8;
    int edge;

    s32 x = xstart;
    Interpolator<0> interpX(xstart, xend+1, wl, wr, polygon->WBuffer);
    Interpolator<0>::SpanDepthInterpolator spanDepth(interpX, zl, zr);
    Interpolator<0>::SpanInterpolator spanAttributes(
        interpX, rl, rr, gl, gr, bl, br, sl, sr, tl, tr);
    // Equal RGB endpoints make color invariant across this entire row,
    // including antialiased edges and the generic/shadow pixel paths. The
    // cached interior already skips these three interpolators; keep the
    // same exact optimization when returning to either edge. RGB recurrence
    // state stays at its constant base, so skipped/depth-rejected pixels and
    // transitions between generic and cached spans need no resynchronizing.
    constexpr bool constantSpanColor = true;
    s32 spanValues[5] = {rl, gl, bl, 0, 0};
    const auto interpolateSpanValues = [&]()
    {
        if (constantSpanColor)
            spanAttributes.Interpolate<3>(spanValues);
        else
            spanAttributes.Interpolate(spanValues);
    };
    const s32 constantDepth = polygon->FinalZ[0];
    constexpr bool constantLinearDepth = true;
    const auto interpolateSpanDepth = [&](s32 pixelX) -> s32
    {
        // Linear attributes and equal depth endpoints never consume the
        // perspective factor, even on antialiased/shadow edge pixels.
        // Invalidate it exactly as the cached interior does, so the next
        // consumer that needs it takes the normal exact resync path.
        if (constantLinearDepth)
        {
            interpX.SetLinearX(pixelX);
            return constantDepth;
        }
        interpX.SetX(pixelX);
        return spanDepth.Interpolate();
    };
    const auto renderSpanPixel = [this, rp](u32, u32, u32, s16 s, s16 t)
        __attribute__((always_inline)) -> u32
    {
        return LookupCachedTexel(rp->PixelState, s, t) & 0xff3f3f3fu;
    };
    const bool cachedModulateInterior = FrontFacing && yedge == 0;

    const s32 visibleStart = std::max<s32>(xstart, 0);
    const s32 visibleEnd = std::min<s32>(xend + 1, 256);
    if (visibleStart < visibleEnd)
    {
        finalPassMinX[y] = std::min<u16>(
            finalPassMinX[y], static_cast<u16>(visibleStart));
        finalPassMaxX[y] = std::max<u16>(
            finalPassMaxX[y], static_cast<u16>(visibleEnd));
    }

    if (x < clipStartX) x = clipStartX;
    s32 xlimit;

    s32 xcov = 0;

    // part 1: left edge
    edge = yedge | 0x1;
    xlimit = xstart+l_edgelen;
    if (xlimit > xend+1) xlimit = xend+1;
    if (xlimit < clipStartX) xlimit = clipStartX;
    if (xlimit > clipEndX) xlimit = clipEndX;
    if (l_edgecov & (1<<31))
    {
        xcov = (l_edgecov >> 12) & 0x3FF;
        if (xcov == 0x3FF) xcov = 0;
    }

    if (!l_filledge) x = xlimit;
    else
    for (; x < xlimit; x++)
    {
        u32 pixeladdr = FirstPixelOffset + (y*ScanlineWidth) + x;
        u32 dstattr = AttrBuffer[pixeladdr];

        // check stencil buffer for shadows
        if (false)
        {
            u8 stencil = stencilBuffer[256*(y&0x1) + x];
            if (!stencil)
                continue;
            if (!(stencil & 0x1))
                pixeladdr += BufferSize;
            if (!(stencil & 0x2))
                dstattr &= ~0xF; // quick way to prevent drawing the shadow under antialiased edges
        }

        s32 z = interpolateSpanDepth(x);

        // if depth test against the topmost pixel fails, test
        // against the pixel underneath
        if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
        {
            if (!(dstattr & 0xF) || pixeladdr >= LowerLayerBufferSize) continue;

            pixeladdr += BufferSize;
            dstattr = AttrBuffer[pixeladdr];
            if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
                continue;
        }

        interpolateSpanValues();
        const u32 vr = spanValues[0];
        const u32 vg = spanValues[1];
        const u32 vb = spanValues[2];
        const s16 s = spanValues[3];
        const s16 t = spanValues[4];

        u32 color = renderSpanPixel(vr, vg, vb, s, t);
        u8 alpha = color >> 24;

        // alpha test
        if (alpha <= GPU3D.RenderAlphaRef) continue;

        if (alpha == 31)
        {
            u32 attr = polyattr | edge;

            if (EffectiveDispCnt & (1<<4))
            {
                // anti-aliasing: all edges are rendered

                // calculate coverage
                s32 cov = l_edgecov;
                if (cov & (1<<31))
                {
                    cov = xcov >> 5;
                    if (cov > 31) cov = 31;
                    xcov += (l_edgecov & 0x3FF);
                }
                attr |= (cov << 8);

                // push old pixel down if needed
                if (pixeladdr < LowerLayerBufferSize)
                {
                    ColorBuffer[pixeladdr+BufferSize] = ColorBuffer[pixeladdr];
                    DepthBuffer[pixeladdr+BufferSize] = DepthBuffer[pixeladdr];
                    AttrBuffer[pixeladdr+BufferSize] = AttrBuffer[pixeladdr];
                }
            }

            DepthBuffer[pixeladdr] = z;
            ColorBuffer[pixeladdr] = color;
            AttrBuffer[pixeladdr] = attr;
        }
        else
        {
            if (!(polygon->Attr & (1<<11))) z = -1;
            PlotTranslucentPixel(pixeladdr, color, z, polyattr, false);

            // blend with bottom pixel too, if needed
            if ((dstattr & 0xF) && (pixeladdr < LowerLayerBufferSize))
                PlotTranslucentPixel(pixeladdr+BufferSize, color, z, polyattr, false);
        }
    }

    // part 2: polygon inside
    edge = yedge;
    xlimit = xend-r_edgelen+1;
    if (xlimit > xend+1) xlimit = xend+1;
    if (xlimit < clipStartX) xlimit = clipStartX;
    if (xlimit > clipEndX) xlimit = clipEndX;

    if (wireframe && !edge) x = std::max(x, xlimit);
    else if (cachedModulateInterior)
    {
        RenderCachedModulateInteriorSpan(
            rp, y, x, xlimit, interpX, spanDepth,
            spanAttributes);
        x = xlimit;
    }
    else if (!FrontFacing && yedge == 0 &&
        TryRenderBackfaceRectangleInterior(rp, y, x, xlimit, spanAttributes))
    {
        x = xlimit;
    }
    else
    for (; x < xlimit; x++)
    {
        u32 pixeladdr = FirstPixelOffset + (y*ScanlineWidth) + x;
        u32 dstattr = AttrBuffer[pixeladdr];

        // check stencil buffer for shadows
        if (false)
        {
            u8 stencil = stencilBuffer[256*(y&0x1) + x];
            if (!stencil)
                continue;
            if (!(stencil & 0x1))
                pixeladdr += BufferSize;
            if (!(stencil & 0x2))
                dstattr &= ~0xF; // quick way to prevent drawing the shadow under antialiased edges
        }

        s32 z = interpolateSpanDepth(x);

        // if depth test against the topmost pixel fails, test
        // against the pixel underneath
        if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
        {
            if (!(dstattr & 0xF) || pixeladdr >= LowerLayerBufferSize) continue;

            pixeladdr += BufferSize;
            dstattr = AttrBuffer[pixeladdr];
            if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
                continue;
        }

        interpolateSpanValues();
        const u32 vr = spanValues[0];
        const u32 vg = spanValues[1];
        const u32 vb = spanValues[2];
        const s16 s = spanValues[3];
        const s16 t = spanValues[4];

        u32 color = renderSpanPixel(vr, vg, vb, s, t);
        u8 alpha = color >> 24;

        // alpha test
        if (alpha <= GPU3D.RenderAlphaRef) continue;

        if (alpha == 31)
        {
            u32 attr = polyattr | edge;

            if ((EffectiveDispCnt & (1<<4)) && (attr & 0xF))
            {
                // anti-aliasing: all edges are rendered

                // set coverage to avoid black lines from anti-aliasing
                attr |= (0x1F << 8);

                // push old pixel down if needed
                if (pixeladdr < LowerLayerBufferSize)
                {
                    ColorBuffer[pixeladdr+BufferSize] = ColorBuffer[pixeladdr];
                    DepthBuffer[pixeladdr+BufferSize] = DepthBuffer[pixeladdr];
                    AttrBuffer[pixeladdr+BufferSize] = AttrBuffer[pixeladdr];
                }
            }

            DepthBuffer[pixeladdr] = z;
            ColorBuffer[pixeladdr] = color;
            AttrBuffer[pixeladdr] = attr;
        }
        else
        {
            if (!(polygon->Attr & (1<<11))) z = -1;
            PlotTranslucentPixel(pixeladdr, color, z, polyattr, false);

            // blend with bottom pixel too, if needed
            if ((dstattr & 0xF) && (pixeladdr < LowerLayerBufferSize))
                PlotTranslucentPixel(pixeladdr+BufferSize, color, z, polyattr, false);
        }
    }

    // part 3: right edge
    edge = yedge | 0x2;
    xlimit = xend+1;
    if (xlimit < clipStartX) xlimit = clipStartX;
    if (xlimit > clipEndX) xlimit = clipEndX;
    if (r_edgecov & (1<<31))
    {
        xcov = (r_edgecov >> 12) & 0x3FF;
        if (xcov == 0x3FF) xcov = 0;
    }

    if (r_filledge)
    for (; x < xlimit; x++)
    {
        u32 pixeladdr = FirstPixelOffset + (y*ScanlineWidth) + x;
        u32 dstattr = AttrBuffer[pixeladdr];

        // check stencil buffer for shadows
        if (false)
        {
            u8 stencil = stencilBuffer[256*(y&0x1) + x];
            if (!stencil)
                continue;
            if (!(stencil & 0x1))
                pixeladdr += BufferSize;
            if (!(stencil & 0x2))
                dstattr &= ~0xF; // quick way to prevent drawing the shadow under antialiased edges
        }

        s32 z = interpolateSpanDepth(x);

        // if depth test against the topmost pixel fails, test
        // against the pixel underneath
        if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
        {
            if (!(dstattr & 0xF) || pixeladdr >= LowerLayerBufferSize) continue;

            pixeladdr += BufferSize;
            dstattr = AttrBuffer[pixeladdr];
            if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
                continue;
        }

        interpolateSpanValues();
        const u32 vr = spanValues[0];
        const u32 vg = spanValues[1];
        const u32 vb = spanValues[2];
        const s16 s = spanValues[3];
        const s16 t = spanValues[4];

        u32 color = renderSpanPixel(vr, vg, vb, s, t);
        u8 alpha = color >> 24;

        // alpha test
        if (alpha <= GPU3D.RenderAlphaRef) continue;

        if (alpha == 31)
        {
            u32 attr = polyattr | edge;

            if (EffectiveDispCnt & (1<<4))
            {
                // anti-aliasing: all edges are rendered

                // calculate coverage
                s32 cov = r_edgecov;
                if (cov & (1<<31))
                {
                    cov = 0x1F - (xcov >> 5);
                    if (cov < 0) cov = 0;
                    xcov += (r_edgecov & 0x3FF);
                }
                attr |= (cov << 8);

                // push old pixel down if needed
                if (pixeladdr < LowerLayerBufferSize)
                {
                    ColorBuffer[pixeladdr+BufferSize] = ColorBuffer[pixeladdr];
                    DepthBuffer[pixeladdr+BufferSize] = DepthBuffer[pixeladdr];
                    AttrBuffer[pixeladdr+BufferSize] = AttrBuffer[pixeladdr];
                }
            }

            DepthBuffer[pixeladdr] = z;
            ColorBuffer[pixeladdr] = color;
            AttrBuffer[pixeladdr] = attr;
        }
        else
        {
            if (!(polygon->Attr & (1<<11))) z = -1;
            PlotTranslucentPixel(pixeladdr, color, z, polyattr, false);

            // blend with bottom pixel too, if needed
            if ((dstattr & 0xF) && (pixeladdr < LowerLayerBufferSize))
                PlotTranslucentPixel(pixeladdr+BufferSize, color, z, polyattr, false);
        }
    }

    rp->XL = rp->SlopeL.Step();
    rp->XR = rp->SlopeR.Step();
}

u32 SoftRenderer3D::BuildScanlinePolygonLists(int npolys)
{
    u16 startCounts[VisibleScanlines] = {};
    u16 endCounts[VisibleScanlines] = {};
    u32 polygonScanlines = 0;

    for (int i = 0; i < npolys; i++)
    {
        const Polygon* polygon = PolygonList[i].PolyData;
        int first = 0;
        int end = 0;

        if (polygon->YBottom >= polygon->YTop)
        {
            first = std::clamp(polygon->YTop, 0, VisibleScanlines);
            end = std::clamp(polygon->YBottom, 0, VisibleScanlines);
            if (polygon->YBottom == polygon->YTop &&
                polygon->YTop >= 0 && polygon->YTop < VisibleScanlines)
                end = first + 1;
        }

        PolygonFirstScanline[i] = static_cast<u8>(first);
        PolygonEndScanline[i] = static_cast<u8>(end);
        if (first < end)
        {
            polygonScanlines += static_cast<u32>(end - first);
            startCounts[first]++;
            if (end < VisibleScanlines)
                endCounts[end]++;
        }
    }

    ScanlineStartOffsets[0] = 0;
    ScanlineEndOffsets[0] = 0;
    for (int y = 0; y < VisibleScanlines; y++)
    {
        ScanlineStartOffsets[y + 1] =
            ScanlineStartOffsets[y] + startCounts[y];
        ScanlineEndOffsets[y + 1] =
            ScanlineEndOffsets[y] + endCounts[y];
    }

    u16 startCursors[VisibleScanlines];
    u16 endCursors[VisibleScanlines];
    std::copy_n(ScanlineStartOffsets, VisibleScanlines, startCursors);
    std::copy_n(ScanlineEndOffsets, VisibleScanlines, endCursors);
    for (int i = 0; i < npolys; i++)
    {
        const int first = PolygonFirstScanline[i];
        const int end = PolygonEndScanline[i];
        if (first >= end) continue;

        ScanlineStartPolygonIndices[startCursors[first]++] =
            static_cast<u16>(i);
        if (end < VisibleScanlines)
            ScanlineEndPolygonIndices[endCursors[end]++] =
                static_cast<u16>(i);
    }

    ActivePolygonMaskWords = (npolys + 31) / 32;
    std::fill_n(ActivePolygonMask, ActivePolygonMaskWords, 0);
    return polygonScanlines;
}

void SoftRenderer3D::UpdateAlternateRows() noexcept
{
    // Publish once per frame, before waking either raster worker. Legacy
    // scanline consumers and AA retain native resolution.
    const bool nextTiny = TinyRequested && FullFrameCompletion && !(EffectiveDispCnt & (1u << 4));
    const bool nextQuarter = (QuarterRequested || nextTiny) && FullFrameCompletion &&
        !(EffectiveDispCnt & (1u << 4));
    const bool next = (AlternateRowsRequested || nextQuarter) && FullFrameCompletion &&
        !(EffectiveDispCnt & (1u << 4));
    if (next != AlternateRows || nextQuarter != Quarter || nextTiny != Tiny)
    {
        FrameIdentical = false;
        RasterTileHistoryValid = false;
    }
    if (nextTiny != Tiny) SparseClearStateValid = false;
    AlternateRows = next;
    Quarter = nextQuarter;
    Tiny = nextTiny;
}

void SoftRenderer3D::ExpandQuarterColumns()
{
    // The guest's geometry remains native. RasterX selects half-width
    // coordinates only while preparing raster edges and work estimates.
    // Expand after joining both workers, before
    // neighbor-dependent edge marking and the existing row expansion.
    const s32 scale = Tiny ? 4 : 2;
    const s32 width = 256 / scale;
    for (s32 y = 0; y < VisibleScanlines; y += RowStep())
    {
        const bool clearImage = EffectiveDispCnt & (1u << 14);
        if (!clearImage && FinalPassMinX[y] >= FinalPassMaxX[y]) continue;
        // Expansion must overwrite the original compact pixels too, or a
        // ghost of the half-width picture would remain. Starting at half
        // the dirty minimum makes the expanded destination cover both the
        // compact damage and its doubled position. Untouched source words
        // contain the same constant clear value. Bitmap clears need all X.
        const s32 first = clearImage ? 0 : (FinalPassMinX[y] / scale) & ~3;
        const s32 end = clearImage ? width : (std::min<s32>(width, FinalPassMaxX[y]) + 3) & ~3;
        const u32 row = FirstPixelOffset + y * ScanlineWidth;
        // With AA disabled only the top layer contributes to visible output.
        // Lower-layer raster scratch need not be expanded: the next frame
        // clears top attributes, and an AA edge initializes its lower pixel
        // before that pixel can contribute to visible output.
        assert(!(EffectiveDispCnt & (1u << 4)));
        for (u32* buffer : {ColorBuffer, DepthBuffer, AttrBuffer})
        {
#if defined(__arm__) && defined(__ARM_NEON)
            // Descending blocks keep overlapping source words intact.
            for (s32 x = end - 4; x >= first; x -= 4)
            {
                const uint32x4_t source = vld1q_u32(buffer + row + x);
                if (Tiny)
                {
                    vst1q_u32(buffer + row + 4*x, vdupq_n_u32(vgetq_lane_u32(source, 0)));
                    vst1q_u32(buffer + row + 4*x + 4, vdupq_n_u32(vgetq_lane_u32(source, 1)));
                    vst1q_u32(buffer + row + 4*x + 8, vdupq_n_u32(vgetq_lane_u32(source, 2)));
                    vst1q_u32(buffer + row + 4*x + 12, vdupq_n_u32(vgetq_lane_u32(source, 3)));
                }
                else
                {
                    const uint32x4x2_t doubled = vzipq_u32(source, source);
                    vst1q_u32(buffer + row + 2*x, doubled.val[0]);
                    vst1q_u32(buffer + row + 2*x + 4, doubled.val[1]);
                }
            }
#else
            for (s32 x = end - 1; x >= first; --x)
            {
                const u32 value = buffer[row + x];
                for (s32 dx = 0; dx < scale; ++dx) buffer[row + scale*x + dx] = value;
            }
#endif
        }
        // Keep every overwritten word visible to later sparse clears.
        FinalPassMinX[y] = first * scale;
        FinalPassMaxX[y] = end * scale;
    }
}

void SoftRenderer3D::SkipPolygonRow(
    RendererPolygon* rp, s32 y, bool& prevIsShadowMask)
{
    // Odd stencil storage is never consumed by a sampled even row. The
    // polygon-order carry flag does cross rows, and must still advance.
    const auto* polygon = rp->PolyData;
    prevIsShadowMask = polygon->IsShadowMask;
    if (!rp->PixelState.FlatRectangle && polygon->YTop != polygon->YBottom)
    {
        if (y >= polygon->Vertices[rp->NextVL]->FinalPosition[1] &&
            rp->CurVL != polygon->VBottom) SetupPolygonLeftEdge(rp, y);
        if (y >= polygon->Vertices[rp->NextVR]->FinalPosition[1] &&
            rp->CurVR != polygon->VBottom) SetupPolygonRightEdge(rp, y);
    }
    rp->XL = rp->SlopeL.Step();
    rp->XR = rp->SlopeR.Step();
}

void SoftRenderer3D::DuplicateAlternateRows(bool attributes)
{
    // Workers have joined. Union previous damage in every skipped row so
    // sparse clears and cancellation recovery cannot leave old pixels behind.
    const s32 step = RowStep();
    const bool clearImage = EffectiveDispCnt & (1u << 14);
    for (s32 y = 0; y < VisibleScanlines; y += step)
    {
        for (s32 offset = 1; offset < step; ++offset)
        {
            const s32 first = clearImage ? 0 : std::min(FinalPassMinX[y], FinalPassMinX[y+offset]);
            const s32 end = clearImage ? 256 : std::max(FinalPassMaxX[y], FinalPassMaxX[y+offset]);
            if (first >= end) continue;
            const u32 src = FirstPixelOffset + y * ScanlineWidth + first;
            const u32 dst = src + offset * ScanlineWidth;
            if (attributes)
            {
                std::copy_n(DepthBuffer + src, end - first, DepthBuffer + dst);
                std::copy_n(AttrBuffer + src, end - first, AttrBuffer + dst);
            }
            else std::copy_n(ColorBuffer + src, end - first, ColorBuffer + dst);
            FinalPassMinX[y+offset] = attributes ? first : clearImage ? 0 : FinalPassMinX[y];
            FinalPassMaxX[y+offset] = attributes ? end : clearImage ? 256 : FinalPassMaxX[y];
        }
    }
}

void SoftRenderer3D::RenderScanline(
    s32 y, RendererPolygon* polygonList, u32* activePolygonMask,
    bool& prevIsShadowMask, u8* stencilBuffer,
    s32 clipStartX, s32 clipEndX,
    u16* finalPassMinX, u16* finalPassMaxX)
{
    if (!UseScanlinePolygonLists)
    {
        for (int i = 0; i < CurrentPolygonCount; i++)
        {
            RendererPolygon* rp = &polygonList[i];
            Polygon* polygon = rp->PolyData;

            if (y >= polygon->YTop &&
                (y < polygon->YBottom ||
                 (y == polygon->YTop && polygon->YBottom == polygon->YTop)))
            {
                if (AlternateRows && (y & (RowStep() - 1)))
                    SkipPolygonRow(rp, y, prevIsShadowMask);
                else if (polygon->IsShadowMask)
                    RenderShadowMaskScanline(
                        rp, y, prevIsShadowMask, stencilBuffer,
                        clipStartX, clipEndX);
                else
                    RenderPolygonScanline(
                        rp, y, prevIsShadowMask, stencilBuffer,
                        clipStartX, clipEndX,
                        finalPassMinX, finalPassMaxX);
            }
        }
        return;
    }

    for (u16 i = ScanlineEndOffsets[y]; i < ScanlineEndOffsets[y + 1]; i++)
    {
        const int polygonIndex = ScanlineEndPolygonIndices[i];
        activePolygonMask[polygonIndex / 32] &=
            ~(1u << (polygonIndex % 32));
    }
    for (u16 i = ScanlineStartOffsets[y]; i < ScanlineStartOffsets[y + 1]; i++)
    {
        const int polygonIndex = ScanlineStartPolygonIndices[i];
        activePolygonMask[polygonIndex / 32] |=
            1u << (polygonIndex % 32);
    }

    for (int word = 0; word < ActivePolygonMaskWords; word++)
    {
        u32 active = activePolygonMask[word];
        while (active)
        {
            const int polygonIndex = word * 32 + __builtin_ctz(active);
            RendererPolygon* rp = &polygonList[polygonIndex];
            Polygon* polygon = rp->PolyData;

            if (AlternateRows && (y & (RowStep() - 1)))
                SkipPolygonRow(rp, y, prevIsShadowMask);
            else if (polygon->IsShadowMask)
                RenderShadowMaskScanline(
                    rp, y, prevIsShadowMask, stencilBuffer,
                    clipStartX, clipEndX);
            else
                RenderPolygonScanline(
                    rp, y, prevIsShadowMask, stencilBuffer,
                    clipStartX, clipEndX,
                    finalPassMinX, finalPassMaxX);

            active &= active - 1;
        }
    }
}

u32 SoftRenderer3D::CalculateFogDensity(u32 pixeladdr) const
{
    u32 z = DepthBuffer[pixeladdr];
    u32 densityid, densityfrac;

    if (z < GPU3D.RenderFogOffset)
    {
        densityid = 0;
        densityfrac = 0;
    }
    else
    {
        // technically: Z difference is shifted right by two, then shifted left by fog shift
        // then bit 0-16 are the fractional part and bit 17-31 are the density index
        // on hardware, the final value can overflow the 32-bit range with a shift big enough,
        // causing fog to 'wrap around' and accidentally apply to larger Z ranges

        z -= GPU3D.RenderFogOffset;
        z = (z >> 2) << GPU3D.RenderFogShift;

        densityid = z >> 17;
        if (densityid >= 32)
        {
            densityid = 32;
            densityfrac = 0;
        }
        else
            densityfrac = z & 0x1FFFF;
    }

    // checkme (may be too precise?)
    u32 density =
        ((GPU3D.RenderFogDensityTable[densityid] * (0x20000-densityfrac)) +
         (GPU3D.RenderFogDensityTable[densityid+1] * densityfrac)) >> 17;
    if (density >= 127) density = 128;

    return density;
}

[[gnu::always_inline, gnu::hot]] inline void
SoftRenderer3D::ScanlineFinalPassAntiAlias(s32 y)
{
    const int xStart = FinalPassMinX[y];
    const int xEnd = FinalPassMaxX[y];
    if (xStart >= xEnd) return;

    const u32 rowAddress = FirstPixelOffset + y * ScanlineWidth;
    u32* top = &ColorBuffer[rowAddress + xStart];
    const u32* bottom = top + BufferSize;
    const u32* attributes = &AttrBuffer[rowAddress + xStart];
    NDS4MiSTerApplyAntiAliasScanline(
        top, bottom, attributes, xEnd - xStart);
}

void SoftRenderer3D::ScanlineFinalPass(s32 y)
{
    if (AlternateRows && (y & (RowStep() - 1))) return;
    // to consider:
    // clearing all polygon fog flags if the master flag isn't set?
    // merging all final pass loops into one?

    int xStart = FinalPassMinX[y];
    int xEnd = FinalPassMaxX[y];
    if ((EffectiveDispCnt & (1<<7)) &&
        ((EffectiveDispCnt & (1<<14)) ||
         (GPU3D.RenderClearAttr1 & (1<<15))))
    {
        xStart = 0;
        xEnd = 256;
        // Fog can modify clear pixels outside every polygon.  Keep the
        // damage bounds complete so a later sparse clear restores them.
        FinalPassMinX[y] = 0;
        FinalPassMaxX[y] = 256;
    }

    if (xStart >= xEnd) return;

    if (EffectiveDispCnt & (1<<5))
    {
        // edge marking
        // only applied to topmost pixels

        for (int x = xStart; x < xEnd; x++)
        {
            u32 pixeladdr = FirstPixelOffset + (y*ScanlineWidth) + x;

            u32 attr = AttrBuffer[pixeladdr];
            if (!(attr & 0xF)) continue;

            u32 polyid = attr >> 24; // opaque polygon IDs are used for edgemarking
            u32 z = DepthBuffer[pixeladdr];

            if (((polyid != (AttrBuffer[pixeladdr-1] >> 24)) && (z < DepthBuffer[pixeladdr-1])) ||
                ((polyid != (AttrBuffer[pixeladdr+1] >> 24)) && (z < DepthBuffer[pixeladdr+1])) ||
                ((polyid != (AttrBuffer[pixeladdr-ScanlineWidth] >> 24)) && (z < DepthBuffer[pixeladdr-ScanlineWidth])) ||
                ((polyid != (AttrBuffer[pixeladdr+ScanlineWidth] >> 24)) && (z < DepthBuffer[pixeladdr+ScanlineWidth])))
            {
                u16 edgecolor = GPU3D.RenderEdgeTable[polyid >> 3];
                u32 edgeR = (edgecolor << 1) & 0x3E; if (edgeR) edgeR++;
                u32 edgeG = (edgecolor >> 4) & 0x3E; if (edgeG) edgeG++;
                u32 edgeB = (edgecolor >> 9) & 0x3E; if (edgeB) edgeB++;

                ColorBuffer[pixeladdr] = edgeR | (edgeG << 8) | (edgeB << 16) | (ColorBuffer[pixeladdr] & 0xFF000000);

                // break antialiasing coverage (checkme)
                AttrBuffer[pixeladdr] = (AttrBuffer[pixeladdr] & 0xFFFFE0FF) | 0x00001000;
            }
        }
    }

    if (EffectiveDispCnt & (1<<7))
    {
        // fog

        // hardware testing shows that the fog step is 0x80000>>SHIFT
        // basically, the depth values used in GBAtek need to be
        // multiplied by 0x200 to match Z-buffer values

        // fog is applied to the topmost two pixels, which is required for
        // proper antialiasing

        // TODO: check the 'fog alpha glitch with small Z' GBAtek talks about

        bool fogcolor = !(EffectiveDispCnt & (1<<6));

        u32 fogR = (GPU3D.RenderFogColor << 1) & 0x3E; if (fogR) fogR++;
        u32 fogG = (GPU3D.RenderFogColor >> 4) & 0x3E; if (fogG) fogG++;
        u32 fogB = (GPU3D.RenderFogColor >> 9) & 0x3E; if (fogB) fogB++;
        u32 fogA = (GPU3D.RenderFogColor >> 16) & 0x1F;

        for (int x = xStart; x < xEnd; x++)
        {
            u32 pixeladdr = FirstPixelOffset + (y*ScanlineWidth) + x;
            u32 density, srccolor, srcR, srcG, srcB, srcA;

            u32 attr = AttrBuffer[pixeladdr];
            if (attr & (1<<15))
            {
                density = CalculateFogDensity(pixeladdr);

                srccolor = ColorBuffer[pixeladdr];
                srcR = srccolor & 0x3F;
                srcG = (srccolor >> 8) & 0x3F;
                srcB = (srccolor >> 16) & 0x3F;
                srcA = (srccolor >> 24) & 0x1F;

                if (fogcolor)
                {
                    srcR = ((fogR * density) + (srcR * (128-density))) >> 7;
                    srcG = ((fogG * density) + (srcG * (128-density))) >> 7;
                    srcB = ((fogB * density) + (srcB * (128-density))) >> 7;
                }

                srcA = ((fogA * density) + (srcA * (128-density))) >> 7;

                ColorBuffer[pixeladdr] = srcR | (srcG << 8) | (srcB << 16) | (srcA << 24);
            }

            // fog for lower pixel
            // TODO: make this code nicer, but avoid using a loop

            if (!LowerLayerBufferSize || !(attr & 0xF)) continue;
            pixeladdr += BufferSize;

            attr = AttrBuffer[pixeladdr];
            if (!(attr & (1<<15))) continue;

            density = CalculateFogDensity(pixeladdr);

            srccolor = ColorBuffer[pixeladdr];
            srcR = srccolor & 0x3F;
            srcG = (srccolor >> 8) & 0x3F;
            srcB = (srccolor >> 16) & 0x3F;
            srcA = (srccolor >> 24) & 0x1F;

            if (fogcolor)
            {
                srcR = ((fogR * density) + (srcR * (128-density))) >> 7;
                srcG = ((fogG * density) + (srcG * (128-density))) >> 7;
                srcB = ((fogB * density) + (srcB * (128-density))) >> 7;
            }

            srcA = ((fogA * density) + (srcA * (128-density))) >> 7;

            ColorBuffer[pixeladdr] = srcR | (srcG << 8) | (srcB << 16) | (srcA << 24);
        }
    }

    if (EffectiveDispCnt & (1<<4))
    {
        // anti-aliasing

        // edges were flagged and their coverages calculated during rendering
        // this is where such edge pixels are blended with the pixels underneath

        const u32 rowAddress = FirstPixelOffset + y * ScanlineWidth;
        u32* top = &ColorBuffer[rowAddress + xStart];
        const u32* bottom = top + BufferSize;
        const u32* attributes = &AttrBuffer[rowAddress + xStart];
        int remaining = xEnd - xStart;

        NDS4MiSTerApplyAntiAliasScanline(
            top, bottom, attributes, remaining);
    }
}

void SoftRenderer3D::RecordPaletteDiagnostic(PaletteDiagnostic& d)
{
    d.Valid = true;
    std::copy_n(GPU.VRAMCNT, 9, d.Banks);
    std::copy_n(GPU.VRAMMap_TexPal, 8, d.Mapping);
    d.PhysicalGNonzero = d.FlatNonzero = 0;
    for (unsigned i = 0; i < sizeof(GPU.VRAM_G); i += 2)
        d.PhysicalGNonzero += (*reinterpret_cast<const u16*>(&GPU.VRAM_G[i]) & 0x7fff) != 0;
    for (unsigned i = 0; i < sizeof(GPU.VRAMFlat_TexPal); i += 2)
        d.FlatNonzero += (*reinterpret_cast<const u16*>(&GPU.VRAMFlat_TexPal[i]) & 0x7fff) != 0;
}

void SoftRenderer3D::RecordPalettePhase215()
{
    if (Parent.StageProfileEnabled) RecordPaletteDiagnostic(PaletteAt215);
}

bool SoftRenderer3D::DumpCompletedInputs(const char* path) const
{
    // Diagnostic caller is the replay owner, after 2D consumed row 96.
    // Do not wait on or reset a semaphore, refresh a cache, or read worker
    // state until this exact frame's completion was already consumed.
    if (!FullFrameCompletion || !RenderFrameFinished) return false;
    std::ostringstream out;
    out << "H3D_COMPLETED_INPUTS_V1\n"
        << "prepared=" << CurrentPolygonCount
        << " latched=" << GPU3D.RenderNumPolygons
        << " identical=" << FrameIdentical
        << " canceled=" << RenderFrameCanceled.load(std::memory_order_relaxed)
        << " dual=" << DualCoreRaster
        << " cache=" << UseTextureCache
        << " sparse=" << SparseClearEnabled
        << " guest_disp=" << GPU3D.RenderDispCnt
        << " effective_disp=" << EffectiveDispCnt
        << " disabled_effect_bits=" << DisabledEffectBits
        << " drop_shadows=" << DropShadows
        << " xpos=" << GPU3D.RenderXPos << '\n';
    out << "viewport=";
    for (auto value : GPU3D.Viewport) out << value << ',';
    out << "\nprojection=";
    for (auto value : GPU3D.ProjMatrix) out << value << ',';
    out << "\nposition=";
    for (auto value : GPU3D.PosMatrix) out << value << ',';
    out << '\n';
    // Include rejected geometry: otherwise an all-degenerate frame contains
    // no polygon evidence in this explicitly armed diagnostic.
    for (unsigned i = 0; i < std::min(32u, GPU3D.RenderNumPolygons); ++i)
    {
        const auto* p = GPU3D.RenderPolygonRAM[i];
        if (!p) continue;
        out << "latched_polygon=" << i << " degenerate=" << p->Degenerate
            << " vertices=" << p->NumVertices << " bounds="
            << p->XTop << ',' << p->XBottom << ',' << p->YTop << ',' << p->YBottom
            << " texparam=" << std::hex << p->TexParam << " palette="
            << p->TexPalette << " attr=" << p->Attr << std::dec << '\n';
        for (unsigned v = 0; v < std::min(10u, p->NumVertices); ++v)
        {
            const auto& a = *p->Vertices[v];
            out << " latched_vertex=" << v << " xy=" << a.FinalPosition[0]
                << ',' << a.FinalPosition[1] << " position=";
            for (auto value : a.Position) out << value << ',';
            out << " uv=" << a.TexCoords[0] << ',' << a.TexCoords[1] << '\n';
        }
    }
    out << "upload_snapshot=" << PreserveUploadSnapshot
        << " trace=" << UploadTraceEnabled
        << " held=" << std::hex << UploadAtStart.Held
        << " expired=" << UploadAtStart.Expired
        << " reassigned=" << UploadAtStart.Reassigned << " banks=";
    for (auto v : UploadBanksAtStart) out << unsigned(v) << ',';
    out << " textures=";
    for (auto v : UploadTextureMapping) out << v << ',';
    out << " palettes=";
    for (auto v : UploadPaletteMapping) out << v << ',';
    out << std::dec << " texture_age=";
    for (auto v : UploadAtStart.TextureAge) out << unsigned(v) << ',';
    out << " palette_age=";
    for (auto v : UploadAtStart.PaletteAge) out << unsigned(v) << ',';
    out << '\n';
    for (const auto& entry : {std::make_pair("215", &PaletteAt215),
                              std::make_pair("start", &PaletteAtStart)})
    {
        const auto& d = *entry.second;
        out << "palette_phase=" << entry.first << " valid=" << d.Valid << " banks=" << std::hex;
        for (auto v : d.Banks) out << unsigned(v) << ',';
        out << " mapping=";
        for (auto v : d.Mapping) out << v << ',';
        out << std::dec << " physical_g_rgb=" << d.PhysicalGNonzero
            << " flat_rgb=" << d.FlatNonzero << '\n';
    }
    std::vector<const u32*> textures;
    for (int i = 0; i < CurrentPolygonCount; ++i)
    {
        const auto& rp = PolygonList[i];
        const auto& ps = rp.PixelState;
        const auto& p = *rp.PolyData;
        const auto found = std::find(textures.begin(), textures.end(), ps.TexturePixels);
        const auto textureId = found - textures.begin();
        if (found == textures.end())
        {
            textures.push_back(ps.TexturePixels);
            const unsigned size = ps.TexturePixels ?
                unsigned(ps.TextureWidth) * unsigned(ps.TextureHeight) : 0;
            // Inspect small textures completely. A regular sparse stride
            // repeatedly selects tile borders and can miss opaque interiors.
            const unsigned samples = std::min(size, 65536u);
            unsigned count = 0, rgb = 0, alpha = 0;
            u64 hash = 1469598103934665603ULL;
            for (unsigned t = 0; t < samples; ++t)
            {
                const unsigned index = size <= 65536 ? t :
                    ((t * 65537u) & (size - 1));
                const u32 v = ps.TexturePixels[index];
                ++count; rgb += (v & 0x00ffffffu) != 0; alpha += (v >> 24) != 0;
                hash = (hash ^ v) * 1099511628211ULL;
            }
            out << "texture=" << textureId << " size=" << size
                << " count=" << count << " rgb=" << rgb << " alpha=" << alpha
                << " hash=" << std::hex << hash << std::dec << '\n';
        }
        out << "polygon=" << i << " texture=" << textureId
            << " texparam=" << std::hex << p.TexParam << " palette=" << p.TexPalette
            << " attr=" << p.Attr << " prepared_attr=" << rp.PolyAttr << std::dec
            << " mode=" << unsigned(ps.BlendMode) << " alpha=" << unsigned(ps.PolyAlpha)
            << " enabled=" << ps.TextureEnabled << " format=" << unsigned(ps.TextureFormat)
            << " bounds=" << p.XTop << ',' << p.XBottom << ',' << p.YTop << ',' << p.YBottom
            << " shadow=" << p.IsShadowMask << ',' << p.IsShadow << '\n';
        unsigned coloredVertices = 0;
        for (unsigned v = 0; v < p.NumVertices; ++v)
            coloredVertices += (p.Vertices[v]->FinalColor[0] |
                p.Vertices[v]->FinalColor[1] | p.Vertices[v]->FinalColor[2]) != 0;
        out << " vertices=" << p.NumVertices << " rgb=" << coloredVertices << '\n';
        for (unsigned v = 0; i < 4 && v < p.NumVertices; ++v)
        {
            const auto& a = *p.Vertices[v];
            out << " vertex=" << v << " xy=" << a.FinalPosition[0] << ',' << a.FinalPosition[1]
                << " color=" << a.FinalColor[0] << ',' << a.FinalColor[1] << ',' << a.FinalColor[2]
                << " uv=" << a.TexCoords[0] << ',' << a.TexCoords[1]
                << " zw=" << p.FinalZ[v] << ',' << p.FinalW[v] << '\n';
        }
    }
    return WriteBounded3DDiagnostic(path, out.str());
}

void SoftRenderer3D::ClearBuffers()
{
    u32 clearz = ((GPU3D.RenderClearAttr2 & 0x7FFF) * 0x200) + 0x1FF;
    u32 polyid = GPU3D.RenderClearAttr1 & 0x3F000000; // this sets the opaque polygonID

    const bool clearImage = EffectiveDispCnt & (1<<14);
    const bool reuseConstantClear = SparseClearEnabled &&
        SparseClearStateValid && !clearImage &&
        SparseClearAttr1 == GPU3D.RenderClearAttr1 &&
        SparseClearAttr2 == GPU3D.RenderClearAttr2;

    if (reuseConstantClear)
    {
        // RenderPolygonScanline expands these bounds before any possible
        // color/depth/attribute write. ScanlineFinalPass also expands them
        // for the only full-row write case (fogging the clear background).
        // Dual-core workers own disjoint rows, and cancellation joins them
        // before another frame starts, so the completed bounds are stable.
        u32 r = (GPU3D.RenderClearAttr1 << 1) & 0x3E; if (r) r++;
        u32 g = (GPU3D.RenderClearAttr1 >> 4) & 0x3E; if (g) g++;
        u32 b = (GPU3D.RenderClearAttr1 >> 9) & 0x3E; if (b) b++;
        u32 a = (GPU3D.RenderClearAttr1 >> 16) & 0x1F;
        const u32 color = r | (g << 8) | (b << 16) | (a << 24);
        polyid |= (GPU3D.RenderClearAttr1 & 0x8000);

        for (int y = 0; y < VisibleScanlines; y++)
        {
            // DuplicateAlternateRows will restore these words from the
            // cleared sampled row. Preserve old bounds until both copies
            // complete, including a cancellation before either pass.
            if (AlternateRows && (y & (RowStep() - 1))) continue;
            const int start = FinalPassMinX[y];
            const int end = FinalPassMaxX[y];
            if (start < end)
            {
                const u32 pixeladdr = FirstPixelOffset +
                    y * ScanlineWidth + start;
                const int count = end - start;
                std::fill_n(&ColorBuffer[pixeladdr], count, color);
                std::fill_n(&DepthBuffer[pixeladdr], count, clearz);
                std::fill_n(&AttrBuffer[pixeladdr], count, polyid);
            }
            FinalPassMinX[y] = 256;
            FinalPassMaxX[y] = 0;
        }
        return;
    }

    for (int y = 0; y < VisibleScanlines; y++)
    {
        FinalPassMinX[y] = 256;
        FinalPassMaxX[y] = 0;
    }

    // fill screen borders for edge marking

    for (int x = 0; x < ScanlineWidth; x++)
    {
        ColorBuffer[x] = 0;
        DepthBuffer[x] = clearz;
        AttrBuffer[x] = polyid;
    }

    for (int x = ScanlineWidth; x < ScanlineWidth*193; x+=ScanlineWidth)
    {
        ColorBuffer[x] = 0;
        DepthBuffer[x] = clearz;
        AttrBuffer[x] = polyid;
        ColorBuffer[x+257] = 0;
        DepthBuffer[x+257] = clearz;
        AttrBuffer[x+257] = polyid;
    }

    for (int x = ScanlineWidth*193; x < ScanlineWidth*194; x++)
    {
        ColorBuffer[x] = 0;
        DepthBuffer[x] = clearz;
        AttrBuffer[x] = polyid;
    }

    // clear the screen

    if (clearImage)
    {
        u8 xoff = (GPU3D.RenderClearAttr2 >> 16) & 0xFF;
        u8 yoff = (GPU3D.RenderClearAttr2 >> 24) & 0xFF;

        for (int y = 0; y < ScanlineWidth*192; y+=ScanlineWidth)
        {
            for (int x = 0; x < 256; x++)
            {
                const u8 sampledX = Quarter ? u8(((GPU3D.RenderClearAttr2 >> 16) & 0xff) + (Tiny ? 4 : 2) * x) : xoff;
                u16 val2 = GPU.ReadVRAMFlat_Texture<u16>(0x40000 + (yoff << 9) + (sampledX << 1));
                u16 val3 = GPU.ReadVRAMFlat_Texture<u16>(0x60000 + (yoff << 9) + (sampledX << 1));

                // TODO: confirm color conversion
                u32 r = (val2 << 1) & 0x3E; if (r) r++;
                u32 g = (val2 >> 4) & 0x3E; if (g) g++;
                u32 b = (val2 >> 9) & 0x3E; if (b) b++;
                u32 a = (val2 & 0x8000) ? 0x1F000000 : 0;
                u32 color = r | (g << 8) | (b << 16) | a;

                u32 z = ((val3 & 0x7FFF) * 0x200) + 0x1FF;

                u32 pixeladdr = FirstPixelOffset + y + x;
                ColorBuffer[pixeladdr] = color;
                DepthBuffer[pixeladdr] = z;
                AttrBuffer[pixeladdr] = polyid | (val3 & 0x8000);

                xoff++;
            }

            yoff++;
        }
        SparseClearStateValid = false;
    }
    else
    {
        // TODO: confirm color conversion
        u32 r = (GPU3D.RenderClearAttr1 << 1) & 0x3E; if (r) r++;
        u32 g = (GPU3D.RenderClearAttr1 >> 4) & 0x3E; if (g) g++;
        u32 b = (GPU3D.RenderClearAttr1 >> 9) & 0x3E; if (b) b++;
        u32 a = (GPU3D.RenderClearAttr1 >> 16) & 0x1F;
        u32 color = r | (g << 8) | (b << 16) | (a << 24);

        polyid |= (GPU3D.RenderClearAttr1 & 0x8000);

        for (int y = 0; y < ScanlineWidth*192; y+=ScanlineWidth)
        {
            for (int x = 0; x < 256; x++)
            {
                u32 pixeladdr = FirstPixelOffset + y + x;
                ColorBuffer[pixeladdr] = color;
                DepthBuffer[pixeladdr] = clearz;
                AttrBuffer[pixeladdr] = polyid;
            }
        }
        SparseClearStateValid = SparseClearEnabled;
        SparseClearAttr1 = GPU3D.RenderClearAttr1;
        SparseClearAttr2 = GPU3D.RenderClearAttr2;
    }
}

int SoftRenderer3D::SetupRenderPolygons(Polygon** polygons, int npolys)
{
    const auto setupStarted =
        renderer3DProfileStarted(Parent.StageProfileEnabled);
    TextureBindingCache textureBinding;
    // Keep reduced-resolution modes on their established layer behavior.
    // The isolated hardware gain was in Native mode.
    LowerLayerBufferSize = SingleLayerAAOff && !AlternateRowsRequested &&
        !QuarterRequested && !TinyRequested && !(EffectiveDispCnt & (1u << 4))
        ? 0 : BufferSize;
    int j = 0;
    for (int i = 0; i < npolys; i++)
    {
        if (polygons[i]->Degenerate) continue;
        if (DropShadows &&
            (polygons[i]->IsShadowMask || polygons[i]->IsShadow)) continue;
        // Keep the established two-layer stencil semantics for every frame
        // containing shadow geometry. Ordinary AA-off frames have no final
        // consumer of lower colors, depth or attributes.
        if (polygons[i]->IsShadowMask || polygons[i]->IsShadow)
            LowerLayerBufferSize = BufferSize;
        SetupPolygon(&PolygonList[j++], polygons[i], textureBinding);
    }
    CurrentPolygonCount = j;
    UseScanlinePolygonLists = j > ScheduledPolygonThreshold;
    const u32 polygonScanlines =
        (UseScanlinePolygonLists || Parent.StageProfileEnabled) ?
            BuildScanlinePolygonLists(j) : 0;
    if (Parent.StageProfileEnabled)
    {
        Parent.StageProfile.ThreeDSetupNs +=
            renderer3DProfileElapsedNs(setupStarted);
        ++Parent.StageProfile.ThreeDPolygonFrames;
        Parent.StageProfile.ThreeDPolygons += static_cast<u64>(j);
        Parent.StageProfile.ThreeDPolygonScanlines += polygonScanlines;
        Parent.StageProfile.ThreeDMaxPolygons = std::max(
            Parent.StageProfile.ThreeDMaxPolygons, static_cast<u64>(j));
        Parent.StageProfile.ThreeDScheduledPolygonFrames +=
            UseScanlinePolygonLists;
    }
    return j;
}

u64 SoftRenderer3D::RenderScanlineBand(
    s32 firstLine, s32 endLine, RendererPolygon* polygonList,
    u32* activePolygonMask, bool& prevIsShadowMask, u8* stencilBuffer,
    s32 clipStartX, s32 clipEndX,
    u16* finalPassMinX, u16* finalPassMaxX)
{
    const auto started = renderer3DProfileStarted(Parent.StageProfileEnabled);
    for (s32 y = firstLine; y < endLine; y++)
    {
        if (CancelRasterIfRequested()) break;
        RenderScanline(
            y, polygonList, activePolygonMask,
            prevIsShadowMask, stencilBuffer,
            clipStartX, clipEndX,
            finalPassMinX, finalPassMaxX);
    }
    return Parent.StageProfileEnabled ? renderer3DProfileElapsedNs(started) : 0;
}

SoftRenderer3D::RasterBandResult SoftRenderer3D::RenderRasterBandJobs(
    int initialBand, RendererPolygon* polygonList,
    u32* activePolygonMask, bool& prevIsShadowMask, u8* stencilBuffer)
{
    RasterBandResult result;
    int band = initialBand;
    s32 contextLine = RasterBandBoundaries[band];
    while (band < RasterBandCount)
    {
        if (CancelRasterIfRequested()) break;
        const s32 firstLine = RasterBandBoundaries[band];
        const s32 endLine = RasterBandBoundaries[band + 1];
        if (contextLine < firstLine)
        {
            RebaseRasterContext(
                firstLine, polygonList, activePolygonMask,
                prevIsShadowMask);
            result.AdvancedScanlines += firstLine - contextLine;
        }
        if (CollectRasterTileCosts)
        {
            // Time 12-row groups, not individual pixels or scanlines. Thread
            // CPU time excludes replay-worker preemption from the work model.
            // Each tile belongs to one worker, and history is read only after
            // the complete-frame fence on the following frame.
            const auto cpuNow = []() -> u64 {
#ifdef CLOCK_THREAD_CPUTIME_ID
                timespec value {};
                if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) == 0)
                    return u64(value.tv_sec) * 1000000000u + value.tv_nsec;
#endif
                return renderer3DClockNowNs();
            };
            for (s32 line = firstLine; line < endLine; line += RasterWorkTileLines)
            {
                const u64 started = cpuNow();
                result.RenderNs += RenderScanlineBand(
                    line, line + RasterWorkTileLines, polygonList, activePolygonMask,
                    prevIsShadowMask, stencilBuffer, 0, 256,
                    FinalPassMinX, FinalPassMaxX);
                RasterTileCosts[line / RasterWorkTileLines] =
                    static_cast<u32>(std::min<u64>(cpuNow() - started, UINT32_MAX));
            }
        }
        else
        {
            result.RenderNs += RenderScanlineBand(
                firstLine, endLine, polygonList, activePolygonMask,
                prevIsShadowMask, stencilBuffer, 0, 256,
                FinalPassMinX, FinalPassMaxX);
        }
        ++result.Jobs;
        contextLine = endLine;
        band = ParallelRasterNextBand_.fetch_add(
            1, std::memory_order_relaxed);
    }
    return result;
}

void SoftRenderer3D::RebaseRasterContext(
    s32 firstLine, RendererPolygon* polygonList,
    u32* activePolygonMask, bool& prevIsShadowMask)
{
    // A stolen band is disjoint from the preceding band rendered by this
    // worker. Replaying every skipped scanline advances the same private edge
    // state but wastes work proportional to the gap. Reconstruct the active
    // set and every crossing edge directly at the new boundary instead.
    // RasterBandQueueSafe() remains the gate for shadow/stencil state, so this
    // changes only private cursor preparation, never pixel ownership/order.
    if (UseScanlinePolygonLists)
        std::fill_n(activePolygonMask, ActivePolygonMaskWords, 0);

    for (int index = 0; index < CurrentPolygonCount; ++index)
    {
        RendererPolygon* rp = &polygonList[index];
        Polygon* polygon = rp->PolyData;
        const bool active = firstLine >= polygon->YTop &&
            (firstLine < polygon->YBottom ||
             (firstLine == polygon->YTop &&
              polygon->YBottom == polygon->YTop));
        if (!active) continue;

        if (UseScanlinePolygonLists)
            activePolygonMask[index / 32] |= 1u << (index % 32);
        if (polygon->YTop != polygon->YBottom)
        {
            SetupPolygonLeftEdge(rp, firstLine);
            SetupPolygonRightEdge(rp, firstLine);
        }
    }
    prevIsShadowMask = false;
}

bool SoftRenderer3D::RasterBandQueueSafe(int npolys) const
{
    bool hasShadow = false;
    for (int index = 0; index < npolys; ++index)
    {
        const Polygon* polygon = PolygonList[index].PolyData;
        hasShadow |= polygon->IsShadowMask || polygon->IsShadow;
    }
    if (!hasShadow) return true;

    // Shadow stencil storage is scanline-local but physically reused by
    // parity. A worker that jumps over a band cannot inherit the other
    // worker's two stencil rows, so only admit a band boundary when the
    // canonical PrevIsShadowMask state is false and each reused parity row is
    // cleared by a shadow mask before a shadow polygon consumes it. This is a
    // sufficient, ordering-preserving condition; uncertain frames retain the
    // exact adaptive two-way renderer.
    bool boundaryPrevIsShadowMask[RasterBandCount] {};
    u32 activePolygonMask[PolygonMaskWords] {};
    bool canonicalPrevIsShadowMask = PrevIsShadowMask;
    for (int y = 0; y < VisibleScanlines; ++y)
    {
        if ((y % RasterBandLines) == 0)
            boundaryPrevIsShadowMask[y / RasterBandLines] =
                canonicalPrevIsShadowMask;

        for (u16 i = ScanlineEndOffsets[y];
             i < ScanlineEndOffsets[y + 1]; ++i)
        {
            const int polygonIndex = ScanlineEndPolygonIndices[i];
            activePolygonMask[polygonIndex / 32] &=
                ~(1u << (polygonIndex % 32));
        }
        for (u16 i = ScanlineStartOffsets[y];
             i < ScanlineStartOffsets[y + 1]; ++i)
        {
            const int polygonIndex = ScanlineStartPolygonIndices[i];
            activePolygonMask[polygonIndex / 32] |=
                1u << (polygonIndex % 32);
        }
        for (int word = 0; word < ActivePolygonMaskWords; ++word)
        {
            u32 active = activePolygonMask[word];
            while (active)
            {
                const int polygonIndex = word * 32 + __builtin_ctz(active);
                canonicalPrevIsShadowMask =
                    PolygonList[polygonIndex].PolyData->IsShadowMask;
                active &= active - 1;
            }
        }
    }

    std::fill_n(activePolygonMask, ActivePolygonMaskWords, 0);
    bool workerPrevIsShadowMask = PrevIsShadowMask;
    bool stencilParityInitialized[2] {true, true};
    for (int y = 0; y < VisibleScanlines; ++y)
    {
        const int band = y / RasterBandLines;
        if (y != 0 && (y % RasterBandLines) == 0)
        {
            if (boundaryPrevIsShadowMask[band]) return false;
            workerPrevIsShadowMask = false;
            stencilParityInitialized[0] = false;
            stencilParityInitialized[1] = false;
        }

        for (u16 i = ScanlineEndOffsets[y];
             i < ScanlineEndOffsets[y + 1]; ++i)
        {
            const int polygonIndex = ScanlineEndPolygonIndices[i];
            activePolygonMask[polygonIndex / 32] &=
                ~(1u << (polygonIndex % 32));
        }
        for (u16 i = ScanlineStartOffsets[y];
             i < ScanlineStartOffsets[y + 1]; ++i)
        {
            const int polygonIndex = ScanlineStartPolygonIndices[i];
            activePolygonMask[polygonIndex / 32] |=
                1u << (polygonIndex % 32);
        }
        for (int word = 0; word < ActivePolygonMaskWords; ++word)
        {
            u32 active = activePolygonMask[word];
            while (active)
            {
                const int polygonIndex = word * 32 + __builtin_ctz(active);
                const Polygon* polygon =
                    PolygonList[polygonIndex].PolyData;
                if (polygon->IsShadowMask)
                {
                    if (!workerPrevIsShadowMask)
                        stencilParityInitialized[y & 1] = true;
                    workerPrevIsShadowMask = true;
                }
                else
                {
                    if (polygon->IsShadow &&
                        !stencilParityInitialized[y & 1])
                        return false;
                    workerPrevIsShadowMask = false;
                }
                active &= active - 1;
            }
        }
    }
    return true;
}

void SoftRenderer3D::PrepareParallelRasterBand(
    int npolys, s32 firstLine, bool preserveShadowState)
{
    std::copy_n(PolygonList, npolys, ParallelPolygonList.get());
    if (UseScanlinePolygonLists)
        std::fill_n(ParallelActivePolygonMask, ActivePolygonMaskWords, 0);
    if (preserveShadowState)
    {
        std::copy_n(
            StencilBuffer, sizeof(StencilBuffer), ParallelStencilBuffer);
        ParallelPrevIsShadowMask = PrevIsShadowMask;
    }
    else
    {
        memset(ParallelStencilBuffer, 0, sizeof(ParallelStencilBuffer));
        ParallelPrevIsShadowMask = false;
    }
    if (preserveShadowState)
    {
        std::fill_n(ParallelFinalPassMinX, VisibleScanlines, 256);
        std::fill_n(ParallelFinalPassMaxX, VisibleScanlines, 0);
    }

    for (int i = 0; i < npolys; i++)
    {
        RendererPolygon* rp = &ParallelPolygonList[i];
        Polygon* polygon = rp->PolyData;
        const bool active = firstLine >= polygon->YTop &&
            (firstLine < polygon->YBottom ||
             (firstLine == polygon->YTop &&
              polygon->YBottom == polygon->YTop));
        if (!active) continue;

        if (UseScanlinePolygonLists)
            ParallelActivePolygonMask[i / 32] |= 1u << (i % 32);

        // Each worker owns mutable edge/interpolator state. Rebuild only the
        // polygons crossing the band boundary directly at that scanline;
        // polygons beginning later retain their normal top-edge setup.
        if (polygon->YTop != polygon->YBottom)
        {
            SetupPolygonLeftEdge(rp, firstLine);
            SetupPolygonRightEdge(rp, firstLine);
        }
    }
}

u32 SoftRenderer3D::BuildRasterScanlineWork(int npolys, u32* lineWork) const
{
    // Shared bounded O(vertices+P+H) estimate for adaptive two-way splitting
    // and the optional four-job layout. Use already-prepared geometry and
    // add no work to the pixel loops.
    s32 scanlineDelta[VisibleScanlines + 1] = {};
    for (int i = 0; i < npolys; i++)
    {
        const Polygon* polygon = PolygonList[i].PolyData;
        int first = std::clamp(polygon->YTop, 0, VisibleScanlines);
        int end = std::clamp(polygon->YBottom, 0, VisibleScanlines);
        if (polygon->YBottom == polygon->YTop &&
            polygon->YTop >= 0 && polygon->YTop < VisibleScanlines)
            end = first + 1;
        if (first >= end) continue;

        s32 left = 256;
        s32 right = -1;
        for (u32 vertex = 0; vertex < polygon->NumVertices; vertex++)
        {
            const s32 x = RasterX(polygon->Vertices[vertex]);
            left = std::min(left, x);
            right = std::max(right, x);
        }
        left = std::clamp(left, 0, 255);
        right = std::clamp(right, 0, 255);
        const s32 projectedWidth = std::max(1, right - left + 1);
        scanlineDelta[first] += projectedWidth;
        scanlineDelta[end] -= projectedWidth;
    }

    u32 totalWork = 0;
    s32 activeProjectedWidth = 0;
    for (int y = 0; y < VisibleScanlines; y++)
    {
        activeProjectedWidth += scanlineDelta[y];
        lineWork[y] = static_cast<u32>(activeProjectedWidth);
        totalWork += lineWork[y];
    }
    return totalWork;
}

bool SoftRenderer3D::IsFpgaLightScene(int npolys) const
{
    if (npolys < 32) return false;
    // The sum of the scanline estimate is the sum of clipped rectangle areas.
    // Admission only needs the threshold, so stop as soon as it is reached.
    u32 totalWork = 0;
    for (int i = 0; i < npolys; i++)
    {
        const Polygon* polygon = PolygonList[i].PolyData;
        int first = std::clamp(polygon->YTop, 0, VisibleScanlines);
        int end = std::clamp(polygon->YBottom, 0, VisibleScanlines);
        if (polygon->YBottom == polygon->YTop &&
            polygon->YTop >= 0 && polygon->YTop < VisibleScanlines)
            end = first + 1;
        if (first >= end) continue;

        s32 left = 256;
        s32 right = -1;
        for (u32 vertex = 0; vertex < polygon->NumVertices; vertex++)
        {
            const s32 x = RasterX(polygon->Vertices[vertex]);
            left = std::min(left, x);
            right = std::max(right, x);
        }
        left = std::clamp(left, 0, 255);
        right = std::clamp(right, 0, 255);
        const s32 projectedWidth = std::max(1, right - left + 1);
        totalWork += u32(projectedWidth) * u32(end - first);
        if (totalWork >= 32768) return false;
    }
    return true;
}

s32 SoftRenderer3D::ChooseParallelRasterSplitLine(int npolys) const
{
    u32 lineWork[VisibleScanlines] {};
    const u32 totalWork = BuildRasterScanlineWork(npolys, lineWork);
    if (totalWork == 0) return 112;

    const u32 primaryPermille = AdaptiveRasterSplit ?
        RasterBalance.PrimaryPermille() :
        NDS4MiSTerRasterBalanceController::DefaultPrimaryPermille;
    const u32 primaryTarget =
        NDS4MiSTerScalePermilleCeil(totalWork, primaryPermille);
    u32 primaryWork = 0;
    for (int y = 0; y < VisibleScanlines - 1; y++)
    {
        primaryWork += lineWork[y];
        if (primaryWork >= primaryTarget) return y + 1;
    }
    return VisibleScanlines - 1;
}

s32 SoftRenderer3D::ChooseParallelRasterSplitX(int npolys) const
{
    // Shadow/stencil ordering prevents an arbitrary worker from starting at
    // a later scanline. Both workers can instead walk every scanline and
    // polygon in canonical order while owning disjoint X intervals. Estimate
    // the pixel work in each column from the prepared polygon bounds and give
    // CPU0 the same feedback-guided share used by the established Y split.
    s32 columnDelta[257] {};
    for (int index = 0; index < npolys; ++index)
    {
        const Polygon* polygon = PolygonList[index].PolyData;
        s32 left = 256;
        s32 right = -1;
        for (u32 vertex = 0; vertex < polygon->NumVertices; ++vertex)
        {
            const s32 x = RasterX(polygon->Vertices[vertex]);
            left = std::min(left, x);
            right = std::max(right, x);
        }
        left = std::clamp(left, 0, 255);
        right = std::clamp(right, 0, 255);
        if (left > right) continue;

        const s32 firstLine = std::clamp(
            polygon->YTop, 0, VisibleScanlines);
        s32 endLine = std::clamp(
            polygon->YBottom, 0, VisibleScanlines);
        if (polygon->YBottom == polygon->YTop &&
            polygon->YTop >= 0 && polygon->YTop < VisibleScanlines)
            endLine = firstLine + 1;
        const s32 height = std::max(0, endLine - firstLine);
        if (height == 0) continue;
        columnDelta[left] += height;
        columnDelta[right + 1] -= height;
    }

    u32 columnWork[256] {};
    u64 totalWork = 0;
    s32 activeHeight = 0;
    for (s32 x = 0; x < 256; ++x)
    {
        activeHeight += columnDelta[x];
        columnWork[x] = static_cast<u32>(activeHeight);
        totalWork += columnWork[x];
    }
    if (totalWork == 0) return 128;

    const u32 primaryPermille = AdaptiveRasterSplit ?
        RasterBalance.PrimaryPermille() :
        NDS4MiSTerRasterBalanceController::DefaultPrimaryPermille;
    const u64 primaryTarget =
        (totalWork * primaryPermille + 999) / 1000;
    u64 primaryWork = 0;
    for (s32 x = 0; x < 255; ++x)
    {
        primaryWork += columnWork[x];
        if (primaryWork >= primaryTarget)
            return std::clamp<s32>(x + 1, 32, 224);
    }
    return 224;
}

void SoftRenderer3D::PrepareFpgaSpanCache()
{
    FpgaSpanCacheHits=FpgaSpanCacheCommands=0;
    if (!FpgaSpanCacheEnabled) return;
    // Bound retained capacities as well as this frame's logical contents.
    // A changing workload cannot accumulate a large history per polygon slot.
    size_t capacity=0;
    for (const auto& c:FpgaSpanCache) capacity+=c.Commands.capacity()+c.PackedCommands.capacity();
    for (const auto& c:FpgaSpanCacheScratch) capacity+=c.Commands.capacity()+c.PackedCommands.capacity();
    if (capacity>4*fpga3d::MaxCommands) { FpgaSpanCache.clear();FpgaSpanCacheScratch.clear(); }
    // Match values across polygon sorting/insertion. Hashes only select a
    // bucket: full exact key equality is required before moving any entry.
    FpgaSpanCache.swap(FpgaSpanCacheScratch);
    auto& previous=FpgaSpanCacheScratch;
    std::array<s16,1024> heads;heads.fill(-1);
    std::array<s16,MaxRendererPolygons> next;
    std::array<u8,MaxRendererPolygons> used {};
    for (size_t i=0;i<previous.size();i++)
    {
        const auto& c=previous[i];
        if (!c.Ready) continue;
        const auto bucket=c.Hash&1023;
        next[i]=heads[bucket];heads[bucket]=i;
    }
    FpgaSpanCache.resize(CurrentPolygonCount);
    for (int i=0;i<CurrentPolygonCount;i++)
    {
        auto& c=FpgaSpanCache[i];
        const auto& rp=PolygonList[i];
        const auto& p=*rp.PolyData;
        const auto& ps=rp.PixelState;
        c.Hit=c.Record=false;
        // Shadow-mask grouping has cross-polygon state; keep both shadow
        // forms on the established producer path.
        if (p.IsShadowMask || p.IsShadow) { c.Ready=false; continue; }
        std::array<u32,128> key;
        size_t k=0;
        const auto add=[&](u32 v){key[k++]=v;};
        add(FpgaFrame.recyclePublished);
        add(EffectiveDispCnt);add(GPU3D.RenderAlphaRef);
        add(p.NumVertices);add(p.Attr);
        add(p.WBuffer);add(p.FacingView);add(p.Type);
        add(p.VTop);add(p.VBottom);add(p.YTop);add(p.YBottom);
        add(p.XTop);add(p.XBottom);add(rp.PolyAttr);
        add(ps.TextureEnabled);add(ps.TextureWidth);add(ps.TextureHeight);
        add(ps.TextureWidthShift);add(ps.TextureWrapFlags);add(ps.BlendMode);
        add(ps.PolyAlpha);add(ps.CachedModulate);add(ps.ConstantVertexColor);
        // Explicit values avoid pointer identity, padding and hash collisions.
        // These are every vertex input consumed by edge setup/interpolation.
        for (u32 v=0;v<p.NumVertices;v++)
        {
            const auto& vertex=*p.Vertices[v];
            add(vertex.FinalPosition[0]);add(vertex.FinalPosition[1]);
            add(vertex.FinalColor[0]);add(vertex.FinalColor[1]);add(vertex.FinalColor[2]);
            add(vertex.TexCoords[0]);add(vertex.TexCoords[1]);
            add(p.FinalW[v]);add(p.FinalZ[v]);
        }
        const s32 first=std::clamp(p.YTop,0,VisibleScanlines);
        const s32 end=p.YTop==p.YBottom && p.YTop>=0 && p.YTop<VisibleScanlines?
            first+1:std::clamp(p.YBottom,0,VisibleScanlines);
        u32 hash=2166136261u;
        for (size_t word=0;word<k;word++) hash=(hash^key[word])*16777619u;
        int match=-1;
        for (int j=heads[hash&1023];j>=0;j=next[j])
        {
            const auto& old=previous[j];
            if (!used[j] && old.Hash==hash && old.KeyWords==k &&
                !std::memcmp(old.Key.data(),key.data(),k*sizeof(u32)))
            { match=j;break; }
        }
        if (match>=0)
        {
            used[match]=1;std::swap(c,previous[match]);
            c.Hit=true;c.Record=false;++FpgaSpanCacheHits;
        }
        else
        {
            std::copy_n(key.begin(),k,c.Key.begin());c.Hash=hash;c.KeyWords=k;
            c.Commands.clear();c.PackedCommands.clear();c.RowEnds.clear();c.RowBounds.clear();
            c.FirstLine=first;c.EndLine=end;c.Ready=false;
            c.Record=first<end;
        }
        c.TextureAddress=ps.TextureEnabled?FpgaFrame.textureOffsets.at(ps.TexturePixels):0;
    }
}

void SoftRenderer3D::RenderFpgaPolygonScanline(
    RendererPolygon* rp,s32 y,bool& prevIsShadowMask,u8* stencilBuffer,
    s32 clipStartX,s32 clipEndX,u16* finalPassMinX,u16* finalPassMaxX)
{
    FpgaPolygonSpans* c=FpgaSpanCacheEnabled?
        &FpgaSpanCache[rp-PolygonList]:nullptr;
    if (c && c->Hit)
    {
        const auto row=y-c->FirstLine;
        const unsigned begin=row?c->RowEnds[row-1]:0;
        const unsigned end=c->RowEnds[row];
        const u16 firstX=c->RowBounds[row]&65535,endX=c->RowBounds[row]>>16;
        if(firstX<endX){
            finalPassMinX[y]=std::min(finalPassMinX[y],firstX);
            finalPassMaxX[y]=std::max(finalPassMaxX[y],endX);
        }
        prevIsShadowMask=false;
        if (FpgaFrame.recyclePublished)
            for (unsigned i=begin;i<end;i++) FpgaFrame.appendPacked(c->PackedCommands[i],c->TextureAddress);
        else
            for (unsigned i=begin;i<end;i++)
            {
                auto command=c->Commands[i];
                if (c->TextureAddress) {
                    command[13]=c->TextureAddress&~1u;
                    command[14]=(command[14]&~0x1000u)|((c->TextureAddress&1u)<<12);
                }
                FpgaFrame.append(command);
            }
        FpgaSpanCacheCommands+=end-begin;
        return;
    }
    const size_t begin=FpgaFrame.recyclePublished?
        FpgaFrame.packedCommands.size():FpgaFrame.commands.size();
    const u16 previousFirst=finalPassMinX[y],previousEnd=finalPassMaxX[y];
    finalPassMinX[y]=256;finalPassMaxX[y]=0;
    RenderPolygonScanlineImpl<true>(rp,y,prevIsShadowMask,stencilBuffer,
        clipStartX,clipEndX,finalPassMinX,finalPassMaxX);
    const u32 rowBounds=finalPassMinX[y]|(u32(finalPassMaxX[y])<<16);
    finalPassMinX[y]=std::min(finalPassMinX[y],previousFirst);
    finalPassMaxX[y]=std::max(finalPassMaxX[y],previousEnd);
    if (c && c->Record)
    {
        if (!FpgaFrame.valid || y!=c->FirstLine+s32(c->RowEnds.size()))
        {
            c->Record=c->Ready=false;
            return;
        }
        c->RowBounds.push_back(rowBounds);
        if (FpgaFrame.recyclePublished)
        {
            c->PackedCommands.insert(c->PackedCommands.end(),FpgaFrame.packedCommands.begin()+begin,
                FpgaFrame.packedCommands.end());
            c->RowEnds.push_back(c->PackedCommands.size());
        }
        else
        {
            c->Commands.insert(c->Commands.end(),FpgaFrame.commands.begin()+begin,
                FpgaFrame.commands.end());
            c->RowEnds.push_back(c->Commands.size());
        }
        // A sealed entry is independent of transport completion. An early
        // producer stop can never turn a partial polygon into a future hit.
        c->Ready=y+1==c->EndLine;
    }
}

bool SoftRenderer3D::TryFpgaFrame()
{
    fpga3d::Attempt trace(FpgaProfile,CurrentPolygonCount,EffectiveDispCnt);
    using Outcome=fpga3d::Outcome;
    // Feature admission precedes hardware work. A later span/capacity failure
    // closes and drains the producer, then retries the entire frame in software.
    if (!FullFrameCompletion || AlternateRows || Quarter || Tiny)
        return trace.finish(Outcome::NotFullFrame);
    if (!CurrentPolygonCount) return trace.finish(Outcome::Empty);
    if (!fpga3d::available()) return trace.finish(Outcome::Unavailable);
    if (EffectiveDispCnt & (1u<<14)) return trace.finish(Outcome::BitmapClear);
    if (fpga3d::adaptiveAdmission)
    {
        if (FpgaAdmission.defer()) return trace.finish(Outcome::Cooldown);
        if (IsFpgaLightScene(CurrentPolygonCount))
            return trace.finish(Outcome::LightScene);
    }
    FpgaFrame.reset();
    FpgaFrame.stencil=StencilBuffer;
    const bool initialShadowMask=PrevIsShadowMask;
    bool needsToon=false;
    for(int i=0;i<CurrentPolygonCount;i++)
    {
        const auto& rp=PolygonList[i];const auto& ps=rp.PixelState;
        needsToon|=ps.BlendMode==2 && !rp.PolyData->IsShadowMask;
        if(ps.Wireframe) return trace.finish(Outcome::Wireframe);
        if(rp.PolyData->IsShadow && !(ps.BlendMode&1)) return trace.finish(Outcome::ShadowMode);
        if(!rp.PolyData->IsShadowMask && ps.TextureEnabled && !ps.TexturePixels) return trace.finish(Outcome::TextureMissing);
    }
    std::vector<fpga3d::Frame::TextureUse> textureUses;
    if(fpga3d::adaptiveAdmission)
    {
        // Raw texels avoid per-span palette reloads. Prefer them when every
        // unique texture and the full WC command budget already fit. Larger
        // scenes retain lossless indexed admission; no feature is disabled.
        constexpr size_t rawBudget=fpga3d::TextureBytes-fpga3d::MaxCommands*64;
        std::map<const u32*,size_t> unique;
        size_t bytes=0;
        for(int i=0;i<CurrentPolygonCount;i++)
        {
            const auto& rp=PolygonList[i];const auto& ps=rp.PixelState;
            if(rp.PolyData->IsShadowMask || !ps.TextureEnabled)continue;
            const size_t count=size_t(ps.TextureWidth)*ps.TextureHeight;
            auto entry=unique.emplace(ps.TexturePixels,textureUses.size());
            const auto rows=unsigned(std::max(0,std::min(192,rp.PolyData->YBottom)-std::max(0,rp.PolyData->YTop)));
            if(!entry.second){textureUses[entry.first->second].rows+=rows;continue;}
            textureUses.push_back({ps.TexturePixels,count,rows});
            bytes+=count*4;
            if(fpga3d::textureTrafficGuard && bytes>rawBudget)
            {
                // Rechecking an unchanged large texture set every frame costs
                // native rendering time. Retry after the existing bounded delay.
                FpgaAdmission.unsupported();
                return trace.finish(Outcome::TextureTraffic);
            }
        }
        FpgaFrame.allowIndexed=bytes>rawBudget;
    }
    // A native admission decision must not migrate its renderer to CPU1.
    // Restoring an unrestricted affinity mask would still leave the caller
    // there until the scheduler moves it, competing with the native worker.
    const FpgaPreparationAffinity preparationAffinity;
    trace.next(fpga3d::Stage::Textures);
    const bool preparedEligible=fpga3d::preparedTexturesEnabled && fpga3d::adaptiveAdmission;
    const bool preparedHit=preparedEligible && FpgaFrame.preparedTextures.matches(textureUses);
    if(preparedHit){
        FpgaFrame.textures=FpgaFrame.preparedTextures.staged;
        FpgaFrame.textureOffsets=FpgaFrame.preparedTextures.bindings;
        ++FpgaFrame.preparedHits;
    }
    if(preparedEligible && ++FpgaFrame.preparedAttempts%120==0 && fpga3d::profileEnabled)
        std::fprintf(stderr,"FPGA3D_PREPARED attempts=%llu hits=%llu\n",
            (unsigned long long)FpgaFrame.preparedAttempts,(unsigned long long)FpgaFrame.preparedHits);
    // Reject unsupported frames before copying any decoded textures. Shadow
    // polygons commonly sort after opaque geometry, so a single combined pass
    // would copy most of a frame's textures before selecting software fallback.
    if(!preparedHit)for(int i=0;i<CurrentPolygonCount;i++)
    {
        const auto& ps=PolygonList[i].PixelState;
        if(!PolygonList[i].PolyData->IsShadowMask && ps.TextureEnabled &&
           !FpgaFrame.addTexture(ps.TexturePixels,size_t(ps.TextureWidth)*ps.TextureHeight))
        {
            // Texture admission can fail after scanning/copying earlier
            // bindings. Bound retries just like late span/capacity failures.
            if (fpga3d::adaptiveAdmission) FpgaAdmission.unsupported();
            if(fpga3d::profileEnabled)std::fprintf(stderr,"FPGA3D_TEXTURE_REJECT reason=%s width=%u height=%u staged_bytes=%zu bindings=%zu\n",fpga3d::outcomeNames[unsigned(FpgaFrame.failure)],ps.TextureWidth,ps.TextureHeight,FpgaFrame.textures.size()*4,FpgaFrame.textureOffsets.size());
            return trace.finish(FpgaFrame.failure);
        }
    }
    if(!preparedHit && fpga3d::adaptiveAdmission && FpgaFrame.allowIndexed)
        FpgaFrame.preferRawTextures(textureUses);
    if(preparedEligible && !preparedHit)
        FpgaFrame.preparedTextures.remember(textureUses,FpgaFrame.textures,FpgaFrame.textureOffsets);
    trace.next(fpga3d::Stage::Emit);
    if(EffectiveDispCnt & (1u<<7))
    {
        const u32 raw=GPU3D.RenderFogColor;
        auto expand=[](u32 v){v&=31;return (v<<1)|(v!=0);};
        const u32 color=expand(raw)|(expand(raw>>5)<<8)|(expand(raw>>10)<<16)|(((raw>>16)&31)<<24);
        FpgaFrame.append(fpga3d::fog(color,GPU3D.RenderFogOffset,GPU3D.RenderFogShift,GPU3D.RenderFogDensityTable));
    }
    if(EffectiveDispCnt & (1u<<5))
        FpgaFrame.append(fpga3d::edge(DepthBuffer[0],AttrBuffer[0],GPU3D.RenderEdgeTable));
    if(needsToon)for(unsigned half=0;half<2;half++)
        FpgaFrame.append(fpga3d::toon(half,GPU3D.RenderToonTable));
    FpgaFrame.startStream();
    PrepareFpgaSpanCache();
    FpgaEmitting=true;
    for(int y=0;y<192 && FpgaFrame.valid && !FpgaFrame.transportError;y++)
    {
        const auto offset=FirstPixelOffset+y*ScanlineWidth;
        FpgaFrame.append(fpga3d::clear(y,ColorBuffer[offset],DepthBuffer[offset],(AttrBuffer[offset]&16)!=0,
            AttrBuffer[offset],EffectiveDispCnt));
        RenderScanline(y,PolygonList,ActivePolygonMask,PrevIsShadowMask,StencilBuffer,
            0,256,FinalPassMinX,FinalPassMaxX);
        const bool fogClear=(EffectiveDispCnt&(1u<<7)) && (GPU3D.RenderClearAttr1&(1u<<15));
        const unsigned first=fogClear?0:std::min(FinalPassMinX[y],FinalPassMaxX[y]);
        const unsigned end=fogClear?256:FinalPassMaxX[y];
        FpgaFrame.append(fpga3d::flush(y,first,end));
        // Publish two complete rows per prefix to amortize transport barriers.
        // submit() still publishes any final partial group before closing.
        if ((y & 1) != 0) FpgaFrame.publish();
    }
    FpgaEmitting=false;
    trace.next(fpga3d::Stage::Submit);
    if(FpgaFrame.submit(ColorBuffer+FirstPixelOffset,ScanlineWidth))
    {
        if (fpga3d::completedFrames==1 || fpga3d::completedFrames%600==0)
            std::fprintf(stderr,"FPGA3D span_cache_hits=%u polygons=%d reused_commands=%u\n",
                FpgaSpanCacheHits,CurrentPolygonCount,FpgaSpanCacheCommands);
        // Hardware returned a full color plane; the next sparse clear must
        // reset every potentially modified color/depth/attribute location.
        std::fill_n(FinalPassMinX,VisibleScanlines,0);
        std::fill_n(FinalPassMaxX,VisibleScanlines,256);
        CancelRasterIfRequested();
        return trace.finish(Outcome::Accepted,FpgaFrame.commandCount(),FpgaFrame.textures.size()*4,FpgaFrame.uploadUs,FpgaFrame.waitUs,FpgaFrame.copyUs);
    }
    // Command preparation advanced edge state. Reconstruct it before taking
    // the original renderer path. No framebuffer was modified on failure.
    if (fpga3d::adaptiveAdmission && !FpgaFrame.valid && !FpgaFrame.transportError)
        FpgaAdmission.unsupported();
    PrevIsShadowMask=initialShadowMask;
    SetupRenderPolygons(&GPU3D.RenderPolygonRAM[0],GPU3D.RenderNumPolygons);
    return trace.finish(FpgaFrame.transportError?Outcome::Transport:FpgaFrame.failure);
}

void SoftRenderer3D::RenderPolygonsDualCore(
    bool threaded, Polygon** polygons, int npolys, bool overlapClear)
{
    if (overlapClear)
    {
        if (CancelRasterIfRequested()) return;
        // Clear owns framebuffer/damage state; setup owns polygon state and
        // texture bindings. Neither raster worker may start until both finish.
        ParallelJob_.store(ParallelJob::Clear, std::memory_order_relaxed);
        Platform::Semaphore_Post(Sema_ParallelRasterStart);
    }
    const int polygonsPrepared = SetupRenderPolygons(polygons, npolys);
    if (overlapClear)
        // A cancellation still consumes the posted job's completion. This
        // fence also protects the next frame, reset and publication.
        Platform::Semaphore_Wait(Sema_ParallelRasterDone);
    if (TryFpgaFrame()) return;

    const bool antiAliasOnlyFinalPass =
        NDS4MiSTerUseAntiAliasOnlyFinalPass(EffectiveDispCnt);
    if (CancelRasterIfRequested()) return;

    // Keep beta.3's adaptive two-way split for light and transitional work.
    // Enter the four-band scheduler only after two consecutive heavy frames,
    // then retain it across short dips so scenes near the threshold do not
    // alternate scheduling latency every frame. Shadow/stencil safety still
    // selects the adaptive path for the affected frame without resetting this
    // hysteresis. The delayed-worker oracle bypasses the production warm-up.
    // The verified Castlevania profile uses completion-based adaptive splitting.
    // Other games retain the established four-band policy and hysteresis.
    const bool castlevaniaProfile = GPU3D.SpriteRasterSpansEnabled();
    RasterBalance.SetCastlevaniaProfile(castlevaniaProfile);
    const bool queuedRaster = RasterBandQueue && !castlevaniaProfile;
    const bool bandQueueHeavy = queuedRaster &&
        (RasterBandQueueTestDelayWorker ||
         polygonsPrepared > RasterBandPolygonThreshold);
    if (!queuedRaster)
    {
        RasterBandQueueActive = false;
        RasterBandHeavyFrames = 0;
        RasterBandLightFrames = 0;
    }
    else if (RasterBandQueueTestDelayWorker)
    {
        RasterBandQueueActive = true;
        RasterBandHeavyFrames = 0;
        RasterBandLightFrames = 0;
    }
    else if (bandQueueHeavy)
    {
        RasterBandLightFrames = 0;
        if (!RasterBandQueueActive &&
            ++RasterBandHeavyFrames >= RasterBandEnterFrames)
        {
            RasterBandQueueActive = true;
            RasterBandHeavyFrames = 0;
        }
    }
    else
    {
        RasterBandHeavyFrames = 0;
        if (RasterBandQueueActive)
        {
            if (++RasterBandLightFrames >= RasterBandExitFrames)
            {
                RasterBandQueueActive = false;
                RasterBandLightFrames = 0;
            }
        }
        else
        {
            RasterBandLightFrames = 0;
        }
    }
    const bool bandQueueRequested =
        RasterBandQueueActive &&
        polygonsPrepared > ScheduledPolygonThreshold;
    bool frameHasShadow = false;
    if (RasterXPartition || (WeightedRasterBands && bandQueueRequested))
    {
        for (int index = 0; index < polygonsPrepared; ++index)
        {
            const Polygon* polygon = PolygonList[index].PolyData;
            if (polygon->IsShadowMask || polygon->IsShadow)
            {
                frameHasShadow = true;
                break;
            }
        }
    }
    // The existing shadow/stencil gate was proved at fixed 48-line
    // boundaries. Preserve that layout for every shadow-bearing frame.
    // Publish the complete plan before waking either raster worker.
    for (int band = 0; band <= RasterBandCount; ++band)
        RasterBandBoundaries[band] = band * RasterBandLines;
    if (WeightedRasterBands && bandQueueRequested && !frameHasShadow)
    {
        u32 tileWork[RasterWorkTileCount] {};
        if (RasterTileHistoryValid)
            std::copy_n(RasterTileHistory, RasterWorkTileCount, tileWork);
        else
        {
            u32 lineWork[VisibleScanlines] {};
            BuildRasterScanlineWork(polygonsPrepared, lineWork);
            for (int line = 0; line < VisibleScanlines; ++line)
                tileWork[line / RasterWorkTileLines] += lineWork[line];
        }
        NDS4MiSTerBalancedRasterBands(tileWork, RasterBandBoundaries);
        for (s32& boundary : RasterBandBoundaries) boundary *= RasterWorkTileLines;
    }
    const bool bandQueueSafe =
        bandQueueRequested && RasterBandQueueSafe(polygonsPrepared);
    const bool bandQueueFrame = bandQueueSafe;
    CollectRasterTileCosts =
        WeightedRasterBands && bandQueueFrame && !frameHasShadow;
    if (!CollectRasterTileCosts) RasterTileHistoryValid = false;
    else std::fill_n(RasterTileCosts, RasterWorkTileCount, 0);
    // AA edge coverage advances only for depth/alpha-accepted pixels.
    // An X-clipped worker cannot reconstruct the skipped edge prefix from
    // its width, and reading its peer's pixels would violate ownership.
    // Retain the established Y split for these frames; non-AA shadows can
    // still use disjoint X intervals, and safe band-queue frames are intact.
    const bool xPartitionFrame =
        RasterXPartition && frameHasShadow && !bandQueueFrame &&
        !(EffectiveDispCnt & (1u << 4));
    const u32 appliedPrimaryPermille = RasterBalance.PrimaryPermille();
    const s32 SplitLine = bandQueueFrame ? RasterBandBoundaries[1] :
        (xPartitionFrame ? 0 :
         ChooseParallelRasterSplitLine(polygonsPrepared));
    const s32 SplitX = xPartitionFrame ?
        ChooseParallelRasterSplitX(polygonsPrepared) : 128;
    ParallelRasterSplitLine_.store(SplitLine, std::memory_order_relaxed);
    ParallelRasterSplitX_.store(SplitX, std::memory_order_relaxed);
    ParallelRasterBandQueueFrame_.store(
        bandQueueFrame, std::memory_order_relaxed);
    ParallelRasterXPartitionFrame_.store(
        xPartitionFrame, std::memory_order_relaxed);
    PrepareParallelRasterBand(
        polygonsPrepared, SplitLine, xPartitionFrame);
    ParallelRasterNs.store(0, std::memory_order_relaxed);
    ParallelRasterJobs.store(0, std::memory_order_relaxed);
    ParallelRasterAdvancedScanlines.store(0, std::memory_order_relaxed);
    ParallelRasterCompletionNs.store(0, std::memory_order_relaxed);
    ParallelRasterNextBand_.store(
        bandQueueFrame ? 2 : RasterBandCount,
        std::memory_order_relaxed);
    Platform::Semaphore_Reset(Sema_ParallelRasterDone);

    const auto rasterStarted =
        renderer3DProfileStarted(Parent.StageProfileEnabled);
    const u64 balanceStartedNs = AdaptiveRasterSplit && !bandQueueFrame ?
        renderer3DClockNowNs() : 0;
    ParallelJob_.store(ParallelJob::Raster, std::memory_order_relaxed);
    Platform::Semaphore_Post(Sema_ParallelRasterStart);
    RasterBandResult primaryResult;
    if (bandQueueFrame)
    {
        primaryResult = RenderRasterBandJobs(
            0, PolygonList, ActivePolygonMask,
            PrevIsShadowMask, StencilBuffer);
    }
    else if (xPartitionFrame)
    {
        primaryResult.RenderNs = RenderScanlineBand(
            0, VisibleScanlines, PolygonList, ActivePolygonMask,
            PrevIsShadowMask, StencilBuffer, 0, SplitX,
            FinalPassMinX, FinalPassMaxX);
        primaryResult.Jobs = 1;
    }
    else
    {
        primaryResult.RenderNs = RenderScanlineBand(
            0, SplitLine, PolygonList, ActivePolygonMask,
            PrevIsShadowMask, StencilBuffer, 0, 256,
            FinalPassMinX, FinalPassMaxX);
        primaryResult.Jobs = 1;
    }
    const u64 primaryCompletedNs = AdaptiveRasterSplit && !bandQueueFrame ?
        renderer3DClockNowNs() : 0;
    const auto joinStarted =
        renderer3DProfileStarted(Parent.StageProfileEnabled);
    Platform::Semaphore_Wait(Sema_ParallelRasterDone);

    if (RenderFrameCanceled.load(std::memory_order_relaxed))
    {
        RasterTileHistoryValid = false;
        return;
    }
    if (CollectRasterTileCosts)
    {
        for (int tile = 0; tile < RasterWorkTileCount; ++tile)
            RasterTileHistory[tile] = RasterTileHistoryValid ?
                static_cast<u32>((u64(RasterTileHistory[tile]) * 3 + RasterTileCosts[tile]) / 4) :
                RasterTileCosts[tile];
        RasterTileHistoryValid = true;
    }

    if (xPartitionFrame)
    {
        // Both workers execute the same polygon sequence for every row, so
        // the carry flag must be identical. Their parity-stencil buffers hold
        // authoritative disjoint columns; merge CPU1's half only after the
        // raster completion fence.
        assert(PrevIsShadowMask == ParallelPrevIsShadowMask);
        for (s32 parity = 0; parity < 2; ++parity)
            std::copy_n(
                &ParallelStencilBuffer[parity * 256 + SplitX],
                256 - SplitX,
                &StencilBuffer[parity * 256 + SplitX]);
    }

    if (AdaptiveRasterSplit && !bandQueueFrame)
    {
        const u64 secondaryCompletedNs =
            ParallelRasterCompletionNs.load(std::memory_order_acquire);
        if (primaryCompletedNs >= balanceStartedNs &&
            secondaryCompletedNs >= balanceStartedNs)
        {
            RasterBalance.Observe(
                primaryCompletedNs - balanceStartedNs,
                secondaryCompletedNs - balanceStartedNs);
        }
    }

    if (Parent.StageProfileEnabled)
    {
        ++Parent.StageProfile.ThreeDParallelFrames;
        Parent.StageProfile.ThreeDPrimaryRasterNs += primaryResult.RenderNs;
        Parent.StageProfile.ThreeDSecondaryRasterNs +=
            ParallelRasterNs.load(std::memory_order_relaxed);
        Parent.StageProfile.ThreeDParallelJoinNs +=
            renderer3DProfileElapsedNs(joinStarted);
        Parent.StageProfile.ThreeDRasterNs +=
            renderer3DProfileElapsedNs(rasterStarted);
        if (bandQueueFrame)
        {
            auto& profile = Parent.StageProfile;
            ++profile.ThreeDBandQueueFrames;
            profile.ThreeDBandQueueJobs += primaryResult.Jobs +
                ParallelRasterJobs.load(std::memory_order_relaxed);
            profile.ThreeDBandQueueAdvancedScanlines +=
                primaryResult.AdvancedScanlines +
                ParallelRasterAdvancedScanlines.load(
                    std::memory_order_relaxed);
        }
        else if (xPartitionFrame)
        {
            auto& profile = Parent.StageProfile;
            if (profile.ThreeDXPartitionFrames == 0)
            {
                profile.ThreeDXPartitionSplitMin = SplitX;
                profile.ThreeDXPartitionSplitMax = SplitX;
            }
            ++profile.ThreeDXPartitionFrames;
            profile.ThreeDXPartitionSplitTotal += SplitX;
            profile.ThreeDXPartitionSplitMin = std::min<u64>(
                profile.ThreeDXPartitionSplitMin, SplitX);
            profile.ThreeDXPartitionSplitMax = std::max<u64>(
                profile.ThreeDXPartitionSplitMax, SplitX);
        }
        else if (bandQueueRequested)
        {
            ++Parent.StageProfile.ThreeDBandQueueShadowFallbackFrames;
        }
        if (AdaptiveRasterSplit && !bandQueueFrame && !xPartitionFrame)
        {
            auto& profile = Parent.StageProfile;
            if (profile.ThreeDAdaptiveFrames == 0)
            {
                profile.ThreeDAdaptivePrimaryPermilleMin =
                    appliedPrimaryPermille;
                profile.ThreeDAdaptivePrimaryPermilleMax =
                    appliedPrimaryPermille;
                profile.ThreeDAdaptiveSplitLineMin = SplitLine;
                profile.ThreeDAdaptiveSplitLineMax = SplitLine;
            }
            ++profile.ThreeDAdaptiveFrames;
            profile.ThreeDAdaptivePrimaryPermilleTotal +=
                appliedPrimaryPermille;
            profile.ThreeDAdaptivePrimaryPermilleMin = std::min<u64>(
                profile.ThreeDAdaptivePrimaryPermilleMin,
                appliedPrimaryPermille);
            profile.ThreeDAdaptivePrimaryPermilleMax = std::max<u64>(
                profile.ThreeDAdaptivePrimaryPermilleMax,
                appliedPrimaryPermille);
            profile.ThreeDAdaptiveSplitLineTotal += SplitLine;
            profile.ThreeDAdaptiveSplitLineMin = std::min<u64>(
                profile.ThreeDAdaptiveSplitLineMin, SplitLine);
            profile.ThreeDAdaptiveSplitLineMax = std::max<u64>(
                profile.ThreeDAdaptiveSplitLineMax, SplitLine);
        }
    }

    if (Quarter) ExpandQuarterColumns();
    if (AlternateRows) DuplicateAlternateRows(true);

    // Raster is joined before any final processing. Legacy scanline consumers
    // retain canonical row order and their existing completion tokens.
    const auto finalPassStarted =
        renderer3DProfileStarted(Parent.StageProfileEnabled);
    if (ParallelFinalPass && threaded && FullFrameCompletion)
    {
        constexpr s32 split = VisibleScanlines / 2;
        const bool edgeMarking = EffectiveDispCnt & (1 << 5);
        // Edge marking reads neighbor attribute words while writing coverage
        // bits in its own word. Two untouched boundary rows prevent a C++
        // read/write race, even though the polygon-ID bits never change.
        const s32 primaryEnd = edgeMarking ? split - 1 : split;
        ParallelFinalFirstLine = edgeMarking ? split + 1 : split;
        ParallelFinalAntiAliasOnly = antiAliasOnlyFinalPass;
        ParallelJob_.store(ParallelJob::FinalPass, std::memory_order_relaxed);
        Platform::Semaphore_Post(Sema_ParallelRasterStart);
        FinalPassRows(0, primaryEnd, antiAliasOnlyFinalPass);
        Platform::Semaphore_Wait(Sema_ParallelRasterDone);
        if (CancelRasterIfRequested()) return;
        if (edgeMarking)
            FinalPassRows(split - 1, split + 1, antiAliasOnlyFinalPass);
    }
    else if (antiAliasOnlyFinalPass)
    {
        for (s32 y = 0; y < VisibleScanlines; y++)
        {
            if (CancelRasterIfRequested()) return;
            ScanlineFinalPassAntiAlias(y);
            if (threaded && !FullFrameCompletion)
                Platform::Semaphore_Post(Sema_ScanlineCount);
        }
    }
    else
    {
        for (s32 y = 0; y < VisibleScanlines; y++)
        {
            if (CancelRasterIfRequested()) return;
            ScanlineFinalPass(y);
            if (threaded && !FullFrameCompletion)
                Platform::Semaphore_Post(Sema_ScanlineCount);
        }
    }
    if (AlternateRows && !CancelRasterIfRequested()) DuplicateAlternateRows(false);
    if (Parent.StageProfileEnabled)
        Parent.StageProfile.ThreeDFinalPassNs +=
            renderer3DProfileElapsedNs(finalPassStarted);
}

void SoftRenderer3D::FinalPassRows(
    s32 firstLine, s32 endLine, bool antiAliasOnly)
{
    if (antiAliasOnly)
    {
        for (s32 y = firstLine; y < endLine; ++y)
        {
            if (CancelRasterIfRequested()) return;
            ScanlineFinalPassAntiAlias(y);
        }
    }
    else
    {
        for (s32 y = firstLine; y < endLine; ++y)
        {
            if (CancelRasterIfRequested()) return;
            ScanlineFinalPass(y);
        }
    }
}

void SoftRenderer3D::RenderPolygons(bool threaded, Polygon** polygons, int npolys)
{
    SetupRenderPolygons(polygons, npolys);
    if (TryFpgaFrame()) return;

    if (CancelRasterIfRequested()) return;

    if (AlternateRows)
    {
        RenderScanlineBand(0, VisibleScanlines, PolygonList, ActivePolygonMask,
            PrevIsShadowMask, StencilBuffer, 0, 256, FinalPassMinX, FinalPassMaxX);
        if (CancelRasterIfRequested()) return;
        if (Quarter) ExpandQuarterColumns();
        DuplicateAlternateRows(true);
        FinalPassRows(0, VisibleScanlines, false);
        if (!CancelRasterIfRequested()) DuplicateAlternateRows(false);
        return;
    }

    auto stageStarted =
        renderer3DProfileStarted(Parent.StageProfileEnabled);
    RenderScanline(
        0, PolygonList, ActivePolygonMask,
        PrevIsShadowMask, StencilBuffer, 0, 256,
        FinalPassMinX, FinalPassMaxX);
    if (Parent.StageProfileEnabled)
        Parent.StageProfile.ThreeDRasterNs +=
            renderer3DProfileElapsedNs(stageStarted);

    for (s32 y = 1; y < 192; y++)
    {
        if (CancelRasterIfRequested()) return;
        stageStarted = renderer3DProfileStarted(Parent.StageProfileEnabled);
        RenderScanline(
            y, PolygonList, ActivePolygonMask,
            PrevIsShadowMask, StencilBuffer, 0, 256,
            FinalPassMinX, FinalPassMaxX);
        if (Parent.StageProfileEnabled)
            Parent.StageProfile.ThreeDRasterNs +=
                renderer3DProfileElapsedNs(stageStarted);
        stageStarted = renderer3DProfileStarted(Parent.StageProfileEnabled);
        ScanlineFinalPass(y-1);
        if (Parent.StageProfileEnabled)
            Parent.StageProfile.ThreeDFinalPassNs +=
                renderer3DProfileElapsedNs(stageStarted);

        if (threaded && !FullFrameCompletion)
            // Notify the main thread that we're done with a scanline.
            Platform::Semaphore_Post(Sema_ScanlineCount);
    }

    if (CancelRasterIfRequested()) return;
    stageStarted = renderer3DProfileStarted(Parent.StageProfileEnabled);
    ScanlineFinalPass(191);
    if (Parent.StageProfileEnabled)
        Parent.StageProfile.ThreeDFinalPassNs +=
            renderer3DProfileElapsedNs(stageStarted);

    if (threaded && !FullFrameCompletion)
        // If this renderer is threaded, notify the main thread that we're done with the frame.
        Platform::Semaphore_Post(Sema_ScanlineCount);
}

void SoftRenderer3D::FinishRendering()
{
    if (RenderThreadRunning.load(std::memory_order_relaxed) && !GPU3D.AbortFrame &&
        (!FullFrameCompletion || !RenderFrameFinished))
    {
        Platform::Semaphore_Wait(Sema_RenderDone);
        Platform::Semaphore_Reset(Sema_ScanlineCount);
        RenderFrameFinished = true;
    }
}

u32 SoftRenderer3D::CurrentEffectMask() noexcept
{
    if (!GraphicsControl.attached()) return DisabledEffectBits;
    // One atomic snapshot chooses both options for this frame. The host's
    // saved/menu setting takes precedence over the legacy experiment variable.
    const auto settings = GraphicsControl.settings();
    AlternateRowsRequested = settings.halfRows;
    QuarterRequested = settings.quarter;
    TinyRequested = settings.tiny;
    RenderOff = settings.renderOff;
    return (DisabledEffectBits & ~(1u << 4)) |
        (settings.antiAlias ? 0u : (1u << 4));
}

void SoftRenderer3D::Blank3DFrame()
{
    // Ignore even an opaque guest clear color. The diagnostic exposes only 2D.
    // Keep the usual completion fences and leave architectural GX state intact.
    memset(ColorBuffer, 0, sizeof(ColorBuffer));
    SparseClearStateValid = false;
    RasterTileHistoryValid = false;
}

void SoftRenderer3D::RenderFrame()
{
    const bool previousRenderOff = RenderOff;
    const u32 nextDispCnt = GPU3D.RenderDispCnt & ~CurrentEffectMask();
    const bool previousAlternateRows = AlternateRows;
    const bool previousQuarter = Quarter;
    const bool previousTiny = Tiny;
    const bool effectsChanged = nextDispCnt != EffectiveDispCnt;
    EffectiveDispCnt = nextDispCnt;
    UpdateAlternateRows();
    const bool qualityChanged = effectsChanged || previousAlternateRows != AlternateRows ||
        previousRenderOff != RenderOff || previousQuarter != Quarter || previousTiny != Tiny;
    if (previousRenderOff != RenderOff) {
        SparseClearStateValid = false;
        RasterTileHistoryValid = false;
    }
    RenderFrameFinished = false;
    RenderCancelRequested.store(false, std::memory_order_relaxed);
    RenderFrameCanceled.store(false, std::memory_order_relaxed);
    if (RenderOff)
    {
        // Do not consume VRAM dirty state: normal rendering must catch up when
        // re-enabled. Geometry commands/queries and the 2D engines still run.
        const bool recovery = RenderForceNextFrame.exchange(false, std::memory_order_relaxed);
        FrameIdentical = previousRenderOff && !qualityChanged && !recovery;
        if (Parent.StageProfileEnabled) {
            ++Parent.StageProfile.ThreeDFrames;
            Parent.StageProfile.ThreeDIdenticalFrames += FrameIdentical;
        }
        if (RenderThreadRunning.load(std::memory_order_relaxed))
            Platform::Semaphore_Post(Sema_RenderStart);
        else if (!FrameIdentical) Blank3DFrame();
        return;
    }
    const auto coherenceStarted =
        renderer3DProfileStarted(Parent.StageProfileEnabled);
    TextureCache.ContentIdentityEnabled = TextureHistoryEnabled &&
        GPU3D.IntegralTextureSpansEnabled();
    if(TextureCache.ContentIdentityEnabled)++TextureHistoryFrames;
    bool textureChanged;
    if (UseTextureCache)
    {
        u8 clearBitmapDirty = 0;
        textureChanged = TextureCache.Update(clearBitmapDirty, PreserveUploadSnapshot,
            UploadTraceEnabled ? &UploadAtStart : nullptr);
        if (UploadTraceEnabled)
        {
            std::copy_n(GPU.VRAMCNT, 9, UploadBanksAtStart);
            std::copy_n(GPU.VRAMMap_Texture, 4, UploadTextureMapping);
            std::copy_n(GPU.VRAMMap_TexPal, 8, UploadPaletteMapping);
        }
    }
    else
    {
        auto textureDirty =
            GPU.VRAMDirty_Texture.DeriveState(GPU.VRAMMap_Texture, GPU);
        auto texPalDirty =
            GPU.VRAMDirty_TexPal.DeriveState(GPU.VRAMMap_TexPal, GPU);
        textureChanged = GPU.MakeVRAMFlat_TextureCoherent(textureDirty);
        textureChanged |= GPU.MakeVRAMFlat_TexPalCoherent(texPalDirty);
    }

    if (Parent.StageProfileEnabled) RecordPaletteDiagnostic(PaletteAtStart);

    const bool forceRecovery =
        RenderForceNextFrame.exchange(false, std::memory_order_relaxed);
    FrameIdentical =
        !qualityChanged && !forceRecovery && !textureChanged && GPU3D.RenderFrameIdentical;
    if (Parent.StageProfileEnabled)
    {
        ++Parent.StageProfile.ThreeDFrames;
        Parent.StageProfile.ThreeDIdenticalFrames += FrameIdentical;
        Parent.StageProfile.ThreeDRasterRecoveryFrames += forceRecovery;
        Parent.StageProfile.ThreeDCoherenceNs +=
            renderer3DProfileElapsedNs(coherenceStarted);
    }

    if (RenderThreadRunning.load(std::memory_order_relaxed))
    {
        // "Render thread, you're up! Get moving."
        Platform::Semaphore_Post(Sema_RenderStart);
    }
    else if (!FrameIdentical)
    {
        ClearBuffers();
        RenderPolygons(false, &GPU3D.RenderPolygonRAM[0], GPU3D.RenderNumPolygons);
    }
}

void SoftRenderer3D::RestartFrame()
{
    SetupRenderThread();
    const bool previousRenderOff = RenderOff;
    const u32 next = GPU3D.RenderDispCnt & ~CurrentEffectMask();
    if (next != EffectiveDispCnt || previousRenderOff != RenderOff) FrameIdentical = false;
    if (previousRenderOff != RenderOff) {
        SparseClearStateValid = false;
        RasterTileHistoryValid = false;
    }
    EffectiveDispCnt = next;
    UpdateAlternateRows();
    EnableRenderThread();
}

void SoftRenderer3D::RenderThreadFunc()
{
    for (;;)
    {
        // Wait for a notice from the main thread to start rendering (or to stop entirely).
        Platform::Semaphore_Wait(Sema_RenderStart);
        if (!RenderThreadRunning) return;

        // Protect the GPU state from the main thread.
        // Some melonDS frontends (though not ours)
        // will repeatedly save or load states;
        // if they do so while the render thread is busy here,
        // the ensuing race conditions may cause a crash
        // (since some of the GPU state includes pointers).
        RenderThreadRendering = true;
        if (FrameIdentical)
        { // If no rendering is needed, just say we're done.
            if (!FullFrameCompletion)
                Platform::Semaphore_Post(Sema_ScanlineCount, 192);
        }
        else if (RenderOff)
        {
            Blank3DFrame();
            if (!FullFrameCompletion)
                Platform::Semaphore_Post(Sema_ScanlineCount, 192);
        }
        else if (ParallelClear && DualCoreRaster && FullFrameCompletion)
        {
            RenderPolygonsDualCore(
                true, &GPU3D.RenderPolygonRAM[0], GPU3D.RenderNumPolygons, true);
        }
        else
        {
            const auto clearStarted =
                renderer3DProfileStarted(Parent.StageProfileEnabled);
            const bool canceledBeforeClear = CancelRasterIfRequested();
            if (!canceledBeforeClear) ClearBuffers();
            if (Parent.StageProfileEnabled)
                Parent.StageProfile.ThreeDClearNs +=
                    renderer3DProfileElapsedNs(clearStarted);
            if (!canceledBeforeClear && !CancelRasterIfRequested())
            {
                if (DualCoreRaster)
                    RenderPolygonsDualCore(
                        true, &GPU3D.RenderPolygonRAM[0],
                        GPU3D.RenderNumPolygons);
                else
                    RenderPolygons(
                        true, &GPU3D.RenderPolygonRAM[0],
                        GPU3D.RenderNumPolygons);
            }
        }

        if (Parent.StageProfileEnabled &&
            RenderFrameCanceled.load(std::memory_order_relaxed))
            ++Parent.StageProfile.ThreeDRasterCanceledFrames;

        // Clear the in-flight state before publishing completion. The main
        // thread may consume Sema_RenderDone and immediately prepare the next
        // frame; publishing first lets SetupRenderThread observe a stale true
        // value and wait a second time on the already-consumed semaphore.
        RenderThreadRendering = false;
        Platform::Semaphore_Post(Sema_RenderDone);
    }
}

void SoftRenderer3D::ParallelRasterThreadFunc()
{
    bindParallelRasterToSecondCpu();
    for (;;)
    {
        Platform::Semaphore_Wait(Sema_ParallelRasterStart);
        if (!ParallelRasterThreadRunning.load(std::memory_order_relaxed))
            return;

        const auto job = ParallelJob_.load(std::memory_order_relaxed);
        if (job == ParallelJob::Clear)
        {
            const auto clearStarted =
                renderer3DProfileStarted(Parent.StageProfileEnabled);
            if (!CancelRasterIfRequested()) ClearBuffers();
            if (Parent.StageProfileEnabled)
                Parent.StageProfile.ThreeDClearNs +=
                    renderer3DProfileElapsedNs(clearStarted);
            Platform::Semaphore_Post(Sema_ParallelRasterDone);
            continue;
        }
        if (job == ParallelJob::FinalPass)
        {
            FinalPassRows(ParallelFinalFirstLine, VisibleScanlines,
                ParallelFinalAntiAliasOnly);
            Platform::Semaphore_Post(Sema_ParallelRasterDone);
            continue;
        }

        const s32 SplitLine =
            ParallelRasterSplitLine_.load(std::memory_order_relaxed);
        const s32 SplitX =
            ParallelRasterSplitX_.load(std::memory_order_relaxed);
        RasterBandResult result;
        const bool bandQueueFrame = ParallelRasterBandQueueFrame_.load(
            std::memory_order_relaxed);
        const bool xPartitionFrame =
            ParallelRasterXPartitionFrame_.load(std::memory_order_relaxed);
        if (RasterBandQueueTestDelayWorker &&
            (bandQueueFrame || xPartitionFrame))
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        if (bandQueueFrame)
        {
            // Self-test-only scheduling perturbation. It proves that a worker
            // can advance its private edge state over a row range rendered by
            // its peer; production never sets this environment switch.
            result = RenderRasterBandJobs(
                1, ParallelPolygonList.get(), ParallelActivePolygonMask,
                ParallelPrevIsShadowMask, ParallelStencilBuffer);
        }
        else if (xPartitionFrame)
        {
            result.RenderNs = RenderScanlineBand(
                0, VisibleScanlines, ParallelPolygonList.get(),
                ParallelActivePolygonMask, ParallelPrevIsShadowMask,
                ParallelStencilBuffer, SplitX, 256,
                ParallelFinalPassMinX, ParallelFinalPassMaxX);
            result.Jobs = 1;
        }
        else
        {
            result.RenderNs = RenderScanlineBand(
                SplitLine, VisibleScanlines, ParallelPolygonList.get(),
                ParallelActivePolygonMask, ParallelPrevIsShadowMask,
                ParallelStencilBuffer, 0, 256,
                FinalPassMinX, FinalPassMaxX);
            result.Jobs = 1;
        }
        if (AdaptiveRasterSplit && !bandQueueFrame)
        {
            ParallelRasterCompletionNs.store(
                renderer3DClockNowNs(), std::memory_order_release);
        }
        ParallelRasterNs.store(result.RenderNs, std::memory_order_relaxed);
        ParallelRasterJobs.store(result.Jobs, std::memory_order_relaxed);
        ParallelRasterAdvancedScanlines.store(
            result.AdvancedScanlines, std::memory_order_relaxed);
        Platform::Semaphore_Post(Sema_ParallelRasterDone);
    }
}

u32* SoftRenderer3D::GetLine(int line)
{
    if (GPU3D.AbortFrame)
    {
        // TODO this isn't accurate
        memset(ScrolledLine, 0, sizeof(ScrolledLine));
        return ScrolledLine;
    }

    if (RenderThreadRunning.load(std::memory_order_relaxed) &&
        !RenderFrameFinished)
    {
        if (FullFrameCompletion)
        {
            // Engine-B display capture can consume 3D before the service's
            // usual frame-publication fence. This mode never posts scanline
            // tokens: join its complete-frame fence once, then let subsequent
            // capture rows and FinishRendering reuse that completed frame.
            FinishRendering();
        }
        else if (line < 192)
            // We need a scanline, so let's wait for the render thread to finish it.
            // (both threads process scanlines from top-to-bottom,
            // so we don't need to wait for a specific row)
            Platform::Semaphore_Wait(Sema_ScanlineCount);
    }

    u32* rawline = &ColorBuffer[(line * ScanlineWidth) + FirstPixelOffset];
    u16 xpos = GPU3D.RenderXPos;
    if (xpos == 0)
        return rawline;

    // apply X scroll

    if (xpos & 0x100)
    {
        int i = 0, j = xpos;
        for (; j < 512; i++, j++)
            ScrolledLine[i] = 0;
        for (j = 0; i < 256; i++, j++)
            ScrolledLine[i] = rawline[j];
    }
    else
    {
        int i = 0, j = xpos;
        for (; j < 256; i++, j++)
            ScrolledLine[i] = rawline[j];
        for (; i < 256; i++)
            ScrolledLine[i] = 0;
    }

    return ScrolledLine;
}

}
