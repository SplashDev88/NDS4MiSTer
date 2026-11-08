// SPDX-License-Identifier: GPL-3.0-only
#include "melonds/MelonDsBackend.h"
#include "NDS.h"
#include "GPU3D.h"
#include "GPU_Soft.h"
#include <fstream>
#include <iostream>
#include <set>
int main(int argc,char** argv){
 if(argc!=3 && argc!=4)return 2;
 nds4mister::MelonDsBackend backend("build-fpga3d/demo-saves");std::string error;
 if(!backend.load_rom(argv[1],error)){std::cerr<<error;return 1;}
 for(int i=0;i<40;i++){nds4mister::FrameTimings t;if(!backend.run_frame(t,error)){std::cerr<<error;return 1;}}
 auto& n=*backend.nds_;auto& r=n.GPU.GetRenderer();r.Finish3DRendering();
 std::ofstream ppm(argv[2],std::ios::binary);ppm<<"P6\n256 192\n255\n";std::set<unsigned> colors;
 std::vector<uint32_t> expected;
 for(unsigned y=0;y<192;y++)for(unsigned x=0;x<256;x++){
  unsigned c=r.Get3DScanline(y)[x];colors.insert(c);
  expected.push_back(c);
  for(int k=0;k<3;k++)ppm.put(char(((c>>(8*k))&63)*255/63));
 }
 unsigned frames=n.ARM9Read32(0x023e0000);
 std::cout<<"DEMO frames="<<frames<<" colors="<<colors.size()<<" polygons="<<n.GPU.GPU3D.RenderNumPolygons<<"\n";
 if(argc==4){
  std::vector<uint32_t> control(0x100000/4),output(0x300000/4);
  control[0]=0x31443348;control[2]=17;
  control[(fpga3d::Mailbox-0x3fc00000+24)/4]=fpga3d::Magic;
  control[(fpga3d::Mailbox-0x3fc00000+28)/4]=17;
  auto& soft=*static_cast<melonDS::SoftRenderer3D*>(r.Rend3D.get());
  soft.SetFullFrameCompletion(true);fpga3d::poisonedSession=0;
  fpga3d::bind(control.data(),output.data(),true);
  n.GPU.GPU3D.RenderFrameIdentical=false;r.Start3DRendering();r.Finish3DRendering();
  fpga3d::bind(nullptr,nullptr,false);
  if(!soft.FpgaFrame.valid || soft.FpgaFrame.commands.size()<=384)return 3;
  for(unsigned y=0;y<192;y++)for(unsigned x=0;x<256;x++)
   if(r.Get3DScanline(y)[x]!=expected[y*256+x])return 4;
  auto save=[&](const char* suffix,const void* bytes,size_t size){
   std::ofstream f(std::string(argv[3])+suffix,std::ios::binary);f.write(static_cast<const char*>(bytes),size);
   if(!f)throw std::runtime_error("fixture write failed");
  };
  save(".commands",soft.FpgaFrame.commands.data(),soft.FpgaFrame.commands.size()*sizeof(fpga3d::Command));
  save(".textures",soft.FpgaFrame.textures.data(),soft.FpgaFrame.textures.size()*4);
  save(".expected",expected.data(),expected.size()*4);
  std::cout<<"DEMO_EMIT commands="<<soft.FpgaFrame.commands.size()<<" texture_bytes="<<soft.FpgaFrame.textures.size()*4<<" exact_fallback=1\n";
 }
 return frames>=30 && colors.size()>100?0:1;
}
