// SPDX-License-Identifier: GPL-3.0-only
#include "transport.h"
#include <random>
#include <cstdio>
#include <stdexcept>
using namespace fpga3d;
void check(bool ok){if(!ok)throw std::runtime_error("transport guard/data mismatch");}
int main(){
 check(!lightScene(31,0) && lightScene(32,32767) && !lightScene(32,32768));
 Admission admission;check(!admission.defer());admission.unsupported();
 for(unsigned i=0;i<60;i++)check(admission.defer());
 check(!admission.defer());admission.unsupported();admission.reset();check(!admission.defer());
 std::mt19937 rng(9716);const uint32_t guard=0xa93c51e7;
 std::vector<Command> cmds(MaxCommands);for(unsigned i=0;i<cmds.size();i++){
  for(auto& w:cmds[i])w=rng();cmds[i][0]=i%5==4?99:i%5+1;
 }
 for(unsigned offset:{32u,33u}){
  std::vector<uint32_t> buffer((MaxCommands+2)*16,guard);
  uploadCommands(buffer.data()+offset,cmds);barrier();
  for(unsigned i=0;i<buffer.size();i++){
   uint32_t expected=guard;
   if(i>=offset && (i-offset)/16<cmds.size()){
    auto& c=cmds[(i-offset)/16];if((i-offset)%16<commandWords(c))expected=pack(c)[(i-offset)%16];
   }
   check(buffer[i]==expected);
  }
 }
 // Both logical and already-packed single-command paths must preserve the
 // invalid-opcode marker and the same partial Device-word write contract.
 for(bool wc:{false,true})for(const auto& c:cmds){
  alignas(8) uint32_t a[20],b[20];std::fill_n(a,20,guard);std::fill_n(b,20,guard);
  const auto packed=pack(c);
  uploadCommand(a+2,c,wc);uploadPackedCommand(b+2,packed,wc);
  for(unsigned i=0;i<20;i++){
   const uint32_t expected=i>=2 && i<2+(wc?16:commandWords(c))?packed[i-2]:guard;
   check(a[i]==expected && b[i]==expected);
  }
 }
 std::vector<uint32_t> source(256*192),dest(258*192+16,guard),texture(8192),target(8200,guard);
 for(auto& w:source)w=rng();for(auto& w:texture)w=rng();
 for(bool wc:{false,true}){
  bind(nullptr,source.data(),false,wc);copyOutput(dest.data()+8,258);
  for(unsigned i=0;i<dest.size();i++)check(dest[i]==(i>=8 && i<dest.size()-8 && (i-8)%258<256?source[((i-8)/258)*256+(i-8)%258]:guard));
  uploadTextures(target.data()+4,texture);barrier();
  for(unsigned i=0;i<target.size();i++)check(target[i]==(i>=4 && i<8196?texture[i-4]:guard));
  uploadTextures(target.data()+4,{});
 }
 puts("PASS aligned/unaligned command upload, opcode field limits, WC and Device copy paths, row and arena guards");
}
