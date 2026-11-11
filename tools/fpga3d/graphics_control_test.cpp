// SPDX-License-Identifier: GPL-3.0-only
// Exercise the real host control mapping against independent native pixels.
#define main original_raster_benchmark_main
#include "../benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include <filesystem>
#include <fstream>
template<class T>static void save(const std::string& path,const std::vector<T>& data){
 std::ofstream f(path,std::ios::binary);f.write(reinterpret_cast<const char*>(data.data()),data.size()*sizeof(T));require(bool(f),"fixture write");
}
static SoftRenderer3D& soft(NDS& n){return *static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n.GetRenderer()).Rend3D.get());}
int main(int argc,char** argv)try{
 require(argc==2,"output directory required");std::filesystem::create_directories(argv[1]);
 char path[]="/tmp/nds-fpga-aa-XXXXXX";const int fd=mkstemp(path);
 uint32_t initial=nds4mister::GraphicsControl::AAOn;
 require(fd>=0 && write(fd,&initial,4)==4,"control file creation");close(fd);
 std::vector<uint32_t> control(0x100000/4),output(0x300000/4,0xa1b2c3d4);
 unsigned captures=0;
 for(unsigned fixture:{0u,9u,64u,16384u|8192u|64u,16384u|16u|3u,16384u|8192u|3u}){
  fpga3d::bind(nullptr,nullptr,false);auto ref=machine(false);
  setenv("NDS4MISTER_GRAPHICS_CONTROL",path,1);
  nds4mister::GraphicsControl host(true);auto test=machine(true);
  unsetenv("NDS4MISTER_GRAPHICS_CONTROL");
  frame(*ref,fixture);frame(*test,fixture);
  for(bool aa:{false,true,false}){
   host.set(aa,false);
   for(auto* n:{ref.get(),test.get()}){
    auto& g=n->GPU.GPU3D;g.RenderDispCnt=1|8|32|128|((n==test.get() || aa)?16:0);
    g.RenderClearAttr1|=1u<<15;
    g.RenderFogColor=0x001f1234;g.RenderFogOffset=0;g.RenderFogShift=6;
    for(unsigned i=0;i<34;i++)g.RenderFogDensityTable[i]=(i*3)&127;
    for(unsigned i=0;i<8;i++)g.RenderEdgeTable[i]=(i*1234)&0x7fff;
   }
   fpga3d::bind(nullptr,nullptr,false);render(*ref);
   std::fill(control.begin(),control.end(),0);control[0]=0x31443348;control[2]=17;
   control[(fpga3d::Mailbox-0x3fc00000+24)/4]=fpga3d::Magic;
   control[(fpga3d::Mailbox-0x3fc00000+28)/4]=17;
   fpga3d::poisonedSession=0;fpga3d::adaptiveAdmission=false;
   auto& s=soft(*test);s.FullFrameCompletion=true;s.FpgaFrame.deadlineMs=1;
   fpga3d::bind(control.data(),output.data(),true);
   // After the first capture, unchanged guest state still must notice AA.
   test->GPU.GPU3D.RenderFrameIdentical=captures%3!=0;
   auto& renderer=test->GetRenderer();renderer.Start3DRendering();renderer.Finish3DRendering();
   for(unsigned y=0;y<192;y++)require(renderer.Get3DScanline(y),"native fallback plane");
   fpga3d::bind(nullptr,nullptr,false);
   require(bool(s.EffectiveDispCnt&16)==aa && !s.FrameIdentical,"live AA transition was ignored");
   require(s.FpgaFrame.valid && s.FpgaFrame.commands.size()>384,"AA fixture did not emit FPGA commands");
   for(const auto& c:s.FpgaFrame.commands)if(c[0]==1)require(bool(c[6]&16)==aa,"FPGA clear ignored effective AA control");
   std::vector<uint32_t> expected;
   for(unsigned y=0;y<192;y++){
    const auto* a=ref->GetRenderer().Get3DScanline(y);const auto* b=test->GetRenderer().Get3DScanline(y);
    require(!std::memcmp(a,b,1024),"AA integration timeout fallback differs from native oracle");
    expected.insert(expected.end(),a,a+256);
   }
   const auto prefix=std::string(argv[1])+"/"+std::to_string(captures++);
   save(prefix+".commands",s.FpgaFrame.commands);save(prefix+".textures",s.FpgaFrame.textures);save(prefix+".expected",expected);
  }
  for(unsigned mode=0;mode<4;mode++){
   host.set(false,mode==0,mode==3,mode==1,mode==2);
   std::fill(control.begin(),control.end(),0);control[0]=0x31443348;control[2]=17;
   control[(fpga3d::Mailbox-0x3fc00000+24)/4]=fpga3d::Magic;
   control[(fpga3d::Mailbox-0x3fc00000+28)/4]=17;
   const auto before=control,beforeOutput=output;fpga3d::poisonedSession=0;
   fpga3d::bind(control.data(),output.data(),true);render(*test);fpga3d::bind(nullptr,nullptr,false);
   require(control==before,"diagnostic resolution acquired FPGA command ownership");
   require(output==beforeOutput,"diagnostic resolution changed FPGA publication memory");
  }
 }
 unlink(path);std::printf("PASS %u native AA/control fixtures, 24 reduced/off admission checks and exact timeout fallback\n",captures);return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
