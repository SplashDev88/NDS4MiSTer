// SPDX-License-Identifier: GPL-3.0-only
#include "transport.h"
#include <random>
#include <cstdio>
#include <stdexcept>
using namespace fpga3d;
void check(bool ok){if(!ok)throw std::runtime_error("transport guard/data mismatch");}
int main(){
 std::mt19937 rng(9716);const uint32_t guard=0xa93c51e7;
 std::vector<Command> cmds(MaxCommands);for(unsigned i=0;i<cmds.size();i++){
  for(auto& w:cmds[i])w=rng();cmds[i][0]=i%4==3?99:i%4+1;
 }
 for(unsigned offset:{32u,33u}){
  std::vector<uint32_t> buffer((MaxCommands+2)*32,guard);
  uploadCommands(buffer.data()+offset,cmds);barrier();
  for(unsigned i=0;i<buffer.size();i++){
   uint32_t expected=guard;
   if(i>=offset && (i-offset)/32<cmds.size()){
    auto& c=cmds[(i-offset)/32];if((i-offset)%32<commandWords(c))expected=c[(i-offset)%32];
   }
   check(buffer[i]==expected);
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
