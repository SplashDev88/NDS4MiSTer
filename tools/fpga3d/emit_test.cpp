// SPDX-License-Identifier: GPL-3.0-only
// Production GX setup and software rasterization are the independent oracle.
// A deliberate hardware timeout also checks exact recovery after span emission.
#define main original_raster_benchmark_main
#include "../benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include <fstream>
#include <filesystem>
#if defined(__linux__)
#include <pthread.h>
#include <sched.h>
#endif
template<class T>void save(const std::string& path,const std::vector<T>& data){
 std::ofstream f(path,std::ios::binary);f.write(reinterpret_cast<const char*>(data.data()),data.size()*sizeof(T));require(bool(f),"fixture write");
}
static unsigned currentScenario=0;
int main(int argc,char** argv)try{
 require(argc==2 || argc==3,"output directory and optional first scenario required");std::filesystem::create_directories(argv[1]);
 const unsigned firstScenario=argc==3?std::stoul(argv[2]):0;
 require(firstScenario<432,"invalid first scenario");
 std::vector<uint32_t> control(0x100000/4),output(0x300000/4);
 unsigned captures=0,fallbacks=0;
 std::ofstream manifest(std::string(argv[1])+"/scenarios.json");manifest<<"[\n";
 for(unsigned scenario=firstScenario;scenario<432;scenario++){
  currentScenario=scenario;fpga3d::bind(nullptr,nullptr,false);
  auto ref=machine(true),test=machine(true);
  unsigned pattern=scenario<48?scenario:scenario-48;
  unsigned fixture=((pattern&1)?16384:0)|((pattern&2)?8192:0)|((pattern&4)?64:0)|((pattern&8)?16:0)|((pattern&16)?8:0)|((pattern&32)?3:0);
  if(scenario>=112)fixture=(fixture&~3u)|((scenario&1)?1:2);
  if(scenario>=144 && scenario<160)fixture|=16384u|((9u+(scenario&1))<<20);
  if(scenario>=224)fixture|=16384u|(4u<<17);
  if(scenario>=400)fixture=16384u|8192u|((scenario&1)?16u:0)|((9u+((scenario>>1)&1))<<20);
  frame(*ref,fixture);frame(*test,fixture);
  bool supported=!(scenario>=40 && scenario<48 && scenario!=40 && scenario!=41 && scenario!=42 && scenario!=44 && scenario!=46);
  for(auto* n:{ref.get(),test.get()}){
   auto& g=n->GPU.GPU3D;g.RenderDispCnt=1|8;
   if(scenario>=40 && scenario<48){
    if(scenario<44)g.RenderDispCnt|=1u<<(scenario==40?4:scenario==41?5:scenario==42?7:14);
    else if(scenario==44)for(unsigned i=0;i<g.RenderNumPolygons;i++){g.RenderPolygonRAM[i]->Attr&=~(31u<<16);g.RenderPolygonRAM[i]->Attr|=15u<<16;}
    else if(scenario==45)for(unsigned i=0;i<g.RenderNumPolygons;i++)g.RenderPolygonRAM[i]->Attr&=~(31u<<16);
    else if(scenario==46)for(unsigned i=0;i<g.RenderNumPolygons;i++)g.RenderPolygonRAM[i]->Attr=(g.RenderPolygonRAM[i]->Attr&~48u)|32u;
    else g.RenderPolygonRAM[g.RenderNumPolygons-1]->IsShadow=true;
   }
   if(scenario>=48){
    if(scenario<80 || (scenario&1) || scenario>=144)g.RenderDispCnt|=16;
    if(scenario>=80 && scenario<112 && (scenario&8))g.RenderDispCnt&=~1u;
    if(scenario>=80 && (scenario&16))g.RenderDispCnt&=~8u;
    const unsigned clearAlpha[]={0,1,15,31};
    g.RenderClearAttr1=(g.RenderClearAttr1&~(31u<<16))|(clearAlpha[scenario&3]<<16);
    g.RenderAlphaRef=scenario>=80 && (scenario&3)==3?15:0;
    if(scenario>=80)for(unsigned i=0;i<g.RenderNumPolygons;i++){
     auto* p=g.RenderPolygonRAM[i];
     unsigned alpha=i%4==0?31:1+(i*7+scenario)%30;
     if(scenario>=144 && !(scenario&4))alpha=31;
     p->Attr=(p->Attr&~((31u<<16)|(63u<<24)|(1u<<11)))|(alpha<<16)|
       (((scenario&4)?(i/2)%8:i%8)<<24)|((scenario&2)?1u<<11:0);
     if((scenario&16) && i%3==0)p->Attr|=1u<<14;
    }
   }
   if(scenario==42 || scenario>=160){
    const unsigned f=scenario==42?0:scenario-160;
    g.RenderDispCnt|=1u<<7;
    if(f&1)g.RenderDispCnt|=1u<<4;else g.RenderDispCnt&=~(1u<<4);
    if(f&2)g.RenderDispCnt|=1u<<6;
    g.RenderFogShift=f&15;
    const unsigned offsets[]={0,0x400000,0x7fffff,0xf00000};
    g.RenderFogOffset=offsets[(f>>2)&3];
    g.RenderFogColor=((f*13)&31)|(((f*7)&31)<<5)|(((f*3)&31)<<10)|(((f*11)&31)<<16);
    for(unsigned i=0;i<34;i++)g.RenderFogDensityTable[i]=
        f<16?i*127/33:f<32?127-i*127/33:f<48?((i*41+f*13)&127):(f&4)?127:0;
    if(f&4)g.RenderClearAttr1|=1u<<15;
    for(unsigned i=0;i<g.RenderNumPolygons;i++){
     auto* p=g.RenderPolygonRAM[i];
     if((f&8) || i%3!=0)p->Attr|=1u<<15;else p->Attr&=~(1u<<15);
    }
   }
   if(scenario>=224 && scenario<240){
    // Equal-depth front faces may pass an opaque back face, but never a
    // translucent back face. Both layers and fog/AA combinations matter.
    g.RenderDispCnt&=~1u;
    for(unsigned i=0;i<g.RenderNumPolygons;i++){
     auto* p=g.RenderPolygonRAM[i];
     unsigned alpha=i==0?((scenario&2)?31:15):31;
     p->Attr=(p->Attr&~((31u<<16)|(1u<<14)|(1u<<11)))|(alpha<<16)|
         ((scenario&4)?0:1u<<11)|((scenario&8)?1u<<14:0);
     for(unsigned v=0;v<p->NumVertices;v++)p->FinalZ[v]=i<2?0x100000:0x200000;
    }
   }
   if(scenario==41 || scenario>=240){
    g.RenderDispCnt|=1u<<5;
    for(unsigned i=0;i<8;i++)g.RenderEdgeTable[i]=((i*5+scenario)&31)|(((i*11+3)&31)<<5)|(((i*7+19)&31)<<10);
    if(scenario>=240){
     const unsigned e=scenario-240;
     if(e&1)g.RenderDispCnt|=1u<<4;else g.RenderDispCnt&=~(1u<<4);
     if(e&2)g.RenderDispCnt|=1u<<7;else g.RenderDispCnt&=~(1u<<7);
     g.RenderClearAttr1=(g.RenderClearAttr1&~(63u<<24))|(((e*7)&63)<<24);
     g.RenderClearAttr2=(g.RenderClearAttr2&~0x7fffu)|((e&4)?0x7fff:0x1000);
     for(unsigned i=0;i<g.RenderNumPolygons;i++){
      auto* p=g.RenderPolygonRAM[i];
      p->Attr=(p->Attr&~(63u<<24))|(((e&8)?i*9:e*3)&63)<<24;
     }
    }
   }
   if(scenario>=304 && scenario<400){
    const unsigned formats[]={4,1,6,7};
    for(unsigned i=0;i<32768;i++)n->GPU.VRAM_A[i]=uint8_t((i*37+(i>>7)*13+scenario)&255);
    for(unsigned i=0;i<256;i++){
     uint16_t rgb=(i&31)|(((i>>3)&31)<<5)|(((i*7)&31)<<10);
     std::memcpy(n->GPU.VRAM_E+2*i,&rgb,2);
    }
    std::memset(n->GPU.VRAMDirty[0].Data,255,sizeof(n->GPU.VRAMDirty[0].Data));
    std::memset(n->GPU.VRAMDirty[4].Data,255,sizeof(n->GPU.VRAMDirty[4].Data));
    for(unsigned i=0;i<g.RenderNumPolygons;i++){
     auto* p=g.RenderPolygonRAM[i];
     p->TexParam=(formats[(scenario+i/3)&3]<<26)|(4u<<20)|(4u<<23)|((scenario&4)?15u<<16:0)|(1u<<29);
     for(unsigned v=0;v<p->NumVertices;v++){
      p->Vertices[v]->TexCoords[0]=s16(p->Vertices[v]->FinalPosition[0]*29-2048);
      p->Vertices[v]->TexCoords[1]=s16(p->Vertices[v]->FinalPosition[1]*31-1024);
     }
    }
   }
   if(scenario==46 || (scenario>=336 && scenario<400)){
    if(scenario&1)g.RenderDispCnt|=2;else g.RenderDispCnt&=~2u;
    if(scenario&2)g.RenderDispCnt&=~1u;
    for(unsigned i=0;i<32;i++)g.RenderToonTable[i]=((i*5+scenario)&31)|(((i*7+3)&31)<<5)|(((i*11+1)&31)<<10);
    for(unsigned i=0;i<g.RenderNumPolygons;i++){
     auto* p=g.RenderPolygonRAM[i];p->Attr=(p->Attr&~48u)|((i%3==0)?16u:32u);
    }
   }
   if(scenario>=400){
    g.RenderDispCnt=1|8|((scenario&4)?16:0)|((scenario&8)?32:0);
    for(unsigned i=0;i<g.RenderNumPolygons;i++){
     auto* p=g.RenderPolygonRAM[i];
     p->Attr=(p->Attr&~(31u<<16))|(31u<<16);
     p->WBuffer=(scenario&16)!=0;
     int minX=256;
     for(unsigned v=0;v<p->NumVertices;v++)minX=std::min(minX,p->Vertices[v]->FinalPosition[0]);
     for(unsigned v=0;v<p->NumVertices;v++){
      const int side=p->Vertices[v]->FinalPosition[0]>minX;
      // A one-pixel-wide diagonal has multi-pixel x-major edge runs. Its
      // cached right-edge revisit starts before the interpolation origin.
      p->Vertices[v]->FinalPosition[0]=16+2*(p->Vertices[v]->FinalPosition[1]-p->YTop)+side*(int(scenario&7)-4);
      p->FinalW[v]=49267-side*264;
      p->FinalZ[v]=0x100000+((scenario&2)?int(v)*4096:0);
      for(unsigned c=0;c<3;c++)p->Vertices[v]->FinalColor[c]=63<<3;
     }
     p->XTop=p->Vertices[p->VTop]->FinalPosition[0];p->XBottom=p->Vertices[p->VBottom]->FinalPosition[0];
    }
   }
  }
  render(*ref);
  auto& soft=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(test->GetRenderer()).Rend3D.get());
  soft.FullFrameCompletion=true;
  std::fill(control.begin(),control.end(),0);control[0]=0x31443348;control[2]=17;
  control[(fpga3d::Mailbox-0x3fc00000+24)/4]=fpga3d::Magic;
  control[(fpga3d::Mailbox-0x3fc00000+28)/4]=17;
  fpga3d::poisonedSession=0;
#ifdef FPGA3D_EARLY_TIMEOUT_TEST
  fpga3d::bind(control.data(),output.data(),true,true);
  soft.FpgaFrame.deadlineMs=0;
#else
  fpga3d::bind(control.data(),output.data(),true);
#endif
#if defined(__linux__)
  cpu_set_t affinityBefore{},affinityAfter{};
  require(!pthread_getaffinity_np(pthread_self(),sizeof(affinityBefore),&affinityBefore),"read original affinity");
#endif
  render(*test);fpga3d::bind(nullptr,nullptr,false);
#if defined(__linux__)
  require(!pthread_getaffinity_np(pthread_self(),sizeof(affinityAfter),&affinityAfter) &&
          CPU_EQUAL(&affinityBefore,&affinityAfter),"FPGA timeout/fallback did not restore caller affinity");
#endif
  std::vector<uint32_t> expected;
  for(unsigned y=0;y<192;y++){
   const auto* a=ref->GetRenderer().Get3DScanline(y);const auto* b=test->GetRenderer().Get3DScanline(y);
   require(!std::memcmp(a,b,1024),"timeout fallback changed software pixels");expected.insert(expected.end(),a,a+256);
  }
  if(!supported){require(soft.FpgaFrame.commands.empty(),"unsupported frame submitted");require(soft.FpgaFrame.textures.empty(),"unsupported frame copied textures before feature preflight");std::printf("FALLBACK_PASS scenario=%u\n",scenario);fallbacks++;continue;}
#ifdef FPGA3D_EARLY_TIMEOUT_TEST
  require(soft.FpgaFrame.transportError && !soft.FpgaFrame.active && fpga3d::poisonedSession==17,
          "first-row producer timeout was not quarantined");
#else
  require(soft.FpgaFrame.valid && soft.FpgaFrame.commands.size()>384,"fixture not admitted");
  if(scenario>=400 && (scenario&7)==3)
   require(std::any_of(soft.FpgaFrame.commands.begin(),soft.FpgaFrame.commands.end(),
       [](const auto& c){return c[0]==2 && (c[31]&(1u<<13));}),"outlier fixture missed literal pixel path");
#endif
  auto prefix=std::string(argv[1])+"/"+std::to_string(captures);
  save(prefix+".commands",soft.FpgaFrame.commands);save(prefix+".textures",soft.FpgaFrame.textures);save(prefix+".expected",expected);
  if(captures)manifest<<",\n";
  manifest<<"{\"fixture\":"<<captures<<",\"scenario\":"<<scenario<<",\"commands\":"<<soft.FpgaFrame.commands.size()<<"}";
  std::printf("EMIT_PASS scenario=%u commands=%zu\n",scenario,soft.FpgaFrame.commands.size());captures++;
 }
 manifest<<"\n]\n";
#ifdef FPGA3D_EARLY_TIMEOUT_TEST
 std::printf("PASS %u first-row producer timeouts with exact software fallback; %u unsupported cases\n",captures,fallbacks);
#else
 std::printf("PASS %u production geometry/raster fixtures and exact timeout fallback; %u unsupported cases\n",captures,fallbacks);
#endif
 return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL scenario=%u %s\n",currentScenario,e.what());return 1;}
