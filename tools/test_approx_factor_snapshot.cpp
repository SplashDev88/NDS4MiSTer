// SPDX-License-Identifier: GPL-3.0-or-later
// Offline saved-frame comparison of the actual ARM SIMD raster path.
#include "Args.h"
#include "NDS.h"
#include "Savestate.h"
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include "NDS4MiSTerApproxFactor.h"
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <vector>
#include <stdexcept>
using namespace melonDS;
static void require(bool v,const char* why){if(!v)throw std::runtime_error(why);}
static uint64_t countDiff(const u32* a,const u32* b,size_t n){uint64_t x=0;for(size_t i=0;i<n;++i)x+=a[i]!=b[i];return x;}
static void dump(NDS& n,const std::string& path){std::ofstream f(path,std::ios::binary);require(bool(f),"dump path");for(unsigned y=0;y<192;++y)f.write(reinterpret_cast<char*>(n.GetRenderer().Get3DScanline(y)),1024);require(bool(f),"dump write");}
static void testResync(){
 uint32_t seed=0x3971be5a;auto next=[&](){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;};unsigned cases=0;
 for(unsigned n=0;n<20000;++n){
  const int width=3+next()%254,x0=int(next()%65)-32;const unsigned w0=next()&65535,w1=next()&65535;
  SoftRenderer3D::Interpolator<0> a(x0,x0+width,w0,w1,true),b(x0,x0+width,w0,w1,true);
  if(!b.CanBatchPerspectiveFactors(x0,x0+width))continue;
  const int last=x0+3+next()%(width-2);a.SetX(last);b.SetX(x0);
  u32 values[4];NDS4MiSTerApproximateFactors4(last-x0-3,width,w0,w1,values);b.SetPerspectiveBatchX(last,values[3]);b.RestoreExactPerspectiveX(last);
  require(a.x==b.x && a.yfactor==b.yfactor && a.factor_denominator==b.factor_denominator && a.factor_remainder==b.factor_remainder && a.factor_valid==b.factor_valid,"exact resync state mismatch");
  for(int x=last+1;x<=std::min(x0+width,last+3);++x){a.SetX(x);b.SetXFast<true>(x);require(a.yfactor==b.yfactor && a.factor_remainder==b.factor_remainder,"scalar tail after approximate batch differs");}
  ++cases;
 }
 std::cout<<"APPROX_RESYNC_PASS cases="<<cases<<" exact_tail_state=1\n";
}
int main(int argc,char** argv)try{
 testResync();
 require(argc==5,"snapshot integral sprite output-prefix arguments required");
 unsetenv("NDS4MISTER_ADAPTIVE_RASTER_SPLIT");unsetenv("NDS4MISTER_RASTER_BAND_QUEUE");unsetenv("NDS4MISTER_ALTERNATE_3D_ROWS");
 setenv("NDS4MISTER_TEXTURE_HISTORY","1",1);unsetenv("NDS4MISTER_DISABLE_3D_AA");setenv("NDS4MISTER_SOLID_SPANS","auto",1);
 std::ifstream input(argv[1],std::ios::binary|std::ios::ate);require(bool(input),"snapshot missing");const auto len=input.tellg();require(len>0&&len<64*1024*1024,"snapshot bounds");input.seekg(0);
 std::vector<u8> data(static_cast<size_t>(len));input.read(reinterpret_cast<char*>(data.data()),len);require(bool(input),"snapshot read");
 for(unsigned dual=0;dual<2;++dual)for(unsigned aa=0;aa<2;++aa){
  if(dual)setenv("NDS4MISTER_DUAL_CORE_3D","1",1);else unsetenv("NDS4MISTER_DUAL_CORE_3D");
  auto load=[&](bool enabled){
   setenv("NDS4MISTER_APPROX_FACTORS",enabled?"auto":"0",1);
   NDSArgs args;args.JIT=std::nullopt;auto n=std::make_unique<NDS>(std::move(args));n->Reset();
   RendererSettings settings{};settings.Threaded=false;settings.ScaleFactor=1;settings.FullFrame3D=true;settings.PackedOutput=true;n->GetRenderer().SetRenderSettings(settings);
   Savestate in(data.data(),data.size(),false);n->GPU.DoSavestate(&in);require(!in.Error,"snapshot decode");n->GetRenderer().Finish3DRendering();auto& g=n->GPU.GPU3D;
   g.SetEnabled(true,true);g.SetExternalCommandReplay(true);g.SetIntegralTextureSpansEnabled(std::stoi(argv[2]));g.SetSpriteRasterSpansEnabled(std::stoi(argv[3]));g.SetSolidSpansEnabled(std::string(argv[1]).find("ffta2")!=std::string::npos);g.RenderFrameIdentical=false;
   g.SetApproximateFactorsEnabled(std::string(argv[1]).find("kart")!=std::string::npos);
   if(aa)g.RenderDispCnt|=16;else g.RenderDispCnt&=~16u;
   auto& s=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n->GetRenderer()).Rend3D.get());require(s.ApproximateFactorsOverride==(enabled?-1:0),"runtime override");require(s.DualCoreRaster==bool(dual),"worker mode");return n;
  };
  auto a=load(false),b=load(true);fpga3d::bind(nullptr,nullptr,false);a->GetRenderer().Start3DRendering();a->GetRenderer().Finish3DRendering();
  const auto before=ApproxFactorTestPixels.load();b->GetRenderer().Start3DRendering();b->GetRenderer().Finish3DRendering();const auto admitted=ApproxFactorTestPixels.load()-before;
  auto& sa=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(a->GetRenderer()).Rend3D.get());auto& sb=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(b->GetRenderer()).Rend3D.get());
  uint64_t changed=0,alpha=0,rgb=0,totalError=0;unsigned maxError=0;
  for(unsigned y=0;y<192;++y){auto* x=a->GetRenderer().Get3DScanline(y);auto* z=b->GetRenderer().Get3DScanline(y);for(unsigned i=0;i<256;++i){changed+=x[i]!=z[i];alpha+=((x[i]^z[i])&0x1f000000)!=0;rgb+=((x[i]^z[i])&0x003f3f3f)!=0;for(unsigned c=0;c<3;++c){unsigned error=std::abs(int((x[i]>>(c*8))&63)-int((z[i]>>(c*8))&63));totalError+=error;maxError=std::max(maxError,error);}}}
  const auto colors=countDiff(sa.ColorBuffer,sb.ColorBuffer,sizeof(sa.ColorBuffer)/4),depths=countDiff(sa.DepthBuffer,sb.DepthBuffer,sizeof(sa.DepthBuffer)/4),attrs=countDiff(sa.AttrBuffer,sb.AttrBuffer,sizeof(sa.AttrBuffer)/4);
  if(aa)require(!admitted&&!colors&&!depths&&!attrs&&!changed,"AA-on fallback differs");
  if(std::string(argv[1]).find("kart")==std::string::npos)require(!admitted&&!colors&&!depths&&!attrs&&!changed,"non-Kart automatic fallback differs");
  std::string prefix=std::string(argv[4])+"-d"+std::to_string(dual)+"-aa"+std::to_string(aa);dump(*a,prefix+"-baseline.rgba6");dump(*b,prefix+"-candidate.rgba6");
  std::cout<<"APPROX_SNAPSHOT dual="<<dual<<" aa="<<aa<<" admitted_pixels="<<admitted<<" visible_changed="<<changed<<" rgb_changed="<<rgb<<" alpha_changed="<<alpha<<" channel_error_sum="<<totalError<<" max_channel_error="<<maxError<<" color_plane_changed="<<colors<<" depth_plane_changed="<<depths<<" attr_plane_changed="<<attrs<<"\n";
 }
 std::cout<<"APPROX_SNAPSHOT_PASS comparisons=4\n";return 0;
}catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
