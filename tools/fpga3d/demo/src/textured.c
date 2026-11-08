// SPDX-License-Identifier: GPL-3.0-only
// Original perspective-texture demo. No external art or cartridge data.
#include <stdint.h>
#define R8(a) (*(volatile uint8_t*)(a))
#define R16(a) (*(volatile uint16_t*)(a))
#define R32(a) (*(volatile uint32_t*)(a))
static void gx(unsigned op,uint32_t value){R32(0x04000400+4*op)=value;}
static void vertex(int x,int y,int z,int s,int t){
 gx(0x22,(uint16_t)(s*16)|((uint32_t)(uint16_t)(t*16)<<16));
 gx(0x23,(uint16_t)x|((uint32_t)(uint16_t)y<<16));gx(0x23,(uint16_t)z);
}
void diagnostic_main(void){
 R32(0x04000208)=0;R16(0x04000304)=0x820f;R32(0x04000000)=0x00010108;
 R16(0x04000060)=9;R32(0x04000350)=0x001f0842;R16(0x04000354)=0x7fff;
 R8(0x04000240)=0x80;
 for(unsigned y=0;y<32;y++)for(unsigned x=0;x<32;x++)
  R16(0x06800000+2*(y*32+x))=((x/4)^(y/4))&1?0xffff:0x98c6;
 R8(0x04000240)=0x83;
 gx(0x60,0xbfff0000);gx(0x10,0);
 const int projection[16]={4096,0,0,0,0,4096,0,0,0,0,4096,4096,0,0,0,4096};
 for(unsigned i=0;i<16;i++)gx(0x16,projection[i]);
 gx(0x10,1);gx(0x15,0);gx(0x2a,(2u<<20)|(2u<<23)|(7u<<26));
 unsigned frame=0;
 for(;;){
  while(R16(0x04000006)>=192){}
  while(R16(0x04000006)<192){}
  int phase=frame&255;int motion=(phase<128?phase:256-phase)*8-512;
  gx(0x29,0x011f00c0);gx(0x40,1);
  gx(0x20,0x03ff);vertex(-2304+motion,-2304,-768,0,0);
  gx(0x20,0x7fff);vertex(2304+motion,-2304,768,32,0);
  gx(0x20,0x7c1f);vertex(2304+motion,2304,768,32,32);
  gx(0x20,0x7fe0);vertex(-2304+motion,2304,-768,0,32);
  gx(0x41,0);gx(0x50,0);*(volatile uint32_t*)0x023e0000=++frame;
 }
}
