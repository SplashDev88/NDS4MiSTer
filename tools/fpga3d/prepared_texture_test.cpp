// SPDX-License-Identifier: GPL-3.0-only
// Actual GX/renderer output is the independent oracle for the RTL fixtures.
#define main original_raster_benchmark_main
#include "../benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include <filesystem>
#include <fstream>

static SoftRenderer3D& soft(NDS& n) {
 return *static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n.GetRenderer()).Rend3D.get());
}
template<class T> static void save(const std::string& path,const std::vector<T>& data) {
 std::ofstream f(path,std::ios::binary);
 f.write(reinterpret_cast<const char*>(data.data()),data.size()*sizeof(T));
 require(bool(f),"write fixture");
}
static unsigned currentVariant=0,currentStep=0;
int main(int argc,char** argv)try {
 require(argc==2,"fixture directory required");std::filesystem::create_directories(argv[1]);
 std::vector<uint32_t> control(0x100000/4),output(0x300000/4);
 unsigned captures=0;
 std::ofstream manifest(std::string(argv[1])+"/scenarios.json");manifest<<"[\n";
 fpga3d::adaptiveAdmission=true;fpga3d::textureTrafficGuard=false;
 fpga3d::preparedTexturesEnabled=true;
 auto emit=[&](NDS& n,bool early) {
  std::fill(control.begin(),control.end(),0);control[0]=0x31443348;control[2]=23;
  control[(fpga3d::Mailbox-0x3fc00000+24)/4]=fpga3d::Magic;
  control[(fpga3d::Mailbox-0x3fc00000+28)/4]=23;
  fpga3d::poisonedSession=0;soft(n).FullFrameCompletion=true;
  soft(n).FpgaFrame.deadlineMs=early?0:1;
  fpga3d::bind(control.data(),output.data(),true,early);
  render(n);fpga3d::bind(nullptr,nullptr,false);
 };
 for(unsigned variant:{0u,24u,0x10000018u,0x10004010u}) {
  currentVariant=variant;
  auto ref=machine(true),test=machine(true);
  frame(*ref,variant);frame(*test,variant);
  for(auto* n:{ref.get(),test.get()}) {
   auto& g=n->GPU.GPU3D;g.RenderDispCnt=1|8|16;
   if(variant&0x10000000u) {
    for(unsigned i=0;i<32768;i++)n->GPU.VRAM_A[i]=uint8_t(i*37+(i>>7)*13);
    std::memset(n->GPU.VRAMDirty[0].Data,255,sizeof(n->GPU.VRAMDirty[0].Data));
    for(unsigned i=0;i<g.RenderNumPolygons;i++) {
     g.RenderPolygonRAM[i]->TexParam|=(5u<<20)|(5u<<23);
     g.RenderPolygonRAM[i]->TexPalette=i%5;
    }
   }
  }
  for(unsigned step=0;step<10;step++) {
   currentStep=step;
   for(auto* n:{ref.get(),test.get()}) {
    auto& g=n->GPU.GPU3D;
    if(step==2)std::swap(g.RenderPolygonRAM[2],g.RenderPolygonRAM[3]);
    if(step==3) {
     auto* p=g.RenderPolygonRAM[3];
     for(unsigned v=0;v<p->NumVertices;v++)p->Vertices[v]->FinalPosition[1]++;
     p->YTop++;p->YBottom++;
    }
    if(step==4 || step==7) {
     n->GPU.VRAM_A[0]^=255;
     std::memset(n->GPU.VRAMDirty[0].Data,255,sizeof(n->GPU.VRAMDirty[0].Data));
    }
    if(step==5) {
     for(unsigned i=0;i<512;i++)n->GPU.VRAM_E[i]^=0x1f;
     std::memset(n->GPU.VRAMDirty[4].Data,255,sizeof(n->GPU.VRAMDirty[4].Data));
    }
    if(step==6)g.RenderPolygonRAM[0]->TexParam^=1u<<20;
   }
   render(*ref);
   const auto hits=soft(*test).FpgaFrame.preparedHits;
   emit(*test,step==8);
   const auto& f=soft(*test).FpgaFrame;
   for(unsigned y=0;y<192;y++)require(!std::memcmp(ref->GetRenderer().Get3DScanline(y),test->GetRenderer().Get3DScanline(y),1024),"timeout fallback differs from native renderer");
   if(step==1 || step==2 || step==3 || step==9)require(f.preparedHits==hits+1,"unchanged texture set did not reuse preparation");
   if(step==4 || step==5 || step==6 || step==7)require(f.preparedHits==hits,"changed texture content/size reused stale preparation");
   if(step==8){require(f.transportError,"early timeout missing");continue;}
   require(f.valid && f.commands.size()>384,"production fixture was not emitted");
   if(variant&0x10000000u)require(f.allowIndexed &&
       std::any_of(f.textureOffsets.begin(),f.textureOffsets.end(),[](const auto& item){return item.second&1u;}) &&
       std::any_of(f.textureOffsets.begin(),f.textureOffsets.end(),[](const auto& item){return !(item.second&1u);}),
       "large fixture missed simultaneous raw/indexed bindings");
   std::vector<uint32_t> expected;
   for(unsigned y=0;y<192;y++) {
    const auto* p=ref->GetRenderer().Get3DScanline(y);expected.insert(expected.end(),p,p+256);
   }
   const auto prefix=std::string(argv[1])+"/"+std::to_string(captures);
   save(prefix+".commands",f.commands);save(prefix+".textures",f.textures);save(prefix+".expected",expected);
   if(captures)manifest<<",\n";
   manifest<<"{\"fixture\":"<<captures<<",\"variant\":"<<variant<<",\"step\":"<<step<<",\"hits\":"<<f.preparedHits<<"}";
   captures++;
  }
 }
 manifest<<"\n]\n";
 std::printf("PASS %u production fixtures: raw/indexed preparation, warm reuse, reordered and moving geometry, texture/palette/size invalidation, exact native fallback and early-timeout recovery\n",captures);
 return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL variant=%u step=%u %s\n",currentVariant,currentStep,e.what());return 1;}
