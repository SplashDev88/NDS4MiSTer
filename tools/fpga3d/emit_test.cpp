// SPDX-License-Identifier: GPL-3.0-only
// Production GX setup -> command emission -> simulator fixtures. A deliberate
// hardware timeout proves the untouched software renderer recovers exact state.
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
int main(int argc,char** argv)try{
 require(argc==2,"output directory required");std::filesystem::create_directories(argv[1]);
 std::vector<uint32_t> control(0x100000/4),output(0x300000/4);
 unsigned captures=0;
 for(unsigned scenario=0;scenario<48;scenario++){
  fpga3d::bind(nullptr,nullptr,false);
  auto ref=machine(true),test=machine(true);
  unsigned fixture=((scenario&1)?16384:0)|((scenario&2)?8192:0)|((scenario&4)?64:0)|((scenario&8)?16:0)|((scenario&16)?8:0)|((scenario&32)?3:0);
  frame(*ref,fixture);frame(*test,fixture);
  for(auto* n:{ref.get(),test.get()})n->GPU.GPU3D.RenderDispCnt=1|8;
  if(scenario>=40)for(auto* n:{ref.get(),test.get()}){
   auto& g=n->GPU.GPU3D;
   if(scenario<44)g.RenderDispCnt|=1u<<(scenario==40?4:scenario==41?5:scenario==42?7:14);
   else if(scenario==44)for(unsigned i=0;i<g.RenderNumPolygons;i++){g.RenderPolygonRAM[i]->Attr&=~(31u<<16);g.RenderPolygonRAM[i]->Attr|=15u<<16;}
   else if(scenario==45)for(unsigned i=0;i<g.RenderNumPolygons;i++)g.RenderPolygonRAM[i]->Attr&=~(31u<<16);
   else if(scenario==46)for(unsigned i=0;i<g.RenderNumPolygons;i++){g.RenderPolygonRAM[i]->Attr=(g.RenderPolygonRAM[i]->Attr&~48u)|32u;}
   else for(unsigned i=0;i<g.RenderNumPolygons;i++){g.RenderPolygonRAM[i]->IsShadow=true;}
  }
  render(*ref);
  auto& soft=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(test->GetRenderer()).Rend3D.get());
  soft.FullFrameCompletion=true;
  std::fill(control.begin(),control.end(),0);control[0]=0x31443348;control[2]=17;
  control[(fpga3d::Mailbox-0x3fc00000+24)/4]=fpga3d::Magic;
  control[(fpga3d::Mailbox-0x3fc00000+28)/4]=17;
  fpga3d::poisonedSession=0;
  fpga3d::bind(control.data(),output.data(),true);
  render(*test);fpga3d::bind(nullptr,nullptr,false);
  std::vector<uint32_t> expected;
  for(unsigned y=0;y<192;y++){
   const auto* a=ref->GetRenderer().Get3DScanline(y);const auto* b=test->GetRenderer().Get3DScanline(y);
   require(!std::memcmp(a,b,1024),"timeout fallback changed software pixels");expected.insert(expected.end(),a,a+256);
  }
  if(scenario>=40){require(soft.FpgaFrame.commands.empty(),"unsupported frame submitted");std::printf("FALLBACK_PASS scenario=%u\n",scenario);continue;}
  require(soft.FpgaFrame.valid && soft.FpgaFrame.commands.size()>384,"fixture not admitted");
  auto prefix=std::string(argv[1])+"/"+std::to_string(captures);
  save(prefix+".commands",soft.FpgaFrame.commands);save(prefix+".textures",soft.FpgaFrame.textures);save(prefix+".expected",expected);
  std::printf("EMIT_PASS scenario=%u commands=%zu\n",scenario,soft.FpgaFrame.commands.size());captures++;
 }
 std::printf("PASS %u production geometry/raster fixtures and exact timeout fallback\n",captures);return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
