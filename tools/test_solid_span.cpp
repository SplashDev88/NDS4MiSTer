// SPDX-License-Identifier: GPL-3.0-or-later
#define NDS4MISTER_SOLID_SPAN_TEST 1
#include "NDS4MiSTerSolidSpan.h"
#include <array>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <random>
#include <stdexcept>
using namespace melonDS;
int main() try {
 std::mt19937 random(0x534f4c49); uint64_t cases=0, pixels=0;
 const int32_t edges[]={INT32_MIN,INT32_MIN+1,-1,0,1,0x00fffe00,0x00ffffff,INT32_MAX-1,INT32_MAX};
 for(unsigned run=0;run<12000;++run){
  std::array<uint32_t,272> c,d,a,rc,rd,ra;
  for(unsigned i=0;i<c.size();++i){c[i]=random();d[i]=random();a[i]=random();}
  const size_t start=1+run%7,count=run%257;
  const int32_t z=run%3?edges[run%9]:static_cast<int32_t>(random());
  const uint32_t color=random(),attr=random();
  for(size_t i=start;i<start+count;++i){
   if(run%5==0)d[i]=static_cast<uint32_t>(z);
   else if(run%5==1)d[i]=static_cast<uint32_t>(edges[(run+i)%9]);
   else if(run%5==2)d[i]=static_cast<uint32_t>(z==INT32_MAX?z:z+1);
   else if(run%5==3)d[i]=static_cast<uint32_t>(z==INT32_MIN?z:z-1);
   a[i]=(a[i]&~0x00400010u)|((i&1)?0x10u:0u)|((i&2)?0x00400000u:0u);
  }
  rc=c;rd=d;ra=a;
  for(size_t i=start;i<start+count;++i){
   // Independently mirror the original named depth-test function, including
   // its <= branch for an opaque back-facing destination.
   const int32_t old=static_cast<int32_t>(rd[i]); bool pass;
   if((ra[i]&0x00400010u)==0x10u)pass=z<=old;else pass=z<old;
   if(pass){rc[i]=color;rd[i]=static_cast<uint32_t>(z);ra[i]=attr;}
  }
  NDS4MiSTerDrawSolidSpan(c.data()+start,d.data()+start,a.data()+start,count,z,color,attr);
  if(c!=rc || d!=rd || a!=ra)throw std::runtime_error("solid span depth/tail/guard mismatch");
  ++cases;pixels+=count;
 }
#if defined(__arm__) && defined(__ARM_NEON)
 if(!SolidSpanTestVectorStores || !SolidSpanTestVectorRejects)throw std::runtime_error("NEON paths not exercised");
#endif
 std::printf("SOLID_SPAN_PASS cases=%llu pixels=%llu vector_stores=%llu vector_rejects=%llu\n",(unsigned long long)cases,(unsigned long long)pixels,(unsigned long long)SolidSpanTestVectorStores.load(),(unsigned long long)SolidSpanTestVectorRejects.load());
 return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
