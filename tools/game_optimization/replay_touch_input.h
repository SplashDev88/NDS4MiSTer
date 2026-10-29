// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <cstdint>
#include <istream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// Optional touch windows for the existing software-reference input replay.
// All fields are decimal: first_frame last_frame_exclusive x y.
class ReplayTouchInput {
public:
 struct Window { unsigned first,last,x,y; };
 void Load(std::istream& input,unsigned frames) {
  std::vector<Window> parsed;
  std::string line;
  while(std::getline(input,line)) {
   std::istringstream row(line);
   std::vector<std::string> words;
   std::string word;
   while(row>>word)words.push_back(word);
   if(words.empty())continue;
   if(words.size()!=4)throw std::runtime_error("Touch input requires four decimal fields");
   std::uint64_t values[4]{};
   for(unsigned i=0;i<4;++i) {
    if(words[i].find_first_not_of("0123456789")!=std::string::npos)
     throw std::runtime_error("Touch input contains a nondecimal field");
    values[i]=std::stoull(words[i]);
   }
   if(values[0]>=values[1]||values[1]>frames||values[2]>255||values[3]>191)
    throw std::runtime_error("Touch input is outside frame or screen bounds");
   if(!parsed.empty()&&values[0]<parsed.back().last)
    throw std::runtime_error("Touch input windows must be ordered and nonoverlapping");
   parsed.push_back({unsigned(values[0]),unsigned(values[1]),unsigned(values[2]),unsigned(values[3])});
  }
  if(input.bad())throw std::runtime_error("Touch input read failed");
  windows=std::move(parsed);
 }
 const Window* At(unsigned frame) const {
  auto it=std::upper_bound(windows.begin(),windows.end(),frame,
                          [](unsigned f,const Window& w){return f<w.first;});
  if(it==windows.begin())return nullptr;
  --it;
  return frame<it->last?&*it:nullptr;
 }
private:
 std::vector<Window> windows;
};
