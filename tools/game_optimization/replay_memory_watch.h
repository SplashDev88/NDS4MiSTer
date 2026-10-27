// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>
#include <istream>
#include <ostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// Diagnostic snapshots of explicitly mapped DS RAM. Never calls an emulated read.
// All fields are supplied by the existing instruction callback and NDS instance.
class ReplayMemoryWatch {
public:
 struct Mapping {
  const uint8_t* ram;
  uint32_t mask, itcmSize, dtcmBase, dtcmMask;
  const uint8_t* dtcm=nullptr;
 };
 struct Span { unsigned reg, bytes, guardReg; int offset; uint32_t guardValue; bool dtcm=false; };
 struct Site { unsigned cpu; uint32_t pc, opcode; bool thumb; std::vector<Span> spans; uint64_t hits=0; };
 std::vector<Site> sites;
 uint64_t events=0;

 void Load(std::istream& input) {
  if(!sites.empty())throw std::runtime_error("Memory watches already loaded");
  std::string line;unsigned total=0;
  while(std::getline(input,line)) {
   std::istringstream row(line);std::string mode,extra;Site site{};Span span{};
   if(!(row>>site.cpu>>std::hex>>site.pc>>mode>>site.opcode>>std::dec>>span.reg>>span.offset>>span.bytes>>span.guardReg>>std::hex>>span.guardValue))
    throw std::runtime_error("Invalid memory-watch row");
   if(row>>extra) {
    if(extra!="main"&&extra!="dtcm")throw std::runtime_error("Invalid memory-watch address space");
    span.dtcm=extra=="dtcm";
    if(row>>extra)throw std::runtime_error("Extra memory-watch field");
   }
   site.thumb=mode=="thumb";
   if(site.cpu>1||(mode!="arm"&&mode!="thumb")||(site.pc&(site.thumb?1:3))||
      (site.thumb&&site.opcode>0xffff)||span.reg>=15||span.guardReg>=16||
      (span.dtcm&&site.cpu!=0)||
      span.offset < -4096||span.offset>4096||span.bytes==0||span.bytes>4096||++total>64)
    throw std::runtime_error("Memory-watch bounds or mode invalid");
   Site* found=nullptr;
   for(auto& old:sites)if(old.cpu==site.cpu&&old.pc==site.pc) {
    if(old.thumb!=site.thumb||old.opcode!=site.opcode)throw std::runtime_error("Conflicting memory-watch site");
    found=&old;break;
   }
   if(!found){sites.push_back(site);found=&sites.back();}
   found->spans.push_back(span);
   if(sites.size()>16)throw std::runtime_error("Too many memory-watch sites");
  }
  if(input.bad()||sites.empty())throw std::runtime_error("Missing memory-watch specification");
 }
 void Header(std::ostream& out)const {
  out<<"event,span,frame,cpu,pc,mode,opcode,cpsr";
  for(unsigned n=0;n<16;++n)out<<",r"<<n;
  out<<",address,length,bytes,space\n";
 }
 void Observe(unsigned cpu,uint32_t pc,uint32_t opcode,const uint32_t* r,
              uint32_t cpsr,unsigned frame,const Mapping& memory,std::ostream& out) {
  for(auto& site:sites) {
   if(site.cpu!=cpu||site.pc!=pc)continue;
   if(bool(cpsr&0x20)!=site.thumb||opcode!=site.opcode)
    throw std::runtime_error("Memory-watch instruction or mode mismatch");
   if(!memory.ram||memory.mask!=0x003fffff)
    throw std::runtime_error("Memory watch requires ordinary 4 MiB DS main RAM");
   // Buffer the complete event so a failed guard cannot emit a partial snapshot.
   std::ostringstream event;unsigned index=0;
   for(const auto& span:site.spans) {
    if(r[span.guardReg]!=span.guardValue)throw std::runtime_error("Memory-watch register guard mismatch");
    const int64_t first=int64_t(r[span.reg])+span.offset;
    if(first<0||first+span.bytes>0x100000000ll)
     throw std::runtime_error("Memory-watch address overflow");
    if(span.dtcm) {
     if(cpu!=0||!memory.dtcm||memory.dtcmMask!=0xffffc000)
      throw std::runtime_error("Memory watch requires explicitly mapped 16 KiB ARM9 DTCM");
    } else if(first<0x02000000ll||first+span.bytes>0x02400000ll)
     throw std::runtime_error("Memory-watch span outside canonical main RAM");
    const auto address=uint32_t(first);
    for(unsigned n=0;n<span.bytes;++n) {
     const bool isDTCM=((address+n)&memory.dtcmMask)==memory.dtcmBase;
     if(cpu==0&&(address+n<memory.itcmSize||(span.dtcm?!isDTCM:isDTCM)))
      throw std::runtime_error("Memory-watch address space differs from ARM9 mapping");
    }
    event<<events<<','<<index++<<','<<frame<<','<<cpu<<','<<std::hex<<pc<<','
         <<(site.thumb?"thumb":"arm")<<','<<opcode<<','<<cpsr;
    for(unsigned n=0;n<16;++n)event<<','<<r[n];
    event<<','<<address<<std::dec<<','<<span.bytes<<',';
    static constexpr char hex[]="0123456789abcdef";
    for(unsigned n=0;n<span.bytes;++n) {
     const uint8_t value=span.dtcm?memory.dtcm[(address+n)&0x3fff]:memory.ram[(address+n)&memory.mask];
     event<<hex[value>>4]<<hex[value&15];
    }
    event<<','<<(span.dtcm?"dtcm":"main")<<'\n';
   }
   out<<event.str();if(!out)throw std::runtime_error("Memory-watch write failed");
   ++events;++site.hits;
  }
 }
 void Finish(std::ostream& output,std::ostream& summary)const {
  output.flush();if(!output)throw std::runtime_error("Memory-watch flush failed");
  summary<<"cpu,pc,hits\n";
  for(const auto& site:sites) {
   summary<<site.cpu<<','<<std::hex<<site.pc<<std::dec<<','<<site.hits<<'\n';
   if(!site.hits)throw std::runtime_error("Memory-watch site was never observed");
  }
  summary.flush();if(!summary)throw std::runtime_error("Memory-watch summary write failed");
 }
};
