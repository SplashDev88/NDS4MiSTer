// Focused extraction of the existing Hybrid3DService synthetic raster oracle.
// No ROM, save, service lifecycle, FPGA mapping, or emulated CPU execution.
#include "NDS.h"
#include "GPU.h"
#include "GPU3D.h"
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <stdexcept>

using namespace melonDS;
static void require(bool ok, const char* why) { if (!ok) throw std::runtime_error(why); }

static std::unique_ptr<NDS> machine(bool cached)
{
    unsetenv("NDS4MISTER_DUAL_CORE_3D");
    unsetenv("NDS4MISTER_ADAPTIVE_RASTER_SPLIT");
    unsetenv("NDS4MISTER_RASTER_BAND_QUEUE");
    setenv("NDS4MISTER_DISABLE_SPARSE_3D_CLEAR", "1", 1);
    if (cached) unsetenv("NDS4MISTER_DISABLE_SOFT_TEXTURE_CACHE");
    else setenv("NDS4MISTER_DISABLE_SOFT_TEXTURE_CACHE", "1", 1);
    NDSArgs args;
    args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args), nullptr);
    nds->Reset();
    nds->GPU.GPU3D.SetEnabled(true, true);
    nds->GPU.GPU3D.SetExternalCommandReplay(true);
    nds->GPU.GPU3D.SetHighResolutionCoordinatesEnabled(false);
    RendererSettings settings {1, true, false, false, false, false, false, true, true};
    auto& r = nds->GPU.GetRenderer();
    r.SetRenderSettings(settings);
    r.Finish3DRendering();
    for (u32 y=0; y<192; ++y) require(r.Get3DScanline(y), "initial plane");
    auto& gpu=nds->GPU;
    gpu.MapVRAM_AB(0, 0x83);
    gpu.MapVRAM_E(4, 0x83);
    for(u32 i=0;i<256;++i) {
        const u16 c=((i*3+1)&31)|(((i*5+7)&31)<<5)|(((i*7+11)&31)<<10);
        std::memcpy(gpu.VRAM_E+i*2,&c,2);
    }
    return nds;
}

static void push(NDS& n,u8 command,u32 value)
{
    n.GPU.GPU3D.WriteExternalNormalizedCommand(command,value);
    n.ARM9Timestamp+=u64{1}<<16; n.ARM9Target=n.ARM9Timestamp;
    n.ARM7Timestamp=n.ARM9Timestamp>>n.ARM9ClockShift; n.ARM7Target=n.ARM7Timestamp;
    n.GPU.GPU3D.Run();
}
static u32 vertex(int x,int y,int z) { return (u32(x)&1023)|((u32(y)&1023)<<10)|((u32(z)&1023)<<20); }
static void frame(NDS& n,unsigned scenario)
{
    const bool clampOnly = scenario & 256u;
    const bool repeatOnly = scenario & 128u;
    const bool varyingDepth = scenario & 64u;
    scenario &= 63u;
    push(n,0x60,0xbfff0000); // Explicit full 256x192 viewport.
    push(n,0x10,1); push(n,0x15,0); push(n,0x20,0x001f00c0); push(n,0x29,0x001f00c0);
    for(int i=0;i<10;++i) {
        int dx=(i%5-2)*12,dy=(i/5)*16;
        push(n,0x40,0);
        push(n,0x24,vertex(-256+dx,-256+dy,0));
        push(n,0x24,vertex(256+dx,-256+dy,0));
        push(n,0x24,vertex(dx,256+dy,0)); push(n,0x41,0);
    }
    push(n,0x50,0); n.GPU.GPU3D.VBlank();
    auto& g=n.GPU.GPU3D;
    require(g.RenderNumPolygons==10,"polygon fixture");
    const u32 formats[]={4,6,1,7}; const u32 fmt=formats[scenario&3u];
    g.RenderDispCnt=1u|8u|((scenario&1)?48u:0u);
    g.RenderAlphaRef=scenario==2?15:0;
    g.RenderClearAttr1=0x0712254a; g.RenderClearAttr2=0x7fff;
    for(u32 i=0;i<128;++i) n.GPU.VRAM_A[i]=u8((i*37+scenario*17)&255);
    std::memset(n.GPU.VRAMDirty[0].Data,255,sizeof(n.GPU.VRAMDirty[0].Data));
    std::memset(n.GPU.VRAMDirty[4].Data,255,sizeof(n.GPU.VRAMDirty[4].Data));
    for(u32 i=0;i<g.RenderNumPolygons;++i) {
        auto* p=g.RenderPolygonRAM[i];
        const u32 polyAlpha=(scenario&32u)?15u:31u;
        p->Attr=0xc0|((i+17)<<24)|(polyAlpha<<16)|((scenario&1)<<11);
        p->TexParam=(fmt<<26)|((clampOnly?0u:repeatOnly || scenario==0?3u:15u)<<16)|(1u<<29);
        p->TexPalette=0; p->FacingView=true; p->Translucent=polyAlpha<31;
        p->IsShadowMask=false; p->IsShadow=false; p->WBuffer=!(scenario&8u);
        for(u32 v=0;v<p->NumVertices;++v) {
            p->FinalZ[v]=0x100000+(scenario&1 ? (i%3)*0x5000 : -int(i)*0x1000);
            if (varyingDepth) p->FinalZ[v] += v * 0x40000;
            p->FinalW[v]=0x800+((scenario&16u)?0:v*0x500)+i*0x40;
            for(u32 c=0;c<3;++c) p->Vertices[v]->FinalColor[c]=((i*(5+4*c)+((scenario&4u)?0:v*(17-5*c))+3+4*c)&63)<<3;
            p->Vertices[v]->TexCoords[0]=s16(int(v)*93-41);
            p->Vertices[v]->TexCoords[1]=s16(151-int(v)*77);
            if(scenario==3 && i==1) p->Vertices[v]->FinalPosition[0]-=192;
        }
    }
}
static void render(NDS& n)
{
    n.GPU.GPU3D.RenderFrameIdentical=false;
    auto& r=n.GPU.GetRenderer(); r.Start3DRendering(); r.Finish3DRendering();
    for(u32 y=0;y<192;++y) require(r.Get3DScanline(y),"render plane");
}
int main(int argc,char** argv) try
{
    const unsigned frames=argc>1?std::strtoul(argv[1],nullptr,10):64;
    const unsigned samples=argc>2?std::strtoul(argv[2],nullptr,10):3;
    const unsigned benchmarkScenario=argc>3?std::strtoul(argv[3],nullptr,10):0;
    const bool timingOnly=argc==5 && std::strcmp(argv[4],"--timing-only")==0;
    require(argc<=5 && (argc<5 || timingOnly),"usage: [frames samples scenario [--timing-only]]");
    require(frames>0 && frames<=512 && samples>0 && samples<=16 && benchmarkScenario<512,"bounds");
    auto ref=machine(false), test=machine(true);
    // Cross product: four texture formats, flat/gradient color, W/Z depth,
    // perspective/linear spans, opaque/translucent polygons, constant/varying
    // depth. Original scenarios0..63 remain byte-identical. The generic
    // uncached renderer is independent of the optimized batch pixel path.
    // Compare these hashes with the saved baseline as well: both paths share
    // scanline setup, so the in-process oracle alone cannot prove that setup.
    // Preserve the original128 fixtures. Add repeat-only flat-color/W/Z
    // combinations so both new wrap specializations exercise full rendering.
    constexpr unsigned extraScenarios[]={132,136,140,196,200,204};
    // Castlevania's profile also exercises clamp/clamp mode (0). Repeat the
    // full 128-case matrix with clamping, preserving all prior 134 hashes.
    // Full qualification remains the default. Repeated native timing can
    // check only its workload after BOTH binaries passed the full matrix.
    // The selected workload is always independently rendered and hash-checked
    // outside the timed interval, including after every timed sample.
    std::printf("CHECK_MODE %s\n",timingOnly?"selected-workload":"full-matrix");
    for(unsigned fixture=0;fixture<(timingOnly?1u:262u);++fixture) {
        const unsigned s=timingOnly ? benchmarkScenario : fixture<128 ? fixture : fixture<134 ?
            extraScenarios[fixture-128] : 256+fixture-134;
        frame(*ref,s); frame(*test,s); render(*ref); render(*test);
        auto& a=ref->GPU.GetRenderer(); auto& b=test->GPU.GetRenderer();
        for(u32 y=0;y<192;++y) require(!std::memcmp(a.Get3DScanline(y),b.Get3DScanline(y),256*4),"visible mismatch");
        u64 ha[3]{},hb[3]{};
        require(a.Get3DNativeBufferHashes(ha)&&b.Get3DNativeBufferHashes(hb),"native hashes");
        require(!std::memcmp(ha,hb,sizeof(ha)),"native color/depth/attr mismatch");
        std::printf("ORACLE_PASS scenario=%u color=%016llx depth=%016llx attr=%016llx\n",s,(unsigned long long)hb[0],(unsigned long long)hb[1],(unsigned long long)hb[2]);
    }
    require(ref->GPU.GetRenderer().GetExternalRendererStageProfile().ThreeDCachedModulatePolygons==0,"oracle cached");
    require(test->GPU.GetRenderer().GetExternalRendererStageProfile().ThreeDCachedModulatePolygons>0,"target path not exercised");
    frame(*ref,benchmarkScenario); render(*ref);
    u64 expected[3]{};
    require(ref->GPU.GetRenderer().Get3DNativeBufferHashes(expected),"timed reference hashes");
    ref.reset(); frame(*test,benchmarkScenario);
    std::printf("BENCH_SCENARIO index=%u constant_color=%u z_buffer=%u linear=%u translucent=%u varying_depth=%u\n",
        benchmarkScenario, bool(benchmarkScenario&4u), bool(benchmarkScenario&8u),
        bool(benchmarkScenario&16u), bool(benchmarkScenario&32u), bool(benchmarkScenario&64u));
    for(unsigned i=0;i<16;++i) render(*test);
    for(unsigned s=0;s<samples;++s) {
        auto before=test->GPU.GetRenderer().GetExternalRendererStageProfile();
        auto begin=std::chrono::steady_clock::now();
        for(unsigned i=0;i<frames;++i) render(*test);
        auto end=std::chrono::steady_clock::now();
        auto after=test->GPU.GetRenderer().GetExternalRendererStageProfile();
        auto wall=std::chrono::duration_cast<std::chrono::nanoseconds>(end-begin).count();
        require(after.ThreeDIdenticalFrames==before.ThreeDIdenticalFrames,"identical-frame shortcut in benchmark");
        require(after.ThreeDPolygonFrames-before.ThreeDPolygonFrames==frames,"raster frame count");
        require(after.ThreeDCachedModulateScanlines>before.ThreeDCachedModulateScanlines,"no cached scanlines");
        u64 actual[3]{};
        require(test->GPU.GetRenderer().Get3DNativeBufferHashes(actual),"timed output hashes");
        require(!std::memcmp(expected,actual,sizeof(actual)),"timed output mismatch");
        std::printf("TIMED_OUTPUT_PASS color=%016llx depth=%016llx attr=%016llx\n",
            (unsigned long long)actual[0],(unsigned long long)actual[1],(unsigned long long)actual[2]);
        std::printf("SAMPLE index=%u frames=%u wall_ns=%lld raster_ns=%llu\n",s,frames,(long long)wall,(unsigned long long)(after.ThreeDRasterNs-before.ThreeDRasterNs));
        std::printf("WORK cached_scanlines=%llu polygon_scanlines=%llu\n",(unsigned long long)(after.ThreeDCachedModulateScanlines-before.ThreeDCachedModulateScanlines),(unsigned long long)(after.ThreeDPolygonScanlines-before.ThreeDPolygonScanlines));
    }
    return 0;
} catch(const std::exception& e) {std::fprintf(stderr,"FAIL %s\n",e.what()); return 1;}
