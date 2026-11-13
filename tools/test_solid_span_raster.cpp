// SPDX-License-Identifier: GPL-3.0-or-later
#define main original_raster_benchmark_main
#include "benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include "NDS4MiSTerSolidSpan.h"
static void solidFrame(NDS& n,unsigned scenario){
 frame(n,16384u|8192u|16u|8u);
 auto& g=n.GPU.GPU3D;auto* p=g.RenderPolygonRAM[g.RenderNumPolygons-1];
 const int widths[]={1,2,3,4,7,31,127,256};const int lefts[]={-7,0,127,255};
 const int left=lefts[(scenario>>3)&3],right=left+widths[scenario&7];
 const int top=scenario&16?17:0,bottom=std::min(192,top+(scenario&32?31:192));
 p->TexParam=0;p->TexPalette=0;p->FacingView=true;p->Translucent=false;
 p->IsShadow=p->IsShadowMask=p->Degenerate=false;p->WBuffer=false;
 p->Attr=0xc0u|(23u<<24)|(31u<<16)|((scenario&64)?1u<<15:0);
 p->VTop=0;p->VBottom=2;p->YTop=top;p->YBottom=bottom;p->XTop=left;p->XBottom=right;
 const int positions[4][2]={{left,top},{left,bottom},{right,bottom},{right,top}};
 for(unsigned v=0;v<4;++v){
  std::copy(positions[v],positions[v]+2,p->Vertices[v]->FinalPosition);
  p->FinalW[v]=4096;p->FinalZ[v]=scenario&8?0x100000:0x00fffe00;
  for(unsigned c=0;c<3;++c)p->Vertices[v]->FinalColor[c]=((v==1||v==2)?79+51*c:367+67*c)&511;
 }
 g.RenderDispCnt=9u|((scenario&32)?32u:0u)|((scenario&64)?128u:0u)|((scenario&128)?16u:0u);
 g.RenderAlphaRef=scenario%11==0?31:0;
 if(scenario>=256){
  switch((scenario>>3)&7){
   case 0:p->FinalZ[1]+=128;break;
   case 1:p->Vertices[2]->FinalColor[0]^=128;break;
   case 2:p->Attr|=1u<<14;break;
   case 3:p->TexParam=4u<<26;break;
   case 4:p->Attr=(p->Attr&~(31u<<16))|(15u<<16);p->Translucent=true;break;
   case 5:p->Attr&=~(31u<<16);break;
   case 6:p->Attr|=2u<<4;break;
   case 7:p->FinalW[1]+=128;break;
  }
 }
}
int main()try{
 // Exercise profile changes on one renderer, plus fresh-session defaults and
 // diagnostic overrides. No environment writes happen while a worker runs.
 unsigned policyCases=0;
 for(const char* setting : {static_cast<const char*>(nullptr), "auto", "0", "1", "invalid"}) {
  if(setting)setenv("NDS4MISTER_SOLID_SPANS",setting,1);else unsetenv("NDS4MISTER_SOLID_SPANS");
  auto n=machine(true);auto& g=n->GPU.GPU3D;
  require(!g.SolidSpansEnabled(),"new GPU session inherited solid profile");
  auto& s=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n->GetRenderer()).Rend3D.get());
  for(bool profile : {false,true,false,true,false}) {
   g.SetSolidSpansEnabled(profile);solidFrame(*n,0);render(*n);
   const bool expected=!setting || !std::strcmp(setting,"auto") ? profile : !std::strcmp(setting,"1");
   require(s.SolidSpans==expected,"solid profile/override transition mismatch");++policyCases;
  }
 }
 unsetenv("NDS4MISTER_SOLID_SPANS");
 std::printf("SOLID_PROFILE_PASS transitions=%u fresh_session_default_off=1\n",policyCases);
 uint64_t compared=0;
 for(unsigned scenario=0;scenario<384;++scenario){
  auto a=machine(true),b=machine(true);solidFrame(*a,scenario);solidFrame(*b,scenario);
  auto& sa=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(a->GetRenderer()).Rend3D.get());
  auto& sb=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(b->GetRenderer()).Rend3D.get());
  sa.SolidSpansOverride=0;sb.SolidSpansOverride=1;render(*a);render(*b);
  for(unsigned y=0;y<192;++y){require(!std::memcmp(a->GetRenderer().Get3DScanline(y),b->GetRenderer().Get3DScanline(y),1024),"solid raster visible mismatch");compared+=256;}
  require(!std::memcmp(sa.ColorBuffer,sb.ColorBuffer,sizeof(sa.ColorBuffer)),"solid color plane mismatch");
  require(!std::memcmp(sa.DepthBuffer,sb.DepthBuffer,sizeof(sa.DepthBuffer)),"solid depth plane mismatch");
  require(!std::memcmp(sa.AttrBuffer,sb.AttrBuffer,sizeof(sa.AttrBuffer)),"solid attribute plane mismatch");
 }
#ifdef NDS4MISTER_SOLID_SPAN_TEST
 require(SolidSpanTestPixels.load()>0,"solid integration never entered");
 std::printf("SOLID_RASTER_COVERAGE pixels=%llu\n",(unsigned long long)SolidSpanTestPixels.load());
#endif
 std::printf("SOLID_RASTER_PASS scenarios=384 visible_pixels=%llu all_native_planes_equal=1\n",(unsigned long long)compared);return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
