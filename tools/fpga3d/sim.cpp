// SPDX-License-Identifier: GPL-3.0-only
#ifdef SHARED_FABRIC
#include "Vnds_fpga3d_shared.h"
using Dut=Vnds_fpga3d_shared;
#else
#include "Vnds_fpga3d.h"
using Dut=Vnds_fpga3d;
#endif
#include "verilated.h"
#include "abi.h"
#include <cstring>
#include <iostream>
#include <random>
#include <string>
#include <cstdlib>
#include <fstream>
using namespace fpga3d;
static void require(bool b,const char* m){if(!b)throw std::runtime_error(m);}
struct Sim {
 Dut v;
 std::vector<uint32_t> mem=std::vector<uint32_t>(0x400000/4);
 std::mt19937 rng{43817};uint64_t cycles=0;
 unsigned remaining=0,readat=0,delay=0;bool stalls=true;
 bool held=false;uint64_t heldData=0;unsigned heldAddr=0,heldBurst=0,heldBe=0;bool heldRead=false,heldWrite=false;
 uint32_t& word(uint32_t a){require(a>=0x3fc00000 && a<0x40000000,"address out of graphics window");return mem.at((a-0x3fc00000)/4);}
 void tick(){
#ifdef REAL_CONTROL
  // Minimal HPS responder for the production packet-mode initializer. Honor
  // its exact quiesce token, Ready/session pair, and live heartbeat.
  if(word(0x3fc00000)==0x51443348){word(0x3fc00078)=word(0x3fc00070);word(0x3fc0007c)=0;}
  if(word(0x3fc00000)==0x31443348){word(0x3fc00028)=2;word(0x3fc0002c)=word(0x3fc00008);word(0x3fc00068)++;}
#endif
  v.clk=0;v.dout_ready=0;v.busy=remaining!=0 || (stalls && rng()%5==0);
  if(remaining && (!stalls || delay--==0)){
   v.dout_ready=1;v.dout=uint64_t(word(readat))|(uint64_t(word(readat+4))<<32);
   readat+=8;remaining--;delay=stalls?rng()%4:0;
  }
  v.eval();
  if(held && !v.reset && v.enable)require(v.rd==heldRead && v.wr==heldWrite && v.addr==heldAddr && v.burst==heldBurst && v.din==heldData && v.be==heldBe,"DDR payload changed while stalled");
  held=v.busy && (v.rd||v.wr);heldRead=v.rd;heldWrite=v.wr;heldAddr=v.addr;heldBurst=v.burst;heldData=v.din;heldBe=v.be;
  if(!v.busy && (v.rd || v.wr)) {
   require(!(v.rd&&v.wr),"read/write overlap");
   uint32_t a=v.addr*8;
   if(v.rd){require(!remaining,"overlapping read");remaining=v.burst;readat=a;delay=stalls?rng()%7:0;}
   else {
    require((a==Mailbox+16 || a==Mailbox+24 || (a>=Output && a<Output+256*192*4)
#ifdef SHARED_FABRIC
      || (a==0x3fc00478 && v.din==0x0123456789abcdefULL)
#endif
#ifdef REAL_CONTROL
      || (a>=0x3fc00000 && a<0x3fc00080)
#endif
    ),"write outside owned output/mailbox");
    require(v.be==255,"partial write");word(a)=uint32_t(v.din);word(a+4)=v.din>>32;
   }
  }
  v.clk=1;v.eval();cycles++;
 }
 void reset(){for(unsigned a=0x3fc00400;a<0x3fc00480;a+=8){word(a)=0x89abcdef;word(a+4)=0x01234567;}v.reset=1;v.enable=0;v.session=17;remaining=0;for(int i=0;i<8;i++)tick();v.reset=0;v.enable=1;
  for(int i=0;i<10000 && word(Mailbox+24)!=Magic;i++)tick();require(word(Mailbox+24)==Magic,"startup missing");}
 uint64_t run(const std::vector<Command>& cmds,unsigned sequence=1,unsigned expectStatus=0,unsigned sess=17){
  require(cmds.size()<=MaxCommands,"command overflow");
  std::memcpy(&word(Commands),cmds.data(),cmds.size()*sizeof(Command));
  word(Mailbox+8)=cmds.size();word(Mailbox+12)=sess;word(Mailbox)=Magic;word(Mailbox+4)=sequence;
  uint64_t start=cycles;
#ifdef SHARED_FABRIC
  constexpr uint64_t cycleLimit=60000000; // Continuous control writes plus three other peers.
#else
  constexpr uint64_t cycleLimit=20000000;
#endif
  while(word(Mailbox+16)!=sequence && cycles-start<cycleLimit)tick();
  require(word(Mailbox+16)==sequence,"completion timeout");
  if(word(Mailbox+20)!=expectStatus)throw std::runtime_error("status "+std::to_string(word(Mailbox+20))+" expected "+std::to_string(expectStatus));
  return cycles-start;
 }
};
static void oracle(const Span& s,const std::vector<uint32_t>& texture,std::array<uint32_t,256>& c,std::array<uint32_t,256>& z,std::array<bool,256>& back){
 for(int x=s.first;x<s.end;x++){
  uint32_t zz=depth(s,x);
  bool pass;
  if(s.flags&Equal){int64_t d=int64_t(zz)-z[x];int threshold=s.flags&WBuffer?255:512;pass=d>=-threshold&&d<=threshold;}
  else pass=zz<z[x]||((s.flags&Front)&&back[x]&&zz==z[x]);
  if(!pass)continue;
  uint32_t pixel=0x1f000000;
  if(s.flags&Textured){
   unsigned a=coord(attribute(s,3,x),s.shiftS,s.wrap&1,s.wrap&4);
   unsigned b=coord(attribute(s,4,x),s.shiftT,s.wrap&2,s.wrap&8);
   uint32_t t=texture.at(a+(b<<s.shiftS));pixel=t&0xff000000;
   for(int k=0;k<3;k++){unsigned tc=(t>>(8*k))&63,vc=(attribute(s,k,x)>>3)&63;pixel|=(((tc+1)*(vc+1)-1)>>6)<<(8*k);}
  }else for(int k=0;k<3;k++)pixel|=((attribute(s,k,x)>>3)&63)<<(8*k);
  if((pixel>>24)<=s.alphaRef)continue;
  c[x]=pixel;z[x]=zz;back[x]=(s.flags&Back)!=0;
 }
}
template<class T>std::vector<T> load(const std::string& path) {
 std::ifstream f(path,std::ios::binary|std::ios::ate);require(bool(f),"missing fixture");
 auto bytes=f.tellg();require(bytes>=0 && size_t(bytes)%sizeof(T)==0,"fixture length");
 std::vector<T> v(size_t(bytes)/sizeof(T));f.seekg(0);f.read(reinterpret_cast<char*>(v.data()),bytes);require(bool(f),"fixture read");return v;
}
int main(int argc,char** argv){try{
 if(argc==3){
  Sim sim;sim.reset();
  for(int j=0;j<std::atoi(argv[2]);j++){
   auto prefix=std::string(argv[1])+"/"+std::to_string(j);
   auto commands=load<Command>(prefix+".commands");
   auto textures=load<uint32_t>(prefix+".textures");auto expected=load<uint32_t>(prefix+".expected");
   require(textures.size()*4<=TextureBytes && expected.size()==256*192,"fixture bounds");
   std::memcpy(&sim.word(Textures),textures.data(),textures.size()*4);
   auto cycles=sim.run(commands,j+1);
   for(size_t k=0;k<expected.size();k++)if(sim.word(Output+4*k)!=expected[k]){
    std::cerr<<"fixture="<<j<<" pixel="<<k<<" expected="<<std::hex<<expected[k]<<" got="<<sim.word(Output+4*k)<<std::dec<<"\n";
    throw std::runtime_error("production renderer mismatch");
   }
   std::cout<<"PRODUCTION_PASS fixture="<<j<<" cycles="<<cycles<<"\n";
  }return 0;
 }

 Sim sim;sim.reset();std::mt19937 rng(91973);unsigned seq=0;uint64_t pixels=0;
 for(int trial=0;trial<18;trial++){
  std::vector<Command> commands;std::vector<uint32_t> expected;
  std::vector<uint32_t> tex(128*64);
  for(auto& p:tex)p=((rng()%7?31u:0u)<<24)|(rng()&0x003f3f3f);
  std::memcpy(&sim.word(Textures),tex.data(),tex.size()*4);
  sim.stalls=trial!=0;
  for(int y=0;y<192;y++){
   std::array<uint32_t,256> color{},z{};std::array<bool,256> back{};
   uint32_t clearColor=(rng()%32)<<24|(rng()&0x3f3f3f),clearDepth=0xffffff;
   color.fill(clearColor);z.fill(clearDepth);back.fill(y&1);
   commands.push_back(clear(y,clearColor,clearDepth,y&1));
   for(int poly=0;poly<(trial==0?1:8);poly++){
    Span s;s.origin=trial==0?0:-int(rng()%32);s.width=trial==0?256:256;
    s.first=trial==0?0:rng()%128;s.end=trial==0?256:s.first+1+rng()%(s.origin+s.width-s.first);
    s.flags=(trial&1?Linear:0)|(trial&2?WBuffer:0)|(trial&4?Textured:0)|(rng()%2?Front:Back);
    if(poly==7)s.flags|=Equal;
    s.w0=trial==0?128:rng()%65536;s.w1=trial==0?128:rng()%65536;
    if(trial==8)s.w0=s.w1=0;
    s.z0=rng()%0x1000000;s.z1=rng()%0x1000000;
    s.shiftS=7;s.shiftT=6;s.wrap=trial%16;s.alphaRef=trial==17?31:0;
    for(int k=0;k<5;k++){s.left[k]=k<3?int(rng()%512):int(rng()%65536)-32768;s.right[k]=k<3?int(rng()%512):int(rng()%65536)-32768;}
    commands.push_back(span(s));oracle(s,tex,color,z,back);pixels+=s.end-s.first;
   }
   commands.push_back(flush(y));expected.insert(expected.end(),color.begin(),color.end());
  }
  auto clocks=sim.run(commands,++seq);
  for(size_t i=0;i<expected.size();i++)if(sim.word(Output+4*i)!=expected[i]){
   std::cerr<<"trial="<<trial<<" pixel="<<i<<" expected="<<std::hex<<expected[i]<<" got="<<sim.word(Output+4*i)<<std::dec<<"\n";
   throw std::runtime_error("pixel mismatch");
  }
  std::cout<<"frame "<<trial<<" PASS cycles="<<clocks<<"\n";
 }
 // Malformed command, count, row ordering, texture bounds and stale session.
 sim.run({flush(0)},++seq,1);
 auto bad=span(Span{});bad[2]|=Textured;bad[13]=0x30000000;
 sim.run({clear(0,0,0xffffff),bad},++seq,1);
 sim.run({clear(1,0,0xffffff)},++seq,1);
 sim.run({clear(0,0,0xffffff)},++seq,2,16);
 sim.run({clear(0,0,0xffffff),flush(0)},++seq,1);
 sim.run({},++seq,1);
 auto extent=span(Span{});extent[2]|=Textured;extent[13]=0x3fd40000;extent[14]=10|(10<<4);
 sim.run({clear(0,0,0xffffff),extent},++seq,1);
 sim.run({flush(0)},0xffffffff,1);sim.run({flush(0)},1,1);
 auto doneBefore=sim.word(Mailbox+16);sim.word(Mailbox)=0;sim.word(Mailbox+4)=2;
 for(int i=0;i<1000;i++)sim.tick();require(sim.word(Mailbox+16)==doneBefore,"invalid magic consumed");
 // Reset must discard the previous request, not replay it into reused memory.
 sim.word(Mailbox+24)=0;sim.reset();auto done=sim.word(Mailbox+16);
 for(int i=0;i<1000;i++)sim.tick();require(sim.word(Mailbox+16)==done,"stale request replayed");
 std::cout<<"PASS "<<pixels<<" candidate pixels, 884736 output comparisons, malformed requests, randomized DDR stalls, reset stale-request quarantine\n";
 return 0;
 }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}}
