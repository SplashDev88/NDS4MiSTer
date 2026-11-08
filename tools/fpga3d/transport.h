// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "codec.h"
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
inline bool permitted=false,writeCombined=false;
inline uint32_t poisonedSession=0;
inline uint64_t completedFrames=0,failedFrames=0;
inline void barrier(){
#if defined(__arm__)
 __asm__ volatile("dsb sy" ::: "memory");
#else
 __atomic_thread_fence(__ATOMIC_SEQ_CST);
#endif
}
inline void bind(void* c,void* p,bool allowed,bool wc=false){
 control=static_cast<volatile uint32_t*>(c);publication=static_cast<volatile uint32_t*>(p);permitted=allowed;writeCombined=wc;
}
inline bool available(){
 if(!permitted || !control || !publication)return false;
 uint32_t session=control[2];
 return session && session!=poisonedSession && control[0]==0x31443348 &&
   control[(Mailbox-0x3fc00000+24)/4]==Magic && control[(Mailbox-0x3fc00000+28)/4]==session;
}
// Compact physical descriptors use fixed 64-byte spacing. Logical commands
// remain 128 bytes so native fixtures retain their independent readable ABI.
inline unsigned commandWords(const Command& c){return c[0]==1?7:c[0]==2?16:c[0]==3?2:c[0]==4?13:16;}
typedef uint64_t MMIO64 __attribute__((__may_alias__));
inline void uploadCommands(volatile uint32_t* target,const std::vector<Command>& commands){
 const bool aligned=(reinterpret_cast<uintptr_t>(target)&7)==0;
 for(const auto& c:commands){
  const PackedCommand packed=pack(c);
  const unsigned count=commandWords(c);unsigned i=0;
  if(aligned)for(;i+1<count;i+=2)
   *reinterpret_cast<volatile MMIO64*>(target+i)=uint64_t(packed[i])|(uint64_t(packed[i+1])<<32);
  for(;i<count;i++)target[i]=packed[i];
  target+=16;
 }
}
inline void uploadTextures(volatile uint32_t* target,const std::vector<uint32_t>& data){
 if(writeCombined){if(!data.empty())std::memcpy(const_cast<uint32_t*>(target),data.data(),data.size()*4);}
 else for(uint32_t w:data)*target++=w;
}
inline void copyOutput(uint32_t* destination,size_t stride){
 for(unsigned y=0;y<192;y++){
  if(writeCombined)std::memcpy(destination+y*stride,const_cast<const uint32_t*>(publication)+y*256,1024);
  else for(unsigned x=0;x<256;x++)destination[y*stride+x]=publication[y*256+x];
 }
}
struct Frame {
 std::vector<Command> commands;
 std::vector<uint32_t> textures;
 std::map<const uint32_t*,uint32_t> textureOffsets;
 bool valid=true;
 unsigned deadlineMs=100;
 uint64_t uploadUs=0,waitUs=0,copyUs=0;
 void reset(){commands.clear();textures.clear();textureOffsets.clear();valid=true;}
 void append(const Command& c){if(commands.size()>=MaxCommands)valid=false;else commands.push_back(c);}
 bool addTexture(const uint32_t* pixels,size_t count){
  if(textureOffsets.count(pixels))return true;
  if(!pixels || count>TextureBytes/4 || textures.size()+count>TextureBytes/4)return false;
  for(size_t i=0;i<count;i++)if((pixels[i]>>24)>31)return false;
  textureOffsets[pixels]=Textures+textures.size()*4;
  textures.insert(textures.end(),pixels,pixels+count);return true;
 }
 bool submit(uint32_t* destination,size_t stride){
  if(!valid || commands.empty() || !available())return false;
  const uint32_t session=control[2];
  const auto start=std::chrono::steady_clock::now();
  auto* mailbox=control+(Mailbox-0x3fc00000)/4;
  // Only the primary raster thread submits. A timeout poisons this session;
  // an old request from a previous epoch was discarded by hardware startup.
  uint32_t seq=mailbox[1]+1;if(!seq)seq=1;
  auto* target=control+(Commands-0x3fc00000)/4;
  uploadCommands(target,commands);
  auto* tex=publication+(Textures-0x3fd00000)/4;
  uploadTextures(tex,textures);
  mailbox[2]=commands.size();mailbox[3]=session;mailbox[0]=Magic;
  barrier();mailbox[1]=seq;barrier();
  const auto uploaded=std::chrono::steady_clock::now();
  const auto deadline=uploaded+std::chrono::milliseconds(deadlineMs);
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
  const auto rendered=std::chrono::steady_clock::now();
  copyOutput(destination,stride);
  const auto copied=std::chrono::steady_clock::now();
  uploadUs=std::chrono::duration_cast<std::chrono::microseconds>(uploaded-start).count();
  waitUs=std::chrono::duration_cast<std::chrono::microseconds>(rendered-uploaded).count();
  copyUs=std::chrono::duration_cast<std::chrono::microseconds>(copied-rendered).count();
  ++completedFrames;
  // CPU-owned telemetry after the eight-word hardware mailbox. Commit the
  // sequence last; readers also check the epoch before interpreting samples.
  mailbox[8]=uploadUs;mailbox[9]=waitUs;mailbox[10]=copyUs;
  mailbox[11]=uint32_t(completedFrames);mailbox[12]=uint32_t(failedFrames);mailbox[13]=session;
  barrier();mailbox[14]=seq;
  if(completedFrames==1 || completedFrames%600==0)
   std::fprintf(stderr,"FPGA3D completed=%llu failures=%llu commands=%zu texture_bytes=%zu upload_us=%llu wait_us=%llu copy_us=%llu\n",
    (unsigned long long)completedFrames,(unsigned long long)failedFrames,commands.size(),textures.size()*4,
    (unsigned long long)uploadUs,(unsigned long long)waitUs,(unsigned long long)copyUs);
  return true;
 }
};
}
