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
 require(out.str().find(",2000100,4,12ab0000,main\n")!=std::string::npos);
 require(out.str().find(",2000200,4,cd000000,main\n")!=std::string::npos);
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
  "0 02001000 arm e92d4000 0 0 4 16 100\n", "0 02001000 arm e92d4000 0 -4097 4 2 100\n",
  "2 02001000 arm e92d4000 0 0 4 2 100\n", "0 02001002 arm e92d4000 0 0 4 2 100\n",
  "0 02001001 thumb b500 0 0 4 2 100\n", "0 02001000 thumb e92d4000 0 0 4 2 100\n",
  "0 02001000 other e92d4000 0 0 4 2 100\n", "0 02001000 arm e92d4000 0 0 4 2 100 extra\n"})
  rejected([&]{load(bad);});
 rejected([&]{load(spec+"0 02001000 arm e92d4001 0 0 4 2 100\n");});
 std::string tooMany;for(unsigned n=0;n<65;++n)tooMany+="0 02001000 arm e92d4000 0 0 4 2 100\n";
 rejected([&]{load(tooMany);});
 auto empty=load(spec);rejected([&]{empty.Finish(out,summary);});
 std::vector<uint8_t> dtcm(0x4000);dtcm[0x100]=0x9a;dtcm[0x101]=0xbc;
 const auto dtcmBefore=dtcm;map.dtcm=dtcm.data();regs[0]=0x027e0100;regs[15]=0x02001008;
 auto local=load("0 02001000 arm e92d4000 0 0 2 15 2001008 dtcm\n");
 local.Observe(0,0x02001000,0xe92d4000,regs.data(),0x1f,10,map,out);
 require(out.str().find(",27e0100,2,9abc,dtcm\n")!=std::string::npos);
 rejected([&]{local.Observe(0,0x02001000,0xe92d4000,originalRegs.data(),0x1f,10,map,out);});
 regs[0]=0x02000100;rejected([&]{local.Observe(0,0x02001000,0xe92d4000,regs.data(),0x1f,10,map,out);});
 regs[0]=0x027e3fff;rejected([&]{local.Observe(0,0x02001000,0xe92d4000,regs.data(),0x1f,10,map,out);});
 regs[0]=0x027e0100;map.dtcmMask=0xffff8000;rejected([&]{local.Observe(0,0x02001000,0xe92d4000,regs.data(),0x1f,10,map,out);});map.dtcmMask=0xffffc000;
 map.dtcm=nullptr;rejected([&]{local.Observe(0,0x02001000,0xe92d4000,regs.data(),0x1f,10,map,out);});map.dtcm=dtcm.data();
 map.itcmSize=0x02800000;rejected([&]{local.Observe(0,0x02001000,0xe92d4000,regs.data(),0x1f,10,map,out);});map.itcmSize=0x8000;
 rejected([&]{load("1 02001000 arm e92d4000 0 0 4 2 100 dtcm\n");});
 rejected([&]{load("0 02001000 arm e92d4000 0 0 4 2 100 itcm\n");});
 rejected([&]{load("0 02001000 arm e92d4000 0 0 4 2 100 dtcm extra\n");});
 require(dtcm==dtcmBefore);
 require(ram==before);
 // Explicit register-only rows do not inspect an address or require RAM backing.
 const ReplayMemoryWatch::Mapping noMemory{nullptr,0,0,0,0,nullptr};
 auto registers=load("1 03800100 arm e92d4010 0 0 0 15 3800108 regs\n");
 regs[0]=0xffffffff;regs[13]=0x0380f000;regs[15]=0x03800108;
 const auto beforeRegisters=regs;
 std::ostringstream registerOut;
 registers.Observe(0,0x03800100,0,regs.data(),0,12,noMemory,registerOut);
 require(registerOut.str().empty()&&registers.events==0);
 registers.Observe(1,0x03800100,0xe92d4010,regs.data(),0x92,12,noMemory,registerOut);
 require(registers.events==1&&registers.sites[0].hits==1);
 require(registerOut.str().find(",0,0,,regs\n")!=std::string::npos);
 require(registerOut.str().find(",380f000,")!=std::string::npos&&regs==beforeRegisters);
 unchanged=registerOut.str();
 rejected([&]{registers.Observe(1,0x03800100,0xe92d4011,regs.data(),0x92,12,noMemory,registerOut);});
 rejected([&]{registers.Observe(1,0x03800100,0xe92d4010,regs.data(),0xb2,12,noMemory,registerOut);});
 regs[15]=0;rejected([&]{registers.Observe(1,0x03800100,0xe92d4010,regs.data(),0x92,12,noMemory,registerOut);});
 require(registerOut.str()==unchanged&&registers.events==1);regs=beforeRegisters;
 auto thumbRegisters=load("1 03800102 thumb df1b 0 0 0 15 3800106 regs\n");
 regs[15]=0x03800106;
 thumbRegisters.Observe(1,0x03800102,0xdf1b,regs.data(),0x3f,12,noMemory,registerOut);
 require(thumbRegisters.events==1);
 // A failed data span must not emit an otherwise valid register-only prefix.
 auto mixed=load("1 03800100 arm e92d4010 0 0 0 15 3800108 regs\n"
                 "1 03800100 arm e92d4010 0 0 4 15 3800108 main\n");
 regs=beforeRegisters;unchanged=registerOut.str();
 rejected([&]{mixed.Observe(1,0x03800100,0xe92d4010,regs.data(),0x92,12,noMemory,registerOut);});
 require(registerOut.str()==unchanged&&mixed.events==0);
 for(const std::string bad:{
  "1 03800100 arm e92d4010 1 0 0 15 3800108 regs\n",
  "1 03800100 arm e92d4010 0 1 0 15 3800108 regs\n",
  "1 03800100 arm e92d4010 0 0 1 15 3800108 regs\n",
  "1 03800100 arm e92d4010 0 0 0 16 3800108 regs\n",
  "1 03800100 arm e92d4010 0 0 0 15 3800108 main\n",
  "1 03800100 arm e92d4010 0 0 0 15 3800108 regs extra\n"})
  rejected([&]{load(bad);});
 require(ram==before&&dtcm==dtcmBefore);
 std::cout<<checks<<" memory-watch checks passed\n";
}
