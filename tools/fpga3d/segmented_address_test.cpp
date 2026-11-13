// SPDX-License-Identifier: GPL-3.0-only
// Exhaustive address-model check; actual RTL is separately simulated.
#include "abi.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
using namespace fpga3d;
int main(){
 uint64_t checks=0;
 auto verify=[&](uint32_t base,uint32_t count,bool segmented){
  const uint16_t biased=uint16_t(((base>>6)&65535)-(segmented?8128:0));
  for(uint32_t index=0;index<count;++index){
   const bool padded=(base==PaddedCommands || segmented) && (!segmented || index<8128);
   const uint16_t slot=uint16_t(biased+index);
   const uint16_t padding=uint16_t((index+64)&8191);
   const uint32_t address=padded?(0x3fe30000u+((padding>>10)*0x40000u)+((padding&1023)*64)):(0x3fc00000u+uint32_t(slot)*64);
   const uint32_t expected=segmented?segmentedCommandAddress(base,index):commandAddress(base,index);
   const unsigned page=padded?(index&63):(slot&63);
   if(address!=expected || page!=((expected>>6)&63)){
    std::fprintf(stderr,"Address mismatch base=%08x index=%u segmented=%u actual=%08x expected=%08x\n",base,index,segmented,address,expected);std::abort();
   }
   ++checks;
  }
 };
 verify(Commands,MaxCommands,false);verify(PaddedCommands,MaxCommands,false);
 for(uint32_t base=Textures;base<=0x3fe00000u;base+=64){
  verify(base,segmentedCapacity(base),true);
  if(base<0x3fe00000u)verify(base,std::min<uint32_t>(MaxCommands,(0x3fe00000u-base)/64),false);
 }
 std::printf("SEGMENTED_ADDRESS_EXHAUSTIVE_PASS checks=%llu\n",(unsigned long long)checks);
}
