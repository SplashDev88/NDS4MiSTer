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
static void expectedQuarter(NDS& n) {
    // Independent reference: transform the reference machine's geometry,
    // raster every row with the native renderer, then expand snapshots.
    render(n);
    auto& r=soft(n);auto& g=n.GPU.GPU3D;
    r.ClearBuffers();
    if(g.RenderDispCnt&(1u<<14))
        for(int y=0;y<192;++y) for(int x=0;x<128;++x) {
            const auto row=r.FirstPixelOffset+y*r.ScanlineWidth;
            r.ColorBuffer[row+x]=r.ColorBuffer[row+2*x];
            r.DepthBuffer[row+x]=r.DepthBuffer[row+2*x];
            r.AttrBuffer[row+x]=r.AttrBuffer[row+2*x];
        }
    // Fixture vertices are separate per polygon; assert that explicitly.
    std::vector<Vertex*> seen;
    for(unsigned i=0;i<g.RenderNumPolygons;++i) {
        auto* p=g.RenderPolygonRAM[i];p->XTop>>=1;p->XBottom>>=1;
        for(unsigned v=0;v<p->NumVertices;++v) {
            auto* a=p->Vertices[v];
            if(std::find(seen.begin(),seen.end(),a)!=seen.end()) continue;
            seen.push_back(a);a->FinalPosition[0]>>=1;a->HiresPosition[0]>>=1;
        }
    }
    r.SetupRenderPolygons(g.RenderPolygonRAM.data(),g.RenderNumPolygons);
    for(int y=0;y<192;++y) r.RenderScanline(y,r.PolygonList,r.ActivePolygonMask,
        r.PrevIsShadowMask,r.StencilBuffer,0,256,r.FinalPassMinX,r.FinalPassMaxX);
    for(int y=0;y<192;y+=2) {
        const auto row=r.FirstPixelOffset+y*r.ScanlineWidth;
        for(auto* buffer:{r.ColorBuffer,r.DepthBuffer,r.AttrBuffer})
            for(unsigned layer:{0u,unsigned(r.BufferSize)}) {
                const std::vector<u32> snapshot(buffer+row+layer,buffer+row+layer+128);
                for(int x=0;x<256;++x) buffer[row+layer+x]=snapshot[x/2];
            }
        for(auto* buffer:{r.ColorBuffer,r.DepthBuffer,r.AttrBuffer})
            std::copy_n(buffer+row,256,buffer+row+r.ScanlineWidth);
        r.FinalPassMinX[y]=0;r.FinalPassMaxX[y]=256;
        r.FinalPassMinX[y+1]=0;r.FinalPassMaxX[y+1]=256;
    }
    for(int y=0;y<192;y+=2) r.ScanlineFinalPass(y);
    for(int y=1;y<192;y+=2) std::copy_n(r.GetLine(y-1),256,r.GetLine(y));
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
        // Dirty-span copies must also preserve row-varying clear images,
        // full-background fog, changing clear values, and empty successors.
        for(unsigned variant=0;variant<12;++variant) {
            for(auto* n:{ref.get(),test.get()}) {
                frame(*n,0);
                auto& gpu=n->GPU; auto& g=gpu.GPU3D;
                gpu.MapVRAM_AB(1,0x93); // texture slot 2: clear color
                gpu.MapVRAM_CD(2,0x9b); // texture slot 3: clear depth
                for(unsigned i=0;i<0x20000;++i) {
                    gpu.VRAM_B[i]=u8(i*17+(i>>9)*29+variant);
                    gpu.VRAM_C[i]=u8(i*31+(i>>9)*13+variant);
                }
                std::memset(gpu.VRAMDirty[1].Data,255,sizeof(gpu.VRAMDirty[1].Data));
                std::memset(gpu.VRAMDirty[2].Data,255,sizeof(gpu.VRAMDirty[2].Data));
                g.RenderDispCnt=1|((variant%3==0)?(1u<<14):0)|((variant&1)?128:0);
                g.RenderClearAttr1=0x07128000|((variant/3)*123);
                g.RenderClearAttr2=0x7fff|((variant%3==0)?0x03070000:0);
                g.RenderFogColor=0x100c4210;
                std::fill_n(g.RenderFogDensityTable,34,64);
                if(variant%3==2) g.RenderNumPolygons=0;
            }
            expected(*ref);render(*test);compare(*ref,*test);++cases;
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
    // Dawn's integral sprite-like rectangles bypass general edge setup.
    // Exercise the actual prepared path, not merely quad-shaped polygons.
    for(unsigned scheduler:{0u,2u}) {
        auto ref=make(0,false),test=make(scheduler,true);
        for(auto* n:{ref.get(),test.get()}) {
            n->GPU.GPU3D.SetSpriteRasterSpansEnabled(true);
            frame(*n,8192u|16384u|32768u|16u|8u);
            n->GPU.GPU3D.RenderDispCnt &= ~16u;
        }
        for(int i=0;i<3;++i) {expected(*ref);render(*test);compare(*ref,*test);++cases;}
        auto& t=soft(*test);unsigned rectangles=0;
        for(int i=0;i<t.CurrentPolygonCount;++i) rectangles+=t.PolygonList[i].PixelState.FlatRectangle;
        require(rectangles>0,"Dawn rectangle fixture missed optimized path");
    }
    // Force the unsafe shadow ordering that selects disjoint X ownership.
    for(bool edge:{false,true}) {
        auto ref=make(0,false),test=make(4,true);
        for(auto* n:{ref.get(),test.get()}) {
            push(*n,0x60,0xbfff0000);push(*n,0x10,0);push(*n,0x15,0);
            push(*n,0x10,1);push(*n,0x15,0);
            push(*n,0x20,0x3e0);push(*n,0x29,0x011f00c0);push(*n,0x40,1);
            for(auto xy:{std::array<int,2>{-60,30},{-20,30},{-20,10},{-60,10}})
                push(*n,0x24,vertex(xy[0],xy[1],-20));
            push(*n,0x41,0);push(*n,0x20,0x1f);push(*n,0x29,0x021f00c0);push(*n,0x40,0);
            push(*n,0x24,vertex(-60,20,0));push(*n,0x24,vertex(60,18,0));push(*n,0x24,vertex(-60,16,0));
            push(*n,0x41,0);push(*n,0x29,0x001f00f0);push(*n,0x40,1);
            for(auto xy:{std::array<int,2>{-60,60},{60,60},{60,-60},{-60,-60}})
                push(*n,0x24,vertex(xy[0],xy[1],30));
            push(*n,0x41,0);push(*n,0x50,0);n->GPU.GPU3D.VBlank();
            auto& g=n->GPU.GPU3D;g.RenderDispCnt=8|(edge?32:0);
            g.RenderClearAttr1=0x071f7c00;g.RenderClearAttr2=0x7fff;
        }
        for(int i=0;i<3;++i) {expected(*ref);render(*test);compare(*ref,*test);++cases;}
        require(test->GetRenderer().GetExternalRendererStageProfile().ThreeDXPartitionFrames==3,
            "X-partition fixture did not exercise required worker path");
    }
    // The actual host control word must switch the same renderer on identical
    // guest frames, including legacy environment requests and AA transitions.
    char controlPath[] = "/tmp/nds-resolution-oracle-XXXXXX";
    const int fd = mkstemp(controlPath);
    const std::uint32_t initial = nds4mister::GraphicsControl::AAOn;
    require(fd >= 0 && write(fd, &initial, 4) == 4, "control fixture creation");
    close(fd);
    for (unsigned scheduler=0;scheduler<5;++scheduler) {
        auto ref=make(0,false);
        setenv("NDS4MISTER_GRAPHICS_CONTROL",controlPath,1);
        nds4mister::GraphicsControl control(true);
        auto test=make(scheduler,true);
        unsetenv("NDS4MISTER_GRAPHICS_CONTROL");
        unsigned variation=0;
        for (int mode : {0,1,1,0,2,1,2,0,3,3,0,3,1,3,2,3,3,0,4,4,1,4,2,4,3,4,0}) {
            const bool aa=mode==2, half=mode==1;
            control.set(aa,half,mode==3,mode==4);
            frame(*ref,variation);ref->GPU.GPU3D.RenderDispCnt=1|(aa?16:0);
            frame(*test,variation++);test->GPU.GPU3D.RenderDispCnt=17;
            if(mode==4) expectedQuarter(*ref); else if (half) expected(*ref); else render(*ref);
            const auto prior=test->GetRenderer().GetExternalRendererStageProfile();
            test->GPU.GPU3D.RenderFrameIdentical=true;
            test->GetRenderer().Start3DRendering();test->GetRenderer().Finish3DRendering();
            require(soft(*test).AlternateRows==(half||mode==4),"live resolution admission");
            require(soft(*test).Quarter==(mode==4),"live quarter admission");
            if (mode==3) {
                auto& renderer=soft(*test);
                require(renderer.RenderOff,"off mode not sampled");
                const auto after=test->GetRenderer().GetExternalRendererStageProfile();
                require(prior.ThreeDCoherenceNs==after.ThreeDCoherenceNs &&
                        prior.ThreeDClearNs==after.ThreeDClearNs &&
                        prior.ThreeDFinalPassNs==after.ThreeDFinalPassNs, "off performed pixel work");
                require(test->GPU.GPU3D.RenderNumPolygons==10,"off discarded geometry");
                for(int y=0;y<192;++y) for(int x=0;x<256;++x)
                    require(renderer.GetLine(y)[x]==0,"off retained visible 3D pixels");
                require(!renderer.SparseClearStateValid && !renderer.RasterTileHistoryValid,
                    "off retained raster history");
            } else compare(*ref,*test);
            require(test->GPU.GPU3D.RenderDispCnt==17,"control changed guest state");
            ++cases;
        }
    }
    unlink(controlPath);
    for(unsigned scheduler=0;scheduler<5;++scheduler) {
        auto ref=make(0,false),test=make(scheduler,false);
        for(unsigned scenario=0;scenario<48;++scenario) {
            for(auto* n:{ref.get(),test.get()}) {
                n->GPU.GPU3D.SetSpriteRasterSpansEnabled((scenario&4)!=0);
                frame(*n,scenario|((scenario&4)?(16384u|32768u|8192u):64u));
                auto& g=n->GPU.GPU3D;g.RenderDispCnt&=~16u;
                if(scenario&2) {g.RenderDispCnt|=128;g.RenderFogColor=0x100c4210;
                    g.RenderClearAttr1|=0x8000;std::fill_n(g.RenderFogDensityTable,34,64);}
                if(scenario&1) {g.RenderDispCnt|=32;std::fill_n(g.RenderEdgeTable,8,0x7c00);}
                if(scenario>=32) {
                    for(unsigned i=0;i<g.RenderNumPolygons;++i) {
                        auto* p=g.RenderPolygonRAM[i];
                        if(i%3==1) {p->IsShadowMask=true;p->Attr&=0x00ffffff;}
                        if(i%3==2) p->IsShadow=true;
                    }
                }
                if(scenario%8==6) {
                    auto& gpu=n->GPU;
                    gpu.MapVRAM_AB(1,0x93);gpu.MapVRAM_CD(2,0x9b);
                    for(unsigned i=0;i<0x20000;++i) {
                        gpu.VRAM_B[i]=u8(i*17+(i>>9)*29+scenario);
                        gpu.VRAM_C[i]=u8(i*31+(i>>9)*13+scenario);
                    }
                    std::memset(gpu.VRAMDirty[1].Data,255,sizeof(gpu.VRAMDirty[1].Data));
                    std::memset(gpu.VRAMDirty[2].Data,255,sizeof(gpu.VRAMDirty[2].Data));
                    g.RenderDispCnt|=1u<<14;g.RenderClearAttr2|=0x03070000;
                }
                if(scenario%8==7) g.RenderNumPolygons=0;
            }
            std::vector<Polygon> original;
            std::vector<Vertex> vertices;
            auto& g=test->GPU.GPU3D;
            for(unsigned i=0;i<g.RenderNumPolygons;++i) {
                original.push_back(*g.RenderPolygonRAM[i]);
                for(unsigned v=0;v<g.RenderPolygonRAM[i]->NumVertices;++v)
                    vertices.push_back(*g.RenderPolygonRAM[i]->Vertices[v]);
            }
            soft(*test).QuarterRequested=true;
            expectedQuarter(*ref);render(*test);compare(*ref,*test);++cases;
            unsigned vi=0;
            for(unsigned i=0;i<g.RenderNumPolygons;++i) {
                require(!std::memcmp(&original[i],g.RenderPolygonRAM[i],sizeof(Polygon)),"quarter altered guest polygon");
                for(unsigned v=0;v<g.RenderPolygonRAM[i]->NumVertices;++v)
                    require(!std::memcmp(&vertices[vi++],g.RenderPolygonRAM[i]->Vertices[v],sizeof(Vertex)),"quarter altered guest vertex");
            }
            // A same-geometry switch back to native must invalidate reuse.
            soft(*test).QuarterRequested=false;
            frame(*ref,0);frame(*test,0);
            render(*ref);
            test->GPU.GPU3D.RenderFrameIdentical=true;
            test->GetRenderer().Start3DRendering();test->GetRenderer().Finish3DRendering();
            compare(*ref,*test);++cases;
        }
        soft(*test).QuarterRequested=true;
        for(auto* n:{ref.get(),test.get()}) {frame(*n,0);n->GPU.GPU3D.RenderDispCnt|=16;}
        render(*ref);render(*test);
        require(!soft(*test).Quarter && !soft(*test).AlternateRows,"quarter AA fallback");
        compare(*ref,*test);++cases;
        if(scheduler>=2) {
            frame(*ref,0);frame(*test,0);expectedQuarter(*ref);
            test->GPU.GPU3D.RenderFrameIdentical=false;
            test->GetRenderer().Start3DRendering();
            require(soft(*test).RequestFrameCancellation(),"quarter cancellation rejected");
            test->GetRenderer().Finish3DRendering();
            require(soft(*test).WasFrameCanceled(),"quarter fixture did not cancel");
            test->GPU.GPU3D.RenderFrameIdentical=true;
            test->GetRenderer().Start3DRendering();test->GetRenderer().Finish3DRendering();
            require(!soft(*test).IsFrameIdentical(),"quarter reused cancellation");
            compare(*ref,*test);++cases;
        }
    }
    // Migrate damage between disjoint spans and through empty frames. Also
    // abandon a frame after its depth/attribute copy but before color copy:
    // the successor must still clear every old odd-row color word.
    for(unsigned scheduler=0;scheduler<5;++scheduler) for(bool quarter:{false,true}) {
        auto ref=make(0,false),test=make(scheduler,true);
        soft(*test).QuarterRequested=quarter;
        for(int offset:{0,80,-80,999,-80,80,0}) {
            for(auto* n:{ref.get(),test.get()}) {
                frame(*n,0);
                auto& g=n->GPU.GPU3D;
                if(offset==999) {g.RenderNumPolygons=0;continue;}
                std::vector<Vertex*> moved;
                for(unsigned i=0;i<g.RenderNumPolygons;++i) {
                    auto* p=g.RenderPolygonRAM[i];p->XTop+=offset;p->XBottom+=offset;
                    for(unsigned v=0;v<p->NumVertices;++v) {
                        auto* a=p->Vertices[v];
                        if(std::find(moved.begin(),moved.end(),a)!=moved.end()) continue;
                        moved.push_back(a);a->FinalPosition[0]+=offset;a->HiresPosition[0]+=offset*16;
                    }
                }
            }
            if(quarter) expectedQuarter(*ref); else expected(*ref);
            auto& r=soft(*test);
            // Establish mode before manually producing the interrupted frame.
            r.UpdateAlternateRows();r.ClearBuffers();
            auto& g=test->GPU.GPU3D;
            r.SetupRenderPolygons(g.RenderPolygonRAM.data(),g.RenderNumPolygons);
            for(int y=0;y<192;++y) r.RenderScanline(y,r.PolygonList,r.ActivePolygonMask,
                r.PrevIsShadowMask,r.StencilBuffer,0,256,r.FinalPassMinX,r.FinalPassMaxX);
            if(quarter) r.ExpandQuarterColumns();
            r.DuplicateAlternateRows(true);
            render(*test);compare(*ref,*test);++cases;
        }
    }
    std::printf("PASS alternate-row oracle cases=%u schedulers=5 repeated/sparse/empty/AA/shadow/cancel/live-resolution\n",cases);
    return 0;
} catch(const std::exception& e) {std::fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
