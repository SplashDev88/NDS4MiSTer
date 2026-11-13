// SPDX-License-Identifier: GPL-3.0-only
// Test negotiation and immutable per-job selection; RTL tests check pixels.
static void mockComplete();
#define FPGA3D_TEST_PROGRESS mockComplete
#include "transport.h"
#include <iostream>
using namespace fpga3d;
static uint64_t checks=0;
static void check(bool value,const char* message){++checks;if(!value)throw std::runtime_error(message);}
static void mockComplete(){auto m=control+(Mailbox-0x3fc00000)/4;check(m[2]>>31,"unsealed producer");m[4]=m[1];m[5]=0;}
int main()try{
 constexpr uint32_t guard=0x71ac95b3;
 std::vector<uint32_t> ctl(0x100000/4,guard),pub(0x300000/4,guard),dest(256*192+16,guard);
 auto m=ctl.data()+(Mailbox-0x3fc00000)/4;
 for(uint32_t ready:{Magic,SegmentedMagic,HashedMagic,0x39443346u,0u})
 for(bool seg:{false,true})for(bool hash:{false,true})for(bool wc:{false,true})
 for(bool allowed:{false,true})for(bool poison:{false,true})for(bool epochMismatch:{false,true}){
  ctl[0]=0x31443348;ctl[2]=17;m[6]=ready;m[7]=epochMismatch?18:17;
  poisonedSession=poison?17:0;segmentedCommandsEnabled=seg;hashedTexturesEnabled=hash;
  bind(ctl.data(),pub.data(),allowed,wc);
  const bool valid=allowed && !poison && !epochMismatch && (ready==Magic || ready==SegmentedMagic || ready==HashedMagic);
  const bool segmented=valid && wc && seg && (ready==SegmentedMagic || ready==HashedMagic);
  const bool hashed=valid && wc && hash && ready==HashedMagic;
  check(available()==valid,"base capability");check(segmentedAvailable()==segmented,"segmented capability");check(hashingAvailable()==hashed,"hash capability");
  Frame f;f.reset();f.commands={clear(0,0,0xffffff),flush(0)};
  const auto sequence=m[1];check(f.start()==valid,"start admission");
  if(!valid){check(!f.active && m[1]==sequence,"unavailable request published");continue;}
  const auto expected=segmented?SegmentedMagic:hashed?HashedMagic:Magic;
  check(f.segmented==segmented && f.hashed==(hashed && !segmented),"mode selection");check(m[0]==expected,"published protocol");
  check(f.commandCapacity==(segmented?MaxSegmentedCommands:MaxCommands),"capacity contract");
  segmentedCommandsEnabled=!seg;hashedTexturesEnabled=!hash;
  f.publish();check(m[0]==expected,"active protocol changed with future preference");
  check(f.submit(dest.data()+8,256) && !f.active,"mock completion");
  for(auto pixel:dest)check(pixel==guard,"destination bounds or mock source changed");
  f.reset();check(!f.hashed && !f.segmented,"reset retained mode");
 }
 hashedTexturesEnabled=true;bind(nullptr,nullptr,true,true);check(!hashingAvailable(),"unbound capability");
 std::cout<<"HASH_PUBLICATION_PASS checks="<<checks<<'\n';return 0;
}catch(const std::exception& error){std::cerr<<"FAIL "<<error.what()<<'\n';return 1;}
