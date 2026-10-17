// SPDX-License-Identifier: GPL-3.0-only
#include "GPU.h"
#include "NDS.h"
#include <array>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
using namespace melonDS;
struct Words {u32 low,high;};
static unsigned cases=0,equal=0,mixed=0;
template<class T>void check(GPU& a,GPU& b,u32 address,T value,u32 mask){
 u32 expectedMask=0;std::array<NonStupidBitField<128*1024/VRAMDirtyGranularity>,9> expectedDirty;std::copy(std::begin(a.VRAMDirty),std::end(a.VRAMDirty),expectedDirty.begin());
 for(u32 bank:{2u,7u,8u})if(mask&(1u<<bank)){
  u32 offset=address&a.VRAMMask[bank];if(std::memcmp(a.VRAM[bank]+offset,&value,sizeof(T))){expectedMask|=1u<<bank;expectedDirty[bank][offset/VRAMDirtyGranularity]=true;}
 }
 std::array<u64,9> oldRevisions{};for(unsigned k=0;k<9;++k)oldRevisions[k]=a.ExternalRenderVRAMRevision[k];
 const auto changed=a.WriteVRAM_BBGChanged<T>(address,value);b.WriteVRAM_BBG<T>(address,value);
 if(changed!=expectedMask)throw std::runtime_error("changed mask");
 if(!changed)++equal;else if(changed!=mask)++mixed;
 a.MarkExternalRenderVRAMMask(changed);
 for(unsigned k=0;k<9;++k){
  if(std::memcmp(a.VRAM[k],b.VRAM[k],a.VRAMMask[k]+1))throw std::runtime_error("VRAM bytes");
  if(std::memcmp(a.VRAMDirty[k].Data,expectedDirty[k].Data,sizeof(a.VRAMDirty[k].Data)))throw std::runtime_error("dirty bits or pre-existing dirty lost");
  if((changed&(1u<<k))?(a.ExternalRenderVRAMRevision[k]<=oldRevisions[k]):(a.ExternalRenderVRAMRevision[k]!=oldRevisions[k]))throw std::runtime_error("revision changed incorrectly");
 }
 auto ad=a.VRAMDirty_BBG.DeriveState(a.VRAMMap_BBG,a);auto bd=b.VRAMDirty_BBG.DeriveState(b.VRAMMap_BBG,b);a.MakeVRAMFlat_BBGCoherent(ad);b.MakeVRAMFlat_BBGCoherent(bd);
 if(std::memcmp(a.VRAMFlat_BBG,b.VRAMFlat_BBG,sizeof(a.VRAMFlat_BBG)))throw std::runtime_error("coherent flat BG mismatch");
 ++cases;
}
int main()try{
 NDSArgs aa,bb;aa.JIT=std::nullopt;bb.JIT=std::nullopt;auto na=std::make_unique<NDS>(std::move(aa));auto nb=std::make_unique<NDS>(std::move(bb));na->Reset();nb->Reset();auto& a=na->GPU;auto& b=nb->GPU;
 for(u32 bits=0;bits<8;++bits){u32 mask=((bits&1)?4:0)|((bits&2)?128:0)|((bits&4)?256:0);
  for(auto* g:{&a,&b}){for(auto& m:g->VRAMMap_BBG)m=mask;for(u32 bank:{2u,7u,8u}){std::memset(g->VRAM[bank],bank==2?0xA5:bank==7?0:0x5A,g->VRAMMask[bank]+1);g->VRAMDirty[bank].SetRange(0,(g->VRAMMask[bank]+1)/512);}}
  for(u32 offset:{0u,2u,4u,504u,508u,510u,512u,0x3ff8u,0x3ffcu,0x3ffeu,0x4000u,0x7ff8u,0x8000u,0x1fff8u,0x20000u,0x1ffff8u}){
   const u32 address=0x06200000+offset;
   for(u32 value:{0xA5A5A5A5u,0xA5A5A5A5u,0xA5A5A55Au,0u,0u,0x5A5A5A5Au}){
    for(auto* g:{&a,&b})g->VRAMDirty[7][11]=true;
    check(a,b,address,u16(value),mask);check(a,b,address,u16(value),mask);
    if(!(offset&3)){check(a,b,address,u32(value),mask);check(a,b,address,u32(value),mask);if(offset%512<=504){check(a,b,address,Words{value,value^0x01000000u},mask);check(a,b,address,Words{value,value^0x01000000u},mask);}}
   }
  }
 }
 if(equal<1000||mixed<1)throw std::runtime_error("insufficient no-op/mixed coverage");std::cout<<"BG_CHANGED_WRITE_ORACLE_PASS cases="<<cases<<" equal="<<equal<<" mixed="<<mixed<<" full_vram=1 dirty=1 revisions=1 flat_coherence=1\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
