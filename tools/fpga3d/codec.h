// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "abi.h"
namespace fpga3d {
using PackedCommand=std::array<uint32_t,16>;
template<unsigned Bit,unsigned Width> inline void put(PackedCommand& p,uint32_t x){
 static_assert(Width<=32 && Bit+Width<=512);
 if constexpr(Width<32)x&=(uint32_t(1)<<Width)-1;
 p[Bit/32]|=x<<(Bit%32);
 if constexpr(Bit%32+Width>32)p[Bit/32+1]|=x>>(32-Bit%32);
}
template<unsigned Bit,unsigned Width> inline uint32_t get(const PackedCommand& p){
 uint32_t x=p[Bit/32]>>(Bit%32);
 if constexpr(Bit%32+Width>32)x|=p[Bit/32+1]<<(32-Bit%32);
 if constexpr(Width<32)x&=(uint32_t(1)<<Width)-1;
 return x;
}
inline uint32_t signed24(uint32_t x){return uint32_t(int32_t(x<<8)>>8);}
inline uint32_t signed16(uint32_t x){return uint32_t(int32_t(x<<16)>>16);}
inline PackedCommand pack(const Command& c){
 PackedCommand p{};
 if(c[0]!=2){
  unsigned n=c[0]==1?7:(c[0]==3 || c[0]==5)?2:c[0]==4?13:1;
  std::copy_n(c.begin(),n,p.begin());if(c[0]!=1 && c[0]!=3 && c[0]!=4 && c[0]!=5)p[15]=0x80000000;return p;
 }
 unsigned first=c[1]&65535,end=c[1]>>16,width=c[3]&65535,dx=c[3]>>16;
 bool invalid=first>=end || end>256 || !width || width>256 || dx+end-first>width ||
  (c[2]&~0x1f3fu) || (c[27]&~0x3f008010u) || (c[31]&~0xf3fu) ||
  (c[30]&65535)>(c[30]>>16) || (c[30]>>16)>256;
 if(c[2]&Textured)invalid|=c[13]<Textures || c[13]>=Textures+TextureBytes || (c[13]&7) ||
  (c[14]&15)<3 || (c[14]&15)>10 || ((c[14]>>4)&15)<3 || ((c[14]>>4)&15)>10 || (c[14]&~0xfffu);
 uint32_t a=(c[2]&WBuffer)?c[15]:c[5],b=(c[2]&WBuffer)?c[26]:c[6];
 if(!(c[2]&WBuffer) && width==1)b=0;
 invalid|=a>0xffffff || ((c[2]&WBuffer)?b>0xffffff:signed24(b)!=b);
 put<0,3>(p,2);put<3,8>(p,first);put<11,8>(p,end);put<19,8>(p,width);put<27,8>(p,dx);
 put<35,6>(p,c[2]);put<41,5>(p,c[2]>>8);put<46,5>(p,c[31]);put<51,1>(p,c[31]>>5);put<52,2>(p,c[31]>>8);
 put<54,24>(p,a);put<78,24>(p,b);put<102,32>(p,c[4]);put<134,17>(p,(c[13]-Textures)>>3);
 put<151,3>(p,(c[14]&15)-3);put<154,3>(p,((c[14]>>4)&15)-3);put<157,4>(p,c[14]>>8);
 put<161,6>(p,c[27]>>24);put<167,1>(p,c[27]>>4);put<168,1>(p,c[27]>>15);
 auto cov=[](uint32_t v){return (v&1023)|(((v>>12)&1023)<<10)|((v>>31)<<20);};
 put<169,21>(p,cov(c[28]));put<190,21>(p,cov(c[29]));put<211,9>(p,c[30]);put<220,9>(p,c[30]>>16);
 {uint32_t attr=c[8],step=width==1?0:c[16];
 if(c[2]&Linear){invalid|=signed16(step)!=step;attr=(attr&65535)|(step<<16);}
 put<229,32>(p,attr);
 invalid|=(c[21]&65535)>255 || (c[21]>>16)>255;
 put<389,8>(p,c[21]);put<397,8>(p,c[21]>>16);}
 {uint32_t attr=c[9],step=width==1?0:c[17];
 if(c[2]&Linear){invalid|=signed16(step)!=step;attr=(attr&65535)|(step<<16);}
 put<261,32>(p,attr);
 invalid|=(c[22]&65535)>255 || (c[22]>>16)>255;
 put<405,8>(p,c[22]);put<413,8>(p,c[22]>>16);}
 {uint32_t attr=c[10],step=width==1?0:c[18];
 if(c[2]&Linear){invalid|=signed16(step)!=step;attr=(attr&65535)|(step<<16);}
 put<293,32>(p,attr);
 invalid|=(c[23]&65535)>255 || (c[23]>>16)>255;
 put<421,8>(p,c[23]);put<429,8>(p,c[23]>>16);}
 {uint32_t attr=c[11],step=width==1?0:c[19];
 if(c[2]&Linear){invalid|=signed16(step)!=step;attr=(attr&65535)|(step<<16);}
 put<325,32>(p,attr);
 invalid|=(c[24]&65535)>255 || (c[24]>>16)>255;
 put<437,8>(p,c[24]);put<445,8>(p,c[24]>>16);}
 {uint32_t attr=c[12],step=width==1?0:c[20];
 if(c[2]&Linear){invalid|=signed16(step)!=step;attr=(attr&65535)|(step<<16);}
 put<357,32>(p,attr);
 invalid|=(c[25]&65535)>255 || (c[25]>>16)>255;
 put<453,8>(p,c[25]);put<461,8>(p,c[25]>>16);}
 put<495,2>(p,c[31]>>10);put<469,13>(p,c[7]);put<482,13>(p,c[7]>>16);put<511,1>(p,invalid);return p;
}
inline Command unpack(const PackedCommand& p){
 Command c{};
 if((p[0]&7)!=2){std::copy(p.begin(),p.end(),c.begin());return c;}
 if(p[15]>>31){c[0]=99;return c;}
 c[0]=2;unsigned end=get<11,8>(p),width=get<19,8>(p);if(!end)end=256;if(!width)width=256;
 c[1]=get<3,8>(p)|(end<<16);c[2]=get<35,6>(p)|(get<41,5>(p)<<8);
 c[3]=width|(get<27,8>(p)<<16);c[4]=get<102,32>(p);
 c[5]=get<54,24>(p);c[6]=signed24(get<78,24>(p));c[15]=get<54,24>(p);c[26]=get<78,24>(p);
 c[7]=get<469,13>(p)|(get<482,13>(p)<<16);
 c[13]=Textures+(get<134,17>(p)<<3);c[14]=(get<151,3>(p)+3)|((get<154,3>(p)+3)<<4)|(get<157,4>(p)<<8);
 c[27]=(get<161,6>(p)<<24)|(get<167,1>(p)<<4)|(get<168,1>(p)<<15);
 auto cov=[](uint32_t v){return (v&1023)|(((v>>10)&1023)<<12)|((v>>20)<<31);};
 c[28]=cov(get<169,21>(p));c[29]=cov(get<190,21>(p));
 c[30]=get<211,9>(p)|(get<220,9>(p)<<16);
 c[31]=get<46,5>(p)|(get<51,1>(p)<<5)|(get<52,2>(p)<<8)|(get<495,2>(p)<<10);
 c[8]=get<229,32>(p);c[16]=signed16(c[8]>>16);
 if(c[2]&Linear)c[8]&=65535;
 c[21]=get<389,8>(p)|(get<397,8>(p)<<16);
 c[9]=get<261,32>(p);c[17]=signed16(c[9]>>16);
 if(c[2]&Linear)c[9]&=65535;
 c[22]=get<405,8>(p)|(get<413,8>(p)<<16);
 c[10]=get<293,32>(p);c[18]=signed16(c[10]>>16);
 if(c[2]&Linear)c[10]&=65535;
 c[23]=get<421,8>(p)|(get<429,8>(p)<<16);
 c[11]=get<325,32>(p);c[19]=signed16(c[11]>>16);
 if(c[2]&Linear)c[11]&=65535;
 c[24]=get<437,8>(p)|(get<445,8>(p)<<16);
 c[12]=get<357,32>(p);c[20]=signed16(c[12]>>16);
 if(c[2]&Linear)c[12]&=65535;
 c[25]=get<453,8>(p)|(get<461,8>(p)<<16);
return c;
}
}
