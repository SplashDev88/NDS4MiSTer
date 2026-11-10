#include "GPU3D_Soft.h"
#include <cstdio>
#include <cstdlib>
using namespace melonDS;
int main() {
#if defined(__arm__) && defined(__ARM_NEON)
 unsigned long long checks=0;
 for (u32 width=1;width<=1024;width*=2)
 for (s32 left=0;left<=511;left+=13)
 for (s32 right=0;right<=511;right+=17)
 for (u32 first : {0u,width/3,width-1}) {
  NDS4MiSTerGrayPowerOfTwoSpan vec(left,right,width,first);
  for(u32 x=first;x<width;x+=4,vec.Advance()) {
   u32 actual[4];vst1q_u32(actual,vec.Get());
   for(u32 i=0;i<4&&x+i<width;++i) {
    const s32 expected=left<right ? left+(right-left)*s32(x+i)/s32(width) : right+(left-right)*s32(width-x-i)/s32(width);
    if(actual[i]!=u32(expected)>>3) {std::fprintf(stderr,"FAIL width=%u endpoints=%d,%d x=%u got=%u expected=%d\n",width,left,right,x+i,actual[i],expected>>3);return 1;}
    ++checks;
   }
  }
 }
 std::printf("PASS power-of-two gray numerator: %llu independent samples\n",checks);
#else
 return 2;
#endif
}
