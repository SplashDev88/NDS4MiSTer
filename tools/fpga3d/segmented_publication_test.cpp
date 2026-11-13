// SPDX-License-Identifier: GPL-3.0-only
// CPU publication/ownership test. Mock completion does not validate pixels;
// saved-game RTL integration provides the independent renderer check.
static void mockComplete();
#define FPGA3D_TEST_PROGRESS mockComplete
#include "transport.h"
#include <iostream>
using namespace fpga3d;
static uint64_t checks=0;
static void require(bool v,const char* s){++checks;if(!v)throw std::runtime_error(s);}
static void mockComplete(){auto p=control+(Mailbox-0x3fc00000)/4;require(p[2]&0x80000000,"mock saw unsealed producer");p[5]=0;p[4]=p[1];}
static uint32_t addressOracle(uint32_t tail,size_t i){
 if(i>=8128)return tail+uint32_t(i-8128)*64;
 const size_t linear=4096+i*64;return 0x3fe30000u+uint32_t(linear/65536)*0x40000u+uint32_t(linear%65536);
}
int main()try{
 constexpr uint32_t guard=0x76543210;
 for(unsigned textureBytes:{0u,64u,TextureBytes-64,TextureBytes}){
  std::vector<uint32_t> ctl(0x100000/4,guard),pub(0x300000/4,guard),dst(256*192+16,guard);
  ctl[0]=0x31443348;ctl[2]=17;auto mailbox=ctl.data()+(Mailbox-0x3fc00000)/4;mailbox[6]=SegmentedMagic;mailbox[7]=17;
  poisonedSession=0;segmentedCommandsEnabled=true;bind(ctl.data(),pub.data(),true,true);
  Frame f;f.reset();f.textures.resize(textureBytes/4,0);f.startStream();
  const uint32_t tail=Textures+textureBytes;const size_t capacity=std::min<size_t>(16383,8128+(TextureBytes-textureBytes)/64);
  require(f.active && f.segmented && f.commandCapacity==capacity,"segmented stream capacity");
  for(size_t i=0;i<capacity;++i){PackedCommand command{};for(unsigned k=0;k<16;++k)command[k]=uint32_t(i*37+k+1);f.appendPacked(command);if(i%31==30)f.publish();}
  require(f.valid && f.commandCount()==capacity,"publication cumulative count");
  require(f.submit(dst.data()+8,256) && !f.active && !f.transportError,"mock completion handoff");
  for(size_t i=0;i<capacity;++i){const uint32_t a=addressOracle(tail,i);require(a>=Output && uint64_t(a)+64<=0x40000000u,"oracle range");
   for(unsigned k=0;k<16;++k)require(pub[(a-Output)/4+k]==uint32_t(i*37+k+1),"publication data/order");}
  for(uint32_t a=0x3fe00000;a<0x40000000;a+=4){const uint32_t plane=(a-0x3fe00000)/0x40000,offset=(a-0x3fe00000)%0x40000;bool owned=false;
   if(offset>=0x30000){const uint32_t linear=plane*65536+offset-0x30000;owned=linear>=4096 && (linear-4096)/64<std::min<size_t>(capacity,8128);}
   if(!owned)require(pub[(a-Output)/4]==guard,"visible pixels, telemetry or unused padding written");}
  for(unsigned i=0;i<textureBytes/4;++i)require(pub[(Textures-Output)/4+i]==0,"texture overwritten");
  for(uint32_t a=tail+uint32_t(capacity>8128?capacity-8128:0)*64;a<0x3fe00000;a+=4)require(pub[(a-Output)/4]==guard,"unused texture tail written");
  for(auto value:dst)require(value==guard,"mock copied outside destination bounds");
  // Overflow must remain invalid and never start a batch transaction.
  f.reset();f.textures.resize(textureBytes/4);f.commands.resize(capacity+1);const auto sequence=mailbox[1];
  require(!f.start() && !f.active && mailbox[1]==sequence,"oversized batch published");
  for(uint32_t ready:{Magic,0x39443346u,SegmentedMagic})for(bool optin:{false,true})for(bool wc:{false,true}){
   mailbox[6]=ready;segmentedCommandsEnabled=optin;writeCombined=wc;
   require(segmentedAvailable()==(ready==SegmentedMagic && optin && wc),"capability negotiation");
  }
 }
 std::cout<<"SEGMENT_PUBLICATION_PASS checks="<<checks<<'\n';return 0;
}catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
