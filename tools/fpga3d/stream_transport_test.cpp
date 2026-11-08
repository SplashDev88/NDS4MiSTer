
#define main original_simulation_main
#include "sim.cpp"
#undef main
static Sim* activeSim=nullptr;
static bool tickEnabled=true;
static void progress(){
 if(activeSim && tickEnabled){
  activeSim->guardedCount=activeSim->word(Mailbox+8)&0x7fffffff;
  activeSim->tick();
 }
}
#define FPGA3D_TEST_PROGRESS progress
#include "transport.h"
int main(int argc,char** argv)try{
 Sim sim;sim.reset();activeSim=&sim;
 sim.word(0x3fc00000)=0x31443348;sim.word(0x3fc00008)=17;
 bind(&sim.word(0x3fc00000),&sim.word(Output),true,true);
 require(available(),"actual RTL unavailable to transport");
 std::array<uint8_t,512> stencil;for(unsigned i=0;i<512;i++)stencil[i]=(i*7>>3)&3;
 Frame f;f.deadlineMs=5000;std::vector<uint32_t> dst(258*192+16,0xa1b2c3d4);
 std::array<uint32_t,64> tex;tex.fill(0x1f123456);
 for(unsigned iteration=0;iteration<3;iteration++){
  f.reset();f.stencil=stencil.data();require(f.addTexture(tex.data(),tex.size()),"texture admission");f.startStream();
  require(f.active && f.commandBase==Textures+256,"WC arena command placement");sim.guardedBase=f.commandBase;sim.guardedCount=0;
  for(unsigned y=0;y<192;y++){
   for(int i=0;i<2000;i++)progress();
   require(sim.word(Mailbox+16)!=f.sequence,"transport prematurely completed");
   f.append(clear(y,0x1f000000+y,0xffffff));f.append(flush(y));f.publish();
   require(f.commands.empty() && f.packedCommands.empty() && f.commandCount()==2*(y+1),"CPU row buffer retained history or lost cumulative count");
  }
  require(f.submit(dst.data()+8,258),"streamed transport submission");
  require(!f.active && !f.transportError,"transport ownership remained active");
  for(unsigned i=0;i<dst.size();i++){
   uint32_t expected=i>=8 && i<dst.size()-8 && (i-8)%258<256?0x1f000000+(i-8)/258:0xa1b2c3d4;
   require(dst[i]==expected,"transport output or row guard mismatch");
  }
  for(unsigned i=0;i<tex.size();i++)require(sim.word(Textures+i*4)==tex[i],"immutable texture overwritten by commands");
 }

 // A complete batch at an unaligned WC page offset must split prefetch at
 // page boundaries, independently of where scanline publication happens.
 f.reset();f.stencil=stencil.data();require(f.addTexture(tex.data(),tex.size()),"page-boundary texture admission");
 f.startStream();sim.guardedBase=f.commandBase;sim.guardedCount=0;
 for(unsigned y=0;y<192;y++){f.append(clear(y,0x1f010203,0xffffff));f.append(flush(y));}
 require(f.submit(dst.data()+8,258),"unaligned WC batch failed");
 for(unsigned y=0;y<192;y++)for(unsigned x=0;x<256;x++)require(dst[8+y*258+x]==0x1f010203,"unaligned WC batch output");
 // Real emitted packets through the CPU transport and actual RTL together.
 std::vector<std::string> fixtures;
 for(unsigned n:{0u,100u,200u,235u,236u,237u})fixtures.push_back("build-fpga3d/fixtures/"+std::to_string(n));
 for(int arg=1;arg<argc;arg++)fixtures.push_back(argv[arg]); // Optional private capture stays outside the repository.
 for(const auto& fixture:fixtures){
  f.reset();f.stencil=stencil.data();auto cmds=load<Command>(fixture+".commands");f.textures=load<uint32_t>(fixture+".textures");auto expected=load<uint32_t>(fixture+".expected");
  auto expectedStencil=stencil;
  if(std::ifstream(fixture+".stencil_input").good()){
   auto seed=load<uint8_t>(fixture+".stencil_input"),result=load<uint8_t>(fixture+".stencil_expected");
   require(seed.size()==512 && result.size()==512,"transport stencil fixture bounds");
   std::copy(seed.begin(),seed.end(),stencil.begin());std::copy(result.begin(),result.end(),expectedStencil.begin());
  }
  f.startStream();require(f.active,"real fixture stream admission");sim.guardedBase=f.commandBase;sim.guardedCount=0;
  for(const auto& cmd:cmds){f.append(cmd);if(cmd[0]==3){f.publish();for(int i=0;i<1000;i++)progress();}}
  require(f.submit(dst.data()+8,258),"real fixture CPU/RTL stream failed");
  require(stencil==expectedStencil,"real fixture CPU/RTL stencil handoff");
  for(unsigned y=0;y<192;y++)for(unsigned x=0;x<256;x++)require(dst[8+y*258+x]==expected[y*256+x],"real fixture CPU/RTL pixels");
 }
 // A full texture arena keeps all 8128 Device descriptors available. The
 // last texture line must not alias command storage or leave its arena.
 f.reset();f.stencil=stencil.data();std::vector<uint32_t> largeTexture(TextureBytes/4,0x1f12342a);
 // More than 256 colors deliberately prevents the new lossless palette
 // encoding, so this still tests the full Device command/texture boundary.
 for(unsigned i=0;i<largeTexture.size();i++)largeTexture[i]=0x1f000000|(i&63)|(((i>>6)&63)<<8)|(((i>>12)&63)<<16);
 require(f.addTexture(largeTexture.data(),largeTexture.size()),"full texture admission");
 f.startStream();require(f.active && f.commandBase==Commands && f.commandCapacity==MaxCommands,"texture-heavy Device stream admission");
 sim.guardedBase=Commands;sim.guardedCount=0;
 for(unsigned y=0;y<192;y++){
  f.append(clear(y,0x1f000001,0xffffff));
  if(y==0){Span s;s.first=0;s.end=1;s.width=1;s.flags=Linear|Textured;s.texture=Textures+TextureBytes-256;s.left={504,504,504,0,0};s.right=s.left;f.append(span(s));}
  f.append(flush(y));f.publish();for(int i=0;i<1000;i++)progress();
 }
 require(f.submit(dst.data()+8,258),"texture-heavy Device stream failed");
 for(unsigned y=0;y<192;y++)for(unsigned x=0;x<256;x++)require(dst[8+y*258+x]==(y==0&&x==0?largeTexture[largeTexture.size()-64]:0x1f000001u),"texture-heavy Device stream output");
 for(unsigned i=0;i<largeTexture.size();i++)require(sim.word(Textures+i*4)==largeTexture[i],"Device stream overwrote texture arena");
 std::fill(dst.begin(),dst.end(),0xa1b2c3d4);
 const auto preservedStencil=stencil;
 uint64_t failures=failedFrames;
 f.reset();f.stencil=stencil.data();f.startStream();sim.guardedBase=f.commandBase;sim.guardedCount=0;
 f.append(clear(0,0x1f010203,0xffffff));f.publish();f.valid=false;
 require(!f.submit(dst.data()+8,258) && !f.active && failedFrames==failures,"intentional admission cancel did not drain cleanly");
 for(auto w:dst)require(w==0xa1b2c3d4,"partial canceled frame copied");
 require(stencil==preservedStencil,"canceled frame copied stencil");
 f.reset();f.stencil=stencil.data();f.startStream();sim.guardedBase=f.commandBase;sim.guardedCount=0;
 f.append(clear(0,0,0xffffff));Span p;p.first=0;p.end=1;p.width=1;p.alphaRef=31;
 for(unsigned i=0;i<MaxCommands;i++)f.append(span(p));
 require(!f.valid && f.commandCount()==MaxCommands,"stream capacity not bounded");
 require(!f.submit(dst.data()+8,258) && !f.active && failedFrames==failures,"capacity cancel did not drain cleanly");
 for(auto w:dst)require(w==0xa1b2c3d4,"capacity cancel copied partial frame");
 require(stencil==preservedStencil,"capacity cancel copied stencil");
 // Recycling CPU rows must not recycle the physical command budget. Fill it
 // over many publications, then reject one more descriptor and drain safely.
 f.reset();f.stencil=stencil.data();f.startStream();sim.guardedBase=f.commandBase;sim.guardedCount=0;
 f.append(clear(0,0,0xffffff));
 for(unsigned i=1;i<MaxCommands;i++){
  f.append(span(p));
  if(i%64==63)f.publish();
 }
 f.publish();require(f.valid && f.commands.empty() && f.commandCount()==MaxCommands,"recycled stream capacity accounting");
 f.append(span(p));require(!f.valid && f.commandCount()==MaxCommands,"recycled stream exceeded physical arena");
 require(!f.submit(dst.data()+8,258) && !f.active && failedFrames==failures,"recycled capacity cancel did not drain cleanly");
 for(auto w:dst)require(w==0xa1b2c3d4,"recycled capacity cancel copied partial frame");
 require(stencil==preservedStencil,"recycled capacity cancel copied stencil");
 // The live batch policy must leave the mailbox and arenas untouched while
 // the CPU prepares commands, then preserve the same pixels and stencil.
 streaming=false;
 for(const auto& fixture:fixtures){
  f.reset();f.stencil=stencil.data();f.commands=load<Command>(fixture+".commands");
  f.textures=load<uint32_t>(fixture+".textures");auto expected=load<uint32_t>(fixture+".expected");
  auto expectedStencil=stencil;
  if(std::ifstream(fixture+".stencil_input").good()){
   auto seed=load<uint8_t>(fixture+".stencil_input"),result=load<uint8_t>(fixture+".stencil_expected");
   require(seed.size()==512 && result.size()==512,"batch stencil fixture bounds");
   std::copy(seed.begin(),seed.end(),stencil.begin());std::copy(result.begin(),result.end(),expectedStencil.begin());
  }
  auto untouched=sim.mem;f.startStream();f.publish();
  require(!f.active && untouched==sim.mem,"batch preparation touched shared memory");
  sim.guardedBase=f.textures.size()*4<=TextureBytes-MaxCommands*64?
      ((Textures+uint32_t(f.textures.size()*4)+63)&~63u):Commands;
  sim.guardedCount=0;
  require(f.submit(dst.data()+8,258),"batch CPU/RTL submission failed");
  require(stencil==expectedStencil,"batch stencil mismatch");
  for(unsigned y=0;y<192;y++)for(unsigned x=0;x<256;x++)
   require(dst[8+y*258+x]==expected[y*256+x],"batch pixel mismatch");
 }
 f.reset();f.valid=false;auto untouched=sim.mem;
 require(!f.submit(dst.data()+8,258) && untouched==sim.mem,"rejected batch touched shared memory");
 streaming=true;
 f.reset();f.stencil=stencil.data();f.deadlineMs=1;f.startStream();f.append(clear(0,0,0xffffff));
 tickEnabled=false;require(!f.submit(dst.data()+8,258),"timeout accepted");tickEnabled=true;
 require(poisonedSession==17 && !available() && failedFrames==failures+1,"timeout did not quarantine ownership");
 auto before=sim.mem;f.reset();f.stencil=stencil.data();f.append(clear(0,0,0xffffff));require(!f.submit(dst.data()+8,258),"poisoned producer reused arena");
 require(before==sim.mem,"poisoned producer changed owned bytes");
 require(stencil==preservedStencil,"timed out or poisoned frame copied stencil");
 puts("PASS actual RTL with WC CPU producer: concurrent prefixes, immutable textures, row guards, intentional cancel, capacity drain and timeout quarantine");
 return 0;
}catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<std::endl;return 1;}
