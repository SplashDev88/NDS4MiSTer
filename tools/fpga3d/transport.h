// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "codec.h"
#include "admission.h"
#include "profile.h"
#include "texture_residency.h"
#include <chrono>
#include <cstring>
#include <cstdio>
#include <thread>
#include <map>
#include <algorithm>
namespace fpga3d {
// Bound once by the service before it creates renderer threads. Reuses its
// existing mappings: no conflicting Device/WC aliases of physical memory.
inline volatile uint32_t* control=nullptr;
inline volatile uint32_t* publication=nullptr;
inline bool permitted=false,writeCombined=false,streaming=true;
inline bool textureResidencyEnabled=false;
inline bool preparedTexturesEnabled=false;
inline bool fastCommandsEnabled=false;
inline uint64_t bindingSerial=0,textureWriterSerial=0;
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
 ++bindingSerial;
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
inline unsigned commandWords(const Command& c){return (c[0]==1 || c[0]==6)?7:c[0]==2?16:c[0]==3?3:c[0]==5?2:c[0]==4?13:c[0]==7?10:16;}
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
inline void uploadPackedCommand(volatile uint32_t* target,const PackedCommand& packed,bool wc){
 if(wc)std::memcpy(const_cast<uint32_t*>(target),packed.data(),sizeof(packed));
 else {
  const unsigned opcode=packed[0];
  const unsigned count=(opcode==1 || opcode==6)?7:opcode==3?3:opcode==5?2:opcode==4?13:opcode==7?10:16;unsigned i=0;
  for(;i+1<count;i+=2)
   *reinterpret_cast<volatile MMIO64*>(target+i)=uint64_t(packed[i])|(uint64_t(packed[i+1])<<32);
  if(i<count)target[i]=packed[i];
 }
}
inline void uploadCommand(volatile uint32_t* target,const Command& c,bool wc){
 uploadPackedCommand(target,pack(c),wc);
}
struct Frame {
 struct TextureUse {const uint32_t* pixels;size_t count;uint64_t rows;};
 struct IndexedTexture {std::vector<uint32_t> source,encoded;uint64_t used=0;};
 static constexpr size_t IndexedCacheBytes=4*1024*1024;
 std::map<const uint32_t*,IndexedTexture> indexedCache;
 size_t indexedCacheBytes=0;
 uint64_t indexedCacheSerial=0,indexedCacheHits=0;
 unsigned canonicalizedColors=0;
 std::vector<Command> commands;
 std::vector<PackedCommand> packedCommands;
 std::vector<uint32_t> textures;
 TextureResidency residentTextures;
 PreparedTextures preparedTextures;
 uint64_t preparedAttempts=0,preparedHits=0;
 bool residentValid=false;
 uint32_t residentSession=0,residentSequence=0;
 uint64_t residentBinding=0,residentWriter=0;
 uint64_t textureUploadedBytes=0,residencyFrames=0,residencyRequested=0,residencyUploaded=0;
 std::map<const uint32_t*,uint32_t> textureOffsets;
 Outcome failure=Outcome::SubmitFailed;
 bool valid=true,active=false,transportError=false,recyclePublished=false,allowIndexed=true;
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
  failure=Outcome::SubmitFailed;commands.clear();packedCommands.clear();textures.clear();textureOffsets.clear();stencil=nullptr;valid=true;active=false;transportError=false;recyclePublished=false;
  published=0;commandCapacity=MaxCommands;uploadUs=waitUs=copyUs=0;allowIndexed=true;
  canonicalizedColors=0;
 }
 size_t commandCount()const{return recyclePublished?published+packedCommands.size():commands.size();}
 void append(const Command& c){
  if(commandCount()>=commandCapacity){valid=false;failure=Outcome::CommandCapacity;}
  else if(recyclePublished)packedCommands.push_back(pack(c));
  else commands.push_back(c);
 }
 void appendPacked(const PackedCommand& c,uint32_t texture=0){
  if(!recyclePublished || commandCount()>=commandCapacity){valid=false;failure=Outcome::CommandCapacity;}
  else {
   packedCommands.push_back(c);
   if(texture)rebindTexture(packedCommands.back(),texture);
  }
 }
 bool addTexture(const uint32_t* pixels,size_t count){
  const auto reject=[&](Outcome why){failure=why;return false;};
  if(active)return reject(Outcome::TextureState);
  if(textureOffsets.count(pixels))return true;
  if(!pixels || !count || count>TextureBytes || (count&63))return reject(Outcome::TextureCapacity);
  // DS palette formats often contain at most 256 exact decoded RGBA values.
  // Store those without quantization: a 1 KiB palette followed by byte indices.
  // This keeps the fixed, non-overlapping DDR arena while admitting up to
  // nearly four times the decoded texture data. Every binding uses current
  // pixels; cached encodings require a full source-content comparison below.
  if(allowIndexed && count>=2048 && count+1024<=TextureBytes){
   auto cached=indexedCache.find(pixels);
   // Pointer identity alone is insufficient: texture palettes animate and
   // decoded-cache storage can be recycled. Compare every current source byte
   // before reusing the lossless encoding; all DDR bindings are still fresh.
   if(cached!=indexedCache.end() && cached->second.source.size()==count &&
      !std::memcmp(cached->second.source.data(),pixels,count*4)){
    const auto& encoded=cached->second.encoded;
    const size_t aligned=(textures.size()+15)&~size_t(15);
    if(aligned+encoded.size()>TextureBytes/4)return reject(Outcome::TextureCapacity);
    textures.resize(aligned,0);textureOffsets[pixels]=(Textures+uint32_t(aligned*4))|1u;
    textures.insert(textures.end(),encoded.begin(),encoded.end());
    cached->second.used=++indexedCacheSerial;++indexedCacheHits;return true;
   }
   std::array<uint32_t,256> palette{};
   std::array<uint16_t,1024> slots{};
   std::vector<uint32_t> indices(count/4,0);
   unsigned colors=0;bool indexed=true;
   for(size_t i=0;i<count;i++){
    const uint32_t color=pixels[i];if((color>>24)>31)return reject(Outcome::TextureAlpha);
    unsigned slot=(color*2654435761u)>>22;
    while(slots[slot] && palette[slots[slot]-1]!=color)slot=(slot+1)&1023;
    if(!slots[slot]){
     if(colors==256){indexed=false;break;}
     palette[colors]=color;slots[slot]=++colors;
    }
    indices[i/4]|=uint32_t(slots[slot]-1)<<(8*(i%4));
   }
   if(indexed){
    const size_t aligned=(textures.size()+15)&~size_t(15);
    if(aligned+palette.size()+indices.size()>TextureBytes/4)return reject(Outcome::TextureCapacity);
    textures.resize(aligned,0);
    textureOffsets[pixels]=(Textures+uint32_t(aligned*4))|1u;
    textures.insert(textures.end(),palette.begin(),palette.end());
    textures.insert(textures.end(),indices.begin(),indices.end());
    const size_t bytes=(count+palette.size()+indices.size())*4;
    if(bytes<=IndexedCacheBytes){
     if(cached!=indexedCache.end()){
      indexedCacheBytes-=(cached->second.source.size()+cached->second.encoded.size())*4;
      indexedCache.erase(cached);
     }
     while(!indexedCache.empty() && (indexedCacheBytes+bytes>IndexedCacheBytes || indexedCache.size()>=512)){
      auto oldest=std::min_element(indexedCache.begin(),indexedCache.end(),[](const auto& a,const auto& b){return a.second.used<b.second.used;});
      indexedCacheBytes-=(oldest->second.source.size()+oldest->second.encoded.size())*4;indexedCache.erase(oldest);
     }
     auto& entry=indexedCache[pixels];entry.source.assign(pixels,pixels+count);
     entry.encoded.assign(textures.begin()+aligned,textures.end());entry.used=++indexedCacheSerial;
     indexedCacheBytes+=bytes;
    }
    return true;
   }
  }
  if(count>TextureBytes/4 || textures.size()+count>TextureBytes/4)return reject(Outcome::TextureCapacity);
  for(size_t i=0;i<count;i++)if((pixels[i]>>24)>31)return reject(Outcome::TextureAlpha);
  textureOffsets[pixels]=Textures+textures.size()*4;
  textures.insert(textures.end(),pixels,pixels+count);return true;
 }
 // Spend spare texture space on the bindings used by the most scanlines per
 // extra byte. Raw bindings avoid the single FPGA palette cache's reloads.
 // Rebuild before starting the producer; cached spans subsequently rebind to
 // these fresh addresses and formats. The dedicated command arena preserves
 // full descriptor capacity when textures exceed the WC command threshold.
 void preferRawTextures(const std::vector<TextureUse>& uses,size_t budget=TextureBytes){
  if(active || !valid || budget>TextureBytes || textures.size()*4>budget)return;
  struct Binding {TextureUse use;uint32_t old;bool raw;size_t extra;};
  std::vector<Binding> bindings;bindings.reserve(uses.size());
  for(const auto& u:uses){
   auto it=textureOffsets.find(u.pixels);
   if(it==textureOffsets.end() || !u.count || (u.count&63))return;
   const bool indexed=it->second&1u;
   bindings.push_back({u,it->second,!indexed,indexed?u.count*3-1024:0});
  }
  if(bindings.size()!=textureOffsets.size())return;
  std::sort(bindings.begin(),bindings.end(),[](const Binding& a,const Binding& b){
   if(a.raw!=b.raw)return !a.raw;
   const auto left=a.use.rows*b.extra,right=b.use.rows*a.extra;
   return left!=right?left>right:a.old<b.old;
  });
  size_t bytes=textures.size()*4;bool changed=false;
  for(auto& b:bindings)if(!b.raw && b.extra<=budget-bytes){b.raw=true;bytes+=b.extra;changed=true;}
  if(!changed)return;
  std::sort(bindings.begin(),bindings.end(),[](const Binding& a,const Binding& b){return a.old<b.old;});
  std::vector<uint32_t> packed;packed.reserve(bytes/4);
  for(const auto& b:bindings){
   textureOffsets[b.use.pixels]=(Textures+uint32_t(packed.size()*4))|(!b.raw);
   if(b.raw)packed.insert(packed.end(),b.use.pixels,b.use.pixels+b.use.count);
   else {
    const auto first=textures.begin()+((b.old&~1u)-Textures)/4;
    packed.insert(packed.end(),first,first+256+b.use.count/4);
   }
  }
  textures.swap(packed);
 }
 bool start(){
  if(active)return true;
  if(!valid || !available() || textures.size()>TextureBytes/4)return false;
  // Reserve full descriptor capacity before starting. Texture-heavy frames
  // keep the Device arena rather than regressing F3D3's admission capacity.
  const bool useWC=writeCombined && textures.size()*4<=TextureBytes-MaxCommands*64;
  commandBase=useWC?((Textures+uint32_t(textures.size()*4)+63)&~63u):
      writeCombined && fastCommandsEnabled?PaddedCommands:Commands;
  commandCapacity=useWC?std::min<size_t>(MaxCommands,(0x3fe00000u-commandBase)/64):MaxCommands;
  if(commandCapacity<384 || commands.size()>commandCapacity){valid=false;return false;}
  started=std::chrono::steady_clock::now();deadline=started+std::chrono::milliseconds(deadlineMs);
  frameSession=control[2];mailbox=control+(Mailbox-0x3fc00000)/4;
  sequence=mailbox[1]+1;if(!sequence)sequence=1;
  uploadUs=waitUs=copyUs=0;published=0;transportError=false;
  const bool reuse=textureResidencyEnabled && residentValid && residentSession==frameSession &&
   residentBinding==bindingSerial && residentWriter==textureWriterSerial &&
   mailbox[1]==residentSequence && mailbox[4]==residentSequence;
  residentValid=false;residentWriter=++textureWriterSerial;residentBinding=bindingSerial;
  auto textureTarget=publication+(Textures-0x3fd00000)/4;
  if(textureResidencyEnabled){
   textureUploadedBytes=residentTextures.upload(textures,reuse,[&](size_t offset,const uint32_t* source,size_t count){
    if(writeCombined)std::memcpy(const_cast<uint32_t*>(textureTarget)+offset,source,count*4);
    else for(size_t i=0;i<count;i++)textureTarget[offset+i]=source[i];
   });
  }else{uploadTextures(textureTarget,textures);textureUploadedBytes=textures.size()*4;}
  ++residencyFrames;residencyRequested+=textures.size()*4;residencyUploaded+=textureUploadedBytes;
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
 void startStream(){
  if(writeCombined && streaming && start()){
   recyclePublished=true;
   for(const auto& c:commands)packedCommands.push_back(pack(c));
   commands.clear();
  }
 }
 bool ownershipHealthy(){
  if(control[2]==frameSession && control[0]==0x31443348 && std::chrono::steady_clock::now()<=deadline)return true;
  poisonedSession=frameSession;transportError=true;active=false;++failedFrames;return false;
 }
 void publish(){
  if(!active || !ownershipHealthy())return;
  if(mailbox[4]==sequence){transportError=true;return;}
  const auto t=std::chrono::steady_clock::now();
  const auto target=[&](size_t index){
   const uint32_t address=commandAddress(commandBase,index);
   return commandBase==Commands?control+(address-0x3fc00000)/4:publication+(address-0x3fd00000)/4;
  };
  if(recyclePublished){
   // Published descriptors already have immutable FPGA-owned storage. Reuse
   // the small CPU row buffer instead of carrying a 1 MiB logical command
   // history through the shared Cortex-A9 cache on every frame.
   for(size_t i=0;i<packedCommands.size();i++)uploadPackedCommand(target(published+i),packedCommands[i],writeCombined && commandBase!=Commands);
   published+=packedCommands.size();packedCommands.clear();
  }else{
   for(;published<commands.size();published++)uploadCommand(target(published),commands[published],writeCombined && commandBase!=Commands);
  }
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
  residentSession=frameSession;residentSequence=sequence;residentValid=textureResidencyEnabled;
  if(profileEnabled && residencyFrames%120==0)
   std::fprintf(stderr,"FPGA3D_RESIDENCY enabled=%u frames=%llu requested_bytes=%llu uploaded_bytes=%llu\n",
    unsigned(textureResidencyEnabled),(unsigned long long)residencyFrames,
    (unsigned long long)residencyRequested,(unsigned long long)residencyUploaded);
  mailbox[8]=uploadUs;mailbox[9]=waitUs;mailbox[10]=copyUs;
  mailbox[11]=uint32_t(completedFrames);mailbox[12]=uint32_t(failedFrames);mailbox[13]=frameSession;
  barrier();mailbox[14]=sequence;
  if(completedFrames==1 || completedFrames%600==0)
   std::fprintf(stderr,"FPGA3D completed=%llu failures=%llu commands=%zu texture_bytes=%zu upload_us=%llu wait_us=%llu copy_us=%llu\n",
    (unsigned long long)completedFrames,(unsigned long long)failedFrames,commandCount(),textures.size()*4,
    (unsigned long long)uploadUs,(unsigned long long)waitUs,(unsigned long long)copyUs);
  return true;
 }
};
}
