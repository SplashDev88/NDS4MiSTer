// SPDX-License-Identifier: GPL-3.0-only
#include "texture_residency.h"
#include "abi.h"
#include <cstdio>
#include <random>
#include <stdexcept>
using namespace fpga3d;
static void check(bool condition){if(!condition)throw std::runtime_error("resident texture memory mismatch");}
int main(){
 std::mt19937 rng(731902);TextureResidency resident;
 constexpr uint32_t Guard=0xac219d74;
 std::vector<uint32_t> device(TextureBytes/4+32,Guard),data;
 uint64_t compared=0;unsigned calls=0;
 auto apply=[&](bool reuse){
  const auto before=device;
  const size_t bytes=resident.upload(data,reuse,[&](size_t off,const uint32_t* p,size_t n){
   check(off+n<=data.size());++calls;
   std::copy_n(p,n,device.begin()+16+off);
  });
  check(bytes<=data.size()*4);
  if(!reuse)check(bytes==data.size()*4);
  for(size_t i=0;i<device.size();++i)
   check(device[i]==(i>=16 && i<16+data.size()?data[i-16]:before[i]));
  compared+=data.size();return bytes;
 };
 // Full, stable, sparse changes, shrink followed by commands overwriting the
 // old tail, zero-valued growth and loss of ownership all use full-copy oracle.
 data.assign(TextureBytes/4,0);check(apply(false)==TextureBytes);check(apply(true)==0);
 data[7]=23;data[257]=91;check(apply(true)==2048);check(apply(true)==0);
 data.resize(64);apply(true);
 std::fill(device.begin()+80,device.end()-16,0xdeadbeef);
 data.resize(4096,0);apply(true);
 std::fill(device.begin()+16,device.end()-16,0x12345678);apply(false);
 for(unsigned i=0;i<2000;i++){
  if(i%7==0)data.resize((rng()%3073)*64);
  if(!data.empty())for(unsigned j=0;j<1+(rng()%40);j++)data[rng()%data.size()]=rng();
  const bool reuse=i%31!=0;
  if(!reuse)std::fill(device.begin()+16,device.end()-16,rng());
  apply(reuse);check(apply(true)==0);
 }
 data.clear();check(apply(true)==0);data.resize(64,0);check(apply(true)==256);
 std::printf("PASS 2000 randomized transitions, %llu exact words, %u upload runs; unchanged frames, mutations, resize, ownership loss and guards\n",(unsigned long long)compared,calls);
}
