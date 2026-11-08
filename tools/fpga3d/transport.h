// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "abi.h"
#include <chrono>
#include <cstring>
#include <cstdio>
#include <thread>
#include <map>
namespace fpga3d {
// Bound once by the service before it creates renderer threads. Reuses its
// existing mappings: no conflicting Device/WC aliases of physical memory.
inline volatile uint32_t* control=nullptr;
inline volatile uint32_t* publication=nullptr;
inline bool permitted=false;
inline uint32_t poisonedSession=0;
inline uint64_t completedFrames=0,failedFrames=0;
inline void barrier(){
#if defined(__arm__)
 __asm__ volatile("dsb sy" ::: "memory");
#else
 __atomic_thread_fence(__ATOMIC_SEQ_CST);
#endif
}
inline void bind(void* c,void* p,bool allowed){
 control=static_cast<volatile uint32_t*>(c);publication=static_cast<volatile uint32_t*>(p);permitted=allowed;
}
inline bool available(){
 if(!permitted || !control || !publication)return false;
 uint32_t session=control[2];
 return session && session!=poisonedSession && control[0]==0x31443348 &&
   control[(Mailbox-0x3fc00000+24)/4]==Magic && control[(Mailbox-0x3fc00000+28)/4]==session;
}
struct Frame {
 std::vector<Command> commands;
 std::vector<uint32_t> textures;
 std::map<const uint32_t*,uint32_t> textureOffsets;
 bool valid=true;
 unsigned deadlineMs=100;
 void reset(){commands.clear();textures.clear();textureOffsets.clear();valid=true;}
 void append(const Command& c){if(commands.size()>=MaxCommands)valid=false;else commands.push_back(c);}
 bool addTexture(const uint32_t* pixels,size_t count){
  if(textureOffsets.count(pixels))return true;
  if(!pixels || count>TextureBytes/4 || textures.size()+count>TextureBytes/4)return false;
  for(size_t i=0;i<count;i++)if((pixels[i]>>24)!=0 && (pixels[i]>>24)!=31)return false;
  textureOffsets[pixels]=Textures+textures.size()*4;
  textures.insert(textures.end(),pixels,pixels+count);return true;
 }
 bool submit(uint32_t* destination,size_t stride){
  if(!valid || commands.empty() || !available())return false;
  const uint32_t session=control[2];
  auto* mailbox=control+(Mailbox-0x3fc00000)/4;
  // Only the primary raster thread submits. A timeout poisons this session;
  // an old request from a previous epoch was discarded by hardware startup.
  uint32_t seq=mailbox[1]+1;if(!seq)seq=1;
  auto* target=control+(Commands-0x3fc00000)/4;
  for(const auto& c:commands)for(uint32_t w:c)*target++=w;
  auto* tex=publication+(Textures-0x3fd00000)/4;
  for(uint32_t w:textures)*tex++=w;
  mailbox[2]=commands.size();mailbox[3]=session;mailbox[0]=Magic;
  barrier();mailbox[1]=seq;barrier();
  const auto deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(deadlineMs);
  while(mailbox[4]!=seq){
   if(control[2]!=session || control[0]!=0x31443348 || std::chrono::steady_clock::now()>deadline){
    // Hardware may still own immutable command/texture data after timeout.
    // Permanently disable submission in this epoch; never reuse those bytes.
    poisonedSession=session;++failedFrames;return false;
   }
   std::this_thread::sleep_for(std::chrono::microseconds(50));
  }
  barrier();
  if(mailbox[5] || control[2]!=session){++failedFrames;return false;}
  for(unsigned y=0;y<192;y++)for(unsigned x=0;x<256;x++)destination[y*stride+x]=publication[y*256+x];
  ++completedFrames;
  if(completedFrames==1 || completedFrames%600==0)
   std::fprintf(stderr,"FPGA3D completed=%llu failures=%llu commands=%zu texture_bytes=%zu\n",
    (unsigned long long)completedFrames,(unsigned long long)failedFrames,commands.size(),textures.size()*4);
  return true;
 }
};
}
