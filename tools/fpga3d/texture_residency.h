// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <map>
#include <vector>

namespace fpga3d {
// CPU shadow of bytes owned by one completed producer. Callers must invalidate
// reuse after a session, mapping, writer or completion change. Never read WC
// memory to compare it: compare normal cached memory and write changed runs.
struct TextureResidency {
 std::vector<uint32_t> previous;
 template<class Write> size_t upload(const std::vector<uint32_t>& data,bool reuse,Write write){
  const size_t oldSize=reuse?previous.size():0;
  if(reuse && oldSize==data.size() &&
     (data.empty() || !std::memcmp(previous.data(),data.data(),data.size()*4)))return 0;
  previous.resize(data.size());
  size_t uploaded=0;
  // Coalesce adjacent changed 1 KiB blocks into one WC copy. Growth beyond
  // the last texture length is always dirty: commands may have occupied it.
  constexpr size_t BlockWords=256;
  size_t run=0;bool dirtyRun=false;
  for(size_t begin=0;begin<data.size();begin+=BlockWords){
   const size_t end=std::min(begin+BlockWords,data.size());
   const bool dirty=end>oldSize || std::memcmp(previous.data()+begin,data.data()+begin,(end-begin)*4);
   if(dirty && !dirtyRun){run=begin;dirtyRun=true;}
   if(dirtyRun && (!dirty || end==data.size())){
    const size_t limit=dirty?end:begin;
    write(run,data.data()+run,limit-run);
    std::memcpy(previous.data()+run,data.data()+run,(limit-run)*4);
    uploaded+=(limit-run)*4;dirtyRun=false;
   }
  }
  return uploaded;
 }
};

// Reuse an exact prepared texture set even when polygon motion changes the
// order or frequency of texture use. Raw and indexed bindings are lossless;
// retaining their previous placement avoids rebuilding and reshuffling DDR.
// Every current decoded source byte is compared; pointers alone never qualify.
struct PreparedTextures {
 static constexpr size_t MaxSourceBytes=4*1024*1024;
 std::map<const uint32_t*,std::vector<uint32_t>> sources;
 std::map<const uint32_t*,uint32_t> bindings;
 std::vector<uint32_t> staged;
 bool ready=false;
 template<class Uses> bool matches(const Uses& uses)const{
  if(!ready || uses.size()!=sources.size())return false;
  for(const auto& use:uses){
   auto found=sources.find(use.pixels);
   if(found==sources.end() || found->second.size()!=use.count ||
      std::memcmp(found->second.data(),use.pixels,use.count*4))return false;
  }
  return true;
 }
 template<class Uses> void remember(const Uses& uses,const std::vector<uint32_t>& data,
                                   const std::map<const uint32_t*,uint32_t>& offsets){
  ready=false;sources.clear();bindings.clear();staged.clear();
  if(uses.size()>512 || uses.size()!=offsets.size())return;
  size_t bytes=0;
  for(const auto& use:uses){
   if(!use.pixels || !use.count || use.count>(MaxSourceBytes-bytes)/4 || !offsets.count(use.pixels))return;
   bytes+=use.count*4;
  }
  for(const auto& use:uses){
   if(!sources.emplace(use.pixels,std::vector<uint32_t>(use.pixels,use.pixels+use.count)).second){sources.clear();return;}
  }
  staged=data;bindings=offsets;ready=true;
 }
};
}
