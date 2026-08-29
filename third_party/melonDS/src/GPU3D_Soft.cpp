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

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <stdio.h>
#include <string.h>
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
        Platform::Semaphore_Post(Sema_RenderStart);
    }
}

SoftRenderer3D::SoftRenderer3D(melonDS::GPU3D& gpu3D, SoftRenderer& parent) noexcept
    : Renderer3D(gpu3D), Parent(parent),
      TextureCache(gpu3D.GPU, SoftTexcacheLoader())
{
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
    if (DualCoreRaster)
        ParallelPolygonList = std::make_unique<RendererPolygon[]>(
            MaxRendererPolygons);
    UseTextureCache = std::getenv("NDS4MISTER_DISABLE_SOFT_TEXTURE_CACHE") == nullptr;
}

SoftRenderer3D::~SoftRenderer3D()
{
    StopRenderThread();

    TextureCache.Reset();

    Platform::Semaphore_Free(Sema_RenderStart);
    Platform::Semaphore_Free(Sema_RenderDone);
    Platform::Semaphore_Free(Sema_ScanlineCount);
    Platform::Semaphore_Free(Sema_ParallelRasterStart);
    Platform::Semaphore_Free(Sema_ParallelRasterDone);
}

void SoftRenderer3D::Reset()
{
    TextureCache.Reset();

    memset(ColorBuffer, 0, BufferSize * 2 * 4);
    memset(DepthBuffer, 0, BufferSize * 2 * 4);
    memset(AttrBuffer, 0, BufferSize * 2 * 4);

    PrevIsShadowMask = false;

    SetupRenderThread();
    EnableRenderThread();
}

u32* SoftTexcacheLoader::GenerateTexture(
    u32 width, u32 height, u32 layers)
{
    return new u32[static_cast<size_t>(width) * height * layers];
}

void SoftTexcacheLoader::UploadTexture(
    u32* handle, u32 width, u32 height, u32 layer, void* data)
{
    const size_t pixels = static_cast<size_t>(width) * height;
    memcpy(handle + pixels * layer, data, pixels * sizeof(u32));
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

    if (GPU3D.RenderDispCnt & (1<<3))
    {
        u32 dstR = dstcolor & 0x3F;
        u32 dstG = (dstcolor >> 8) & 0x3F;
        u32 dstB = (dstcolor >> 16) & 0x3F;

        alpha++;
        srcR = ((srcR * alpha) + (dstR * (32-alpha))) >> 5;
        srcG = ((srcG * alpha) + (dstG * (32-alpha))) >> 5;
        srcB = ((srcB * alpha) + (dstB * (32-alpha))) >> 5;
        alpha--;
    }

    if (alpha > dstalpha)
        dstalpha = alpha;

    return srcR | (srcG << 8) | (srcB << 16) | (dstalpha << 24);
}

u32 SoftRenderer3D::RenderPixel(
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

            s >>= 4;
            t >>= 4;

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

            const u32 texel = state.TexturePixels[(t * width) + s];
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

u32 SoftRenderer3D::RenderPixelCachedModulate(
    const RendererPolygon::PixelShaderState& state,
    u32 vertexColor, s16 s, s16 t)
{
    const s32 width = state.TextureWidth;
    const s32 height = state.TextureHeight;

    s >>= 4;
    t >>= 4;

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

    const u32 texel = state.TexturePixels[(t * width) + s];
    const u32 tr = texel & 0x3F;
    const u32 tg = (texel >> 8) & 0x3F;
    const u32 tb = (texel >> 16) & 0x3F;
    const u32 talpha = texel >> 24;
    const u32 vr = vertexColor & 0x3F;
    const u32 vg = (vertexColor >> 8) & 0x3F;
    const u32 vb = (vertexColor >> 16) & 0x3F;

    const u32 r = ((tr+1) * (vr+1) - 1) >> 6;
    const u32 g = ((tg+1) * (vg+1) - 1) >> 6;
    const u32 b = ((tb+1) * (vb+1) - 1) >> 6;
    const u32 a = ((talpha+1) * (state.PolyAlpha+1) - 1) >> 5;
    return r | (g << 8) | (b << 16) | (a << 24);
}

void SoftRenderer3D::PlotTranslucentPixel(u32 pixeladdr, u32 color, u32 z, u32 polyattr, u32 shadow)
{
    u32 dstattr = AttrBuffer[pixeladdr];
    u32 attr = (polyattr & 0xE0F0) | ((polyattr >> 8) & 0xFF0000) | (1<<22) | (dstattr & 0xFF001F0F);

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

    rp->XL = rp->SlopeL.Setup(polygon->Vertices[rp->CurVL]->FinalPosition[0], polygon->Vertices[rp->NextVL]->FinalPosition[0],
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

    rp->XR = rp->SlopeR.Setup(polygon->Vertices[rp->CurVR]->FinalPosition[0], polygon->Vertices[rp->NextVR]->FinalPosition[0],
                              polygon->Vertices[rp->CurVR]->FinalPosition[1], polygon->Vertices[rp->NextVR]->FinalPosition[1],
                              polygon->FinalW[rp->CurVR], polygon->FinalW[rp->NextVR], y, polygon->WBuffer);
}

void SoftRenderer3D::SetupPolygon(SoftRenderer3D::RendererPolygon* rp, Polygon* polygon)
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
    pixelState.TextureFormat = static_cast<u8>(textureFormat);
    pixelState.TextureWrapFlags =
        static_cast<u8>((polygon->TexParam >> 16) & 0xF);
    pixelState.TexturePaletteBase = polygon->TexPalette <<
        (textureFormat == 2 ? 3 : 4);
    pixelState.BlendMode = static_cast<u8>((polygon->Attr >> 4) & 0x3);
    pixelState.PolyAlpha = static_cast<u8>((polygon->Attr >> 16) & 0x1F);
    pixelState.Alpha0 = (polygon->TexParam & (1<<29)) ? 0 : 31;
    pixelState.TextureEnabled =
        (GPU3D.RenderDispCnt & (1<<0)) && textureFormat != 0;
    pixelState.TexturePixels = nullptr;
    if (pixelState.TextureEnabled && UseTextureCache)
    {
        u32* textureArray;
        u32 textureLayer;
        u32* textureHelper;
        TextureCache.GetTexture(
            polygon->TexParam, polygon->TexPalette,
            textureArray, textureLayer, textureHelper);
        pixelState.TexturePixels = textureArray +
            static_cast<size_t>(textureLayer) *
                pixelState.TextureWidth * pixelState.TextureHeight;
    }
    pixelState.Highlight =
        pixelState.BlendMode == 2 && (GPU3D.RenderDispCnt & (1<<1));
    pixelState.Wireframe = pixelState.PolyAlpha == 0;
    pixelState.CachedModulate = pixelState.TexturePixels &&
        pixelState.BlendMode == 0 && !pixelState.Highlight &&
        !pixelState.Wireframe;

    rp->PolyAttr = polygon->Attr & 0x3F008000;
    if (!polygon->FacingView) rp->PolyAttr |= (1<<4);
    if (polygon->Attr & (1<<14))
        rp->DepthTest = polygon->WBuffer ? DepthTest_Equal_W : DepthTest_Equal_Z;
    else if (polygon->FacingView)
        rp->DepthTest = DepthTest_LessThan_FrontFacing;
    else
        rp->DepthTest = DepthTest_LessThan;

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
        if (polygon->Vertices[i]->FinalPosition[0] < polygon->Vertices[vtop]->FinalPosition[0]) vtop = i;
        if (polygon->Vertices[i]->FinalPosition[0] > polygon->Vertices[vbot]->FinalPosition[0]) vbot = i;

        i = nverts - 1;
        if (polygon->Vertices[i]->FinalPosition[0] < polygon->Vertices[vtop]->FinalPosition[0]) vtop = i;
        if (polygon->Vertices[i]->FinalPosition[0] > polygon->Vertices[vbot]->FinalPosition[0]) vbot = i;

        rp->CurVL = vtop; rp->NextVL = vtop;
        rp->CurVR = vbot; rp->NextVR = vbot;

        rp->XL = rp->SlopeL.SetupDummy(polygon->Vertices[rp->CurVL]->FinalPosition[0], polygon->WBuffer);
        rp->XR = rp->SlopeR.SetupDummy(polygon->Vertices[rp->CurVR]->FinalPosition[0], polygon->WBuffer);
    }
    else
    {
        SetupPolygonLeftEdge(rp, ytop);
        SetupPolygonRightEdge(rp, ytop);
    }
}

void SoftRenderer3D::RenderShadowMaskScanline(
    RendererPolygon* rp, s32 y, bool& prevIsShadowMask,
    u8* stencilBuffer)
{
    Polygon* polygon = rp->PolyData;

    const u32 polyattr = rp->PolyAttr;
    u32 polyalpha = rp->PixelState.PolyAlpha;
    const bool wireframe = rp->PixelState.Wireframe;
    const auto fnDepthTest = rp->DepthTest;

    if (!prevIsShadowMask)
        memset(&stencilBuffer[256 * (y&0x1)], 0, 256);

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
        if ((GPU3D.RenderDispCnt & ((1<<4)|(1<<5))) || ((polyalpha < 31) && (GPU3D.RenderDispCnt & (1<<3))) || wireframe)
        {
            l_filledge = true;
            r_filledge = true;
        }
        else
        {
            l_filledge = (rp->SlopeR.Negative || !rp->SlopeR.XMajor)
                || (y == polygon->YBottom-1) && rp->SlopeR.XMajor && (vlnext->FinalPosition[0] != vrnext->FinalPosition[0]);
            r_filledge = (!rp->SlopeL.Negative && rp->SlopeL.XMajor)
                || (!(rp->SlopeL.Negative && rp->SlopeL.XMajor) && rp->SlopeR.Increment==0)
                || (y == polygon->YBottom-1) && rp->SlopeL.XMajor && (vlnext->FinalPosition[0] != vrnext->FinalPosition[0]);
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
        if ((GPU3D.RenderDispCnt & ((1<<4)|(1<<5))) || ((polyalpha < 31) && (GPU3D.RenderDispCnt & (1<<3))) || wireframe)
        {
            l_filledge = true;
            r_filledge = true;
        }
        else
        {
            l_filledge = ((rp->SlopeL.Negative || !rp->SlopeL.XMajor)
                || (y == polygon->YBottom-1) && rp->SlopeL.XMajor && (vlnext->FinalPosition[0] != vrnext->FinalPosition[0]))
                || (rp->SlopeL.Increment == rp->SlopeR.Increment) && (xstart+l_edgelen == xend+1);
            r_filledge = (!rp->SlopeR.Negative && rp->SlopeR.XMajor) || (rp->SlopeR.Increment==0)
                || (y == polygon->YBottom-1) && rp->SlopeR.XMajor && (vlnext->FinalPosition[0] != vrnext->FinalPosition[0]);
        }
    }

    // color/texcoord attributes aren't needed for shadow masks
    // all the pixels are guaranteed to have the same alpha
    // even if a texture is used (decal blending is used for shadows)
    // similarly, we can perform alpha test early (checkme)

    if (wireframe) polyalpha = 31;
    if (polyalpha <= GPU3D.RenderAlphaRef) return;

    // in wireframe mode, there are special rules for equal Z (TODO)

    int yedge = 0;
    if (y == polygon->YTop)           yedge = 0x4;
    else if (y == polygon->YBottom-1) yedge = 0x8;
    int edge;

    s32 x = xstart;
    Interpolator<0> interpX(xstart, xend+1, wl, wr, polygon->WBuffer);

    if (x < 0) x = 0;
    s32 xlimit;

    // for shadow masks: set stencil bits where the depth test fails.
    // draw nothing.

    // part 1: left edge
    edge = yedge | 0x1;
    xlimit = xstart+l_edgelen;
    if (xlimit > xend+1) xlimit = xend+1;
    if (xlimit > 256) xlimit = 256;

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
    if (xlimit > 256) xlimit = 256;
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
    if (xlimit > 256) xlimit = 256;

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

void SoftRenderer3D::RenderPolygonScanline(
    RendererPolygon* rp, s32 y, bool& prevIsShadowMask,
    u8* stencilBuffer)
{
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
        if ((GPU3D.RenderDispCnt & ((1<<4)|(1<<5))) || ((polyalpha < 31) && (GPU3D.RenderDispCnt & (1<<3))) || wireframe)
        {
            l_filledge = true;
            r_filledge = true;
        }
        else
        {
            l_filledge = (rp->SlopeR.Negative || !rp->SlopeR.XMajor)
                || (y == polygon->YBottom-1) && rp->SlopeR.XMajor && (vlnext->FinalPosition[0] != vrnext->FinalPosition[0]);
            r_filledge = (!rp->SlopeL.Negative && rp->SlopeL.XMajor)
                || (!(rp->SlopeL.Negative && rp->SlopeL.XMajor) && rp->SlopeR.Increment==0)
                || (y == polygon->YBottom-1) && rp->SlopeL.XMajor && (vlnext->FinalPosition[0] != vrnext->FinalPosition[0]);
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
        if ((GPU3D.RenderDispCnt & ((1<<4)|(1<<5))) || ((polyalpha < 31) && (GPU3D.RenderDispCnt & (1<<3))) || wireframe)
        {
            l_filledge = true;
            r_filledge = true;
        }
        else
        {
            l_filledge = ((rp->SlopeL.Negative || !rp->SlopeL.XMajor)
                || (y == polygon->YBottom-1) && rp->SlopeL.XMajor && (vlnext->FinalPosition[0] != vrnext->FinalPosition[0]))
                || (rp->SlopeL.Increment == rp->SlopeR.Increment) && (xstart+l_edgelen == xend+1);
            r_filledge = (!rp->SlopeR.Negative && rp->SlopeR.XMajor) || (rp->SlopeR.Increment==0)
                || (y == polygon->YBottom-1) && rp->SlopeR.XMajor && (vlnext->FinalPosition[0] != vrnext->FinalPosition[0]);
        }
    }

    // interpolate attributes along Y

    s32 rl = interp_start->Interpolate(vlcur->FinalColor[0], vlnext->FinalColor[0]);
    s32 gl = interp_start->Interpolate(vlcur->FinalColor[1], vlnext->FinalColor[1]);
    s32 bl = interp_start->Interpolate(vlcur->FinalColor[2], vlnext->FinalColor[2]);

    s32 sl = interp_start->Interpolate(vlcur->TexCoords[0], vlnext->TexCoords[0]);
    s32 tl = interp_start->Interpolate(vlcur->TexCoords[1], vlnext->TexCoords[1]);

    s32 rr = interp_end->Interpolate(vrcur->FinalColor[0], vrnext->FinalColor[0]);
    s32 gr = interp_end->Interpolate(vrcur->FinalColor[1], vrnext->FinalColor[1]);
    s32 br = interp_end->Interpolate(vrcur->FinalColor[2], vrnext->FinalColor[2]);

    s32 sr = interp_end->Interpolate(vrcur->TexCoords[0], vrnext->TexCoords[0]);
    s32 tr = interp_end->Interpolate(vrcur->TexCoords[1], vrnext->TexCoords[1]);

    // in wireframe mode, there are special rules for equal Z (TODO)

    int yedge = 0;
    if (y == polygon->YTop)           yedge = 0x4;
    else if (y == polygon->YBottom-1) yedge = 0x8;
    int edge;

    s32 x = xstart;
    Interpolator<0> interpX(xstart, xend+1, wl, wr, polygon->WBuffer);
    Interpolator<0>::SpanInterpolator spanAttributes(
        interpX, rl, rr, gl, gr, bl, br, sl, sr, tl, tr);
    s32 spanValues[5];
    const auto renderSpanPixel = [this, rp](
        u32 vr, u32 vg, u32 vb, s16 s, s16 t) -> u32
    {
        if (rp->PixelState.CachedModulate)
        {
            const u32 vertexColor = (vr >> 3) |
                ((vg >> 3) << 8) | ((vb >> 3) << 16);
            return RenderPixelCachedModulate(
                rp->PixelState, vertexColor, s, t);
        }
        return RenderPixel(
            rp->PixelState, vr >> 3, vg >> 3, vb >> 3, s, t);
    };

    const s32 visibleStart = std::max<s32>(xstart, 0);
    const s32 visibleEnd = std::min<s32>(xend + 1, 256);
    if (visibleStart < visibleEnd)
    {
        FinalPassMinX[y] = std::min<u16>(
            FinalPassMinX[y], static_cast<u16>(visibleStart));
        FinalPassMaxX[y] = std::max<u16>(
            FinalPassMaxX[y], static_cast<u16>(visibleEnd));
    }

    if (x < 0) x = 0;
    s32 xlimit;

    s32 xcov = 0;

    // part 1: left edge
    edge = yedge | 0x1;
    xlimit = xstart+l_edgelen;
    if (xlimit > xend+1) xlimit = xend+1;
    if (xlimit > 256) xlimit = 256;
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

        interpX.SetX(x);

        s32 z = interpX.InterpolateZ(zl, zr);

        // if depth test against the topmost pixel fails, test
        // against the pixel underneath
        if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
        {
            if (!(dstattr & 0xF) || pixeladdr >= BufferSize) continue;

            pixeladdr += BufferSize;
            dstattr = AttrBuffer[pixeladdr];
            if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
                continue;
        }

        spanAttributes.Interpolate(spanValues);
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

            if (GPU3D.RenderDispCnt & (1<<4))
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
                if (pixeladdr < BufferSize)
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
            if ((dstattr & 0xF) && (pixeladdr < BufferSize))
                PlotTranslucentPixel(pixeladdr+BufferSize, color, z, polyattr, polygon->IsShadow);
        }
    }

    // part 2: polygon inside
    edge = yedge;
    xlimit = xend-r_edgelen+1;
    if (xlimit > xend+1) xlimit = xend+1;
    if (xlimit > 256) xlimit = 256;

    if (wireframe && !edge) x = std::max(x, xlimit);
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

        interpX.SetX(x);

        s32 z = interpX.InterpolateZ(zl, zr);

        // if depth test against the topmost pixel fails, test
        // against the pixel underneath
        if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
        {
            if (!(dstattr & 0xF) || pixeladdr >= BufferSize) continue;

            pixeladdr += BufferSize;
            dstattr = AttrBuffer[pixeladdr];
            if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
                continue;
        }

        spanAttributes.Interpolate(spanValues);
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

            if ((GPU3D.RenderDispCnt & (1<<4)) && (attr & 0xF))
            {
                // anti-aliasing: all edges are rendered

                // set coverage to avoid black lines from anti-aliasing
                attr |= (0x1F << 8);

                // push old pixel down if needed
                if (pixeladdr < BufferSize)
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
            if ((dstattr & 0xF) && (pixeladdr < BufferSize))
                PlotTranslucentPixel(pixeladdr+BufferSize, color, z, polyattr, polygon->IsShadow);
        }
    }

    // part 3: right edge
    edge = yedge | 0x2;
    xlimit = xend+1;
    if (xlimit > 256) xlimit = 256;
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

        interpX.SetX(x);

        s32 z = interpX.InterpolateZ(zl, zr);

        // if depth test against the topmost pixel fails, test
        // against the pixel underneath
        if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
        {
            if (!(dstattr & 0xF) || pixeladdr >= BufferSize) continue;

            pixeladdr += BufferSize;
            dstattr = AttrBuffer[pixeladdr];
            if (!RunDepthTest(fnDepthTest, DepthBuffer[pixeladdr], z, dstattr))
                continue;
        }

        spanAttributes.Interpolate(spanValues);
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

            if (GPU3D.RenderDispCnt & (1<<4))
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
                if (pixeladdr < BufferSize)
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
            if ((dstattr & 0xF) && (pixeladdr < BufferSize))
                PlotTranslucentPixel(pixeladdr+BufferSize, color, z, polyattr, polygon->IsShadow);
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

void SoftRenderer3D::RenderScanline(
    s32 y, RendererPolygon* polygonList, u32* activePolygonMask,
    bool& prevIsShadowMask, u8* stencilBuffer)
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
                if (polygon->IsShadowMask)
                    RenderShadowMaskScanline(
                        rp, y, prevIsShadowMask, stencilBuffer);
                else
                    RenderPolygonScanline(
                        rp, y, prevIsShadowMask, stencilBuffer);
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

            if (polygon->IsShadowMask)
                RenderShadowMaskScanline(
                    rp, y, prevIsShadowMask, stencilBuffer);
            else
                RenderPolygonScanline(
                    rp, y, prevIsShadowMask, stencilBuffer);

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

void SoftRenderer3D::ScanlineFinalPass(s32 y)
{
    // to consider:
    // clearing all polygon fog flags if the master flag isn't set?
    // merging all final pass loops into one?

    int xStart = FinalPassMinX[y];
    int xEnd = FinalPassMaxX[y];
    if ((GPU3D.RenderDispCnt & (1<<7)) &&
        ((GPU3D.RenderDispCnt & (1<<14)) ||
         (GPU3D.RenderClearAttr1 & (1<<15))))
    {
        xStart = 0;
        xEnd = 256;
    }

    if (xStart >= xEnd) return;

    if (GPU3D.RenderDispCnt & (1<<5))
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

    if (GPU3D.RenderDispCnt & (1<<7))
    {
        // fog

        // hardware testing shows that the fog step is 0x80000>>SHIFT
        // basically, the depth values used in GBAtek need to be
        // multiplied by 0x200 to match Z-buffer values

        // fog is applied to the topmost two pixels, which is required for
        // proper antialiasing

        // TODO: check the 'fog alpha glitch with small Z' GBAtek talks about

        bool fogcolor = !(GPU3D.RenderDispCnt & (1<<6));

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

            if (!(attr & 0xF)) continue;
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

    if (GPU3D.RenderDispCnt & (1<<4))
    {
        // anti-aliasing

        // edges were flagged and their coverages calculated during rendering
        // this is where such edge pixels are blended with the pixels underneath

        for (int x = xStart; x < xEnd; x++)
        {
            u32 pixeladdr = FirstPixelOffset + (y*ScanlineWidth) + x;

            u32 attr = AttrBuffer[pixeladdr];
            if (!(attr & 0xF)) continue;

            u32 coverage = (attr >> 8) & 0x1F;
            if (coverage == 0x1F) continue;

            if (coverage == 0)
            {
                ColorBuffer[pixeladdr] = ColorBuffer[pixeladdr+BufferSize];
                continue;
            }

            u32 topcolor = ColorBuffer[pixeladdr];
            u32 topR = topcolor & 0x3F;
            u32 topG = (topcolor >> 8) & 0x3F;
            u32 topB = (topcolor >> 16) & 0x3F;
            u32 topA = (topcolor >> 24) & 0x1F;

            u32 botcolor = ColorBuffer[pixeladdr+BufferSize];
            u32 botR = botcolor & 0x3F;
            u32 botG = (botcolor >> 8) & 0x3F;
            u32 botB = (botcolor >> 16) & 0x3F;
            u32 botA = (botcolor >> 24) & 0x1F;

            coverage++;

            // only blend color if the bottom pixel isn't fully transparent
            if (botA > 0)
            {
                topR = ((topR * coverage) + (botR * (32-coverage))) >> 5;
                topG = ((topG * coverage) + (botG * (32-coverage))) >> 5;
                topB = ((topB * coverage) + (botB * (32-coverage))) >> 5;
            }

            // alpha is always blended
            topA = ((topA * coverage) + (botA * (32-coverage))) >> 5;

            ColorBuffer[pixeladdr] = topR | (topG << 8) | (topB << 16) | (topA << 24);
        }
    }
}

void SoftRenderer3D::ClearBuffers()
{
    u32 clearz = ((GPU3D.RenderClearAttr2 & 0x7FFF) * 0x200) + 0x1FF;
    u32 polyid = GPU3D.RenderClearAttr1 & 0x3F000000; // this sets the opaque polygonID

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

    if (GPU3D.RenderDispCnt & (1<<14))
    {
        u8 xoff = (GPU3D.RenderClearAttr2 >> 16) & 0xFF;
        u8 yoff = (GPU3D.RenderClearAttr2 >> 24) & 0xFF;

        for (int y = 0; y < ScanlineWidth*192; y+=ScanlineWidth)
        {
            for (int x = 0; x < 256; x++)
            {
                u16 val2 = GPU.ReadVRAMFlat_Texture<u16>(0x40000 + (yoff << 9) + (xoff << 1));
                u16 val3 = GPU.ReadVRAMFlat_Texture<u16>(0x60000 + (yoff << 9) + (xoff << 1));

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
    }
}

int SoftRenderer3D::SetupRenderPolygons(Polygon** polygons, int npolys)
{
    const auto setupStarted =
        renderer3DProfileStarted(Parent.StageProfileEnabled);
    int j = 0;
    for (int i = 0; i < npolys; i++)
    {
        if (polygons[i]->Degenerate) continue;
        SetupPolygon(&PolygonList[j++], polygons[i]);
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
    u32* activePolygonMask, bool& prevIsShadowMask, u8* stencilBuffer)
{
    const auto started = renderer3DProfileStarted(Parent.StageProfileEnabled);
    for (s32 y = firstLine; y < endLine; y++)
        RenderScanline(
            y, polygonList, activePolygonMask,
            prevIsShadowMask, stencilBuffer);
    return Parent.StageProfileEnabled ? renderer3DProfileElapsedNs(started) : 0;
}

void SoftRenderer3D::PrepareParallelRasterBand(int npolys, s32 firstLine)
{
    std::copy_n(PolygonList, npolys, ParallelPolygonList.get());
    if (UseScanlinePolygonLists)
        std::fill_n(ParallelActivePolygonMask, ActivePolygonMaskWords, 0);
    memset(ParallelStencilBuffer, 0, sizeof(ParallelStencilBuffer));
    ParallelPrevIsShadowMask = false;

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

s32 SoftRenderer3D::ChooseParallelRasterSplitLine(int npolys) const
{
    // CPU1 also owns command replay, so give CPU0 roughly 60% of projected
    // polygon area. A fixed split left CPU0 nearly idle whenever NSMB placed
    // most geometry low on screen. This bounded O(vertices+P+H) estimate uses
    // the frame's already-prepared polygons and adds no work to pixel loops.
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
            const s32 x = polygon->Vertices[vertex]->FinalPosition[0];
            left = std::min(left, x);
            right = std::max(right, x);
        }
        left = std::clamp(left, 0, 255);
        right = std::clamp(right, 0, 255);
        const s32 projectedWidth = std::max(1, right - left + 1);
        scanlineDelta[first] += projectedWidth;
        scanlineDelta[end] -= projectedWidth;
    }

    u32 lineWork[VisibleScanlines] = {};
    u32 totalWork = 0;
    s32 activeProjectedWidth = 0;
    for (int y = 0; y < VisibleScanlines; y++)
    {
        activeProjectedWidth += scanlineDelta[y];
        lineWork[y] = static_cast<u32>(activeProjectedWidth);
        totalWork += lineWork[y];
    }
    if (totalWork == 0) return 112;

    const u32 primaryTarget = (totalWork * 3u + 4u) / 5u;
    u32 primaryWork = 0;
    for (int y = 0; y < VisibleScanlines - 1; y++)
    {
        primaryWork += lineWork[y];
        if (primaryWork >= primaryTarget) return y + 1;
    }
    return VisibleScanlines - 1;
}

void SoftRenderer3D::RenderPolygonsDualCore(
    bool threaded, Polygon** polygons, int npolys)
{
    const int polygonsPrepared = SetupRenderPolygons(polygons, npolys);
    const s32 SplitLine = ChooseParallelRasterSplitLine(polygonsPrepared);
    ParallelRasterSplitLine_.store(SplitLine, std::memory_order_relaxed);
    PrepareParallelRasterBand(polygonsPrepared, SplitLine);
    ParallelRasterNs.store(0, std::memory_order_relaxed);
    Platform::Semaphore_Reset(Sema_ParallelRasterDone);

    const auto rasterStarted =
        renderer3DProfileStarted(Parent.StageProfileEnabled);
    Platform::Semaphore_Post(Sema_ParallelRasterStart);
    const u64 primaryRasterNs = RenderScanlineBand(
        0, SplitLine, PolygonList, ActivePolygonMask,
        PrevIsShadowMask, StencilBuffer);
    const auto joinStarted =
        renderer3DProfileStarted(Parent.StageProfileEnabled);
    Platform::Semaphore_Wait(Sema_ParallelRasterDone);

    if (Parent.StageProfileEnabled)
    {
        ++Parent.StageProfile.ThreeDParallelFrames;
        Parent.StageProfile.ThreeDPrimaryRasterNs += primaryRasterNs;
        Parent.StageProfile.ThreeDSecondaryRasterNs +=
            ParallelRasterNs.load(std::memory_order_relaxed);
        Parent.StageProfile.ThreeDParallelJoinNs +=
            renderer3DProfileElapsedNs(joinStarted);
        Parent.StageProfile.ThreeDRasterNs +=
            renderer3DProfileElapsedNs(rasterStarted);
    }

    // Edge marking reads the adjacent rasterized rows. Join both disjoint
    // bands first, then perform the inexpensive final pass in canonical line
    // order. This avoids a boundary race without changing any pixel result.
    const auto finalPassStarted =
        renderer3DProfileStarted(Parent.StageProfileEnabled);
    for (s32 y = 0; y < VisibleScanlines; y++)
    {
        ScanlineFinalPass(y);
        if (threaded)
            Platform::Semaphore_Post(Sema_ScanlineCount);
    }
    if (Parent.StageProfileEnabled)
        Parent.StageProfile.ThreeDFinalPassNs +=
            renderer3DProfileElapsedNs(finalPassStarted);
}

void SoftRenderer3D::RenderPolygons(bool threaded, Polygon** polygons, int npolys)
{
    SetupRenderPolygons(polygons, npolys);

    auto stageStarted =
        renderer3DProfileStarted(Parent.StageProfileEnabled);
    RenderScanline(
        0, PolygonList, ActivePolygonMask,
        PrevIsShadowMask, StencilBuffer);
    if (Parent.StageProfileEnabled)
        Parent.StageProfile.ThreeDRasterNs +=
            renderer3DProfileElapsedNs(stageStarted);

    for (s32 y = 1; y < 192; y++)
    {
        stageStarted = renderer3DProfileStarted(Parent.StageProfileEnabled);
        RenderScanline(
            y, PolygonList, ActivePolygonMask,
            PrevIsShadowMask, StencilBuffer);
        if (Parent.StageProfileEnabled)
            Parent.StageProfile.ThreeDRasterNs +=
                renderer3DProfileElapsedNs(stageStarted);
        stageStarted = renderer3DProfileStarted(Parent.StageProfileEnabled);
        ScanlineFinalPass(y-1);
        if (Parent.StageProfileEnabled)
            Parent.StageProfile.ThreeDFinalPassNs +=
                renderer3DProfileElapsedNs(stageStarted);

        if (threaded)
            // Notify the main thread that we're done with a scanline.
            Platform::Semaphore_Post(Sema_ScanlineCount);
    }

    stageStarted = renderer3DProfileStarted(Parent.StageProfileEnabled);
    ScanlineFinalPass(191);
    if (Parent.StageProfileEnabled)
        Parent.StageProfile.ThreeDFinalPassNs +=
            renderer3DProfileElapsedNs(stageStarted);

    if (threaded)
        // If this renderer is threaded, notify the main thread that we're done with the frame.
        Platform::Semaphore_Post(Sema_ScanlineCount);
}

void SoftRenderer3D::FinishRendering()
{
    if (RenderThreadRunning.load(std::memory_order_relaxed) && !GPU3D.AbortFrame)
    {
        Platform::Semaphore_Wait(Sema_RenderDone);
        Platform::Semaphore_Reset(Sema_ScanlineCount);
        RenderFrameFinished = true;
    }
}

void SoftRenderer3D::RenderFrame()
{
    RenderFrameFinished = false;
    const auto coherenceStarted =
        renderer3DProfileStarted(Parent.StageProfileEnabled);
    bool textureChanged;
    if (UseTextureCache)
    {
        u8 clearBitmapDirty = 0;
        textureChanged = TextureCache.Update(clearBitmapDirty);
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

    FrameIdentical = !textureChanged && GPU3D.RenderFrameIdentical;
    if (Parent.StageProfileEnabled)
    {
        ++Parent.StageProfile.ThreeDFrames;
        Parent.StageProfile.ThreeDIdenticalFrames += FrameIdentical;
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
            Platform::Semaphore_Post(Sema_ScanlineCount, 192);
        }
        else
        {
            const auto clearStarted =
                renderer3DProfileStarted(Parent.StageProfileEnabled);
            ClearBuffers();
            if (Parent.StageProfileEnabled)
                Parent.StageProfile.ThreeDClearNs +=
                    renderer3DProfileElapsedNs(clearStarted);
            if (DualCoreRaster)
                RenderPolygonsDualCore(
                    true, &GPU3D.RenderPolygonRAM[0],
                    GPU3D.RenderNumPolygons);
            else
                RenderPolygons(
                    true, &GPU3D.RenderPolygonRAM[0],
                    GPU3D.RenderNumPolygons);
        }

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

        const s32 SplitLine =
            ParallelRasterSplitLine_.load(std::memory_order_relaxed);
        const u64 elapsed = RenderScanlineBand(
            SplitLine, VisibleScanlines, ParallelPolygonList.get(),
            ParallelActivePolygonMask, ParallelPrevIsShadowMask,
            ParallelStencilBuffer);
        ParallelRasterNs.store(elapsed, std::memory_order_relaxed);
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
        if (line < 192)
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
