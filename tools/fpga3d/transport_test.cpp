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
 for(unsigned i=0;i<1000;i++){
  Span s;s.flags|=Textured;s.texture=Textures+(rng()%(TextureBytes/8))*8;
  auto c=span(s);auto p=pack(c);
  c[13]=Textures+(rng()%(TextureBytes/8))*8;rebindTexture(p,c[13]);
  check(p==pack(c));
  c[13]=Textures+(rng()%(TextureBytes/64))*64;c[14]|=1u<<12;
  rebindTexture(p,c[13]|1u);check(p==pack(c));
  c[14]&=~(1u<<12);rebindTexture(p,c[13]);check(p==pack(c));
 }
 // More decoded data than the original 768 KiB arena, with exact RGBA
 // reconstruction, duplicate bindings, mutation, and the 256-color boundary.
 {
  Frame f;std::vector<std::vector<uint32_t>> data(16,std::vector<uint32_t>(128*128));
  for(unsigned t=0;t<data.size();t++){
   for(unsigned i=0;i<data[t].size();i++)data[t][i]=((i+t)&31)<<24|((i&63)<<16)|(((i>>2)&63)<<8)|((i*7+t)&63);
   check(f.addTexture(data[t].data(),data[t].size()));
   const auto binding=f.textureOffsets.at(data[t].data());check(binding&1);
   const auto base=((binding&~1u)-Textures)/4;
   for(unsigned i=0;i<data[t].size();i++)check(f.textures[base+((f.textures[base+256+i/4]>>(8*(i%4)))&255)]==data[t][i]);
   const auto size=f.textures.size();check(f.addTexture(data[t].data(),data[t].size()) && f.textures.size()==size);
  }
  check(f.textures.size()*4==16*(1024+16384));
  std::vector<Frame::TextureUse> uses;
  for(unsigned t=0;t<data.size();t++)uses.push_back({data[t].data(),data[t].size(),t+1});
  f.preferRawTextures(uses);
  check(f.textures.size()*4<=TextureBytes);
  unsigned raw=0,indexed=0;
  for(unsigned t=0;t<data.size();t++){
   const auto binding=f.textureOffsets.at(data[t].data());
   const auto base=((binding&~1u)-Textures)/4;
   check(!(base&15));
   if(binding&1){
    indexed++;
    for(unsigned i=0;i<data[t].size();i++)check(f.textures[base+((f.textures[base+256+i/4]>>(8*(i%4)))&255)]==data[t][i]);
   }else{
    raw++;
    check(std::equal(data[t].begin(),data[t].end(),f.textures.begin()+base));
   }
  }
  check(raw==10 && indexed==6 && (f.textureOffsets.at(data.front().data())&1) && !(f.textureOffsets.at(data.back().data())&1));
  const auto savedTextures=f.textures;const auto savedOffsets=f.textureOffsets;
  f.active=true;f.preferRawTextures(uses);f.active=false;
  check(f.textures==savedTextures && f.textureOffsets==savedOffsets);
  f.reset();f.allowIndexed=false;
  check(f.addTexture(data[0].data(),data[0].size()) && !(f.textureOffsets.at(data[0].data())&1));
  check(f.textures==data[0]);
  f.reset();check(f.allowIndexed);
  const auto previousHits=f.indexedCacheHits;
  check(f.addTexture(data[0].data(),data[0].size()) && (f.textureOffsets.at(data[0].data())&1));
  check(f.indexedCacheHits==previousHits+1);
  // Recycled pointers and animated colors must never reuse a stale encoding.
  f.reset();data[0][937]^=0x00000100;
  check(f.addTexture(data[0].data(),data[0].size()) && f.indexedCacheHits==previousHits+1);
  const auto changed=f.textureOffsets.at(data[0].data());
  const auto changedBase=((changed&~1u)-Textures)/4;
  for(unsigned i=0;i<data[0].size();i++)check((changed&1?
   f.textures[changedBase+((f.textures[changedBase+256+i/4]>>(8*(i%4)))&255)]:
   f.textures[changedBase+i])==data[0][i]);
  f.reset();for(unsigned i=0;i<data[0].size();i++)data[0][i]=0x1f000000|i;
  check(f.addTexture(data[0].data(),data[0].size()) && !(f.textureOffsets.at(data[0].data())&1));
  check(f.textures==data[0]);
  f.reset();data[0].back()=0xff000000;
  check(!f.addTexture(data[0].data(),data[0].size()) && f.textures.empty());
 }
 {
  Frame f;std::vector<std::vector<uint32_t>> data(20,std::vector<uint32_t>(256*256));
  for(unsigned t=0;t<data.size();t++){
   std::fill(data[t].begin(),data[t].end(),0x1f000000u|t);f.reset();
   check(f.addTexture(data[t].data(),data[t].size()));
   check(f.indexedCacheBytes<=Frame::IndexedCacheBytes);
  }
  check(!f.indexedCache.count(data.front().data()));
  const auto hits=f.indexedCacheHits;f.reset();
  check(f.addTexture(data.back().data(),data.back().size()) && f.indexedCacheHits==hits+1);
  f.reset();check(f.addTexture(data.front().data(),data.front().size()) && f.indexedCacheHits==hits+1);
  check(f.textures.front()==data.front().front() && f.indexedCacheBytes<=Frame::IndexedCacheBytes);
 }
 std::vector<uint32_t> source(256*192),dest(258*192+16,guard),texture(8192),target(8200,guard);
 // Prepared bindings survive geometry/use-order changes, but never animated
 // palettes, recycled decoded pointers, resizing, or an incomplete source set.
 {
  Frame f;std::vector<std::vector<uint32_t>> data(12,std::vector<uint32_t>(16384));
  std::vector<Frame::TextureUse> uses;
  for(unsigned t=0;t<data.size();t++){
   for(unsigned i=0;i<data[t].size();i++)data[t][i]=0x1f000000u|((i+t)&255);
   uses.push_back({data[t].data(),data[t].size(),t+1});
   check(f.addTexture(data[t].data(),data[t].size()));
  }
  f.preferRawTextures(uses);
  f.preparedTextures.remember(uses,f.textures,f.textureOffsets);
  check(f.preparedTextures.matches(uses));
  std::reverse(uses.begin(),uses.end());for(auto& use:uses)use.rows=999;
  check(f.preparedTextures.matches(uses));
  for(const auto& use:uses){
   const uint32_t binding=f.preparedTextures.bindings.at(use.pixels);
   const size_t base=((binding&~1u)-Textures)/4;const auto& bytes=f.preparedTextures.staged;
   for(size_t i=0;i<use.count;i++)check((binding&1?
    bytes[base+((bytes[base+256+i/4]>>(8*(i%4)))&255)]:bytes[base+i])==use.pixels[i]);
  }
  data[3][777]^=0x100;check(!f.preparedTextures.matches(uses));data[3][777]^=0x100;
  check(f.preparedTextures.matches(uses));uses[0].count/=2;check(!f.preparedTextures.matches(uses));uses[0].count*=2;
  auto replacement=data.back();uses[0].pixels=replacement.data();check(!f.preparedTextures.matches(uses));uses[0].pixels=data.back().data();
  uses.pop_back();check(!f.preparedTextures.matches(uses));
  f.preparedTextures.remember(uses,f.textures,f.textureOffsets);check(!f.preparedTextures.ready);
  uses={{data[0].data(),PreparedTextures::MaxSourceBytes/4+1,1}};
  f.preparedTextures.remember(uses,{},{{data[0].data(),Textures}});check(!f.preparedTextures.ready);
 }
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
