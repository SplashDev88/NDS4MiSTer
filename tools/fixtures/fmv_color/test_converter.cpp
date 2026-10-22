// SPDX-License-Identifier: GPL-3.0-only
// Compare both ARMv5 routines against wrapping 32-bit color arithmetic.
#include <array>
#include <cstdint>
#include <cstring>
#include <vector>
#include <iostream>
#include <algorithm>
extern "C" void original_converter(void*,unsigned,unsigned);
extern "C" void candidate_converter(void*,unsigned,unsigned);
static uint32_t rng=0x695ca19b;
static uint32_t random32(){rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;return rng;}
static void word(std::array<uint8_t,0x400>& s,unsigned off,uint32_t v){std::memcpy(s.data()+off,&v,4);}
static uint16_t reference(uint32_t y,uint32_t cb,uint32_t cr){
 y+=128;
 auto asr=[](uint32_t x){return uint32_t(int32_t(x)>>12);};
 int32_t r=int32_t(y+asr(cr*0x166f)),g=int32_t(y-asr(cr*0xb6c+cb*0x581)),b=int32_t(y+asr(cb*0x1c59));
 auto clamp=[](int32_t x){return std::clamp(x,0,255)>>3;};
 return uint16_t(clamp(r)|(clamp(g)<<5)|(clamp(b)<<10));
}
int main(){
 std::array<uint32_t,256> y,cb,cr;
 alignas(4) std::array<uint8_t,0x400> a{},b{};
 uint64_t pixels=0;
 constexpr uint32_t edge[]={0,1,127,128,255,256,0xffffff80,0xffffffff,0x7fffffff,0x80000000,0x80000080,0x7fffff80};
 for(unsigned test=0;test<12000;++test){
  unsigned stride=test%3==0?16:test%3==1?32:256;
  std::vector<uint16_t> out1(16*stride+64,0xcdcd),out2(out1),expected(out1);
  for(unsigned i=0;i<256;++i){
   y[i]=test%4==0?random32():test%4==1?edge[random32()%12]:uint32_t(int(random32()%256)-128);
   cb[i]=test%4==0?random32():test%4==1?edge[random32()%12]:uint32_t(int(random32()%256)-128);
   cr[i]=test%4==0?random32():test%4==1?edge[random32()%12]:uint32_t(int(random32()%256)-128);
   if(i && ((test%5==0)||(test%5==1 && i%2)||(test%5==2 && i%8))){cb[i]=cb[i-1];cr[i]=cr[i-1];}
   expected[(i/16)*stride+(i%16)]=reference(y[i],cb[i],cr[i]);
  }
  word(a,0,stride);word(a,0x2e8,(uintptr_t)y.data());word(a,0x2ec,(uintptr_t)cb.data());word(a,0x2f0,(uintptr_t)cr.data());
  b=a;word(a,0x2b8,(uintptr_t)out1.data());word(b,0x2b8,(uintptr_t)out2.data());
  original_converter(a.data(),0,0);candidate_converter(b.data(),0,0);
  if(out1!=out2 || out1!=expected){
   for(unsigned i=0;i<out1.size();++i)if(out1[i]!=out2[i] || out1[i]!=expected[i]){
    std::cerr<<"FAIL test="<<test<<" destination="<<i<<" original="<<out1[i]<<" candidate="<<out2[i]<<" reference="<<expected[i]<<"\n";return 1;
   }
  }
  pixels+=256;
 }
 std::cout<<"PASS full ARMv5 converter equivalence: "<<pixels<<" pixels, 12000 blocks, repeated/distinct/extreme chroma and destination guards\n";
}
