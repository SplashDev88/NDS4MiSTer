// SPDX-License-Identifier: GPL-3.0-only
#include "Vnds_fpga3d_mix_test.h"
#include <cstdio>
#include <initializer_list>
int main(){
 Vnds_fpga3d_mix_test v;unsigned comparisons=0;
 for(unsigned shift:{5u,7u})for(unsigned a=0;a<64;a++)for(unsigned b=0;b<64;b++)for(unsigned w=0;w<=(1u<<shift);w++){
  v.source=a;v.dest=b;v.weight=w;v.shift=shift;v.eval();
  unsigned expected=(a*w+b*((1u<<shift)-w))>>shift;
  if(v.result_value!=expected){std::fprintf(stderr,"FAIL source=%u dest=%u weight=%u shift=%u expected=%u actual=%u\n",a,b,w,shift,expected,v.result_value);return 1;}
  comparisons++;
 }
 std::printf("PASS %u exact signed blend/fog interpolation comparisons, including every negative delta and endpoint\n",comparisons);
}
