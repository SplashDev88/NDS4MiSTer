// SPDX-License-Identifier: GPL-3.0-or-later
#include "NDS4MiSTerApproxFactor.h"
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <stdexcept>
#if !defined(__arm__) || !defined(__ARM_NEON)
#error This test must execute the actual ARM NEON implementation.
#endif
static uint64_t lanes=0, changed=0, below=0, above=0, endpoints=0;
static int maxError=0;
static void check(uint32_t x,uint32_t width,uint32_t w0,uint32_t w1){
 uint32_t out[4];melonDS::NDS4MiSTerApproximateFactors4(x,width,w0,w1,out);
 for(unsigned i=0;i<4;++i){
  const uint64_t left=uint64_t(x+i)*w0,den=left+uint64_t(width-x-i)*w1;
  const uint32_t exact=den?uint32_t((left<<8)/den):0;
  if(out[i]>256)throw std::runtime_error("factor outside0..256");
  const int error=int(out[i])-int(exact);maxError=std::max(maxError,std::abs(error));
  ++lanes;changed+=error!=0;below+=error<0;above+=error>0;
  endpoints+=(x+i==0 || x+i==width) && error!=0;
  if(std::abs(error)>1)throw std::runtime_error("factor error greater than one");
  if(den==0 && out[i]!=0)throw std::runtime_error("zero denominator changed");
 }
}
int main()try{
 const uint32_t ws[]={0,1,2,3,7,15,16,31,32,255,256,511,512,1023,4095,4096,32767,32768,65534,65535};
 for(uint32_t width=3;width<=256;++width)for(auto a:ws)for(auto b:ws){
  check(0,width,a,b);check(width-3,width,a,b);check((width-3)/2,width,a,b);
 }
 uint32_t seed=0x6125a59b;
 auto next=[&](){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;};
 for(unsigned n=0;n<200000;++n){uint32_t width=3+next()%254;check(next()%(width-2),width,next()&65535,next()&65535);}
 std::printf("APPROX_FACTOR_BOUND_PASS lanes=%llu changed=%llu below=%llu above=%llu max_error=%d endpoint_changes=%llu\n",
  (unsigned long long)lanes,(unsigned long long)changed,(unsigned long long)below,(unsigned long long)above,maxError,(unsigned long long)endpoints);
 return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
