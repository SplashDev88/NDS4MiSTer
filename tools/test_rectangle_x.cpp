// SPDX-License-Identifier: GPL-3.0-only
// ROM-free full-render oracle; --kernel performs CPU-only on/off cost checks.
#define main original_raster_benchmark_main
#include "benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include "replay/GameQueryProfile.h"
#include "umk3_profile_test.h"
#include <array>
#include <vector>

static SoftRenderer3D& soft(NDS& n) {
    return *static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n.GetRenderer()).Rend3D.get());
}
static void configure(NDS& n,bool enabled,bool dual=false) {
    n.GPU.GPU3D.SetIntegralTextureSpansEnabled(false);
    n.GPU.GPU3D.SetSpriteRasterSpansEnabled(true);
    n.GPU.GPU3D.SetTextureRangeHashReuseEnabled(true);
    n.GPU.GPU3D.SetNColor8PaletteExpansionEnabled(true);
    n.GPU.GPU3D.SetRectangleTextureXEnabled(enabled);
    auto& s=soft(n);s.StopRenderThread();s.DualCoreRaster=dual;
    s.RasterBandQueue=dual;s.WeightedRasterBands=dual;s.AdaptiveRasterSplit=dual;
    s.RasterXPartition=dual;s.ParallelFinalPass=dual;s.SetFullFrameCompletion(true);
    if(dual)s.ParallelPolygonList=std::make_unique<SoftRenderer3D::RendererPolygon[]>(s.MaxRendererPolygons);
    s.SetupRenderThread();
}
static void fixture(NDS& n,unsigned scenario,unsigned height=64,unsigned count=10,s32 forcedWidth=0) {
    frame(n,16384u|8192u|16u);auto& gpu=n.GPU;auto& g=gpu.GPU3D;
    require(count<=10,"fixture polygon limit");g.RenderNumPolygons=count;
    const u32 fmt=std::array<u32,4>{4,1,6,7}[scenario&3];
    const unsigned wrap=std::array<unsigned,4>{0,3,15,9}[(scenario>>2)&3];
    const s32 width=forcedWidth?forcedWidth:std::array<s32,4>{160,127,63,255}[(scenario>>4)&3];
    const s32 left=(scenario&64)?-17:3,top=0;
    for(unsigned i=0;i<131072;++i)gpu.VRAM_A[i]=u8(i*37+(i>>8));
    for(unsigned i=0;i<65536;++i)gpu.VRAM_E[i]=u8(i*11+(i>>7));
    for(unsigned i=0;i<count;++i) {
        auto* p=g.RenderPolygonRAM[i];p->Attr=0xc0|((i+17)<<24)|(31u<<16)|((scenario&128)?1u<<11:0);
        p->TexParam=(fmt<<26)|(wrap<<16)|(4u<<20)|(3u<<23)|(1u<<29);p->TexPalette=0;
        p->FacingView=true;p->Translucent=false;p->IsShadow=p->IsShadowMask=p->Degenerate=false;
        p->WBuffer=scenario&256;p->VTop=0;p->VBottom=2;
        p->YTop=top;p->YBottom=std::min<s32>(192,top+height);p->XTop=left;p->XBottom=left+width;
        const s32 positions[4][2]={{left,top},{left,p->YBottom},{left+width,p->YBottom},{left+width,top}};
        const s16 sl=scenario&512?30000:-1077,sr=scenario&512?-30000:2113;
        const s16 tt=scenario&1024?1907:-71,tb=scenario&1024?-97:1003;
        for(unsigned v=0;v<4;++v) {
            std::copy(positions[v],positions[v]+2,p->Vertices[v]->FinalPosition);
            std::fill(p->Vertices[v]->FinalColor,p->Vertices[v]->FinalColor+3,63<<3);
            p->FinalW[v]=4096;p->FinalZ[v]=0x100000-int(i)*0x1000;
            p->Vertices[v]->TexCoords[0]=v<2?sl:sr;
            p->Vertices[v]->TexCoords[1]=(v==1||v==2)?tb:tt;
        }
        if(scenario&2048) {
            p->FacingView=false;std::reverse(p->Vertices,p->Vertices+4);
            std::reverse(p->FinalZ,p->FinalZ+4);std::reverse(p->FinalW,p->FinalW+4);
            p->VTop=3-p->VTop;p->VBottom=3-p->VBottom;
        }
    }
    g.RenderDispCnt=1|8|((scenario&4096)?16:0)|((scenario&8192)?32:0);
    g.RenderAlphaRef=(scenario&16384)?15:0;
    // Explicit proof failures. They must use the original raster path.
    const unsigned reject=(scenario>>16)&15;
    if(reject)for(unsigned i=0;i<count;++i) {
        auto* p=g.RenderPolygonRAM[i];
        switch(reject) {
        case 1:p->Vertices[1]->TexCoords[0]+=1;break;
        case 2:p->Vertices[3]->TexCoords[1]+=1;break;
        case 3:p->FinalW[1]+=128;break;
        case 4:p->FinalZ[1]+=128;break;
        case 5:p->Vertices[0]->FinalColor[0]-=8;break;
        case 6:p->Attr=(p->Attr&~(31u<<16))|(15u<<16);p->Translucent=true;break;
        case 7:p->Attr|=1u<<14;break;
        case 8:p->TexParam=0;break;
        }
    }
}
static void equal(NDS& a,NDS& b) {
    auto& sa=soft(a);auto& sb=soft(b);
    require(!std::memcmp(sa.ColorBuffer,sb.ColorBuffer,sizeof(sa.ColorBuffer)),"color differs");
    require(!std::memcmp(sa.DepthBuffer,sb.DepthBuffer,sizeof(sa.DepthBuffer)),"depth differs");
    require(!std::memcmp(sa.AttrBuffer,sb.AttrBuffer,sizeof(sa.AttrBuffer)),"attributes differ");
}
static int boundaries() {
    unsigned frames=0,admitted=0;
    for(bool dual:{false,true}) {
        auto a=machine(true),b=machine(true);configure(*a,false,dual);configure(*b,true,dual);
        for(s32 width:{1,2,3,4,255,256})for(unsigned scenario:{64u,2048u|4096u,512u|16384u}) {
            fixture(*a,scenario,64,10,width);fixture(*b,scenario,64,10,width);
            render(*a);render(*b);equal(*a,*b);++frames;admitted+=soft(*b).RectangleTextureXCount;
            if(width==1)require(soft(*b).RectangleTextureXCount==0,"single-column proof");
        }
    }
    require(admitted>0,"boundary path unused");
    std::printf("RECTANGLE_X_BOUNDARIES_PASS frames=%u admitted=%u native_color_depth_attributes_equal=1\n",frames,admitted);return 0;
}
static int kernel() {
    auto a=machine(true),b=machine(true);configure(*a,false);configure(*b,true);
    for(unsigned height:{16u,64u,128u})for(unsigned count:{1u,10u}) {
        fixture(*a,0,height,count);fixture(*b,0,height,count);render(*a);render(*b);equal(*a,*b);
        require(soft(*b).RectangleTextureXCount==count,"kernel path not admitted");
        std::array<double,3> oldNs{},newNs{};constexpr unsigned iterations=32;
        for(unsigned round=0;round<3;++round)for(unsigned order=0;order<2;++order) {
            const bool enabled=(round+order)%2;auto& n=enabled?*b:*a;
            for(unsigned warm=0;warm<4;++warm)render(n);
            const auto start=std::chrono::steady_clock::now();
            for(unsigned i=0;i<iterations;++i)render(n);
            (enabled?newNs:oldNs)[round]=std::chrono::duration<double,std::nano>(std::chrono::steady_clock::now()-start).count()/iterations;
            equal(*a,*b);
        }
        std::sort(oldNs.begin(),oldNs.end());std::sort(newNs.begin(),newNs.end());
        std::printf("RECTANGLE_X_KERNEL height=%u polygons=%u iterations=%u old_ns=%.3f new_ns=%.3f saved_percent=%.3f\n",height,count,iterations,oldNs[1],newNs[1],100*(1-newNs[1]/oldNs[1]));std::fflush(stdout);
    }
    std::puts("RECTANGLE_X_KERNEL_DONE color_depth_attributes_equal=1");return 0;
}
int main(int argc,char** argv) try {
    if(argc==2 && !std::strcmp(argv[1],"--kernel"))return kernel();
    if(argc==2 && !std::strcmp(argv[1],"--boundaries"))return boundaries();
    require(argc==1,"expected no arguments or --kernel");
    using namespace nds4mister::replay;
    verify_umk3_regions(umk3_rectangle_x_profile);
    unsigned transitions=0,coordinates=0,frames=0,admitted=0,rejected=0;
    for(const char* setting:{static_cast<const char*>(nullptr),"auto","0","1","invalid"}) {
        if(setting)setenv("NDS4MISTER_RECTANGLE_TEXTURE_X",setting,1);else unsetenv("NDS4MISTER_RECTANGLE_TEXTURE_X");
        auto n=machine(true);configure(*n,false);require(!n->GPU.GPU3D.RectangleTextureXEnabled(),"fresh policy");
        for(bool policy:{false,true,false,true,false}) {
            n->GPU.GPU3D.SetRectangleTextureXEnabled(policy);fixture(*n,0);render(*n);
            const bool expected=!setting||!std::strcmp(setting,"auto")?policy:!std::strcmp(setting,"1");
            require(soft(*n).UseRectangleTextureX==expected,"override policy");
            require(bool(soft(*n).RectangleTextureXCount)==expected,"policy admission");++transitions;
        }
    }
    unsetenv("NDS4MISTER_RECTANGLE_TEXTURE_X");
    // Independent signed endpoint formula, including descending DS rounding.
    for(u32 width=1;width<=512;++width)for(s32 left:{-32768,-1025,-1,0,65,32767})for(s32 right:{-32768,-63,0,17,1024,32767}) {
        const u32 first=width/3;NDS4MiSTerGraySpan c(left,right,width,first);
        for(u32 x=first;x<=width;++x,c.Advance()) {
            const s32 expected=left<right?left+s64(right-left)*x/width:right+s64(left-right)*(width-x)/width;
            require(c.Get()==expected,"signed coordinate recurrence");++coordinates;
        }
    }
    for(bool dual:{false,true}) {
        auto a=machine(true),b=machine(true);configure(*a,false,dual);configure(*b,true,dual);
        // Wrap/clamp, signed endpoints, winding, AA/edge marks, alpha test,
        // translucent texture formats and texture-cache invalidations.
        for(unsigned test=0;test<256;++test) {
            const unsigned scenario=(test*131)&32767;
            fixture(*a,scenario);fixture(*b,scenario);render(*a);render(*b);equal(*a,*b);
            admitted+=soft(*b).RectangleTextureXCount;++frames;
        }
        for(unsigned reason=1;reason<=8;++reason) {
            fixture(*a,reason<<16);fixture(*b,reason<<16);render(*a);render(*b);equal(*a,*b);
            require(soft(*b).RectangleTextureXCount==0,"failed rectangle proof admitted");++rejected;++frames;
        }
        for(unsigned height:{1u,2u,3u,15u,16u,191u,192u}) {
            fixture(*a,2048|4096,height);fixture(*b,2048|4096,height);render(*a);render(*b);equal(*a,*b);
            require(bool(soft(*b).RectangleTextureXCount)==(height>=16),"height admission");++frames;
        }
        for(unsigned mode=1;mode<=3;++mode) {
            soft(*a).AlternateRowsRequested=soft(*b).AlternateRowsRequested=mode==1;
            soft(*a).QuarterRequested=soft(*b).QuarterRequested=mode==2;
            soft(*a).TinyRequested=soft(*b).TinyRequested=mode==3;
            fixture(*a,0);fixture(*b,0);render(*a);render(*b);equal(*a,*b);
            require(soft(*b).RectangleTextureXCount==0,"reduced mode admitted");++frames;
        }
    }
    // Bound exhaustion is a normal fallback. Tables are reused only after
    // complete rendering and remain immutable for the parallel worker.
    {
        auto n=machine(true);configure(*n,true);fixture(*n,0);render(*n);auto& s=soft(*n);
        auto rp=s.PolygonList[0];require(rp.PixelState.RectangleTextureX,"budget fixture");
        s.RectangleTextureXCount=0;
        for(unsigned i=0;i<s.MaxRectangleTextureXRows+8;++i) {
            rp.PixelState.RectangleTextureX=nullptr;s.PrepareRectangleTextureX(&rp);
            require(bool(rp.PixelState.RectangleTextureX)==(i<s.MaxRectangleTextureXRows),"bounded fallback");
        }
        require(s.RectangleTextureXCount==s.MaxRectangleTextureXRows,"table budget overflow");
    }
    require(admitted>0,"optimized path untested");
    std::printf("RECTANGLE_X_PASS coordinate_checks=%u render_frames=%u admitted_rectangles=%u rejected_cases=%u policy_transitions=%u budget_bytes=65536 native_color_depth_attributes_equal=1 dual_workers_and_reduced_fallback=1\n",coordinates,frames,admitted,rejected,transitions);
    return boundaries();
}catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
