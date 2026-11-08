// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <array>
#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <vector>
namespace fpga3d {
constexpr uint32_t Magic=0x33443346; // F3D3
constexpr uint32_t Mailbox=0x3fc80000, Commands=0x3fc81000;
constexpr uint32_t Output=0x3fd00000, Textures=0x3fd40000;
constexpr uint32_t TextureBytes=0xc0000, MaxCommands=0x7f000/64;
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
constexpr auto smallReciprocals=[](){std::array<uint32_t,257> a{};for(unsigned d=2;d<=256;d++)a[d]=(uint64_t(1)<<32)/d;return a;}();
constexpr auto depthReciprocals=[](){std::array<uint32_t,257> a{};for(unsigned d=1;d<=256;d++)a[d]=(1u<<22)/d;return a;}();
inline int32_t floorDivSmall(int32_t n,int32_t d){
 if(d==1)return n;
 const uint32_t magnitude=n<0?uint32_t(-n):uint32_t(n);
 uint32_t q=(uint64_t(magnitude)*smallReciprocals[d])>>32;
 uint32_t r=magnitude-q*d;if(r>=uint32_t(d)){q++;r-=d;}
 return n<0?-int32_t(q)-int32_t(r!=0):int32_t(q);
}
inline Command spanRegular(const Span& s) {
 if(s.first<0 || s.end>256 || s.first>=s.end || s.width<1 || s.width>256 ||
    s.first<s.origin || s.end>s.origin+s.width || s.w0<0 || s.w0>65535 || s.w1<0 || s.w1>65535 ||
    s.z0<0 || s.z1<0 || s.z0>0xffffff || s.z1>0xffffff || s.alphaRef>31 ||
    s.shiftS<3 || s.shiftS>10 || s.shiftT<3 || s.shiftT>10 || (s.flags&~63u) || s.polyAlpha>31 || s.leftEnd>s.rightBegin || s.rightBegin>256 || (s.yEdge&~12u))
    throw std::invalid_argument("span outside hardware contract");
 Command c{};const int dx=s.first-s.origin;
 c[0]=2;c[1]=s.first|(s.end<<16);c[2]=s.flags|(s.alphaRef<<8);
 c[3]=s.width|(dx<<16);c[4]=s.w0|(s.w1<<16);
 if(!(s.flags&WBuffer)){
 const int64_t dz=int64_t(std::abs(s.z1-s.z0)>>9)*depthReciprocals[s.width];
 const int64_t initial=dz*(s.z0<s.z1?dx:s.width-dx);
 const int64_t step=s.z0<s.z1?dz:-dz;
 c[5]=std::min(s.z0,s.z1)+(initial>>13);
 c[6]=uint32_t(floorDiv(step,8192));
 c[7]=uint32_t(initial&8191)|(uint32_t(step-floorDiv(step,8192)*8192)<<16);
 }
 for(int i=0;i<5;i++) {
   if(s.left[i]<-32768 || s.left[i]>32767 || s.right[i]<-32768 || s.right[i]>32767)
     throw std::invalid_argument("attribute outside signed16");
   c[8+i]=uint16_t(s.left[i])|(uint32_t(uint16_t(s.right[i]))<<16);
   if(s.flags&Linear){
    const int32_t delta=s.right[i]-s.left[i],n=delta*dx;
    const int32_t qn=floorDivSmall(n,s.width),qd=floorDivSmall(delta,s.width);
    c[8+i]=uint16_t(s.left[i]+qn);c[16+i]=uint32_t(qd);
    c[21+i]=uint32_t(n-qn*s.width)|(uint32_t(delta-qd*s.width)<<16);
   }
 }
 c[13]=s.texture;c[14]=s.shiftS|(s.shiftT<<4)|(s.wrap<<8);
 c[15]=s.z0;c[26]=s.z1;
 c[27]=s.polyAttr|((s.flags&Back)?16:0);c[28]=s.leftCov;c[29]=s.rightCov;
 c[30]=s.leftEnd|(s.rightBegin<<16);c[31]=s.polyAlpha|(s.depthWrite?32:0)|(s.yEdge<<6);
 return c;
}
// The cached native interior may revisit the pixel immediately left of a
// narrow linear span. Preserve its exact recurrence with a shifted origin and
// a scaled denominator; coverage still advances in the FPGA after depth pass.
[[gnu::noinline]] inline Command spanLinearExtrapolated(Span value) {
                    const auto old=value;const int dx=old.first-old.origin;
                    if(old.width<1 || old.width>256 || old.z0<0 || old.z1<0 || old.z0>0xffffff || old.z1>0xffffff)throw std::invalid_argument("extrapolated span bounds");
                    for(int k=0;k<5;k++)if(old.left[k]<-32768 || old.left[k]>32767 || old.right[k]<-32768 || old.right[k]>32767)throw std::invalid_argument("extrapolated endpoint bounds");
                    const int scale=(old.end-old.first+old.width-1)/old.width;
                    value.origin=value.first;value.width=old.width*scale;
                    if(old.width<1 || value.width>256)throw std::invalid_argument("extrapolated span denominator");
                    const int64_t dz=int64_t(std::abs(old.z1-old.z0)>>9)*((1<<22)/old.width);
                    const int64_t initial=dz*(old.z0<old.z1?dx:old.width-dx);
                    const int64_t step=old.z0<old.z1?dz:-dz;
                    const int64_t zfirst=std::min(old.z0,old.z1)+fpga3d::floorDiv(initial,8192);
                    const int64_t zend=std::min(old.z0,old.z1)+fpga3d::floorDiv(initial+step*(old.end-old.first-1),8192);
                    if(zfirst<0 || zfirst>0xffffff || zend<0 || zend>0xffffff)throw std::invalid_argument("extrapolated depth bounds");
                    value.z0=value.z1=int(zfirst);
                    for(int k=0;k<5;k++)value.left[k]=value.right[k]=old.left[k]+fpga3d::floorDiv(int64_t(old.right[k]-old.left[k])*dx,old.width);
                    auto c=spanRegular(value);
                    const int64_t zstep=fpga3d::floorDiv(step,8192);
                    if(zstep<-8388608 || zstep>8388607)throw std::invalid_argument("extrapolated depth step bounds");
                    c[5]=zfirst;c[6]=uint32_t(zstep);
                    c[7]=uint32_t(initial-fpga3d::floorDiv(initial,8192)*8192)|(uint32_t(step-fpga3d::floorDiv(step,8192)*8192)<<16);
                    for(int k=0;k<5;k++){
                        const int64_t delta=old.right[k]-old.left[k],n=delta*dx;
                        const int64_t qn=fpga3d::floorDiv(n,old.width),qd=fpga3d::floorDiv(delta,old.width);
                        const int64_t last=old.left[k]+fpga3d::floorDiv(delta*(dx+old.end-old.first-1),old.width);
                        if(qd<-32768 || qd>32767 || last<-32768 || last>32767)throw std::invalid_argument("extrapolated attribute bounds");
                        c[16+k]=uint32_t(qd);
                        c[21+k]=uint32_t((n-qn*old.width)*scale)|(uint32_t((delta-qd*old.width)*scale)<<16);
                    }
 return c;
}
inline Command span(const Span& s){
 if((s.flags&Linear) && !(s.flags&WBuffer) && s.first>=0 && s.end<=256 && s.first<s.end &&
    s.width>=1 && s.width<=256 && int64_t(s.first)==int64_t(s.origin)-1 &&
    int64_t(s.end)<=int64_t(s.origin)+s.width)return spanLinearExtrapolated(s);
 return spanRegular(s);
}
// Independent closed-form pixel oracle (no RTL recurrence state).
inline uint32_t factor(const Span& s,int x) {
 uint64_t dx=x-s.origin,den=dx*s.w0+(s.width-dx)*s.w1;
 return den ? uint32_t((dx*s.w0*256)/den):0;
}
inline int32_t attribute(const Span& s,int i,int x) {
 int64_t delta=s.right[i]-s.left[i];
 if(s.flags&Linear)return s.left[i]+floorDiv(delta*int64_t(x-s.origin),s.width);
 return s.left[i]+floorDiv(delta*factor(s,x),256);
}
inline uint32_t depth(const Span& s,int x) {
 if(s.flags&WBuffer)return s.z0+floorDiv(int64_t(s.z1-s.z0)*factor(s,x),256);
 int64_t d=std::abs(s.z1-s.z0)>>9;
 int f=s.z0<s.z1?x-s.origin:s.width-(x-s.origin);
 return std::min(s.z0,s.z1)+((d*f*depthReciprocals[s.width])>>13);
}
inline unsigned coord(int v,unsigned shift,bool repeat,bool flip) {
 v=int16_t(v)>>4;unsigned size=1u<<shift,mask=size-1;
 if(!repeat)return std::clamp(v,0,int(mask));
 return flip&&(v&size)?mask-(v&mask):(v&mask);
}
}
