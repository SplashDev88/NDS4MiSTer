// SPDX-License-Identifier: GPL-3.0-only
#include <array>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <vector>
#include <algorithm>
#include <sys/mman.h>
#include <stdexcept>
extern "C" void original_dct(void*);
extern "C" void candidate_dct(void*);
extern "C" void candidate_dct_stack(void*,void*);
static uint32_t rng=0x5912abf8;
static uint32_t random32(){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static constexpr unsigned order[]={0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5,12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28,35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63};
static void set(std::array<uint8_t,0x400>&s,unsigned o,uint32_t v){std::memcpy(s.data()+o,&v,4);}
int main(){
 constexpr int32_t cuts[]={-2147483647-1,-1,0,1,7,8,15,16,23,24,31,32,39,40,47,48,55,56,63,64,2147483647};
 uint64_t outputs=0;
 auto* stack=static_cast<uint8_t*>(mmap(reinterpret_cast<void*>(0x027c0000),0x4000,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED,-1,0));
 if(stack!=reinterpret_cast<void*>(0x027c0000))throw std::runtime_error("Cannot map test DTCM stack");

 for(unsigned t=0;t<16000;++t){
  int32_t cutoff=cuts[t%(sizeof(cuts)/sizeof(*cuts))];unsigned count=std::min(64u,(unsigned(std::max(0,cutoff))/8+1)*8);
  std::vector<uint8_t>a(0x3000,0xcd);
  for(unsigned j=0;j<64;++j){uint32_t v=(t%5 && random32()%5)?0:random32();std::memcpy(a.data()+j*4,&v,4);}
  for(unsigned j=0;j<4096;++j){uint16_t v=random32();std::memcpy(a.data()+0x400+j*2,&v,2);}
  unsigned outoff=t%7==0?(t%3)*16:t%7==1?0x400+(t%3)*16:0x2800;
  auto b=a,expected=a;
  for(unsigned row=0;row<64;++row){
   uint32_t total=0;
   for(unsigned j=0;j<count;++j){uint32_t c;int16_t basis;std::memcpy(&c,expected.data()+order[j]*4,4);std::memcpy(&basis,expected.data()+0x400+row*128+order[j]*2,2);total+=c*uint32_t(int32_t(basis));}
   int32_t v=int32_t(total)>>14;std::memcpy(expected.data()+outoff+row*4,&v,4);
  }
  alignas(4) std::array<uint8_t,0x400> sa{},sb{};
  auto setup=[&](auto&s,auto&mem){set(s,0x44,cutoff);set(s,0x48,uintptr_t(mem.data()+0x400));set(s,0x2f4,uintptr_t(mem.data()));set(s,0x2f8,uintptr_t(mem.data()+outoff));};
  setup(sa,a);setup(sb,b);auto beforea=sa,beforeb=sb;
  original_dct(sa.data());
  if(t<160){
   std::memset(stack,0xa5,0x4000);
   constexpr unsigned positions[]={0x3aa4,0x3a28,0x3a24,0x3830};
   candidate_dct_stack(sb.data(),stack+positions[t%4]);
   for(unsigned j=0;j<0x3800;++j)if(stack[j]!=0xa5){std::cerr<<"FAIL stack floor t="<<t<<" offset="<<j<<"\n";return 3;}
   // Dense case reaches the list; sparse fallback must not reserve it.
  }else candidate_dct(sb.data());
  if(a!=b||a!=expected||sa!=beforea||sb!=beforeb){
   for(unsigned j=0;j<a.size();++j)if(a[j]!=b[j]||a[j]!=expected[j]){std::cerr<<"FAIL t="<<t<<" cutoff="<<cutoff<<" count="<<count<<" dest="<<outoff<<" byte="<<j<<" original="<<unsigned(a[j])<<" candidate="<<unsigned(b[j])<<" reference="<<unsigned(expected[j])<<"\n";return 1;}
   std::cerr<<"FAIL state mutated\n";return 2;
  }
  outputs+=64;
 }
 std::cout<<"PASS DCT equivalence: "<<outputs<<" outputs; 160 DTCM stack-boundary calls; sparse/dense signed 32-bit coefficients, signed 16-bit bases, cutoff edges, overlaps, output guards\n";
}
