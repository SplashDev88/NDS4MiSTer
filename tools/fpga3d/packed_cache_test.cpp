// SPDX-License-Identifier: GPL-3.0-only
#include <cstdint>
static void observeRead(uint32_t address,unsigned beats);
#define FPGA3D_READ_OBSERVER observeRead
#define main legacy_sim_main
#include "sim.cpp"
#undef main

static uint64_t checked=0;
static bool forbidTextureRead=false;
static void observeRead(uint32_t address,unsigned) {
 if(forbidTextureRead)require(address<Textures,"invalid descriptor fetched texture or out-of-arena memory");
}
static std::vector<Command> frame(const Span& s) {
 std::vector<Command> c;
 for(unsigned y=0;y<192;y++) {
  c.push_back(clear(y,0x1f010203,0xffffff));
  if(y==0)c.push_back(span(s));
  c.push_back(flush(y));
 }
 return c;
}
static void compare(Sim& sim,const Span& s,const std::vector<uint32_t>& texture) {
 std::array<uint32_t,256> color,z;std::array<bool,256> back{};
 color.fill(0x1f010203);z.fill(0xffffff);oracle(s,texture,color,z,back);
 for(unsigned i=0;i<49152;i++) {
  require(sim.word(Output+4*i)==(i<256?color[i]:0x1f010203),"packed cache boundary/format pixels differ");++checked;
 }
}
static void submitRaw(Sim& sim,const std::vector<Command>& commands,unsigned seq,bool removeInvalid=false) {
 for(size_t i=0;i<commands.size();i++) {
  auto p=pack(commands[i]);if(removeInvalid && i==1)p[15]&=0x7fffffffu;
  std::memcpy(&sim.word(Commands)+i*16,p.data(),64);
 }
 sim.word(Mailbox+60)=Commands;sim.word(Mailbox+8)=0x80000000u|commands.size();
 sim.word(Mailbox+12)=17;sim.word(Mailbox)=Magic;sim.word(Mailbox+4)=seq;
}
int main(int argc,char** argv)try {
 if(argc>1 && std::string(argv[1])=="--legacy")return legacy_sim_main(1,argv);
 if(argc>1 && std::string(argv[1])=="--fixtures")return legacy_sim_main(argc-1,argv+1);
 Sim sim;sim.reset();unsigned sequence=900;unsigned good=0,bad=0,cuts=0;
 for(unsigned format=0;format<3;format++)for(unsigned end=0;end<2;end++) {
  const unsigned bytes=format==0?256:format==1?128:1088;
  const uint32_t base=end?0x3fe00000-bytes:Textures;
  std::vector<uint32_t> texture(64);
  for(unsigned i=0;i<64;i++)texture[i]=unpackTexture16(uint16_t(0x8000|(i*487&32767)));
  if(format==0)std::memcpy(&sim.word(base),texture.data(),bytes);
  else if(format==1) {
   std::vector<uint32_t> packed;require(packTexture16(texture.data(),64,packed),"test texture packing");
   std::memcpy(&sim.word(base),packed.data(),bytes);
  }else {
   for(unsigned i=0;i<256;i++)sim.word(base+4*i)=texture[i%64];
   for(unsigned i=0;i<64;i+=4)sim.word(base+1024+i)=i|((i+1)<<8)|((i+2)<<16)|((i+3)<<24);
  }
  for(unsigned linear=0;linear<2;linear++) {
   Span s;s.flags=Textured|(linear?Linear:0);s.texture=base|(format==1?2:format==2?1:0);
   s.left={504,504,504,0,0};s.right={504,504,504,128,128};
   sim.run(frame(s),++sequence);compare(sim,s,texture);++good;
  }
 }
 // Bypass the software packer's invalid marker to exercise the RTL's full
 // arena checks, including the representable region above the texture end.
 for(uint32_t address:{0x3fdfff80u,0x3fe00000u,0x3fe3ff80u}) {
  Span s;s.flags=Linear|Textured;s.texture=address;
  s.first=0;s.end=1;s.width=1;s.left={504,504,504,0,0};s.right=s.left;
  auto commands=frame(s);const auto reads=sim.textureReads;
  forbidTextureRead=true;submitRaw(sim,commands,++sequence,true);
  const auto start=sim.cycles;
  while(sim.word(Mailbox+16)!=sequence && sim.cycles-start<60000000)sim.tick();
  require(sim.word(Mailbox+16)==sequence && sim.word(Mailbox+20)==1,"out-of-arena descriptor accepted");
  require(sim.textureReads==reads,"invalid extent fetched texture memory");forbidTextureRead=false;++bad;
 }
 // Both cache words carry a tag. Interrupt before either a two-beat sector
 // or an eight-beat line has completed, then change memory under the same
 // address in a fresh session and check that no partial entry survives.
 for(unsigned length:{2u,8u})for(unsigned cut=1;cut<length;cut++) {
  Span s;s.flags=Textured|(length==8?Linear:0);s.first=0;s.end=1;s.width=1;
  s.left={504,504,504,0,0};s.right=s.left;s.texture=Textures;
  sim.word(Textures)=0x1f030507;auto commands=frame(s);
  submitRaw(sim,commands,++sequence);const unsigned interrupted=sequence;
  uint64_t start=sim.cycles;bool reached=false;
  while(sim.cycles-start<60000000) {
   sim.tick();
   if(sim.readat>=Textures && sim.readat<Textures+256 && sim.remaining==length-cut){reached=true;break;}
  }
  require(reached,"did not reach requested partial texture refill");
  sim.v.enable=0;
  while(sim.remaining && sim.readat>=Textures && sim.readat<Textures+256)sim.tick();
  for(unsigned i=0;i<2000;i++){sim.tick();require(sim.word(Mailbox+16)!=interrupted,"disabled partial refill completed");}
  sim.word(Mailbox+24)=0;sim.reset();sim.word(Textures)=0x1f152637;
  sim.run(commands,++sequence);std::vector<uint32_t> texture(64,0x1f152637);compare(sim,s,texture);++cuts;
 }
 std::cout<<"PACKED_CACHE_PASS boundary_frames="<<good<<" rejected_extents="<<bad
          <<" partial_refill_cuts="<<cuts<<" pixels="<<checked<<"\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
