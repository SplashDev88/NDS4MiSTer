// Independent oracle: raster ALL native rows, then sample and expand that raw
// plane. Candidate must match despite skipping odd-row pixel/shader work.
#define main original_raster_benchmark_main
#include "benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include <thread>

static SoftRenderer3D& soft(NDS& n) {
    return *static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n.GetRenderer()).Rend3D.get());
}
static std::unique_ptr<NDS> make(unsigned scheduling, bool alternate) {
    auto n=machine(true);
    auto& r=soft(*n);
    r.StopRenderThread();
    r.DualCoreRaster=scheduling!=0;
    r.RasterBandQueue=scheduling>=2;
    r.WeightedRasterBands=scheduling==3;
    r.AdaptiveRasterSplit=scheduling!=0;
    r.RasterXPartition=scheduling==4;
    r.ParallelFinalPass=scheduling!=0;
    r.RasterBandQueueTestDelayWorker=scheduling>=2;
    r.SparseClearEnabled=true;
    if(r.DualCoreRaster) r.ParallelPolygonList=std::make_unique<SoftRenderer3D::RendererPolygon[]>(r.MaxRendererPolygons);
    r.AlternateRowsRequested=alternate;
    r.SetFullFrameCompletion(true);
    r.SetupRenderThread();
    return n;
}
static void expected(NDS& n) {
    render(n); // coherence/texture binding on the unchanged full renderer
    auto& r=soft(n);
    r.ClearBuffers();
    r.SetupRenderPolygons(n.GPU.GPU3D.RenderPolygonRAM.data(),n.GPU.GPU3D.RenderNumPolygons);
    for(int y=0;y<192;++y) r.RenderScanline(y,r.PolygonList,r.ActivePolygonMask,
        r.PrevIsShadowMask,r.StencilBuffer,0,256,r.FinalPassMinX,r.FinalPassMaxX);
    // Deliberately do not call the candidate duplication helper.
    for(int y=0;y<192;y+=2) {
        auto a=r.FirstPixelOffset+y*r.ScanlineWidth,b=a+r.ScanlineWidth;
        for(int x=0;x<256;++x) {
            r.ColorBuffer[b+x]=r.ColorBuffer[a+x];
            r.DepthBuffer[b+x]=r.DepthBuffer[a+x];
            r.AttrBuffer[b+x]=r.AttrBuffer[a+x];
        }
        r.FinalPassMinX[y+1]=0; r.FinalPassMaxX[y+1]=256;
    }
    for(int y=0;y<192;y+=2) r.ScanlineFinalPass(y);
    for(int y=1;y<192;y+=2) std::copy_n(r.GetLine(y-1),256,r.GetLine(y));
}
static void compare(NDS& ref,NDS& n) {
    auto& a=soft(ref);auto& b=soft(n);
    for(int y=0;y<192;++y) {
        const auto address=a.FirstPixelOffset+y*a.ScanlineWidth;
        require(!std::memcmp(a.GetLine(y),b.GetLine(y),1024),"expanded color differs from native-row oracle");
        require(!std::memcmp(a.DepthBuffer+address,b.DepthBuffer+address,1024),"sampled depth mismatch");
        require(!std::memcmp(a.AttrBuffer+address,b.AttrBuffer+address,1024),"sampled attributes mismatch");
    }
}
int main() try {
    unsigned cases=0;
    for(unsigned scheduler=0;scheduler<5;++scheduler) {
        auto ref=make(0,false),test=make(scheduler,true);
        for(unsigned scenario=0;scenario<48;++scenario) {
            for(auto* n:{ref.get(),test.get()}) {
                frame(*n,scenario | ((scenario&4)?(16384u|32768u):64u));
                auto& g=n->GPU.GPU3D;
                g.RenderDispCnt &= ~16u;
                if(scenario&2) {g.RenderDispCnt|=128;g.RenderFogColor=0x100c4210;
                    std::fill_n(g.RenderFogDensityTable,34,64);}
                if(scenario&1) {g.RenderDispCnt|=32;std::fill_n(g.RenderEdgeTable,8,0x7c00);}
                for(unsigned i=0;i<g.RenderNumPolygons;++i) {
                    auto* p=g.RenderPolygonRAM[i];
                    if(scenario&2) p->Attr|=1u<<15;
                    if(scenario>=32 && i%3==1) {p->IsShadowMask=true;p->IsShadow=false;p->Attr&=0x00ffffff;}
                    if(scenario>=32 && i%3==2) {p->IsShadow=true;p->IsShadowMask=false;}
                }
                // Native small-list and scheduled-mask paths, empty transitions.
                if(scenario%8==6) g.RenderNumPolygons=1;
                if(scenario%8==7) g.RenderNumPolygons=0;
            }
            for(int repeat=0;repeat<2;++repeat) {expected(*ref);render(*test);compare(*ref,*test);++cases;}
            auto& t=soft(*test);
            test->GPU.GPU3D.RenderFrameIdentical=true;
            test->GetRenderer().Start3DRendering();test->GetRenderer().Finish3DRendering();
            compare(*ref,*test);
        }
        // AA fallback and native/half-row transitions must override reuse hints.
        for(bool aa:{true,false,true,false}) {
            for(auto* n:{ref.get(),test.get()}) {frame(*n,0);n->GPU.GPU3D.RenderDispCnt=aa?16:0;}
            if(aa) render(*ref); else expected(*ref);
            test->GPU.GPU3D.RenderFrameIdentical=true;
            test->GetRenderer().Start3DRendering();test->GetRenderer().Finish3DRendering();
            require(soft(*test).AlternateRows==!aa,"AA admission gate");compare(*ref,*test);++cases;
        }
        // Cancellation joins workers; an identical successor must rerender.
        if(scheduler>=2) {
            frame(*test,0);frame(*ref,0);expected(*ref);
            test->GPU.GPU3D.RenderFrameIdentical=false;
            test->GetRenderer().Start3DRendering();
            require(soft(*test).RequestFrameCancellation(),"cancellation rejected");
            test->GetRenderer().Finish3DRendering();
            require(soft(*test).WasFrameCanceled(),"cancel fixture did not cancel");
            test->GPU.GPU3D.RenderFrameIdentical=true;
            test->GetRenderer().Start3DRendering();test->GetRenderer().Finish3DRendering();
            require(!soft(*test).IsFrameIdentical(),"canceled result reused");compare(*ref,*test);++cases;
        }
    }
    std::printf("PASS alternate-row oracle cases=%u schedulers=5 repeated/sparse/empty/AA/shadow/cancel\n",cases);
    return 0;
} catch(const std::exception& e) {std::fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
