// SPDX-License-Identifier: GPL-3.0-or-later
#include "replay_memory_watch.h"
#include <iostream>
#include <functional>
#include <array>

int main() {
 unsigned checks=0;
 auto require=[&](bool ok){if(!ok)throw std::runtime_error("Memory-watch test failed");++checks;};
 auto rejected=[&](const std::function<void()>& call){bool failed=false;try{call();}catch(const std::runtime_error&){failed=true;}require(failed);};
 auto load=[](const std::string& text){ReplayMemoryWatch watch;std::istringstream in(text);watch.Load(in);return watch;};
 const std::string spec="0 02001000 arm e92d4000 0 0 4 2 100\n0 02001000 arm e92d4000 3 -4 4 2 100\n";
 std::vector<uint8_t> ram(0x400000);ram[0x100]=0x12;ram[0x101]=0xab;ram[0x200]=0xcd;
 const auto before=ram;
 std::array<uint32_t,16> regs{};regs[0]=0x02000100;regs[2]=256;regs[3]=0x02000204;
 const auto originalRegs=regs;
 ReplayMemoryWatch::Mapping map{ram.data(),0x3fffff,0x8000,0x027e0000,0xffffc000};
 auto watch=load(spec);std::ostringstream out;watch.Header(out);
 watch.Observe(1,0x02001000,0,regs.data(),0,7,map,out);require(watch.events==0);
 watch.Observe(0,0x02001004,0,regs.data(),0,7,map,out);require(watch.events==0);
 watch.Observe(0,0x02001000,0xe92d4000,regs.data(),0x1f,7,map,out);
 require(watch.events==1&&watch.sites[0].hits==1);
 require(out.str().find(",2000100,4,12ab0000\n")!=std::string::npos);
 require(out.str().find(",2000200,4,cd000000\n")!=std::string::npos);
 std::ostringstream summary;watch.Finish(out,summary);require(summary.str()=="cpu,pc,hits\n0,2001000,1\n");
 require(ram==before&&regs==originalRegs);
 auto observe=[&](uint32_t opcode,uint32_t cpsr){watch.Observe(0,0x02001000,opcode,regs.data(),cpsr,8,map,out);};
 rejected([&]{observe(0xe92d4001,0);});
 rejected([&]{observe(0xe92d4000,0x20);});
 regs[2]=255;rejected([&]{observe(0xe92d4000,0);});regs=originalRegs;
 for(uint32_t address:{0x01ffffffu,0x023ffffeu,0x027e0000u,0x04000000u,0xfffffffdu}) {
  regs[0]=address;rejected([&]{observe(0xe92d4000,0);});
 }
 regs=originalRegs;map.mask=0xffffff;rejected([&]{observe(0xe92d4000,0);});map.mask=0x3fffff;
 map.itcmSize=0x02000200;rejected([&]{observe(0xe92d4000,0);});map.itcmSize=0x8000;
 map.dtcmBase=0x02000000;rejected([&]{observe(0xe92d4000,0);});map.dtcmBase=0x027e0000;
 // Fail on the second span without writing the otherwise valid first span.
 auto unchanged=out.str();regs[3]=3;rejected([&]{observe(0xe92d4000,0);});require(out.str()==unchanged);regs=originalRegs;
 // Boundary crossing into a tiny synthetic DTCM range must be rejected too.
 map.dtcmBase=0x02000102;map.dtcmMask=0xfffffffe;rejected([&]{observe(0xe92d4000,0);});
 auto arm7=load("1 02001002 thumb b500 0 0 4 2 100\n");
 arm7.Observe(1,0x02001002,0xb500,regs.data(),0x3f,9,map,out);require(arm7.events==1);
 map.dtcmBase=0x027e0000;map.dtcmMask=0xffffc000;
 regs[0]=0x023ffffc;observe(0xe92d4000,0);require(watch.events==2);
 for(const std::string bad:{"", "0 02001000 arm e92d4000 0 0 0 2 100\n",
  "0 02001000 arm e92d4000 0 0 4097 2 100\n", "0 02001000 arm e92d4000 15 0 4 2 100\n",
  "0 02001000 arm e92d4000 0 0 4 15 100\n", "0 02001000 arm e92d4000 0 -4097 4 2 100\n",
  "2 02001000 arm e92d4000 0 0 4 2 100\n", "0 02001002 arm e92d4000 0 0 4 2 100\n",
  "0 02001001 thumb b500 0 0 4 2 100\n", "0 02001000 thumb e92d4000 0 0 4 2 100\n",
  "0 02001000 other e92d4000 0 0 4 2 100\n", "0 02001000 arm e92d4000 0 0 4 2 100 extra\n"})
  rejected([&]{load(bad);});
 rejected([&]{load(spec+"0 02001000 arm e92d4001 0 0 4 2 100\n");});
 std::string tooMany;for(unsigned n=0;n<65;++n)tooMany+="0 02001000 arm e92d4000 0 0 4 2 100\n";
 rejected([&]{load(tooMany);});
 auto empty=load(spec);rejected([&]{empty.Finish(out,summary);});
 require(ram==before);
 std::cout<<checks<<" memory-watch checks passed\n";
}
