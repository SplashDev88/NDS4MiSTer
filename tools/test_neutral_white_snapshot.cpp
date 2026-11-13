// SPDX-License-Identifier: GPL-3.0-or-later
#include "Args.h"
#include "NDS.h"
#include "Savestate.h"
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include "NDS4MiSTerNeutralWhite.h"
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <vector>
#include <stdexcept>
using namespace melonDS;
static void require(bool v,const char* why){if(!v)throw std::runtime_error(why);}
static void dump(NDS& n,const std::string& path){std::ofstream f(path,std::ios::binary);require(bool(f),"dump path");for(unsigned y=0;y<192;++y)f.write(reinterpret_cast<char*>(n.GetRenderer().Get3DScanline(y)),1024);require(bool(f),"dump write");}
static void kernel(){
 uint32_t seed=0x1a39bc87;uint64_t count=0;alignas(16)u32 in[4],out[4];
 auto next=[&](){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;};
 auto check=[&](){vst1q_u32(out,NDS4MiSTerNeutralWhiteModulate4(vld1q_u32(in)));for(unsigned i=0;i<4;++i){require(out[i]==NDS4MiSTerModulateCachedOpaquePixel(in[i],0x3f3f3f),"neutral white scalar equivalence");++count;}};
 for(unsigned a=0;a<256;++a)for(unsigned v=0;v<256;v+=4){
  for(unsigned i=0;i<4;++i)in[i]=(a<<24)|((v+i)<<16)|((255-v-i)<<8)|(v+i);
  check();
 }
 for(unsigned n=0;n<50000;++n){for(auto& v:in)v=next();check();}
 std::cout<<"NEUTRAL_WHITE_KERNEL_PASS lanes="<<count<<" alpha_all_256=1 unused_rgb_bits=1\n";
}
int main(int argc,char** argv)try{
 if(argc==2 && std::string(argv[1])=="--kernel"){kernel();return 0;}
 require(argc==5,"snapshot integral sprite output-prefix arguments required");
 unsetenv("NDS4MISTER_ADAPTIVE_RASTER_SPLIT");unsetenv("NDS4MISTER_RASTER_BAND_QUEUE");unsetenv("NDS4MISTER_ALTERNATE_3D_ROWS");
 setenv("NDS4MISTER_TEXTURE_HISTORY","1",1);unsetenv("NDS4MISTER_DISABLE_3D_AA");setenv("NDS4MISTER_SOLID_SPANS","auto",1);
 std::ifstream input(argv[1],std::ios::binary|std::ios::ate);require(bool(input),"snapshot missing");const auto len=input.tellg();require(len>0&&len<64*1024*1024,"snapshot bounds");input.seekg(0);
 std::vector<u8> data(static_cast<size_t>(len));input.read(reinterpret_cast<char*>(data.data()),len);require(bool(input),"snapshot read");
 const bool kart=std::string(argv[1]).find("kart")!=std::string::npos;unsigned comparisons=0;
 for(unsigned approx=0;approx<(kart?2u:1u);++approx)for(unsigned dual=0;dual<2;++dual)for(unsigned aa=0;aa<2;++aa){
  if(dual)setenv("NDS4MISTER_DUAL_CORE_3D","1",1);else unsetenv("NDS4MISTER_DUAL_CORE_3D");
  auto load=[&](bool enabled){
   setenv("NDS4MISTER_NEUTRAL_WHITE",enabled?"auto":"0",1);setenv("NDS4MISTER_APPROX_FACTORS","auto",1);
   NDSArgs args;args.JIT=std::nullopt;auto n=std::make_unique<NDS>(std::move(args));n->Reset();
   RendererSettings settings{};settings.Threaded=false;settings.ScaleFactor=1;settings.FullFrame3D=true;settings.PackedOutput=true;n->GetRenderer().SetRenderSettings(settings);
   Savestate in(data.data(),data.size(),false);n->GPU.DoSavestate(&in);require(!in.Error,"snapshot decode");n->GetRenderer().Finish3DRendering();auto& g=n->GPU.GPU3D;
   g.SetEnabled(true,true);g.SetExternalCommandReplay(true);g.SetIntegralTextureSpansEnabled(std::stoi(argv[2]));g.SetSpriteRasterSpansEnabled(std::stoi(argv[3]));g.SetSolidSpansEnabled(std::string(argv[1]).find("ffta2")!=std::string::npos);g.RenderFrameIdentical=false;g.SetApproximateFactorsEnabled(approx);
   if(aa)g.RenderDispCnt|=16;else g.RenderDispCnt&=~16u;
   auto& s=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n->GetRenderer()).Rend3D.get());require(s.NeutralWhiteOverride==(enabled?-1:0),"runtime override");require(s.DualCoreRaster==bool(dual),"worker mode");return n;
  };
  auto a=load(false),b=load(true);fpga3d::bind(nullptr,nullptr,false);a->GetRenderer().Start3DRendering();a->GetRenderer().Finish3DRendering();
  auto beforeConsidered=NeutralWhiteConsideredPixels.load(),beforeBypassed=NeutralWhiteBypassedPixels.load();b->GetRenderer().Start3DRendering();b->GetRenderer().Finish3DRendering();
  auto considered=NeutralWhiteConsideredPixels.load()-beforeConsidered,bypassed=NeutralWhiteBypassedPixels.load()-beforeBypassed;
  auto& sa=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(a->GetRenderer()).Rend3D.get());auto& sb=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(b->GetRenderer()).Rend3D.get());
  require(sb.NeutralWhite==bool(approx && !aa),"automatic scope");
  require(sb.NeutralWhite || bypassed==0,"unqualified bypass");
  for(unsigned y=0;y<192;++y)require(!std::memcmp(a->GetRenderer().Get3DScanline(y),b->GetRenderer().Get3DScanline(y),1024),"visible image mismatch");
  require(!std::memcmp(sa.ColorBuffer,sb.ColorBuffer,sizeof(sa.ColorBuffer)),"color plane mismatch");require(!std::memcmp(sa.DepthBuffer,sb.DepthBuffer,sizeof(sa.DepthBuffer)),"depth plane mismatch");require(!std::memcmp(sa.AttrBuffer,sb.AttrBuffer,sizeof(sa.AttrBuffer)),"attribute plane mismatch");
  std::string prefix=std::string(argv[4])+"-p"+std::to_string(approx)+"-d"+std::to_string(dual)+"-aa"+std::to_string(aa);dump(*a,prefix+"-baseline.rgba6");dump(*b,prefix+"-candidate.rgba6");
  std::cout<<"NEUTRAL_WHITE_SNAPSHOT approx="<<approx<<" dual="<<dual<<" aa="<<aa<<" considered_pixels="<<considered<<" bypassed_pixels="<<bypassed<<" all_native_planes_equal=1\n";++comparisons;
 }
 std::cout<<"NEUTRAL_WHITE_SNAPSHOT_PASS comparisons="<<comparisons<<"\n";return 0;
}catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
