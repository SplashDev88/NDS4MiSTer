/* SPDX-License-Identifier: GPL-3.0-only */
/* Authored DS hardware test. No retail ROM, logo, firmware or BIOS bytes.
 * Screen: yellow=running, green=program/readback passed, blue=prior save loaded,
 * red=failure. Two full pages cover banks above 1 MiB and near the writable end.
 */
typedef unsigned int u32, uint32_t; typedef unsigned short u16, uint16_t; typedef unsigned char uint8_t;
#include "display.h"
static volatile u32 stage, observed;
#define REG32(a) (*(volatile u32 *)(a))
#define REG16(a) (*(volatile u16 *)(a))
#ifndef SAVE_BYTES
#define SAVE_BYTES 0x01000000u
#endif
#define BASE 0x06a00000u
#define ADDR0 (BASE+0x00100000u)
#define ADDR1 (BASE+SAVE_BYTES-0x20800u)
static void color(u16 value){
 REG16(0x04000304)=0x8003; *(volatile uint8_t*)0x04000240=0x80;
 REG32(0x04000000)=0x00020000; REG16(0x0400006c)=0;
 for(u32 i=0;i<256*192;i++) fb[i]=0x8000|value;
 text(8,8,"NAND authored test v2"); text(8,24,"Stage");hex(48,24,stage,2);
 text(8,40,"Value");hex(48,40,observed,8);
}
static void fail(void){color(31);for(;;){}}
static void idle(void){for(u32 i=0;i<10000000;i++)if(!(REG32(0x040001a4)&0x80000000))return;fail();}
static void ready(void){for(u32 i=0;i<10000000;i++)if(REG32(0x040001a4)&0x00800000)return;fail();}
static void command(u32 op,u32 a,u32 len,u32 writing){
 idle();REG32(0x040001a8)=op|((a>>24)&255)<<8|((a>>16)&255)<<16|((a>>8)&255)<<24;
 REG32(0x040001ac)=a&255;REG32(0x040001a4)=0x80000000u|(len<<24)|(writing<<30);
 if(!len)idle();
}
static u32 receive(void){ready();return REG32(0x04100010);}
static u32 status(void){command(0xd6,0,7,0);return receive();}
static void window(u32 a){command(0xb2,a,0,0);}
static u32 pattern(u32 page,u32 i){return 0xa5c36987u^(i*0x00010001u)^(page*0x19283746u);}
static int check(u32 page,u32 a){
 window(a);command(0xb7,a,3,0);u32 mismatch=0;
 for(u32 i=0;i<512;i++)mismatch|=receive()^pattern(page,i);
 return mismatch==0;
}
static void program(u32 page,u32 a){
 window(a);command(0x85,0,0,0);if(status()!=0x30303030u)fail();
 for(u32 part=0;part<4;part++){
  command(0x81,a,1,1);
  for(u32 i=0;i<128;i++){ready();REG32(0x04100010)=pattern(page,part*128+i);}
 }
 command(0x82,0,0,0);
 for(u32 n=0;n<100000;n++)if(status()&32)return;
 fail();
}
void main(void){
 REG32(0x04000208)=0;REG16(0x04000204)=REG16(0x04000204)&~0x800;
 REG16(0x040001a0)=0xc000;color(31|31<<5);
 stage=1; observed=status(); if(observed!=0x20202020u)fail();
 stage=2; command(0xb8,0,7,0);observed=receive();if(observed!=0x08007fc2u)fail();
 stage=3; command(0x94,0,7,0);observed=receive();if(observed!=0x9500f1ecu)fail();
 stage=4; int persisted=check(0,ADDR0)&check(1,ADDR1);
 if(!persisted){stage=5; program(0,ADDR0);stage=6; program(1,ADDR1);stage=7;if(!check(0,ADDR0)||!check(1,ADDR1))fail();}
 stage=8; window(BASE+SAVE_BYTES-0x20000);command(0xb7,BASE+SAVE_BYTES-0x800,7,0);if(receive()!=0xa19e00ecu)fail();
 stage=9; command(0x8b,0,0,0);command(0xb7,BASE,7,0);if(receive()!=0xffffffffu)fail();
 stage=10; observed=persisted; color(persisted ? 31<<10 : 31<<5);for(;;){}
}
