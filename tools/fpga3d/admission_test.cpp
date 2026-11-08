// SPDX-License-Identifier: GPL-3.0-only
#define main original_raster_benchmark_main
#include "../benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
int main() try {
 require(!fpga3d::lightScene(31,0) && fpga3d::lightScene(32,32767) &&
     !fpga3d::lightScene(32,32768),"work admission boundary");
 fpga3d::Admission policy;policy.unsupported();
 for(unsigned i=0;i<60;i++)require(policy.defer(),"early admission retry");
 require(!policy.defer(),"unbounded admission backoff");
 policy.unsupported();policy.reset();require(!policy.defer(),"admission reset");
 for(unsigned scenario=0;scenario<16;scenario++){
  fpga3d::bind(nullptr,nullptr,false);fpga3d::adaptiveAdmission=false;
  auto ref=machine(true),test=machine(true);
  unsigned fixture=16384u|8192u|64u|((scenario&1)?16u:0)|((scenario&2)?8u:0)|(scenario&3);
  frame(*ref,fixture);frame(*test,fixture);
  auto get=[](NDS& n)->SoftRenderer3D&{return *static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n.GetRenderer()).Rend3D.get());};
  for(auto* n:{ref.get(),test.get()}){
   n->GPU.GPU3D.RenderDispCnt=1|8|((scenario&4)?16:0)|((scenario&8)?128:0);
   for(unsigned i=0;i<512;i++)get(*n).StencilBuffer[i]=(i+scenario)&3;
   get(*n).PrevIsShadowMask=(scenario&1)!=0;
  }
  render(*ref);
  std::vector<uint32_t> control(0x100000/4),output(0x300000/4,0xa1b2c3d4);
  control[0]=0x31443348;control[2]=17;
  control[(fpga3d::Mailbox-0x3fc00000+24)/4]=fpga3d::Magic;
  control[(fpga3d::Mailbox-0x3fc00000+28)/4]=17;
  const auto untouched=control;auto& soft=get(*test);soft.FullFrameCompletion=true;
  soft.FpgaAdmission.cooldown=1;fpga3d::poisonedSession=0;
  fpga3d::adaptiveAdmission=true;fpga3d::bind(control.data(),output.data(),true,true);
  render(*test);fpga3d::bind(nullptr,nullptr,false);fpga3d::adaptiveAdmission=false;
  require(control==untouched && std::all_of(output.begin(),output.end(),[](auto x){return x==0xa1b2c3d4;}),"deferred frame touched shared memory");
  require(soft.FpgaAdmission.cooldown==0 && soft.FpgaFrame.commands.empty() && !soft.FpgaFrame.active,"deferred frame acquired ownership");
  for(unsigned y=0;y<192;y++)require(!std::memcmp(ref->GetRenderer().Get3DScanline(y),test->GetRenderer().Get3DScanline(y),1024),"admission fallback pixels");
  require(!std::memcmp(get(*ref).StencilBuffer,soft.StencilBuffer,512) && get(*ref).PrevIsShadowMask==soft.PrevIsShadowMask,"admission fallback stencil state");
 }
 puts("PASS adaptive admission: 60-frame bounded retry, reset, work boundaries, 786432 exact native fallback pixels and untouched mailbox/arenas");
 return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
