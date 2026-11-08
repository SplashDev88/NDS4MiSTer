// SPDX-License-Identifier: GPL-3.0-only
#include "codec.h"
#include <cstdio>
#include <stdexcept>
using namespace fpga3d;
static int64_t quotient(int64_t n,int64_t d){auto q=n/d;return q-(n%d<0);}
static void check(bool b){if(!b)throw std::runtime_error("span recurrence mismatch");}
int main(){
 unsigned pixels=0;
 for(int width=1;width<=128;width++)for(int delta:{-127,-64,-1,0,1,64,127})for(bool descending:{false,true}){
  Span s;s.first=24;s.origin=25;s.end=25+width;s.width=width;s.flags=Linear|Front;
  s.z0=descending?0x800000:0x600000;s.z1=descending?0x600000:0x800000;
  for(int k=0;k<5;k++){s.left[k]=1000+k*64;s.right[k]=s.left[k]+delta;}
  auto c=span(s);check(!(pack(c)[15]>>31));
  int32_t z=c[5];unsigned zr=c[7]&8191,zrs=(c[7]>>16)&8191;
  int32_t a[5];unsigned rem[5],rs[5];for(int k=0;k<5;k++){a[k]=int16_t(c[8+k]);rem[k]=c[21+k]&65535;rs[k]=c[21+k]>>16;}
  for(int x=s.first;x<s.end;x++){
   int64_t factor=descending?s.width-(x-s.origin):x-s.origin;
   int64_t dz=(std::abs(s.z1-s.z0)>>9)*(int64_t(1<<22)/s.width);
   check(z==std::min(s.z0,s.z1)+quotient(dz*factor,8192));
   for(int k=0;k<5;k++){
    check(a[k]==s.left[k]+quotient(int64_t(delta)*(x-s.origin),width));
    rem[k]+=rs[k];a[k]+=int32_t(c[16+k]);if(rem[k]>=(c[3]&65535)){rem[k]-=c[3]&65535;a[k]++;}
   }
   zr+=zrs;z+=int32_t(c[6]);if(zr>=8192){zr-=8192;z++;}pixels++;
  }
 }
 for(int width=1;width<=256;width++)for(int dx=0;dx<width;dx++)for(int delta:{-65535,-32769,-32768,-1,0,1,32767,32768,65535})
  check(floorDivSmall(delta*dx,width)==quotient(int64_t(delta)*dx,width));
 for(int kind=0;kind<4;kind++){
  Span s;s.first=24;s.origin=25;s.end=26;s.width=1;
  if(kind==0)s.flags|=WBuffer;if(kind==1)s.first=23;if(kind==2)s.width=129,s.end=154;if(kind==3)s.z0=0,s.z1=0xffffff;
  bool rejected=false;try{span(s);}catch(const std::invalid_argument&){rejected=true;}check(rejected);
 }
 auto bad=span(Span{});bad[13]=Textures+4;bad[2]|=Textured;check(pack(bad)[15]>>31);
 bad=span(Span{});bad[31]|=1u<<10;check(pack(bad)[15]>>31);
 bad={};bad[0]=10;check(pack(bad)[15]>>31);
 std::printf("PASS %u extrapolated linear pixels, signed reciprocal boundaries and malformed compact descriptors\n",pixels);
}
