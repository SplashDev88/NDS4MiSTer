
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
 Frame f;f.deadlineMs=5000;std::vector<uint32_t> dst(258*192+16,0xa1b2c3d4);
 std::array<uint32_t,64> tex;tex.fill(0x1f123456);
 for(unsigned iteration=0;iteration<3;iteration++){
  f.reset();require(f.addTexture(tex.data(),tex.size()),"texture admission");f.startStream();
  require(f.active && f.commandBase==Textures+256,"WC arena command placement");sim.guardedBase=f.commandBase;sim.guardedCount=0;
  for(unsigned y=0;y<192;y++){
   for(int i=0;i<2000;i++)progress();
   require(sim.word(Mailbox+16)!=f.sequence,"transport prematurely completed");
   f.append(clear(y,0x1f000000+y,0xffffff));f.append(flush(y));f.publish();
  }
  require(f.submit(dst.data()+8,258),"streamed transport submission");
  require(!f.active && !f.transportError,"transport ownership remained active");
  for(unsigned i=0;i<dst.size();i++){
   uint32_t expected=i>=8 && i<dst.size()-8 && (i-8)%258<256?0x1f000000+(i-8)/258:0xa1b2c3d4;
   require(dst[i]==expected,"transport output or row guard mismatch");
  }
  for(unsigned i=0;i<tex.size();i++)require(sim.word(Textures+i*4)==tex[i],"immutable texture overwritten by commands");
 }

 // Real emitted packets through the CPU transport and actual RTL together.
 std::vector<std::string> fixtures;
 for(unsigned n:{0u,100u,200u,235u,236u,237u})fixtures.push_back("build-fpga3d/fixtures/"+std::to_string(n));
 if(argc==2)fixtures.push_back(argv[1]); // Optional private capture stays outside the repository.
 for(const auto& fixture:fixtures){
  f.reset();auto cmds=load<Command>(fixture+".commands");f.textures=load<uint32_t>(fixture+".textures");auto expected=load<uint32_t>(fixture+".expected");
  f.startStream();require(f.active,"real fixture stream admission");sim.guardedBase=f.commandBase;sim.guardedCount=0;
  for(const auto& cmd:cmds){f.append(cmd);if(cmd[0]==3){f.publish();for(int i=0;i<1000;i++)progress();}}
  require(f.submit(dst.data()+8,258),"real fixture CPU/RTL stream failed");
  for(unsigned y=0;y<192;y++)for(unsigned x=0;x<256;x++)require(dst[8+y*258+x]==expected[y*256+x],"real fixture CPU/RTL pixels");
 }
 // A full texture arena keeps all 8128 Device descriptors available. The
 // last texture line must not alias command storage or leave its arena.
 f.reset();std::vector<uint32_t> largeTexture(TextureBytes/4,0x1f12342a);
 require(f.addTexture(largeTexture.data(),largeTexture.size()),"full texture admission");
 f.startStream();require(f.active && f.commandBase==Commands && f.commandCapacity==MaxCommands,"texture-heavy Device stream admission");
 sim.guardedBase=Commands;sim.guardedCount=0;
 for(unsigned y=0;y<192;y++){
  f.append(clear(y,0x1f000001,0xffffff));
  if(y==0){Span s;s.first=0;s.end=1;s.width=1;s.flags=Linear|Textured;s.texture=Textures+TextureBytes-256;s.left={504,504,504,0,0};s.right=s.left;f.append(span(s));}
  f.append(flush(y));f.publish();for(int i=0;i<1000;i++)progress();
 }
 require(f.submit(dst.data()+8,258),"texture-heavy Device stream failed");
 for(unsigned y=0;y<192;y++)for(unsigned x=0;x<256;x++)require(dst[8+y*258+x]==(y==0&&x==0?0x1f12342au:0x1f000001u),"texture-heavy Device stream output");
 for(unsigned i=0;i<largeTexture.size();i++)require(sim.word(Textures+i*4)==largeTexture[i],"Device stream overwrote texture arena");
 std::fill(dst.begin(),dst.end(),0xa1b2c3d4);
 uint64_t failures=failedFrames;
 f.reset();f.startStream();sim.guardedBase=f.commandBase;sim.guardedCount=0;
 f.append(clear(0,0x1f010203,0xffffff));f.publish();f.valid=false;
 require(!f.submit(dst.data()+8,258) && !f.active && failedFrames==failures,"intentional admission cancel did not drain cleanly");
 for(auto w:dst)require(w==0xa1b2c3d4,"partial canceled frame copied");
 f.reset();f.startStream();sim.guardedBase=f.commandBase;sim.guardedCount=0;
 f.append(clear(0,0,0xffffff));Span p;p.first=0;p.end=1;p.width=1;p.alphaRef=31;
 for(unsigned i=0;i<MaxCommands;i++)f.append(span(p));
 require(!f.valid && f.commands.size()==MaxCommands,"stream capacity not bounded");
 require(!f.submit(dst.data()+8,258) && !f.active && failedFrames==failures,"capacity cancel did not drain cleanly");
 for(auto w:dst)require(w==0xa1b2c3d4,"capacity cancel copied partial frame");
 f.reset();f.deadlineMs=1;f.startStream();f.append(clear(0,0,0xffffff));
 tickEnabled=false;require(!f.submit(dst.data()+8,258),"timeout accepted");tickEnabled=true;
 require(poisonedSession==17 && !available() && failedFrames==failures+1,"timeout did not quarantine ownership");
 auto before=sim.mem;f.reset();f.append(clear(0,0,0xffffff));require(!f.submit(dst.data()+8,258),"poisoned producer reused arena");
 require(before==sim.mem,"poisoned producer changed owned bytes");
 puts("PASS actual RTL with WC CPU producer: concurrent prefixes, immutable textures, row guards, intentional cancel, capacity drain and timeout quarantine");
 return 0;
}catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<std::endl;return 1;}
