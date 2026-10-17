// Reuse the existing independent cached/uncached fixture machinery. Compile
// with -fno-access-control; NDS_TEST_GRAY_PATH also checks the new path census.
#define main texture_raster_benchmark_main
#include "benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"

static void grayFrame(NDS& n, unsigned scenario)
{
    frame(n, 16384u | 8192u | 16u | (scenario & 63u));
    auto& g = n.GPU.GPU3D;
    auto* p = g.RenderPolygonRAM[g.RenderNumPolygons - 1];
    const u32 widths[] = {1, 2, 3, 16, 63, 127, 255, 256};
    const s32 width = widths[scenario & 7];
    const s32 left = scenario & 8 ? 128 : 0;
    const s32 top = scenario & 16 ? 17 : 0;
    const s32 height = scenario & 32 ? 31 : 192;
    const s32 bottom = std::min(192, top + height);
    const u32 alpha = 1 + (scenario * 7) % 30;
    const u32 id = scenario & 64 ? 17 : 12;
    p->Attr = 0xc0 | (id << 24) | (alpha << 16) |
        ((scenario & 1) ? 1u << 11 : 0) | ((scenario & 2) ? 1u << 15 : 0);
    p->TexParam = 0;
    p->TexPalette = 0;
    p->FacingView = true;
    p->Translucent = true;
    p->IsShadow = p->IsShadowMask = p->Degenerate = false;
    p->WBuffer = scenario & 4;
    p->VTop = 0; p->VBottom = 2;
    p->YTop = top; p->YBottom = bottom;
    p->XTop = left; p->XBottom = left + width;
    const s32 positions[4][2] = {
        {left, top}, {left, bottom}, {left + width, bottom}, {left + width, top}};
    for (u32 v = 0; v < 4; ++v)
    {
        p->FinalZ[v] = scenario & 128 ? 0x100000 : 0x1000;
        p->FinalW[v] = 4096;
        std::copy(positions[v], positions[v] + 2, p->Vertices[v]->FinalPosition);
        const s32 gray = (scenario * 13 + v * (scenario & 64 ? 127 : 37)) & 511;
        std::fill(p->Vertices[v]->FinalColor, p->Vertices[v]->FinalColor + 3, gray);
    }
    g.RenderDispCnt = 1 | 8 | ((scenario & 2) ? 16 : 0) |
        ((scenario & 4) ? 32 : 0);
    g.RenderAlphaRef = scenario % 3 == 0 ? 0 : scenario % 3 == 1 ? 15 : 30;
    // The second half exercises reasons the proof must reject a rectangle.
    if (scenario >= 256)
    {
        switch ((scenario >> 3) & 7)
        {
        case 0: p->Vertices[2]->FinalColor[1] ^= 1; break;
        case 1: p->FinalW[1] += 128; break;
        case 2: p->FinalZ[1] += 128; break;
        case 3: p->Attr |= 1u << 14; break;
        case 4: g.RenderDispCnt &= ~8u; break;
        case 5: p->TexParam = 4u << 26; break;
        case 6: p->Attr = (p->Attr & ~(31u << 16)) | (31u << 16); break;
        case 7: p->Attr = (p->Attr & ~(3u << 4)) | (2u << 4); break;
        }
    }
    if (scenario & 1)
    {
        p->FacingView = false;
        std::reverse(p->Vertices, p->Vertices + 4);
        std::reverse(p->FinalZ, p->FinalZ + 4);
        std::reverse(p->FinalW, p->FinalW + 4);
        p->VTop = 3 - p->VTop; p->VBottom = 3 - p->VBottom;
    }
}

int main() try
{
    unsigned paths = 0;
    for (unsigned scenario = 0; scenario < 512; ++scenario)
    {
        auto ref = machine(false), test = machine(true);
        grayFrame(*ref, scenario); grayFrame(*test, scenario);
        render(*ref); render(*test);
        auto& a = ref->GetRenderer(); auto& b = test->GetRenderer();
        for (u32 y = 0; y < 192; ++y)
            require(!std::memcmp(a.Get3DScanline(y), b.Get3DScanline(y), 256 * 4),
                "gray visible mismatch");
        u64 ha[3]{}, hb[3]{};
        require(a.Get3DNativeBufferHashes(ha) && b.Get3DNativeBufferHashes(hb), "gray hashes");
        require(!std::memcmp(ha, hb, sizeof(ha)), "gray full color/depth/attribute mismatch");
#ifdef NDS_TEST_GRAY_PATH
        const auto* soft = static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(b).Rend3D.get());
        unsigned currentPaths = 0;
        for (int i = 0; i < soft->CurrentPolygonCount; ++i)
            currentPaths += soft->PolygonList[i].PixelState.GrayRectangle;
        const bool expected = scenario < 256 && (scenario & 7) != 0;
        require(currentPaths == unsigned(expected), "gray proof accepted/rejected wrong polygon");
        paths += currentPaths;
#endif
        std::printf("GRAY_PASS scenario=%u color=%016llx depth=%016llx attr=%016llx\n",
            scenario, (unsigned long long)hb[0], (unsigned long long)hb[1],
            (unsigned long long)hb[2]);
    }
#ifdef NDS_TEST_GRAY_PATH
    require(paths == 224, "gray path census");
#endif
    std::printf("PASS gray raster: 512 independent full-buffer cases; paths=%u\n", paths);
    return 0;
}
catch (const std::exception& e)
{
    std::fprintf(stderr, "FAIL: %s\n", e.what());
    return 1;
}
