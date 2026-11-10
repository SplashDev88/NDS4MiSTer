#define NDS_ALTERNATE_ORACLE_LIBRARY
#include "test_alternate_3d_rows.cpp"
static void expectedTiny(NDS& n) {
 render(n);auto&r=soft(n);auto&g=n.GPU.GPU3D;r.ClearBuffers();
 if(g.RenderDispCnt&(1u<<14))for(int y=0;y<192;++y)for(int x=0;x<64;++x){const auto row=r.FirstPixelOffset+y*r.ScanlineWidth;for(auto*buffer:{r.ColorBuffer,r.DepthBuffer,r.AttrBuffer})buffer[row+x]=buffer[row+4*x];}
 std::vector<Vertex*>seen;
 for(unsigned i=0;i<g.RenderNumPolygons;++i){auto*p=g.RenderPolygonRAM[i];p->XTop>>=2;p->XBottom>>=2;
  for(unsigned v=0;v<p->NumVertices;++v){auto*a=p->Vertices[v];if(std::find(seen.begin(),seen.end(),a)!=seen.end())continue;seen.push_back(a);a->FinalPosition[0]>>=2;a->HiresPosition[0]>>=2;}}
 r.SetupRenderPolygons(g.RenderPolygonRAM.data(),g.RenderNumPolygons);
 for(int y=0;y<192;++y)r.RenderScanline(y,r.PolygonList,r.ActivePolygonMask,r.PrevIsShadowMask,r.StencilBuffer,0,256,r.FinalPassMinX,r.FinalPassMaxX);
 for(int y=0;y<192;y+=4){const auto row=r.FirstPixelOffset+y*r.ScanlineWidth;
  for(auto*buffer:{r.ColorBuffer,r.DepthBuffer,r.AttrBuffer}){
   const std::vector<u32>snapshot(buffer+row,buffer+row+64);for(int x=0;x<256;++x)buffer[row+x]=snapshot[x/4];
   for(int dy=1;dy<4;++dy)std::copy_n(buffer+row,256,buffer+row+dy*r.ScanlineWidth);}
  for(int dy=0;dy<4;++dy){r.FinalPassMinX[y+dy]=0;r.FinalPassMaxX[y+dy]=256;}}
 for(int y=0;y<192;y+=4)r.ScanlineFinalPass(y);
 for(int y=0;y<192;y+=4)for(int dy=1;dy<4;++dy)std::copy_n(r.GetLine(y),256,r.GetLine(y+dy));
}
int main() try {
    unsigned cases=0;
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
            soft(*test).TinyRequested=true;
            expectedTiny(*ref);render(*test);compare(*ref,*test);++cases;
            unsigned vi=0;
            for(unsigned i=0;i<g.RenderNumPolygons;++i) {
                require(!std::memcmp(&original[i],g.RenderPolygonRAM[i],sizeof(Polygon)),"tiny altered guest polygon");
                for(unsigned v=0;v<g.RenderPolygonRAM[i]->NumVertices;++v)
                    require(!std::memcmp(&vertices[vi++],g.RenderPolygonRAM[i]->Vertices[v],sizeof(Vertex)),"tiny altered guest vertex");
            }
            // A same-geometry switch back to native must invalidate reuse.
            soft(*test).TinyRequested=false;
            frame(*ref,0);frame(*test,0);
            render(*ref);
            test->GPU.GPU3D.RenderFrameIdentical=true;
            test->GetRenderer().Start3DRendering();test->GetRenderer().Finish3DRendering();
            compare(*ref,*test);++cases;
        }
        soft(*test).TinyRequested=true;
        for(auto* n:{ref.get(),test.get()}) {frame(*n,0);n->GPU.GPU3D.RenderDispCnt|=16;}
        render(*ref);render(*test);
        require(!soft(*test).Tiny && !soft(*test).AlternateRows,"tiny AA fallback");
        compare(*ref,*test);++cases;
        if(scheduler>=2) {
            frame(*ref,0);frame(*test,0);expectedTiny(*ref);
            test->GPU.GPU3D.RenderFrameIdentical=false;
            test->GetRenderer().Start3DRendering();
            require(soft(*test).RequestFrameCancellation(),"tiny cancellation rejected");
            test->GetRenderer().Finish3DRendering();
            require(soft(*test).WasFrameCanceled(),"tiny fixture did not cancel");
            test->GPU.GPU3D.RenderFrameIdentical=true;
            test->GetRenderer().Start3DRendering();test->GetRenderer().Finish3DRendering();
            require(!soft(*test).IsFrameIdentical(),"tiny reused cancellation");
            compare(*ref,*test);++cases;
        }
    }
    // Lower-layer history must be rebuilt correctly when tiny rendering
    // returns to AA, including overlapping opaque/translucent fogged edges.
    for(unsigned scheduler=0;scheduler<5;++scheduler) {
        auto ref=make(0,false),test=make(scheduler,false);
        for(unsigned variation=0;variation<4;++variation) {
            for(auto* n:{ref.get(),test.get()}) {frame(*n,variation|32);n->GPU.GPU3D.RenderDispCnt&=~16u;}
            soft(*test).TinyRequested=true;
            expectedTiny(*ref);render(*test);compare(*ref,*test);++cases;
            for(auto* n:{ref.get(),test.get()}) {
                frame(*n,variation|1);
                auto& g=n->GPU.GPU3D;
                g.RenderDispCnt|=16|32|128;
                g.RenderFogColor=0x100c4210;std::fill_n(g.RenderFogDensityTable,34,64);
                std::fill_n(g.RenderEdgeTable,8,0x7c00);
                for(unsigned i=0;i<g.RenderNumPolygons;++i) {
                    auto* p=g.RenderPolygonRAM[i];
                    p->Attr=(p->Attr&~(31u<<16))|((i%3?15u:31u)<<16)|(1u<<15);
                }
            }
            render(*ref);render(*test);compare(*ref,*test);++cases;
        }
    }
    // Migrate damage between disjoint spans and through empty frames. Also
    // abandon a frame after its depth/attribute copy but before color copy:
    // the successor must still clear every old odd-row color word.
    for(unsigned scheduler=0;scheduler<5;++scheduler) for(bool quarter:{false,true}) {
        auto ref=make(0,false),test=make(scheduler,true);
        soft(*test).TinyRequested=quarter;
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
            if(quarter) expectedTiny(*ref); else expected(*ref);
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
    char controlPath[] = "/tmp/nds-tiny-control-XXXXXX";
    const int fd = mkstemp(controlPath);
    const u32 initial = nds4mister::GraphicsControl::AAOff;
    require(fd >= 0 && write(fd, &initial, 4) == 4, "tiny control create");
    close(fd);
    for (unsigned scheduler : {0u, 3u}) {
        auto ref = make(0, false);
        setenv("NDS4MISTER_GRAPHICS_CONTROL", controlPath, 1);
        nds4mister::GraphicsControl control(true);
        auto test = make(scheduler, false);
        unsetenv("NDS4MISTER_GRAPHICS_CONTROL");
        for (unsigned mode : {5u,4u,5u,1u,5u,3u,5u,2u,5u,0u,5u}) {
            control.set(mode==2, mode==1, mode==3, mode==4, mode==5);
            frame(*ref,0); frame(*test,0);
            ref->GPU.GPU3D.RenderDispCnt = 1 | (mode==2 ? 16u : 0u);
            test->GPU.GPU3D.RenderDispCnt = 17;
            if(mode==5) expectedTiny(*ref);
            else if(mode==4) expectedQuarter(*ref);
            else if(mode==1) expected(*ref);
            else render(*ref);
            test->GPU.GPU3D.RenderFrameIdentical = true;
            test->GetRenderer().Start3DRendering(); test->GetRenderer().Finish3DRendering();
            require(soft(*test).Tiny == (mode==5), "tiny control sampling");
            if(mode==3) { for(int y=0;y<192;++y)for(int x=0;x<256;++x)require(!soft(*test).GetLine(y)[x], "tiny off recovery"); }
            else compare(*ref,*test);
            require(test->GPU.GPU3D.RenderDispCnt==17,"tiny changed guest state");
            ++cases;
        }
    }
    unlink(controlPath);
    std::printf("PASS tiny 64x48 oracle cases=%u schedulers=5 repeated/sparse/empty/AA/shadow/cancel/live-resolution\n",cases);
    return 0;
} catch(const std::exception& e) {std::fprintf(stderr,"FAIL: %s\n",e.what());return 1;}
