// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <istream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// Reference-output normalization only. Never writes emulated memory or installs
// a patch. Overlay context is compared byte-for-byte before any code is masked.
class ReplayCodeComparison {
public:
 struct Patch { uint32_t address; std::vector<uint8_t> original,replacement; };
 struct Region {
  bool overlay=false; uint32_t id=0,address=0;
  std::vector<uint8_t> original,replacement;
  std::vector<Patch> patches;
 };
 struct Counts { unsigned original=0,replacement=0,unmatchedOverlay=0; };
 std::vector<Region> regions;

 static void Require(bool ok,const char* message) {
  if(!ok)throw std::runtime_error(message);
 }
 static uint32_t Number(const std::string& text,int base) {
  size_t used=0;auto value=std::stoull(text,&used,base);
  Require(used==text.size()&&value<=0xffffffffu,"Invalid comparison address/ID");
  return uint32_t(value);
 }
 static std::vector<uint8_t> Hex(const std::string& text) {
  Require(!text.empty()&&text.size()%2==0&&text.find_first_not_of("0123456789abcdefABCDEF")==std::string::npos,"Invalid comparison hex");
  std::vector<uint8_t> result;
  for(size_t n=0;n<text.size();n+=2)result.push_back(uint8_t(std::stoul(text.substr(n,2),nullptr,16)));
  return result;
 }
 static void Bounds(uint32_t address,size_t bytes) {
  Require(address>=0x02000000u&&bytes>0&&uint64_t(address)+bytes<=0x02400000u,"Comparison outside main RAM");
 }
 void Load(std::istream& input) {
  Require(regions.empty(),"Comparisons already loaded");
  std::string line;unsigned sites=0;
  while(std::getline(input,line)) {
   std::istringstream row(line);std::string address,before,after,kind;
   Require(bool(row>>address>>before>>after),"Invalid comparison row");
   Patch patch{Number(address,16),Hex(before),Hex(after)};
   Require(patch.original.size()>=8&&patch.original.size()<=4096&&patch.original.size()==patch.replacement.size(),"Invalid comparison extent");
   Bounds(patch.address,patch.original.size());Require(++sites<=64,"Too many comparison sites");
   Region region;region.address=patch.address;region.original=patch.original;
   if(row>>kind) {
    std::string id,base,path,extra;
    Require(kind=="overlay"&&bool(row>>id>>base>>std::quoted(path))&&!(row>>extra),"Invalid overlay comparison row");
    region.overlay=true;region.id=Number(id,10);region.address=Number(base,16);
    std::ifstream file(path,std::ios::binary|std::ios::ate);
    Require(bool(file),"Missing original overlay context");
    const auto size=file.tellg();Require(size>0&&size<=0x400000,"Invalid overlay context size");
    region.original.resize(size_t(size));file.seekg(0);file.read(reinterpret_cast<char*>(region.original.data()),size);
    Require(bool(file),"Incomplete original overlay context");
    Bounds(region.address,region.original.size());
   }
   Require(patch.address>=region.address&&uint64_t(patch.address)+patch.original.size()<=uint64_t(region.address)+region.original.size(),"Patch outside comparison context");
   Require(std::equal(patch.original.begin(),patch.original.end(),region.original.begin()+(patch.address-region.address)),"Original patch differs from context");
   Region* group=nullptr;
   for(auto& old:regions) {
    for(const auto& site:old.patches)
     Require(uint64_t(patch.address)+patch.original.size()<=site.address||uint64_t(site.address)+site.original.size()<=patch.address,"Overlapping comparison patches");
    if(region.overlay&&old.overlay&&region.id==old.id) {
     Require(region.address==old.address&&region.original==old.original,"Conflicting overlay identity/context");
     group=&old;
    } else {
     Require(uint64_t(region.address)+region.original.size()<=old.address||uint64_t(old.address)+old.original.size()<=region.address,"Overlapping comparison contexts");
    }
   }
   if(!group) {
    region.replacement=region.original;regions.push_back(std::move(region));group=&regions.back();
   }
   std::copy(patch.replacement.begin(),patch.replacement.end(),group->replacement.begin()+(patch.address-group->address));
   group->patches.push_back(std::move(patch));
  }
  Require(!input.bad()&&!regions.empty(),"Missing comparison specification");
 }
 Counts Normalize(std::vector<uint8_t>& copy)const {
  Require(copy.size()==0x400000,"Comparison needs canonical 4 MiB RAM");
  Counts counts;
  for(const auto& region:regions) {
   auto at=copy.begin()+(region.address-0x02000000u);
   if(std::equal(region.original.begin(),region.original.end(),at))counts.original+=region.patches.size();
   else if(std::equal(region.replacement.begin(),region.replacement.end(),at))counts.replacement+=region.patches.size();
   else {
    Require(region.overlay,"Unexpected initial-main code bytes");
    // Includes absent, partially loaded, different and corrupted bodies.
    // Leave every byte unchanged so a raw RAM mismatch remains visible.
    counts.unmatchedOverlay+=region.patches.size();continue;
   }
   for(const auto& patch:region.patches)
    std::copy(patch.original.begin(),patch.original.end(),copy.begin()+(patch.address-0x02000000u));
  }
  return counts;
 }
};
