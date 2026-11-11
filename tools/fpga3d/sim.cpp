// SPDX-License-Identifier: GPL-3.0-only
#ifdef SHARED_FABRIC
#include "Vnds_fpga3d_shared.h"
using Dut=Vnds_fpga3d_shared;
#else
#include "Vnds_fpga3d.h"
using Dut=Vnds_fpga3d;
#endif
#include "verilated.h"
#include "codec.h"
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
 uint64_t textureReads=0,textureBeats=0;
 unsigned readLatency=std::getenv("READ_LATENCY")?std::atoi(std::getenv("READ_LATENCY")):0;
 unsigned remaining=0,readat=0,delay=0,writeRemaining=0,writeAt=0,writeBase=0,writeBurst=0;bool stalls=true;
 uint32_t guardedBase=0,guardedCount=0;
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
#ifndef SHARED_FABRIC
  v.accepted=!v.busy && (v.rd || v.wr);v.eval();
#endif
  if(v.reset)writeRemaining=0;
  if(writeRemaining && !v.busy && !v.reset)require(v.wr && !v.rd,"gap in physical Avalon write burst");
  if(held && !v.reset && v.enable)require(v.rd==heldRead && v.wr==heldWrite && v.addr==heldAddr && v.burst==heldBurst && v.din==heldData && v.be==heldBe,"DDR payload changed while stalled");
  held=v.busy && (v.rd||v.wr);heldRead=v.rd;heldWrite=v.wr;heldAddr=v.addr;heldBurst=v.burst;heldData=v.din;heldBe=v.be;
  if(!v.busy && (v.rd || v.wr)) {
   require(!(v.rd&&v.wr),"read/write overlap");
   uint32_t a=v.addr*8;
   if(v.rd)require((a&4095)+v.burst*8<=4096,"physical read crossed a 4 KiB page");
   if(v.rd){
    if(a>=Textures && a<0x3fe00000 && (!guardedBase || guardedBase==Commands || a<guardedBase)){textureReads++;textureBeats+=v.burst;}
    if(guardedBase==PaddedCommands && a>=0x3fe00000){
     const uint32_t plane=(a-0x3fe00000)>>18,offset=a&0x3ffff;
     require(offset>=0x30000 && offset+v.burst*8<=0x40000,"command read entered visible display pixels");
     const uint32_t logical=plane*0x10000+offset-0x30000;
     require(logical>=4096 && uint64_t(logical-4096)+v.burst*8<=uint64_t(guardedCount)*64,"read beyond published immutable command prefix");
    }else if(guardedBase && a>=guardedBase && a<(guardedBase==Commands?Commands+MaxCommands*64:0x3fe00000))
     require(uint64_t(a)+v.burst*8<=uint64_t(guardedBase)+guardedCount*64,"read beyond published immutable command prefix");
    require(!writeRemaining,"read interrupted write burst");require(!remaining,"overlapping read");remaining=v.burst;readat=a;delay=stalls?readLatency+rng()%7:0;
   }
   else {
    if(!writeRemaining){require(v.burst>0,"zero write burst");writeRemaining=v.burst;writeAt=a;writeBase=a;writeBurst=v.burst;}
    else require(a==writeBase && v.burst==writeBurst,"physical write burst command changed");
    a=writeAt;writeAt+=8;writeRemaining--;
    require((a==Mailbox+16 || a==Mailbox+24 || (a>=Output && a<Output+256*192*4) || (a>=StencilOutput && a<StencilOutput+512)
#ifdef SHARED_FABRIC
      || (a==0x3fc00478 && v.din==0x0123456789abcdefULL)
      || (a>=0x3fc00500 && a<0x3fc00580)
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
  for(size_t i=0;i<cmds.size();i++){auto packed=pack(cmds[i]);std::memcpy(&word(Commands)+i*16,packed.data(),sizeof(PackedCommand));}
  word(Mailbox+60)=Commands;word(Mailbox+8)=0x80000000u|cmds.size();word(Mailbox+12)=sess;word(Mailbox)=Magic;word(Mailbox+4)=sequence;
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
 uint64_t runStreaming(const std::vector<Command>& cmds,unsigned sequence,unsigned textureBytes=0,unsigned expectStatus=0,bool abort=false){
  uint32_t base=textureBytes<=TextureBytes-MaxCommands*64?((Textures+textureBytes+63)&~63u):Commands;
  require(cmds.size()<=MaxCommands && (base==Commands || base+cmds.size()*64<=0x3fe00000u),"stream arena capacity");
  guardedBase=base;guardedCount=0;
  for(unsigned i=0;i<cmds.size()*16;i++)word(base+4*i)=0xffffffff;
  word(Mailbox+60)=base;word(Mailbox+8)=0;word(Mailbox+12)=17;word(Mailbox)=Magic;word(Mailbox+4)=sequence;
  uint64_t start=cycles;
  for(int i=0;i<5000;i++){tick();require(word(Mailbox+16)!=sequence,"empty open producer completed early");}
  for(unsigned n=0;n<cmds.size();){
   unsigned end=std::min<unsigned>(cmds.size(),n+1+rng()%29);
   for(unsigned i=n;i<end;i++){auto packed=pack(cmds[i]);std::memcpy(&word(base)+i*16,packed.data(),sizeof(packed));}
   guardedCount=end;word(Mailbox+8)=end;n=end;
   for(unsigned i=0;i<1000+rng()%2000;i++){tick();require(word(Mailbox+16)!=sequence,"open producer completed early");}
   if(abort && n>=30)break;
  }
  for(int i=0;i<5000;i++){tick();require(word(Mailbox+16)!=sequence,"open final prefix completed early");}
  word(Mailbox+8)=0x80000000u|guardedCount;
  while(word(Mailbox+16)!=sequence && cycles-start<60000000)tick();
  require(word(Mailbox+16)==sequence,"stream completion timeout");
  require(word(Mailbox+20)==expectStatus,"stream completion status");
  guardedBase=0;return cycles-start;
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
 if(argc>=3){
  Sim sim;sim.reset();
  for(int j=0;j<std::atoi(argv[2]);j++){
   auto prefix=std::string(argv[1])+"/"+std::to_string(j);
   auto commands=load<Command>(prefix+".commands");
   auto textures=load<uint32_t>(prefix+".textures");auto expected=load<uint32_t>(prefix+".expected");
   require(textures.size()*4<=TextureBytes && expected.size()==256*192,"fixture bounds");
   std::memset(&sim.word(StencilInput),0,512);
   std::vector<uint8_t> expectedStencil;
   if(std::ifstream(prefix+".stencil_input").good()){
    auto seed=load<uint8_t>(prefix+".stencil_input");expectedStencil=load<uint8_t>(prefix+".stencil_expected");
    require(seed.size()==512 && expectedStencil.size()==512,"stencil fixture bounds");
    std::memcpy(&sim.word(StencilInput),seed.data(),512);
   }
   std::memcpy(&sim.word(Textures),textures.data(),textures.size()*4);
   auto reads=sim.textureReads,beats=sim.textureBeats;auto cycles=argc==4?sim.runStreaming(commands,j+1,textures.size()*4):sim.run(commands,j+1);
   for(size_t k=0;k<expected.size();k++)if(sim.word(Output+4*k)!=expected[k]){
    std::cerr<<"fixture="<<j<<" pixel="<<k<<" expected="<<std::hex<<expected[k]<<" got="<<sim.word(Output+4*k)<<std::dec<<"\n";
    throw std::runtime_error("production renderer mismatch");
   }
   for(size_t k=0;k<expectedStencil.size();k++)if(reinterpret_cast<uint8_t*>(&sim.word(StencilOutput))[k]!=expectedStencil[k]){
    std::cerr<<"fixture="<<j<<" stencil="<<k<<" expected="<<unsigned(expectedStencil[k])<<" got="<<unsigned(reinterpret_cast<uint8_t*>(&sim.word(StencilOutput))[k])<<"\n";
    throw std::runtime_error("production stencil mismatch");
   }
   std::cout<<"PRODUCTION_PASS fixture="<<j<<" cycles="<<cycles<<" texture_reads="<<(sim.textureReads-reads)<<" texture_beats="<<(sim.textureBeats-beats)<<"\n";
  }return 0;
 }


 // Incremental producer boundaries, unpublished poison, late finalization,
 // intentional cancellation, metadata regression and stale epoch.
 {
  Sim p;p.reset();std::vector<Command> c;
  for(unsigned y=0;y<192;y++){c.push_back(clear(y,0x1f010203,0xffffff));c.push_back(flush(y));}
  for(unsigned seq=101;seq<104;seq++){
   p.runStreaming(c,seq);
   for(unsigned i=0;i<49152;i++)require(p.word(Output+4*i)==0x1f010203,"streamed frame output");
  }
  p.runStreaming(c,104,0,1,true);
  for(unsigned mode=0;mode<4;mode++){
   unsigned seq=105+mode;auto packed=pack(clear(0,0,0xffffff));
   std::memcpy(&p.word(Commands),packed.data(),sizeof(packed));
   p.word(Mailbox+60)=Commands;p.word(Mailbox+8)=1;p.word(Mailbox+12)=17;p.word(Mailbox)=Magic;p.word(Mailbox+4)=seq;
   for(int i=0;i<5000;i++)p.tick();require(p.word(Mailbox+16)!=seq,"producer did not wait");
   if(mode==0)p.word(Mailbox+8)=0; // Prefix cannot shrink.
   if(mode==1)p.word(Mailbox+8)=8129; // Cannot exceed physical arena.
   if(mode==2)p.word(Mailbox+12)=16; // Epoch cannot change in flight.
   if(mode==3)p.word(Mailbox+8)=0x80000001; // Closed incomplete scanline.
   unsigned limit=0;while(p.word(Mailbox+16)!=seq && ++limit<10000)p.tick();
   require(limit<10000 && p.word(Mailbox+20)==(mode==2?2:1),"bad producer metadata accepted");
  }
  for(uint32_t base:{0x3fc00000u,0x3fd40004u,0x3fe00000u,0x3fe30000u,0x3fe31040u,0x3fff0000u,0x40000000u}){
   p.word(Mailbox+60)=base;p.word(Mailbox+8)=0x80000000;p.word(Mailbox+12)=17;p.word(Mailbox)=Magic;
   unsigned seq=++p.word(Mailbox+4),limit=0;while(p.word(Mailbox+16)!=seq && ++limit<10000)p.tick();
   require(limit<10000 && p.word(Mailbox+20)==1,"bad command base accepted");
  }
  std::cout<<"PASS streamed immutable prefixes, unpublished-read guard, delayed finalization, cancellation, metadata and base bounds\n";
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
 // Exercise the entire compact command arena, including more than 4064 spans.
 std::vector<Command> fullArena;
 for(unsigned y=0;y<192;y++){
  fullArena.push_back(clear(y,0x1f102030,0xffffff));
  for(unsigned k=0;k<40+(y<64);k++){
   Span s;s.first=0;s.end=1;s.width=1;s.alphaRef=31;s.flags=Linear|(y&1?WBuffer:0);
   s.z0=0xffffff;s.z1=0;s.left.fill(-32768);s.right.fill(32767);
   fullArena.push_back(span(s));
  }
  fullArena.push_back(flush(y));
 }
 require(fullArena.size()==MaxCommands,"compact arena coverage");sim.run(fullArena,++seq);
 for(unsigned k=0;k<49152;k++)require(sim.word(Output+4*k)==0x1f102030,"compact full arena output");
 std::cout<<"PASS compact 8128 descriptors, full arena boundary and width-one unused-step extrema\n";
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
 // Fog requires a leading configuration, validates the shift, and may
 // never reuse configuration implicitly from an earlier submitted frame.
 sim.run({clear(0,0,0xffffff,false,0,128)},++seq,1);
 std::array<uint8_t,34> fogTable{};auto badFog=fog(0,0,0,fogTable.data());badFog[3]=16;
 sim.run({badFog},++seq,1);
 sim.run({clear(0,0,0xffffff),fog(0,0,0,fogTable.data())},++seq,1);
 // Out-of-range texel alpha must fail without publishing a completed image.
 Span alpha;alpha.first=0;alpha.end=1;alpha.width=1;alpha.flags=Linear|Textured;
 sim.word(Textures)=0x3f123456;
 sim.run({clear(0,0,0xffffff),span(alpha)},++seq,3);
 // Three spans alias the same direct-mapped cache entry (A, B, A), then
 // replace the underlying texture bytes in a new immutable frame epoch.
 std::vector<Command> cacheCommands;
 for(unsigned y=0;y<192;y++){
  cacheCommands.push_back(clear(y,0,0xffffff));
  if(y==0)for(int x=0;x<3;x++){
   Span s;s.first=x;s.end=x+1;s.origin=x;s.width=1;s.flags=Linear|Textured;
   s.left={504,504,504,0,0};s.right=s.left;s.texture=Textures+(x==1?4096:0);
   cacheCommands.push_back(span(s));
  }
  cacheCommands.push_back(flush(y));
 }
 auto checkCache=[&](uint32_t a,uint32_t b){
  sim.word(Textures)=a;sim.word(Textures+4096)=b;sim.run(cacheCommands,++seq);
  for(unsigned i=0;i<256*192;i++)require(sim.word(Output+4*i)==(i==0||i==2?a:i==1?b:0),"texture cache alias/invalidation mismatch");
 };
 checkCache(0x1f3f3f3f,0x1f030507);checkCache(0x1f112233,0x1f213223);
 // Interrupt in-flight frames at several points, discard the prior request,
 // and prove that partially filled pipeline/cache state cannot leak forward.
 for(unsigned cut:{256u,4096u,32768u}){
  for(size_t i=0;i<cacheCommands.size();i++){auto packed=pack(cacheCommands[i]);std::memcpy(&sim.word(Commands)+i*16,packed.data(),sizeof(PackedCommand));}
  sim.word(Mailbox+60)=Commands;sim.word(Mailbox+8)=0x80000000u|cacheCommands.size();sim.word(Mailbox+12)=17;
  sim.word(Mailbox)=Magic;const unsigned interrupted=++seq;sim.word(Mailbox+4)=interrupted;
  for(unsigned k=0;k<cut;k++)sim.tick();
  require(sim.word(Mailbox+16)!=interrupted,"reset cut did not interrupt a frame");
  sim.word(Mailbox+24)=0;sim.reset();
  for(unsigned k=0;k<1000;k++)sim.tick();
  require(sim.word(Mailbox+16)!=interrupted,"interrupted frame completed after reset");
  checkCache(0x1f06090c,0x1f3a2b1c);
 }

 // A long descriptor read remains owned by the fabric after enable loss.
 // Drain it before a new epoch and reject all old output publication.
 for(unsigned cut:{1u,32u,63u,127u}){
  for(size_t i=0;i<cacheCommands.size();i++){auto packed=pack(cacheCommands[i]);std::memcpy(&sim.word(Commands)+i*16,packed.data(),sizeof(PackedCommand));}
  sim.word(Mailbox+60)=Commands;sim.word(Mailbox+8)=0x80000000u|cacheCommands.size();sim.word(Mailbox+12)=17;
  sim.word(Mailbox)=Magic;const unsigned interrupted=++seq;sim.word(Mailbox+4)=interrupted;
  unsigned guard=0;
  while(!(sim.remaining && sim.readat>=Commands && sim.readat<Commands+MaxCommands*64 && sim.remaining<=128-cut) && guard++<2000000)sim.tick();
  require(guard<2000000,"did not reach long descriptor read");
  sim.v.enable=0;guard=0;
  while(sim.remaining && guard++<10000){sim.tick();require(!(sim.v.wr && sim.v.addr*8>=Output && sim.v.addr*8<Output+49152*4),"disabled reader wrote output");}
  require(guard<10000,"disabled descriptor read did not drain");
  for(unsigned k=0;k<1000;k++)sim.tick();
  require(sim.word(Mailbox+16)!=interrupted,"disabled descriptor frame completed");
  sim.v.enable=1;for(unsigned k=0;k<1000;k++)sim.tick();
  checkCache(0x1f021426,0x1f352719);
 }
 std::cout<<"PASS long descriptor read ownership across enable loss and 196608 fresh-frame pixels\n";
 // Dropping the renderer enable must drain an already accepted physical
 // burst even though no completion for that interrupted frame is published.
 for(unsigned cut:{1u,2u,63u,127u}){
  for(size_t i=0;i<cacheCommands.size();i++){auto packed=pack(cacheCommands[i]);std::memcpy(&sim.word(Commands)+i*16,packed.data(),sizeof(PackedCommand));}
  sim.word(Mailbox+60)=Commands;sim.word(Mailbox+8)=0x80000000u|cacheCommands.size();sim.word(Mailbox+12)=17;
  sim.word(Mailbox)=Magic;const unsigned interrupted=++seq;sim.word(Mailbox+4)=interrupted;
  unsigned guard=0;
  while(!(sim.writeRemaining && sim.writeBase>=Output && sim.writeBase<Output+256*192*4 &&
          sim.writeBurst==128 && sim.writeRemaining<=128-cut) && guard++<2000000)sim.tick();
  require(guard<2000000,"did not reach an in-flight output burst");
  sim.v.enable=0;
  guard=0;
  while(sim.writeRemaining && sim.writeBase>=Output && sim.writeBase<Output+256*192*4 && guard++<10000)sim.tick();
  require(guard<10000,"disabled output burst did not drain");
  for(unsigned k=0;k<1000;k++){
   sim.tick();require(!(sim.v.wr && sim.v.addr*8>=Output && sim.v.addr*8<Output+256*192*4),"disabled rasterizer started another output write");
  }
  require(sim.word(Mailbox+16)!=interrupted,"disabled frame completed");
  sim.word(Mailbox+24)=0;sim.v.enable=1;
  for(unsigned k=0;k<10000 && sim.word(Mailbox+24)!=Magic;k++)sim.tick();
  require(sim.word(Mailbox+24)==Magic,"re-enabled rasterizer did not restart");
  for(unsigned k=0;k<1000;k++)sim.tick();
  require(sim.word(Mailbox+16)!=interrupted,"disabled request replayed");
  checkCache(0x1f090c0f,0x1f302115);
 }
 std::cout<<"PASS enable-loss burst drain at beats 1,2,63,127 and 196608 fresh-frame comparisons\n";
 // Stencil seeding and publication own additional DDR transactions. Abort
 // during each boundary and verify a fresh frame receives all 512 seed bytes.
 for(unsigned phase=0;phase<2;phase++)for(unsigned cut:{1u,32u,63u}){
  for(unsigned i=0;i<128;i++){sim.word(StencilInput+4*i)=0x03020100;sim.word(StencilOutput+4*i)=0xdeadbeef;}
  for(size_t i=0;i<cacheCommands.size();i++){auto packed=pack(cacheCommands[i]);std::memcpy(&sim.word(Commands)+i*16,packed.data(),sizeof(PackedCommand));}
  sim.word(Mailbox+60)=Commands;sim.word(Mailbox+8)=0x80000000u|cacheCommands.size();sim.word(Mailbox+12)=17;
  sim.word(Mailbox)=Magic;const unsigned interrupted=++seq;sim.word(Mailbox+4)=interrupted;
  unsigned guard=0;
  auto reached=[&](){return phase==0?
    sim.remaining && sim.readat>=StencilInput && sim.readat<StencilInput+512 && sim.remaining<=64-cut:
    sim.word(StencilOutput+8*(cut-1))!=0xdeadbeef;};
  while(!reached() && guard++<3000000)sim.tick();
  require(guard<3000000,"did not reach stencil transaction interruption");
  require(sim.word(Mailbox+16)!=interrupted,"stencil interruption too late");
  sim.v.enable=0;for(unsigned k=0;k<10000;k++)sim.tick();
  // Other DDR clients continue after the rasterizer is disabled. Only its
  // seed/output transactions must be gone; the shared bus need not be idle.
  require(!(sim.remaining && sim.readat>=StencilInput && sim.readat<StencilInput+512) &&
          !(sim.writeRemaining && sim.writeBase>=StencilOutput && sim.writeBase<StencilOutput+512),
          "disabled stencil transaction did not drain");
  require(sim.word(Mailbox+16)!=interrupted,"interrupted stencil frame completed");
  sim.v.enable=1;for(unsigned k=0;k<1000;k++)sim.tick();
  checkCache(0x1f091527,0x1f342618);
  for(unsigned i=0;i<128;i++)require(sim.word(StencilOutput+4*i)==0x03020100,"fresh stencil state after interruption");
 }
 std::cout<<"PASS stencil seed/dump enable-loss ownership, 294912 fresh pixels and 3072 stencil bytes\n";
 sim.run({flush(0)},0xffffffff,1);sim.run({flush(0)},1,1);
 auto doneBefore=sim.word(Mailbox+16);sim.word(Mailbox)=0;sim.word(Mailbox+4)=2;
 for(int i=0;i<1000;i++)sim.tick();require(sim.word(Mailbox+16)==doneBefore,"invalid magic consumed");
 // Reset must discard the previous request, not replay it into reused memory.
 sim.word(Mailbox+24)=0;sim.reset();auto done=sim.word(Mailbox+16);
 for(int i=0;i<1000;i++)sim.tick();require(sim.word(Mailbox+16)==done,"stale request replayed");
 std::cout<<"PASS "<<pixels<<" candidate pixels, 884736 random output comparisons plus 245760 cache/reset comparisons, malformed requests/alpha, cache collisions and invalidation, randomized DDR stalls, interrupted-frame reset quarantine\n";
 return 0;
 }catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<"\n";return 1;}}
