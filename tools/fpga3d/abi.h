// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <array>
#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <vector>
namespace fpga3d {
constexpr uint32_t Magic=0x32443346; // F3D2
constexpr uint32_t Mailbox=0x3fc80000, Commands=0x3fc81000;
constexpr uint32_t Output=0x3fd00000, Textures=0x3fd40000;
constexpr uint32_t TextureBytes=0xc0000, MaxCommands=0x7f000/128;
using Command=std::array<uint32_t,32>;
enum Flags:uint32_t { Linear=1, WBuffer=2, Textured=4, Front=8, Back=16, Equal=32 };
struct Span {
 int first=0,end=256,origin=0,width=256,w0=128,w1=128;
 int32_t z0=0,z1=0;
 std::array<int32_t,5> left{},right{};
 uint32_t flags=Linear,texture=Textures,shiftS=3,shiftT=3,wrap=0,alphaRef=0;
 uint32_t polyAttr=0,leftCov=31,rightCov=31,leftEnd=0,rightBegin=256,polyAlpha=31,yEdge=0;
 bool depthWrite=false;
};
inline int64_t floorDiv(int64_t n,int64_t d) {
 if(d<=0)throw std::invalid_argument("nonpositive divisor");
 return n/d-((n<0 && n%d)!=0);
}
inline Command clear(uint32_t y,uint32_t color,uint32_t depth,bool back=false,uint32_t attr=0,uint32_t config=0) {
 Command c{};c[0]=1;c[1]=color;c[2]=depth;c[3]=back;c[4]=y;c[5]=attr|(back?16:0);c[6]=config;return c;
}
inline Command fog(uint32_t color,uint32_t offset,uint32_t shift,const uint8_t* table) {
 if(shift>15 || !table)throw std::invalid_argument("invalid fog configuration");
 Command c{};c[0]=4;c[1]=color;c[2]=offset;c[3]=shift;
 for(unsigned i=0;i<34;i++){
  if(table[i]>127)throw std::invalid_argument("invalid fog density");
  c[4+i/4]|=uint32_t(table[i])<<(8*(i%4));
 }
 return c;
}
inline Command flush(uint32_t y) {Command c{};c[0]=3;c[1]=y;return c;}
inline Command span(const Span& s) {
 if(s.first<0 || s.end>256 || s.first>=s.end || s.width<1 || s.width>256 ||
    s.first<s.origin || s.end>s.origin+s.width || s.w0<0 || s.w0>65535 || s.w1<0 || s.w1>65535 ||
    s.z0<0 || s.z1<0 || s.z0>0xffffff || s.z1>0xffffff || s.alphaRef>31 ||
    s.shiftS<3 || s.shiftS>10 || s.shiftT<3 || s.shiftT>10 || (s.flags&~63u) || s.polyAlpha>31 || s.leftEnd>s.rightBegin || s.rightBegin>256 || (s.yEdge&~12u))
    throw std::invalid_argument("span outside hardware contract");
 Command c{};const int dx=s.first-s.origin;
 c[0]=2;c[1]=s.first|(s.end<<16);c[2]=s.flags|(s.alphaRef<<8);
 c[3]=s.width|(dx<<16);c[4]=s.w0|(s.w1<<16);
 const int64_t dz=int64_t(std::abs(s.z1-s.z0)>>9)*((1<<22)/s.width);
 const int64_t initial=dz*(s.z0<s.z1?dx:s.width-dx);
 const int64_t step=s.z0<s.z1?dz:-dz;
 c[5]=std::min(s.z0,s.z1)+(initial>>13);
 c[6]=uint32_t(floorDiv(step,8192));
 c[7]=uint32_t(initial&8191)|(uint32_t(step-floorDiv(step,8192)*8192)<<16);
 for(int i=0;i<5;i++) {
   if(s.left[i]<-32768 || s.left[i]>32767 || s.right[i]<-32768 || s.right[i]>32767)
     throw std::invalid_argument("attribute outside signed16");
   int64_t delta=s.right[i]-s.left[i],n=delta*dx;
   c[8+i]=uint16_t(s.left[i])|(uint32_t(uint16_t(s.right[i]))<<16);
   if(s.flags&Linear)c[8+i]=uint16_t(s.left[i]+floorDiv(n,s.width));
   c[16+i]=uint32_t(floorDiv(delta,s.width));
   c[21+i]=uint32_t(n-floorDiv(n,s.width)*s.width)|
       (uint32_t(delta-floorDiv(delta,s.width)*s.width)<<16);
 }
 c[13]=s.texture;c[14]=s.shiftS|(s.shiftT<<4)|(s.wrap<<8);
 c[15]=s.z0;c[26]=s.z1;
 c[27]=s.polyAttr|((s.flags&Back)?16:0);c[28]=s.leftCov;c[29]=s.rightCov;
 c[30]=s.leftEnd|(s.rightBegin<<16);c[31]=s.polyAlpha|(s.depthWrite?32:0)|(s.yEdge<<6);
 return c;
}
// Independent closed-form pixel oracle (no RTL recurrence state).
inline uint32_t factor(const Span& s,int x) {
 uint64_t dx=x-s.origin,den=dx*s.w0+(s.width-dx)*s.w1;
 return den ? uint32_t((dx*s.w0*256)/den):0;
}
inline int32_t attribute(const Span& s,int i,int x) {
 int64_t delta=s.right[i]-s.left[i];
 return s.left[i]+floorDiv(delta*((s.flags&Linear)?x-s.origin:factor(s,x)),(s.flags&Linear)?s.width:256);
}
inline uint32_t depth(const Span& s,int x) {
 if(s.flags&WBuffer)return s.z0+floorDiv(int64_t(s.z1-s.z0)*factor(s,x),256);
 int64_t d=std::abs(s.z1-s.z0)>>9;
 int f=s.z0<s.z1?x-s.origin:s.width-(x-s.origin);
 return std::min(s.z0,s.z1)+((d*f*((1<<22)/s.width))>>13);
}
inline unsigned coord(int v,unsigned shift,bool repeat,bool flip) {
 v=int16_t(v)>>4;unsigned size=1u<<shift,mask=size-1;
 if(!repeat)return std::clamp(v,0,int(mask));
 return flip&&(v&size)?mask-(v&mask):(v&mask);
}
}
