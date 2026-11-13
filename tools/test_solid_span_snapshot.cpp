// SPDX-License-Identifier: GPL-3.0-or-later
// Saved GPU inputs only: no ROM execution, service lifecycle or board access.
#include "Args.h"
#include "NDS.h"
#include "Savestate.h"
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include "NDS4MiSTerSolidSpan.h"
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <vector>
#include <stdexcept>
using namespace melonDS;
static void require(bool v,const char* why){if(!v)throw std::runtime_error(why);}
int main(int argc,char** argv)try{
 require(argc==4,"snapshot integral sprite arguments required");
 unsetenv("NDS4MISTER_ADAPTIVE_RASTER_SPLIT");unsetenv("NDS4MISTER_RASTER_BAND_QUEUE");unsetenv("NDS4MISTER_ALTERNATE_3D_ROWS");
 setenv("NDS4MISTER_TEXTURE_HISTORY","1",1);unsetenv("NDS4MISTER_DISABLE_3D_AA");
 std::ifstream input(argv[1],std::ios::binary|std::ios::ate);require(bool(input),"snapshot missing");
 const auto len=input.tellg();require(len>0 && len<64*1024*1024,"snapshot bounds");input.seekg(0);
 std::vector<u8> data(static_cast<size_t>(len));input.read(reinterpret_cast<char*>(data.data()),len);require(bool(input),"snapshot read");
 for(unsigned dual=0;dual<2;++dual)for(unsigned aa=0;aa<2;++aa){
  if(dual)setenv("NDS4MISTER_DUAL_CORE_3D","1",1);else unsetenv("NDS4MISTER_DUAL_CORE_3D");
  auto load=[&](bool enabled){
   setenv("NDS4MISTER_SOLID_SPANS",enabled?"1":"0",1);
   NDSArgs args;args.JIT=std::nullopt;auto n=std::make_unique<NDS>(std::move(args));n->Reset();
   RendererSettings settings{};settings.Threaded=false;settings.ScaleFactor=1;settings.FullFrame3D=true;settings.PackedOutput=true;n->GetRenderer().SetRenderSettings(settings);
   Savestate in(data.data(),data.size(),false);n->GPU.DoSavestate(&in);require(!in.Error,"snapshot decode");n->GetRenderer().Finish3DRendering();auto& g=n->GPU.GPU3D;
   g.SetEnabled(true,true);g.SetExternalCommandReplay(true);g.SetIntegralTextureSpansEnabled(std::stoi(argv[2]));g.SetSpriteRasterSpansEnabled(std::stoi(argv[3]));g.RenderFrameIdentical=false;
   if(aa)g.RenderDispCnt|=16;else g.RenderDispCnt&=~16u;
   auto& s=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n->GetRenderer()).Rend3D.get());require(s.SolidSpansOverride==int(enabled),"runtime experiment override not applied");
   require(s.DualCoreRaster==bool(dual),"worker mode not applied");return n;
  };
  auto a=load(false),b=load(true);auto draw=[](NDS& n){n.GetRenderer().Start3DRendering();n.GetRenderer().Finish3DRendering();};
  fpga3d::bind(nullptr,nullptr,false);draw(*a);
#ifdef NDS4MISTER_SOLID_SPAN_TEST
  const auto before=SolidSpanTestPixels.load();
#endif
  draw(*b);
  auto& sa=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(a->GetRenderer()).Rend3D.get());
  auto& sb=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(b->GetRenderer()).Rend3D.get());
  for(unsigned y=0;y<192;++y)require(!std::memcmp(a->GetRenderer().Get3DScanline(y),b->GetRenderer().Get3DScanline(y),1024),"saved visible pixels differ");
  require(!std::memcmp(sa.ColorBuffer,sb.ColorBuffer,sizeof(sa.ColorBuffer)),"saved color plane differs");
  require(!std::memcmp(sa.DepthBuffer,sb.DepthBuffer,sizeof(sa.DepthBuffer)),"saved depth plane differs");
  require(!std::memcmp(sa.AttrBuffer,sb.AttrBuffer,sizeof(sa.AttrBuffer)),"saved attributes differ");
  std::cout<<"SOLID_SNAPSHOT dual="<<dual<<" aa="<<aa<<" lower_layer="<<sb.LowerLayerBufferSize;
#ifdef NDS4MISTER_SOLID_SPAN_TEST
  const auto used=SolidSpanTestPixels.load()-before;
  require(!aa || !used,"AA-on entered solid shortcut");
  require(!sb.LowerLayerBufferSize || !used,"backing-layer frame entered shortcut");
  std::cout<<" shortcut_pixels="<<used;
#endif
  std::cout<<" visible_pixels=49152 native_planes_equal=1\n";
 }
 std::cout<<"SOLID_SNAPSHOT_PASS comparisons=4 visible_pixels=196608\n";return 0;
}catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
