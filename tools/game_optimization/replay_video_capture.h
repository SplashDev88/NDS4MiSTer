// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <cstdint>
#include <ostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

// Copies completed framebuffers and indexes existing audio; no emulated reads.
class ReplayVideoCapture {
 std::vector<std::pair<unsigned,unsigned>> ranges;
 unsigned total=0, next=0, captured=0, expected=0;
 uint64_t audioOffset=0;
 size_t screenBytes;
public:
 explicit ReplayVideoCapture(size_t bytes=256*192*4):screenBytes(bytes){}
 bool Enabled()const{return !ranges.empty();}
 void Load(const std::string& text,unsigned frames) {
  if(Enabled()||!frames)throw std::runtime_error("Video capture already loaded or empty replay");
  std::istringstream list(text);std::string value;
  while(std::getline(list,value,',')) {
   const auto colon=value.find(':');
   if(colon==std::string::npos||value.find_first_not_of("0123456789:")!=std::string::npos||
      value.find(':',colon+1)!=std::string::npos)
    throw std::runtime_error("Invalid video capture range");
   auto first=std::stoull(value.substr(0,colon)),last=std::stoull(value.substr(colon+1));
   if(first>=last||last>frames||ranges.size()>=32)
    throw std::runtime_error("Video capture range out of bounds");
   for(auto old:ranges)if(first<old.second&&old.first<last)
    throw std::runtime_error("Overlapping video capture ranges");
   ranges.emplace_back(unsigned(first),unsigned(last));expected+=unsigned(last-first);
  }
  if(ranges.empty()||text.back()==',')throw std::runtime_error("Empty video capture range");
  std::sort(ranges.begin(),ranges.end());total=frames;
 }
 void Header(std::ostream& index)const {
  index<<"frame,first_audio_sample,audio_samples,hash_top,hash_bottom\n";
 }
 void Frame(unsigned frame,const void* top,const void* bottom,unsigned samples,
            uint64_t topHash,uint64_t bottomHash,std::ostream& pixels,std::ostream& index) {
  if(!Enabled())return;
  if(frame!=next++||frame>=total)throw std::runtime_error("Video capture frame sequence differs");
  bool wanted=false;for(auto range:ranges)wanted|=frame>=range.first&&frame<range.second;
  if(wanted) {
   if(!top||!bottom)throw std::runtime_error("Missing video framebuffer");
   pixels.write(static_cast<const char*>(top),screenBytes);
   pixels.write(static_cast<const char*>(bottom),screenBytes);
   index<<frame<<','<<audioOffset<<','<<samples<<','<<topHash<<','<<bottomHash<<'\n';
   if(!pixels||!index)throw std::runtime_error("Video capture write failed");
   ++captured;
  }
  audioOffset+=samples;
 }
 void Finish(std::ostream& pixels,std::ostream& index)const {
  if(!Enabled())return;
  pixels.flush();index.flush();
  if(next!=total||captured!=expected||!pixels||!index)
   throw std::runtime_error("Incomplete video capture");
 }
};
