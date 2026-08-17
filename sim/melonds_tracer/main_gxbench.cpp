// A9 rasterizer timing bench: how long does melonDS's software 3D renderer take
// per frame on the DE10-Nano's Cortex-A9?
//
// WHY THIS EXISTS. The hybrid-core plan puts the DS geometry engine's readback
// state (matrix stack, POS/VEC/BOX test) in fabric and everything downstream of
// clipping — raster, texture, blend, fog, edge marking — on the HPS ARM. That
// plan is only worth designing if the ARM can actually rasterize a DS scene in
// under a frame. Budget at 60 Hz on one 800 MHz core is ~90 cycles per output
// pixel BEFORE overdraw, and a textured alpha-blended depth-tested span pixel is
// plausibly 30-80. So the answer is somewhere near the line, and no amount of
// arguing settles it. Measure it before writing any RTL.
//
// WHAT IT MEASURES. Steady-state SoftRenderer::RenderFrame() over a fixed scene:
// ClearBuffers + RenderPolygons for one frame's RenderPolygonRAM. It does NOT
// measure the emulator around it — after the scene is reached the NDS never
// steps again, so the ARM7/ARM9 interpreters are not competing for cache. That
// is deliberate: in the hybrid core the DS CPUs are in fabric, so the isolated
// number is the one that predicts the design, and a whole-emulator number would
// be pessimistic for reasons that will not exist on the real thing.
//
// It also excludes melonDS's VRAM flattening (MakeVRAMFlat_*Coherent): the first
// RenderFrame after a state load does that work, and every iteration after it
// finds nothing dirty. The hybrid core does not have this step at all — the HPS
// reads a DDR3 bank mirror the fabric writes through — so excluding it is
// correct, not generous. Iteration 0 is reported separately and discarded.
//
// USAGE
//
//   Capture a scene (desktop, fast):
//     melonds_gxbench --capture scene.mln --frames 900 game.nds
//
//   Bench it (on the board):
//     melonds_gxbench --state scene.mln --iters 300 game.nds
//
//   Or skip the savestate and just run to a frame, then bench in place:
//     melonds_gxbench --frames 900 --iters 300 game.nds
//
// The ROM is required in both modes: a melonDS savestate carries machine state,
// not cart contents, so the cart has to be inserted before the state loads.
//
// BIOS9/BIOS7/FIRMWARE env vars work exactly as in main_fbdump.cpp.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <algorithm>
#include <memory>
#include <vector>

#include "NDS.h"
#include "NDSCart.h"
#include "ARM.h"
#include "GPU.h"
#include "GPU3D.h"
#include "GPU3D_Soft.h"
#include "Savestate.h"

using namespace melonDS;

static double now_ms()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}

static u8* slurp(const char* path, long* out_len)
{
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); return nullptr; }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    u8* buf = new u8[len];
    if (fread(buf, 1, len, f) != (size_t)len)
    {
        fprintf(stderr, "short read on %s\n", path);
        fclose(f); delete[] buf; return nullptr;
    }
    fclose(f);
    *out_len = len;
    return buf;
}

// Scene shape, printed alongside the timing so a number can be attributed to a
// workload rather than to "some frame of some game". Span rows is the sum of
// each polygon's scanline extent: not a pixel count, but it tracks overdraw far
// better than the polygon count alone does, and it is free to compute.
struct SceneStats
{
    u32 polys = 0, verts = 0, translucent = 0, shadow = 0, spanRows = 0;
};

static SceneStats describeScene(GPU3D& gpu3d)
{
    SceneStats s;
    s.polys = gpu3d.RenderNumPolygons;
    for (u32 i = 0; i < s.polys; i++)
    {
        Polygon* p = gpu3d.RenderPolygonRAM[i];
        if (!p) continue;
        s.verts += p->NumVertices;
        if (p->Translucent) s.translucent++;
        if (p->IsShadow || p->IsShadowMask) s.shadow++;
        if (p->YBottom >= p->YTop) s.spanRows += (u32)(p->YBottom - p->YTop + 1);
    }
    return s;
}

int main(int argc, char** argv)
{
    const char* statePath   = nullptr;
    const char* capturePath = nullptr;
    const char* rompath     = nullptr;
    int frames = 0;
    int iters  = 100;
    u32 mashMask = 0xFFF;   // KEYINPUT polarity: a 0 bit is a pressed button

    // KEYINPUT bit order, with X/Y in the two bits SetKeyMask folds up to 16/17.
    static const struct { const char* name; int bit; } KEYS[] = {
        {"a",0}, {"b",1}, {"select",2}, {"start",3}, {"right",4}, {"left",5},
        {"up",6}, {"down",7}, {"r",8}, {"l",9}, {"x",10}, {"y",11},
    };

    for (int i = 1; i < argc; i++)
    {
        if      (!strcmp(argv[i], "--state")   && i + 1 < argc) statePath   = argv[++i];
        else if (!strcmp(argv[i], "--capture") && i + 1 < argc) capturePath = argv[++i];
        else if (!strcmp(argv[i], "--frames")  && i + 1 < argc) frames      = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--iters")   && i + 1 < argc) iters       = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--mash")    && i + 1 < argc)
        {
            char* list = strdup(argv[++i]);
            for (char* tok = strtok(list, ","); tok; tok = strtok(nullptr, ","))
            {
                bool found = false;
                for (auto& k : KEYS)
                    if (!strcmp(tok, k.name)) { mashMask &= ~(1u << k.bit); found = true; }
                if (!found) { fprintf(stderr, "unknown button '%s'\n", tok); return 2; }
            }
            free(list);
        }
        else if (argv[i][0] != '-')                            rompath     = argv[i];
        else
        {
            fprintf(stderr, "unknown option %s\n", argv[i]);
            return 2;
        }
    }
    if (!rompath)
    {
        fprintf(stderr,
            "usage: %s [--capture <state>] [--state <state>] [--frames n]\n"
            "          [--mash a,start,...] [--iters n] <game.nds>\n",
            argv[0]);
        return 2;
    }

    long romlen = 0;
    u8* rom = slurp(rompath, &romlen);
    if (!rom) return 1;
    if (romlen < 0x200) { fprintf(stderr, "image too small\n"); return 1; }

    // Heap-allocated: the 1.1 NDS object is far too large for the stack.
    auto nds_holder = std::make_unique<NDS>();
    NDS& nds = *nds_holder;

    auto loadBIOS = [&](const char* envname, auto image, auto setter) -> bool
    {
        const char* path = getenv(envname);
        if (!path) return true;
        FILE* bf = fopen(path, "rb");
        if (!bf) { fprintf(stderr, "cannot open %s=%s\n", envname, path); return false; }
        bool ok = fread(image.data(), 1, image.size(), bf) == image.size();
        int extra = fgetc(bf);
        fclose(bf);
        if (!ok || extra != EOF) { fprintf(stderr, "%s has wrong size\n", path); return false; }
        setter(image);
        printf("loaded %s from %s\n", envname, path);
        return true;
    };
    if (!loadBIOS("BIOS9", nds.GetARM9BIOS(), [&](const auto& v) { nds.SetARM9BIOS(v); })) return 1;
    if (!loadBIOS("BIOS7", nds.GetARM7BIOS(), [&](const auto& v) { nds.SetARM7BIOS(v); })) return 1;

    auto cart = NDSCart::ParseROM(rom, (u32)romlen);
    if (!cart) { fprintf(stderr, "ParseROM failed on %s\n", rompath); return 1; }
    nds.SetNDSCart(std::move(cart));
    nds.Reset();
    nds.SetupDirectBoot(rompath);
    nds.Start();

    // The renderer must be synchronous for the timing to mean anything: in
    // threaded mode RenderFrame only posts a semaphore and returns, so a timer
    // around it measures the post, not the raster. melonDS's render thread is
    // one extra thread that moves the work off the main thread without
    // parallelising the raster itself, and in the hybrid core the main thread
    // has nothing else to do anyway — so single-threaded IS the number we want.
    auto* soft = dynamic_cast<SoftRenderer*>(&nds.GPU.GPU3D.GetCurrentRenderer());
    if (!soft) { fprintf(stderr, "current renderer is not the SoftRenderer\n"); return 1; }
    soft->SetThreaded(false, nds.GPU);

    if (statePath)
    {
        long slen = 0;
        u8* sbuf = slurp(statePath, &slen);
        if (!sbuf) return 1;
        Savestate state(sbuf, (u32)slen, false);
        if (state.Error) { fprintf(stderr, "%s is not a valid savestate\n", statePath); return 1; }
        if (!nds.DoSavestate(&state) || state.Error)
        {
            fprintf(stderr, "savestate load failed (built from a different melonDS?)\n");
            return 1;
        }
        delete[] sbuf;
        printf("loaded state %s (%ld bytes)\n", statePath, slen);
        // A state load leaves the renderer's threading mode to whatever the
        // object had; re-assert it rather than trusting the restore.
        soft->SetThreaded(false, nds.GPU);
    }

    if (frames > 0)
    {
        printf("running %d frames to reach the scene...\n", frames);
        double t0 = now_ms();
        for (int n = 0; n < frames; n++)
        {
            // Mashing exists because --frames alone cannot reach gameplay in a
            // game with a title screen: the attract sequence waits for input and
            // a headless run sits there forever, so you capture a menu and time
            // its alpha-blended overlays instead of a level. 6 frames held / 6
            // released is slow enough for menus that debounce.
            if (mashMask != 0xFFF)
                nds.SetKeyMask(((n / 6) & 1) ? mashMask : 0xFFF);
            nds.RunFrame();
        }
        nds.SetKeyMask(0xFFF);
        printf("  %d frames in %.1f s (%.1f fps emulated — NOT the number we want)\n",
               frames, (now_ms() - t0) / 1000.0, frames / ((now_ms() - t0) / 1000.0));
    }

    if (capturePath)
    {
        Savestate state;
        if (!nds.DoSavestate(&state) || state.Error)
        {
            fprintf(stderr, "savestate save failed\n");
            return 1;
        }
        state.Finish();
        FILE* f = fopen(capturePath, "wb");
        if (!f) { fprintf(stderr, "cannot write %s\n", capturePath); return 1; }
        fwrite(state.Buffer(), 1, state.Length(), f);
        fclose(f);
        printf("captured state to %s (%u bytes)\n", capturePath, state.Length());
    }

    SceneStats scene = describeScene(nds.GPU.GPU3D);
    printf("\nscene: %u polygons (%u vertices), %u translucent, %u shadow, "
           "%u span-rows\n",
           scene.polys, scene.verts, scene.translucent, scene.shadow, scene.spanRows);
    fflush(stdout);   // else these land above the run log they follow
    if (scene.polys == 0)
    {
        fprintf(stderr,
            "\nNO POLYGONS IN RENDER RAM — this scene has no 3D, so the timing below\n"
            "measures an empty clear and says nothing. Advance to a 3D scene with\n"
            "--frames, or capture a state where the game is actually drawing.\n");
    }
    else if (scene.polys < 200 && scene.translucent * 4 > scene.polys * 3)
    {
        // Few polygons, nearly all translucent, is the signature of a title card
        // or a fade: a handful of big alpha quads over not much. It is a real
        // workload but it is the CHEAP one, and sizing the HPS split against it
        // would flatter the design badly.
        fprintf(stderr,
            "\nWARNING: %u polygons, %u of them translucent. That shape is usually a\n"
            "menu, logo or fade rather than gameplay — a few large alpha quads. Real\n"
            "3D scenes run to many hundreds of polygons. Push further in with\n"
            "--frames and --mash, or load a state saved mid-level.\n",
            scene.polys, scene.translucent);
    }

    if (iters < 2) { fprintf(stderr, "--iters must be >= 2\n"); return 2; }
    std::vector<double> ms;
    ms.reserve(iters);

    for (int i = 0; i < iters; i++)
    {
        // RenderFrame short-circuits when nothing changed. After the first call
        // the VRAM flat caches are clean, so FrameIdentical collapses to exactly
        // this flag — clearing it each iteration is what forces a real raster.
        nds.GPU.GPU3D.RenderFrameIdentical = false;
        double t0 = now_ms();
        soft->RenderFrame(nds.GPU);
        ms.push_back(now_ms() - t0);
    }

    // Iteration 0 carries the VRAM flatten and a cold cache; it is a different
    // measurement and is reported, not averaged in.
    double warmup = ms[0];
    std::vector<double> steady(ms.begin() + 1, ms.end());
    std::sort(steady.begin(), steady.end());
    auto pct = [&](double p) { return steady[(size_t)(p * (steady.size() - 1))]; };
    double sum = 0;
    for (double v : steady) sum += v;
    double mean = sum / steady.size();

    printf("\nRenderFrame over %zu steady iterations (warmup iter 0: %.3f ms)\n",
           steady.size(), warmup);
    printf("  min %.3f  p50 %.3f  mean %.3f  p95 %.3f  max %.3f  ms\n",
           steady.front(), pct(0.50), mean, pct(0.95), steady.back());
    printf("  p50 => %.1f fps of pure raster; frame budget at 60 Hz is 16.67 ms "
           "(%.0f%% used)\n",
           1000.0 / pct(0.50), 100.0 * pct(0.50) / 16.67);

    // A verdict off one or two samples is noise wearing a conclusion's clothes,
    // and --iters 2 is exactly what the capture step uses. Say nothing instead.
    if (steady.size() < 10)
    {
        printf("  (no verdict: %zu steady iterations is not a measurement — "
               "use --iters 300)\n", steady.size());
        return 0;
    }
    if (scene.polys == 0)
    {
        printf("  (no verdict: nothing was rendered)\n");
        return 0;
    }
    printf("  VERDICT: %s\n",
           pct(0.95) < 16.67 ? "fits a 60 Hz budget on one core"
         : pct(0.95) < 33.3  ? "misses 60 Hz, fits 30 Hz"
                             : "misses 30 Hz — the split needs rethinking");
    return 0;
}
