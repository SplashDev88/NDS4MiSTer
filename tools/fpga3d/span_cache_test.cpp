// SPDX-License-Identifier: GPL-3.0-only
#define main original_raster_benchmark_main
#include "../benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"

static unsigned currentVariant=0,currentStep=0;static bool currentPacked=false;
static SoftRenderer3D& soft(NDS& n) {
 return *static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n.GetRenderer()).Rend3D.get());
}
static void change(NDS& n,unsigned kind) {
 auto& g=n.GPU.GPU3D;auto& p=*g.RenderPolygonRAM[3];
 switch(kind) {
 case 0: p.Vertices[0]->FinalPosition[0]++;break;
 case 1: for(unsigned v=0;v<p.NumVertices;v++)p.Vertices[v]->FinalPosition[1]++;p.YTop++;p.YBottom++;break;
 case 2: p.Vertices[0]->FinalColor[0]^=8;break;
 case 3: p.Vertices[0]->FinalColor[1]^=8;break;
 case 4: p.Vertices[0]->FinalColor[2]^=8;break;
 case 5: p.Vertices[0]->TexCoords[0]++;break;
 case 6: p.Vertices[0]->TexCoords[1]++;break;
 case 7: p.FinalW[0]+=16;break;
 case 8: p.FinalZ[0]+=4096;break;
 case 9: p.Attr^=1u<<11;break;
 case 10: p.Attr^=1u<<14;break;
 case 11: p.Attr^=1u<<24;break;
 case 12: p.Attr=(p.Attr&~(31u<<16))|(15u<<16);break;
 case 13: p.TexParam^=1u<<18;break;
 case 14: p.TexPalette^=1;break;
 case 15:
  p.FacingView=!p.FacingView;
  std::reverse(p.Vertices,p.Vertices+p.NumVertices);
  std::reverse(p.FinalZ,p.FinalZ+p.NumVertices);
  std::reverse(p.FinalW,p.FinalW+p.NumVertices);
  p.VTop=p.NumVertices-1-p.VTop;p.VBottom=p.NumVertices-1-p.VBottom;break;
 case 16: p.WBuffer=!p.WBuffer;break;
 case 17: g.RenderAlphaRef^=15;break;
 case 18: g.RenderDispCnt^=16;break;
 case 19: g.RenderDispCnt^=8;break;
 case 20: p.TexParam^=1u<<20;break;
 case 21: p.TexParam^=1u<<23;break;
 case 22: g.RenderDispCnt^=1;break;
 case 23: std::swap(g.RenderPolygonRAM[2],g.RenderPolygonRAM[3]);break;
 case 24: n.GPU.VRAM_A[0]^=255;std::memset(n.GPU.VRAMDirty[0].Data,255,sizeof(n.GPU.VRAMDirty[0].Data));break;
 case 25: g.RenderPolygonRAM[0]->TexParam^=1u<<20;break;
 case 26: p.TexParam=(p.TexParam&~(7u<<26))|(7u<<26);break;
 case 27: p.TexParam=(p.TexParam&~(7u<<26))|(4u<<26);break;
 case 28: p.Attr=(p.Attr&~48u)|32u;break;
 case 29: for(auto& c:g.RenderToonTable)c^=0x7fff;break;
 }
}
int main()try {
 std::vector<uint32_t> control(0x100000/4),output(0x300000/4);
 auto emit=[&](NDS& n,bool early=false,bool packed=false) {
  std::fill(control.begin(),control.end(),0);control[0]=0x31443348;control[2]=19;
  control[(fpga3d::Mailbox-0x3fc00000+24)/4]=fpga3d::Magic;
  control[(fpga3d::Mailbox-0x3fc00000+28)/4]=19;
  fpga3d::poisonedSession=0;soft(n).FullFrameCompletion=true;
  soft(n).FpgaFrame.deadlineMs=early?0:packed?100:1;
  fpga3d::bind(control.data(),output.data(),true,early || packed);
  render(n);fpga3d::bind(nullptr,nullptr,false);
 };
 auto commands=[&](NDS& n) {
  const auto& f=soft(n).FpgaFrame;std::vector<fpga3d::PackedCommand> result;
  if(!f.recyclePublished)for(const auto& c:f.commands)result.push_back(fpga3d::pack(c));
  else {
   const uint32_t* p=f.commandBase==fpga3d::Commands?
       control.data()+(f.commandBase-0x3fc00000)/4:
       output.data()+(f.commandBase-0x3fd00000)/4;
   for(size_t i=0;i<f.published;i++) {
    fpga3d::PackedCommand c;std::copy_n(p+i*16,16,c.begin());result.push_back(c);
   }
  }
  return result;
 };
 unsigned comparisons=0;
 for(bool packed:{false,true}) {
 currentPacked=packed;
 for(unsigned variant:{0u,8u,16u,24u,16384u|8u,16384u|24u,0x10000000u,0x10000018u}) {
  currentVariant=variant;
  auto ref=machine(true),test=machine(true);
  frame(*ref,variant);frame(*test,variant);
  if(variant&0x10000000u)for(auto* n:{ref.get(),test.get()}){
   for(unsigned i=0;i<32768;i++)n->GPU.VRAM_A[i]=uint8_t((i*37+(i>>7)*13)&255);
   std::memset(n->GPU.VRAMDirty[0].Data,255,sizeof(n->GPU.VRAMDirty[0].Data));
   auto& g=n->GPU.GPU3D;
   for(unsigned i=0;i<g.RenderNumPolygons;i++)g.RenderPolygonRAM[i]->TexParam|=(4u<<20)|(4u<<23);
  }
  ref->GPU.GPU3D.RenderDispCnt=test->GPU.GPU3D.RenderDispCnt=1|8|16;
  soft(*ref).FpgaSpanCacheEnabled=false;
  for(unsigned step=0;step<33;step++) {
   currentStep=step;
   // Alternate runtime raw admission with forced indexed fixture encoding.
   // Unchanged polygons must rebind cached commands across either format.
   fpga3d::adaptiveAdmission=(step&1)!=0;
   if(step==2) {change(*ref,23);change(*test,23);}
   if(step>=3) {change(*ref,step-3);change(*test,step-3);}
   emit(*ref);const auto expected=commands(*ref);emit(*test,false,packed);
   require(soft(*ref).FpgaFrame.valid==soft(*test).FpgaFrame.valid,"cache changed span admission");
   require(expected==commands(*test),"cached physical commands differ from cold producer");
   if(!packed)require(soft(*ref).FpgaFrame.commands==soft(*test).FpgaFrame.commands,"cached logical commands differ from cold producer");
   require(soft(*ref).FpgaFrame.textures==soft(*test).FpgaFrame.textures,"cached frame reused stale texture contents");
   for(unsigned y=0;y<192;y++)require(!std::memcmp(ref->GetRenderer().Get3DScanline(y),test->GetRenderer().Get3DScanline(y),1024),"cached timeout fallback changed pixels");
   if(step==1 || step==2)require(soft(*test).FpgaFrame.valid && soft(*test).FpgaSpanCacheHits==10 && soft(*test).FpgaSpanCacheCommands>0,"identical or reordered geometry did not hit cache");
   if(step>=3 && step<27 && step-3!=14 && step-3!=23)require(soft(*test).FpgaSpanCacheHits<10,"changed span inputs did not invalidate");
   comparisons++;
  }
  // Start with empty entries, interrupt production on the first row, then
  // recover into a complete frame. Partial entries must never be reused.
  fpga3d::adaptiveAdmission=false;
  soft(*test).FpgaSpanCache.clear();soft(*test).FpgaSpanCacheScratch.clear();emit(*test,true);
  require(soft(*test).FpgaFrame.transportError,"early timeout missing");
  emit(*ref);const auto expected=commands(*ref);emit(*test,false,packed);
  require(expected==commands(*test),"partial cache survived early timeout");
  comparisons++;
 }
 }
 std::printf("PASS %u cold/cached logical and streamed physical command, fresh-texture and native-fallback comparisons; all vertex/render input invalidations and early producer timeouts\n",comparisons);
 return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL packed=%u variant=%u step=%u %s\n",currentPacked,currentVariant,currentStep,e.what());return 1;}
