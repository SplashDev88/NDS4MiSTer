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
inline unsigned commandWords(const Command& c){return c[0]==1?7:c[0]==2?16:(c[0]==3 || c[0]==5)?2:c[0]==4?13:16;}
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
// F3D5 permits an immutable producer prefix. WC command storage follows the
// immutable decoded textures in the existing WC mapping; Device storage is
// retained for batch callers without a WC mapping. No overlapping aliases.
inline void uploadCommand(volatile uint32_t* target,const Command& c,bool wc){
 const auto packed=pack(c);
 if(wc)std::memcpy(const_cast<uint32_t*>(target),packed.data(),sizeof(packed));
 else {
  const unsigned count=commandWords(c);unsigned i=0;
  for(;i+1<count;i+=2)
   *reinterpret_cast<volatile MMIO64*>(target+i)=uint64_t(packed[i])|(uint64_t(packed[i+1])<<32);
  if(i<count)target[i]=packed[i];
 }
}
struct Frame {
 std::vector<Command> commands;
 std::vector<uint32_t> textures;
 std::map<const uint32_t*,uint32_t> textureOffsets;
 bool valid=true,active=false,transportError=false;
 unsigned deadlineMs=100;
 uint8_t* stencil=nullptr;
 uint64_t uploadUs=0,waitUs=0,copyUs=0;
 uint32_t frameSession=0,sequence=0,commandBase=Commands;
 size_t published=0,commandCapacity=MaxCommands;
 std::chrono::steady_clock::time_point started,deadline;
 volatile uint32_t* mailbox=nullptr;
 void reset(){
  // An abandoned producer must never reuse bytes still owned by the FPGA.
  if(active){poisonedSession=frameSession;++failedFrames;}
  commands.clear();textures.clear();textureOffsets.clear();stencil=nullptr;valid=true;active=false;transportError=false;
  published=0;commandCapacity=MaxCommands;uploadUs=waitUs=copyUs=0;
 }
 void append(const Command& c){if(commands.size()>=commandCapacity)valid=false;else commands.push_back(c);}
 bool addTexture(const uint32_t* pixels,size_t count){
  if(active)return false;
  if(textureOffsets.count(pixels))return true;
  if(!pixels || count>TextureBytes/4 || textures.size()+count>TextureBytes/4)return false;
  for(size_t i=0;i<count;i++)if((pixels[i]>>24)>31)return false;
  textureOffsets[pixels]=Textures+textures.size()*4;
  textures.insert(textures.end(),pixels,pixels+count);return true;
 }
 bool start(){
  if(active)return true;
  if(!valid || !available() || textures.size()>TextureBytes/4)return false;
  // Reserve full descriptor capacity before starting. Texture-heavy frames
  // keep the Device arena rather than regressing F3D3's admission capacity.
  const bool useWC=writeCombined && textures.size()*4<=TextureBytes-MaxCommands*64;
  commandBase=useWC?((Textures+uint32_t(textures.size()*4)+63)&~63u):Commands;
  commandCapacity=useWC?std::min<size_t>(MaxCommands,(0x3fe00000u-commandBase)/64):MaxCommands;
  if(commandCapacity<384 || commands.size()>commandCapacity){valid=false;return false;}
  started=std::chrono::steady_clock::now();deadline=started+std::chrono::milliseconds(deadlineMs);
  frameSession=control[2];mailbox=control+(Mailbox-0x3fc00000)/4;
  sequence=mailbox[1]+1;if(!sequence)sequence=1;
  uploadUs=waitUs=copyUs=0;published=0;transportError=false;
  uploadTextures(publication+(Textures-0x3fd00000)/4,textures);
  // The fixed mailbox gap has the same Device mapping as control. Preserve
  // both parity rows across hardware/software transitions, including timeout.
  for(unsigned i=0;i<128;i++){
   uint32_t value=0;
   if(stencil)for(unsigned j=0;j<4;j++)value|=uint32_t(stencil[4*i+j]&3u)<<(8*j);
   control[(StencilInput-0x3fc00000)/4+i]=value;
  }
  mailbox[15]=commandBase;mailbox[2]=0;mailbox[3]=frameSession;mailbox[0]=Magic;
  barrier();mailbox[1]=sequence;barrier();active=true;
  uploadUs=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-started).count();
  return true;
 }
 // Native fixture generation keeps batch behavior; live WC rendering starts
 // only after feature/texture admission and before scanline command emission.
 void startStream(){if(writeCombined)start();}
 bool ownershipHealthy(){
  if(control[2]==frameSession && control[0]==0x31443348 && std::chrono::steady_clock::now()<=deadline)return true;
  poisonedSession=frameSession;transportError=true;active=false;++failedFrames;return false;
 }
 void publish(){
  if(!active || !ownershipHealthy())return;
  if(mailbox[4]==sequence){transportError=true;return;}
  const auto t=std::chrono::steady_clock::now();
  volatile uint32_t* target=commandBase==Commands?control+(commandBase-0x3fc00000)/4:publication+(commandBase-0x3fd00000)/4;
  for(;published<commands.size();published++)uploadCommand(target+published*16,commands[published],writeCombined && commandBase!=Commands);
  // The consumer may read only this committed immutable prefix.
  barrier();mailbox[2]=uint32_t(published);barrier();
  uploadUs+=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-t).count();
 }
 bool submit(uint32_t* destination,size_t stride){
  if(!active && (!valid || commands.empty() || !start()))return false;
  publish();
  if(!active)return false;
  // Always close and drain a started producer, including a late capacity or
  // span-admission failure. The partial output is never copied on failure.
  barrier();mailbox[2]=0x80000000u|uint32_t(published);barrier();
  const auto waiting=std::chrono::steady_clock::now();
  while(mailbox[4]!=sequence){
   if(!ownershipHealthy())return false;
#ifdef FPGA3D_TEST_PROGRESS
   FPGA3D_TEST_PROGRESS();
#else
   std::this_thread::sleep_for(std::chrono::microseconds(50));
#endif
  }
  barrier();active=false;
  if(control[2]!=frameSession){++failedFrames;return false;}
  if(!valid && !transportError)return false;
  if(transportError || mailbox[5]){++failedFrames;return false;}
  const auto rendered=std::chrono::steady_clock::now();copyOutput(destination,stride);
  if(stencil){
   auto source=publication+(StencilOutput-Output)/4;
   for(unsigned i=0;i<128;i++){const uint32_t value=source[i];for(unsigned j=0;j<4;j++)stencil[4*i+j]=(value>>(8*j))&3u;}
  }
  const auto copied=std::chrono::steady_clock::now();
  waitUs=std::chrono::duration_cast<std::chrono::microseconds>(rendered-waiting).count();
  copyUs=std::chrono::duration_cast<std::chrono::microseconds>(copied-rendered).count();
  ++completedFrames;
  mailbox[8]=uploadUs;mailbox[9]=waitUs;mailbox[10]=copyUs;
  mailbox[11]=uint32_t(completedFrames);mailbox[12]=uint32_t(failedFrames);mailbox[13]=frameSession;
  barrier();mailbox[14]=sequence;
  if(completedFrames==1 || completedFrames%600==0)
   std::fprintf(stderr,"FPGA3D completed=%llu failures=%llu commands=%zu texture_bytes=%zu upload_us=%llu wait_us=%llu copy_us=%llu\n",
    (unsigned long long)completedFrames,(unsigned long long)failedFrames,commands.size(),textures.size()*4,
    (unsigned long long)uploadUs,(unsigned long long)waitUs,(unsigned long long)copyUs);
  return true;
 }
};
}
