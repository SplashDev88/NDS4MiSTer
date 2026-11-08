// SPDX-License-Identifier: GPL-3.0-only
// Original ROM-free-content demo: two moving, depth-tested Gouraud triangles.
// All matrices and vertex commands execute through the normal emulated GX.
#include <stdint.h>
#define R16(a) (*(volatile uint16_t*)(a))
#define R32(a) (*(volatile uint32_t*)(a))
static void gx(unsigned op,uint32_t value){R32(0x04000400+4*op)=value;}
static void vertex(int x,int y,int z){gx(0x23,(uint16_t)x|((uint32_t)(uint16_t)y<<16));gx(0x23,(uint16_t)z);}
void diagnostic_main(void){
 R32(0x04000208)=0;
 R16(0x04000304)=0x820f;
 R32(0x04000000)=0x00010108;
 R16(0x04000060)=0x0009; // texture/alpha enabled, no AA/fog/edge effects
 R32(0x04000350)=0x001f0842;
 R16(0x04000354)=0x7fff;
 gx(0x60,0xbfff0000);
 gx(0x10,0);gx(0x15,0);gx(0x10,1);gx(0x15,0);
 gx(0x2a,0);
 unsigned frame=0;
 for(;;){
  while(R16(0x04000006)>=192){}
  while(R16(0x04000006)<192){}
  int phase=frame&255;int movement=(phase<128?phase:256-phase)*16-1024;
  gx(0x29,0x011f00c0);gx(0x40,0);
  gx(0x20,31);vertex(-2304+movement,-2048,512);
  gx(0x20,31<<5);vertex(2304+movement,-2048,512);
  gx(0x20,31<<10);vertex(movement,2304,512);
  gx(0x41,0);
  gx(0x29,0x021f00c0);gx(0x40,0);
  gx(0x20,0x03ff);vertex(-1792-movement,1536,-512);
  gx(0x20,0x7c1f);vertex(1792-movement,1536,-512);
  gx(0x20,0x7fe0);vertex(-movement,-1792,-512);
  gx(0x41,0);gx(0x50,0);
  *(volatile uint32_t*)0x023e0000=++frame;
 }
}
