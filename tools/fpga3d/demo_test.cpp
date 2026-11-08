// SPDX-License-Identifier: GPL-3.0-only
#include "melonds/MelonDsBackend.h"
#include "NDS.h"
#include "GPU3D.h"
#include <fstream>
#include <iostream>
#include <set>
int main(int argc,char** argv){
 if(argc!=3)return 2;
 nds4mister::MelonDsBackend backend("build-fpga3d/demo-saves");std::string error;
 if(!backend.load_rom(argv[1],error)){std::cerr<<error;return 1;}
 for(int i=0;i<40;i++){nds4mister::FrameTimings t;if(!backend.run_frame(t,error)){std::cerr<<error;return 1;}}
 auto& n=*backend.nds_;auto& r=n.GPU.GetRenderer();r.Finish3DRendering();
 std::ofstream ppm(argv[2],std::ios::binary);ppm<<"P6\n256 192\n255\n";std::set<unsigned> colors;
 for(unsigned y=0;y<192;y++)for(unsigned x=0;x<256;x++){
  unsigned c=r.Get3DScanline(y)[x];colors.insert(c);
  for(int k=0;k<3;k++)ppm.put(char(((c>>(8*k))&63)*255/63));
 }
 unsigned frames=n.ARM9Read32(0x023e0000);
 std::cout<<"DEMO frames="<<frames<<" colors="<<colors.size()<<" polygons="<<n.GPU.GPU3D.RenderNumPolygons<<"\n";
 return frames>=30 && colors.size()>100?0:1;
}
