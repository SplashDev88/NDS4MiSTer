// SPDX-License-Identifier: GPL-3.0-only
// The production software renderer independently supplies pixels and stencil.
#define main original_raster_benchmark_main
#include "../benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include <fstream>
#include <filesystem>
template<class T>void save(const std::string& path,const std::vector<T>& data){
 std::ofstream f(path,std::ios::binary);f.write(reinterpret_cast<const char*>(data.data()),data.size()*sizeof(T));require(bool(f),"fixture write");
}
static SoftRenderer3D& soft(NDS& n){return *static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n.GetRenderer()).Rend3D.get());}
static unsigned currentScenario=0;
int main(int argc,char** argv)try{
 require(argc==2,"output directory required");std::filesystem::create_directories(argv[1]);
 std::vector<uint32_t> control(0x100000/4),output(0x300000/4);
 for(unsigned scenario=0;scenario<192;scenario++){
  currentScenario=scenario;fpga3d::bind(nullptr,nullptr,false);
  auto ref=machine(true),test=machine(true);
  unsigned fixture=((scenario&1)?16384:0)|((scenario&2)?64:0)|((scenario&4)?16:0)|((scenario&8)?8:0)|(scenario%4);
  frame(*ref,fixture);frame(*test,fixture);
  std::vector<uint8_t> seed(512);for(unsigned i=0;i<512;i++)seed[i]=((i*7+scenario*3)>>3)&3;
  for(auto* n:{ref.get(),test.get()}){
   auto& g=n->GPU.GPU3D;g.RenderDispCnt=1|8|((scenario&1)?16:0);
   if(scenario&16)g.RenderDispCnt&=~8u;
   g.RenderClearAttr1=(g.RenderClearAttr1&~(31u<<16))|((scenario&2)?31u:0u)<<16;
   g.RenderAlphaRef=(scenario%13==0)?15:0;
   if(scenario&32){g.RenderDispCnt|=128;g.RenderFogColor=0x1712254a;g.RenderFogOffset=0;g.RenderFogShift=7;
    for(unsigned i=0;i<34;i++)g.RenderFogDensityTable[i]=(i*37+scenario)&127;}
   for(unsigned i=0;i<g.RenderNumPolygons;i++){
    auto* p=g.RenderPolygonRAM[i];
    unsigned role=i<2?0:i==2 || i==3 || i==6?2:3;
    if(scenario>=64 && scenario<96)role=1; // Ordinary decal with every texture alpha.
    if(scenario>=96 && scenario<128)role=3; // Seeded stencil, no clears.
    if(scenario>=128 && scenario<160)role=2; // Contiguous masks and frame-to-frame state.
    if(scenario>=160 && i==7)role=1; // Split mask groups with ordinary decals.
    unsigned alpha=role==0?31:(scenario&4)?31:1+(scenario*7+i*11)%30;
    p->Attr=0xc0|(alpha<<16)|(((i+scenario)%4)<<24)|((scenario&32)?1u<<15:0)|
        ((scenario&16)?1u<<11:0)|((scenario%7==0)?1u<<14:0);
    if(role)p->Attr|=(role==1?1u:3u)<<4;
    if(role==2)p->Attr&=~(63u<<24);
    p->IsShadowMask=role==2;p->IsShadow=role==3;p->Translucent=alpha<31;
    if(role==0 || (scenario%3==0))p->TexParam=0;
    for(unsigned v=0;v<p->NumVertices;v++){
     p->FinalZ[v]=(role==2?0x200000:role==3?0x080000:0x100000)+((scenario&2)?v*0x50000:0);
    }
   }
   std::memcpy(soft(*n).StencilBuffer,seed.data(),seed.size());soft(*n).PrevIsShadowMask=(scenario&8)!=0;
  }
  render(*ref);
  auto& s=soft(*test);s.FullFrameCompletion=true;
  std::fill(control.begin(),control.end(),0);control[0]=0x31443348;control[2]=17;
  control[(fpga3d::Mailbox-0x3fc00000+24)/4]=fpga3d::Magic;
  control[(fpga3d::Mailbox-0x3fc00000+28)/4]=17;fpga3d::poisonedSession=0;
#ifdef FPGA3D_EARLY_TIMEOUT_TEST
  fpga3d::bind(control.data(),output.data(),true,true);s.FpgaFrame.deadlineMs=0;
#else
  fpga3d::bind(control.data(),output.data(),true);
#endif
  render(*test);fpga3d::bind(nullptr,nullptr,false);
  std::vector<uint32_t> expected;
  for(unsigned y=0;y<192;y++){
   const auto* a=ref->GetRenderer().Get3DScanline(y);const auto* b=test->GetRenderer().Get3DScanline(y);
   require(!std::memcmp(a,b,1024),"shadow timeout fallback changed pixels");expected.insert(expected.end(),a,a+256);
  }
  require(!std::memcmp(soft(*ref).StencilBuffer,s.StencilBuffer,512),"shadow timeout fallback changed stencil");
  require(soft(*ref).PrevIsShadowMask==s.PrevIsShadowMask,"shadow timeout fallback changed mask grouping");
#ifdef FPGA3D_EARLY_TIMEOUT_TEST
  require(s.FpgaFrame.transportError && !s.FpgaFrame.active && fpga3d::poisonedSession==17,"shadow first-row timeout not quarantined");
#else
  require(s.FpgaFrame.valid && s.FpgaFrame.commands.size()>384,"shadow frame not admitted");
#endif
  auto prefix=std::string(argv[1])+"/"+std::to_string(scenario);
  save(prefix+".commands",s.FpgaFrame.commands);save(prefix+".textures",s.FpgaFrame.textures);save(prefix+".expected",expected);
  save(prefix+".stencil_input",seed);save(prefix+".stencil_expected",std::vector<uint8_t>(soft(*ref).StencilBuffer,soft(*ref).StencilBuffer+512));
  std::printf("SHADOW_EMIT_PASS scenario=%u commands=%zu\n",scenario,s.FpgaFrame.commands.size());
 }
 std::puts("PASS 192 production shadow/decal fixtures, seeded stencil and exact pixel/stencil/group timeout recovery");return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL scenario=%u %s\n",currentScenario,e.what());return 1;}
