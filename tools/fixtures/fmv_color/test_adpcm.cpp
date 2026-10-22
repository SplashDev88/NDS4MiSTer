// SPDX-License-Identifier: GPL-3.0-only
#include <algorithm>
#include <array>
#include <vector>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <sys/mman.h>
extern "C" void test_decode(void*,void*,void*,void*,unsigned);
extern "C" void test_decode_exit();
static uint32_t seed=0x4be72291;
static uint32_t rnd(){seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;return seed;}
static std::vector<uint8_t> read(const char*p){std::ifstream f(p,std::ios::binary);if(!f)throw std::runtime_error(p);return {std::istreambuf_iterator<char>(f),{}};}
static uint8_t* map(uintptr_t a,size_t n){auto*p=mmap((void*)a,n,PROT_READ|PROT_WRITE|PROT_EXEC,MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE,-1,0);if(p!=(void*)a)throw std::runtime_error("map failed");return (uint8_t*)p;}
int main(){
 auto o=read("/tmp/original-adpcm.bin"),c=read("/tmp/candidate-adpcm.bin"),tab=read("/tmp/adpcm-tables.bin"),lit=read("/tmp/adpcm-original-literals.bin");
 auto*oc=map(0x02059000,0x2000);auto*cc=map(0x03059000,0x2000);auto*t=map(0x02086000,0x1000);std::memcpy(t+0x2d0,tab.data(),tab.size());
 uint32_t ret[]={0xe51ff004,uint32_t(uintptr_t(&test_decode_exit))};
 for(auto x:{oc,cc}){std::memcpy(x+0xd20,lit.data(),lit.size());std::memcpy(x+0xab0,ret,sizeof(ret));}
 std::memcpy(oc+0x960,o.data(),o.size());std::memcpy(cc+0x960,c.data(),c.size());__builtin___clear_cache((char*)oc,(char*)oc+0x2000);__builtin___clear_cache((char*)cc,(char*)cc+0x2000);
 uint64_t samples=0;
 for(unsigned test=0;test<50000;++test){
  unsigned bytes=1+rnd()%128;std::vector<uint8_t> data(bytes);for(auto&v:data)v=rnd();
  constexpr int pred[]={-32768,-32767,-1,0,1,32766,32767};int predictor=test<256*89*7?pred[test%7]:int16_t(rnd());unsigned index=(test/7)%89;
  if(test<256*89*7)data[0]=uint8_t(test/(89*7));
  std::array<uint8_t,4>a{},b{},expected{};int16_t p=predictor;std::memcpy(a.data(),&p,2);a[2]=index;a[3]=0xcd;b=a;expected=a;
  std::vector<int16_t> oa(bytes*2+32,0x1234),ob=oa,ref=oa;
  for(unsigned j=0;j<bytes*2;++j){unsigned nib=(data[j/2]>>(j%2*4))&15;int16_t step;std::memcpy(&step,t+0x2e0+index*2,2);int delta=(step>>3)+((nib&4)?step:0)+((nib&2)?step>>1:0)+((nib&1)?step>>2:0);predictor+=(nib&8)?-delta:delta;predictor=std::max(-32768,std::min(32767,predictor));index=std::max(0,std::min(88,int(index)+int8_t(t[0x2d0+nib])));ref[16+j]=predictor;}
  p=predictor;std::memcpy(expected.data(),&p,2);expected[2]=index;
  test_decode(oc+0x960,a.data(),data.data(),oa.data()+16,bytes*2);test_decode(cc+0x960,b.data(),data.data(),ob.data()+16,bytes*2);
  if(a!=b||a!=expected||oa!=ob||oa!=ref){std::cerr<<"FAIL test="<<test<<" bytes="<<bytes<<" state="<<unsigned(a[2])<<","<<unsigned(b[2])<<","<<unsigned(expected[2])<<"\n";return 1;}
  samples+=bytes*2;
 }
 std::cout<<"PASS ADPCM original/candidate/reference: "<<samples<<" samples, 50000 blocks; predictor saturation, all step indices, PCM and state guards\n";
}
