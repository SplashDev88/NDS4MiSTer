// SPDX-License-Identifier: GPL-3.0-only
// Focused renderer oracle. Test-only access; production object layout is unchanged.
#include <bits/stdc++.h>
#define private public
#include "NDS.h"
#include "GPU_Soft.h"
#include "GPU2D_Soft.h"
#undef private
using namespace melonDS;
static uint32_t seed=0x39528a71u;
static uint32_t random32(){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
static uint64_t digest(const u32* p,size_t n){uint64_t h=1469598103934665603ULL;for(size_t i=0;i<n;++i){h^=p[i];h*=1099511628211ULL;}return h;}
int main() try {
 unsetenv("NDS4MISTER_DUAL_CORE_3D");
 NDSArgs args;args.JIT=std::nullopt;auto nds=std::make_unique<NDS>(std::move(args));nds->Reset();
 auto& g=nds->GPU;auto& parent=static_cast<SoftRenderer&>(nds->GetRenderer());
 uint64_t hash=0;unsigned cases=0,eligible=0,changed=0;
 for(unsigned engine=0;engine<2;++engine){
  auto& e=engine?g.GPU2D_B:g.GPU2D_A;SoftRenderer2D r(e,parent);
  u8* vram;u32 mask;e.GetBGVRAM(vram,mask);for(u32 i=0;i<=mask;++i)vram[i]=random32();
  for(auto& x:g.Palette)x=random32();
  for(unsigned slot=0;slot<4;++slot)for(unsigned pal=0;pal<16;++pal){auto* p=e.GetBGExtPal(slot,pal);for(unsigned i=0;i<256;++i)p[i]=random32();}
  std::array<u32,512> initial,reference;std::array<u8,256> mosaic;
  for(unsigned test=0;test<8192;++test){
   const unsigned bg=2+(test&1),size=(test>>1)&3,wrap=(test>>3)&1,ext=(test>>4)&1;
   const unsigned dimension=128u<<size;
   e.DispCnt=(ext<<30)|((random32()&7)<<24)|((random32()&7)<<27);
   e.BGCnt[bg]=(size<<14)|(wrap<<13)|(random32()&0x1f3c);
   int x;
   switch((test>>5)&7){
    case 0:x=-1;break;case 1:x=0;break;case 2:x=7;break;case 3:x=dimension-1;break;
    case 4:x=dimension;break;case 5:x=-256;break;default:x=int(random32()%(dimension*4))-int(dimension*2);break;
   }
   const int y=(test&128)?int((random32()%(dimension+2)))-1:int(random32()%dimension);
   e.BGXRefInternal[bg-2]=x*256+int(random32()&255);
   e.BGYRefInternal[bg-2]=y*256+int(random32()&255);
   const bool useMosaic=(test%11)==0;
   e.BGRotA[bg-2]=(test%13)?256:s16(-128);
   e.BGRotC[bg-2]=(test%17)?0:s16(32);
   const unsigned mosaicSize=1+random32()%16;
   for(unsigned i=0;i<256;++i){mosaic[i]=i%mosaicSize;r.WindowMask[i]=(test%3==0)?0x3f:((test%3==1)?0:u8(random32()));}
   r.CurBGXMosaicTable=mosaic.data();
   for(auto& x:initial)x=random32();
   // Mutate live graphics and palettes between calls, exercising scanline
   // boundaries without depending on external revision hints.
   vram[random32()&mask]=random32();g.Palette[random32()%sizeof(g.Palette)]=random32();
   std::copy(initial.begin(),initial.end(),r.BGOBJLine);r.AffineTileCache=false;
   if(useMosaic)r.DrawBG_Extended<true>(test%192,bg);else r.DrawBG_Extended<false>(test%192,bg);
   std::copy(std::begin(r.BGOBJLine),std::end(r.BGOBJLine),reference.begin());
   std::copy(initial.begin(),initial.end(),r.BGOBJLine);r.AffineTileCache=true;
   if(useMosaic)r.DrawBG_Extended<true>(test%192,bg);else r.DrawBG_Extended<false>(test%192,bg);
   if(std::memcmp(reference.data(),r.BGOBJLine,sizeof(r.BGOBJLine)))throw std::runtime_error("affine mismatch engine="+std::to_string(engine)+" case="+std::to_string(test));
   if(reference!=initial)++changed;
   eligible+=!useMosaic&&e.BGRotA[bg-2]==256&&e.BGRotC[bg-2]==0;
   hash=(hash*1099511628211ULL)^digest(reference.data(),reference.size());++cases;
  }
 }
 if(eligible<10000||changed<1000)throw std::runtime_error("insufficient meaningful test coverage");
 std::cout<<"AFFINE_BG_RUNS_ORACLE_PASS cases="<<cases<<" eligible="<<eligible<<" changed="<<changed<<" hash="<<hash<<'\n';
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
