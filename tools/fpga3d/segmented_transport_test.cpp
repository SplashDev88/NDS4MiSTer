// SPDX-License-Identifier: GPL-3.0-only
#define main original_simulation_main
#include "sim.cpp"
#undef main
static Sim* activeSim=nullptr;
static void progress(){if(activeSim){activeSim->guardedCount=activeSim->word(Mailbox+8)&0x7fffffff;activeSim->tick();}}
#define FPGA3D_TEST_PROGRESS progress
#include "transport.h"
static constexpr uint32_t Canary=0x6b725118;
static uint64_t pixelsChecked=0;
static unsigned completed=0,rejected=0;
static void setup(Sim& sim,bool segmented,bool hashed=false){
 std::fill(sim.mem.begin(),sim.mem.end(),Canary);sim.reset();activeSim=&sim;
 sim.word(0x3fc00000)=0x31443348;sim.word(0x3fc00008)=17;
 poisonedSession=0;bind(&sim.word(0x3fc00000),&sim.word(Output),true,true);
 segmentedCommandsEnabled=segmented;textureResidencyEnabled=false;fastCommandsEnabled=false;
 hashedTexturesEnabled=hashed;
}
static uint32_t addressOracle(uint32_t tail,size_t index){
 if(index>=8128)return tail+uint32_t(index-8128)*64;
 const size_t logical=4096+index*64;
 return 0x3fe30000u+uint32_t(logical/65536)*0x40000u+uint32_t(logical%65536);
}
static void checkOwnership(Sim& sim,const Frame& frame,const std::vector<Command>& commands){
 for(uint32_t a=0x3fe00000;a<0x40000000;a+=4){
  const uint32_t plane=(a-0x3fe00000)/0x40000,offset=(a-0x3fe00000)%0x40000;
  bool command=false;
  if(frame.segmented && offset>=0x30000){
   const uint32_t logical=plane*65536+offset-0x30000;
   command=logical>=4096 && (logical-4096)/64<std::min<size_t>(8128,commands.size());
  }
  if(!command)require(sim.word(a)==Canary,"visible plane, telemetry or unused padding changed");
 }
 if(frame.segmented){
  for(size_t i=0;i<commands.size();++i){auto packed=pack(commands[i]);
   require(!std::memcmp(&sim.word(addressOracle(frame.commandBase,i)),packed.data(),64),"segmented command bytes/order mismatch");}
  const uint32_t end=frame.commandBase+uint32_t(commands.size()>8128?commands.size()-8128:0)*64;
  for(uint32_t a=end;a<0x3fe00000;a+=4)require(sim.word(a)==Canary,"unowned texture tail changed");
 }
 for(size_t i=0;i<frame.textures.size();++i)require(sim.word(Textures+4*i)==frame.textures[i],"immutable texture changed");
}
struct Cost{uint64_t cycles,reads,beats,textureReads,textureBeats;};
static Cost execute(const std::vector<Command>& commands,const std::vector<uint32_t>& textures,
                    const std::vector<uint32_t>& expected,bool segmented,bool streamed,unsigned latency=0,bool hashed=false){
 Sim sim;sim.readLatency=latency;setup(sim,segmented,hashed);
 Frame f;f.deadlineMs=30000;f.reset();f.textures=textures;
 std::vector<uint32_t> destination(258*192+16,Canary);
 const uint64_t start=sim.cycles;
 if(streamed)f.startStream();else {f.commands=commands;require(f.start(),"batch admission");}
 require(f.active && f.segmented==segmented,"requested protocol unavailable");
 require(f.hashed==(hashed && !segmented),"requested hash mode unavailable");
 require(sim.word(Mailbox)==(segmented?SegmentedMagic:hashed?HashedMagic:Magic),"request magic mismatch");
 sim.guardedBase=f.commandBase;sim.guardedSegmented=f.segmented;sim.guardedCount=0;
 if(streamed){
  for(unsigned i=0;i<2000;++i)progress();
  require(sim.word(Mailbox+16)!=f.sequence,"empty open producer completed");
  for(size_t i=0;i<commands.size();++i){
   f.append(commands[i]);
   if(i%37==0 || (i>=8118 && i<=8140) || commands[i][0]==3){
    f.publish();for(unsigned k=0;k<29;++k)progress();
    require(sim.word(Mailbox+16)!=f.sequence,"open segmented producer completed");
   }
  }
 }
 require(f.submit(destination.data()+8,258),"segmented/legacy submit");
 for(size_t i=0;i<destination.size();++i){
  const bool visible=i>=8 && i<destination.size()-8 && (i-8)%258<256;
  const auto value=visible?expected[((i-8)/258)*256+(i-8)%258]:Canary;
  require(destination[i]==value,"pixel or destination stride guard mismatch");if(visible)++pixelsChecked;
 }
 checkOwnership(sim,f,commands);++completed;
 return {sim.cycles-start,sim.descriptorReads,sim.descriptorBeats,sim.textureReads,sim.textureBeats};
}
static std::vector<Command> synthetic(size_t count){
 require(count>=384,"synthetic command minimum");std::vector<Command> commands;
 Span p;p.first=0;p.end=1;p.width=1;p.alphaRef=31;
 const size_t extra=count-384;
 for(unsigned y=0;y<192;++y){commands.push_back(clear(y,0x1f000000+y,0xffffff));
  for(size_t n=0;n<extra/192+(y<extra%192);++n)commands.push_back(span(p));
  commands.push_back(flush(y));}
 require(commands.size()==count,"synthetic command count");return commands;
}
static std::vector<uint32_t> syntheticExpected(){std::vector<uint32_t> p;for(unsigned y=0;y<192;++y)p.insert(p.end(),256,0x1f000000+y);return p;}
static void finish(Sim& sim,uint32_t seq,unsigned status){
 const auto start=sim.cycles;
 while(sim.word(Mailbox+16)!=seq && sim.cycles-start<60000000)sim.tick();
 require(sim.word(Mailbox+16)==seq && sim.word(Mailbox+20)==status,"manual completion/status");
}
static void initialReject(uint32_t count,uint32_t tail,uint32_t epoch=17,uint32_t magic=SegmentedMagic){
 Sim sim;setup(sim,true);sim.rejectFrameReads=true;
 sim.word(Mailbox)=magic;sim.word(Mailbox+4)=1;sim.word(Mailbox+8)=0x80000000u|count;sim.word(Mailbox+12)=epoch;sim.word(Mailbox+60)=tail;
 finish(sim,1,epoch==17?1:2);require(sim.word(Output)==Canary,"rejected request published pixels");++rejected;
}
static void negativeAndAbort(){
 for(uint32_t count:{16384u,32768u,0x40004000u,0x7fffffffu})initialReject(count,Textures);
 for(uint32_t tail:{Commands,PaddedCommands,Textures-64,Textures+8,0x3fe00040u,0xbfd40000u})initialReject(384,tail);
 initialReject(8129,0x3fe00000);initialReject(8193,0x3fdff000);initialReject(384,Textures,18);
 initialReject(8129,Commands,17,Magic); // Legacy count remains bounded.
 for(uint32_t count:{16384u,0x40004000u}){
  Sim sim;setup(sim,true);sim.word(Mailbox)=SegmentedMagic;sim.word(Mailbox+4)=1;sim.word(Mailbox+8)=0;sim.word(Mailbox+12)=17;sim.word(Mailbox+60)=Textures;
  for(unsigned i=0;i<4000;++i)sim.tick();sim.word(Mailbox+8)=0x80000000u|count;finish(sim,1,1);++rejected;
 }
 // A declared texture extent must stop before the command tail.
 {Sim sim;setup(sim,true);sim.guardedBase=Textures+64;sim.guardedSegmented=true;sim.guardedCount=3;
  Span p;p.flags=Linear|Textured;p.texture=Textures+64;
  const std::vector<Command> commands{clear(0,0,0xffffff),span(p),flush(0)};
  for(size_t i=0;i<commands.size();++i){auto c=pack(commands[i]);std::memcpy(&sim.word(addressOracle(Textures+64,i)),c.data(),64);}
  sim.word(Mailbox)=SegmentedMagic;sim.word(Mailbox+4)=1;sim.word(Mailbox+8)=0x80000003;sim.word(Mailbox+12)=17;sim.word(Mailbox+60)=Textures+64;finish(sim,1,1);++rejected;
 }
 const auto commands=synthetic(8192);const auto expected=syntheticExpected();
 for(bool reset:{false,true})for(bool tailCut:{false,true})for(unsigned latency:{0u,64u}){
  Sim sim;sim.readLatency=latency;setup(sim,true);const uint32_t tail=0x3fdff000;
  sim.guardedBase=tail;sim.guardedSegmented=true;sim.guardedCount=commands.size();
  for(size_t i=0;i<commands.size();++i){auto c=pack(commands[i]);std::memcpy(&sim.word(addressOracle(tail,i)),c.data(),64);}
  sim.word(Mailbox)=SegmentedMagic;sim.word(Mailbox+4)=1;sim.word(Mailbox+8)=0x80000000u|commands.size();sim.word(Mailbox+12)=17;sim.word(Mailbox+60)=tail;
  unsigned budget=8000000;
  auto reached=[&](){return sim.remaining>0 && sim.remaining<127 && (tailCut?(sim.readat>=tail && sim.readat<0x3fe00000):(sim.readat>=PaddedCommands));};
  while(!reached() && budget--)sim.tick();require(reached(),"abort did not reach requested segment DMA");
  if(reset){sim.word(Mailbox+24)=0;sim.reset();}
  else {sim.v.enable=0;unsigned drain=0;while(sim.remaining && drain++<10000)sim.tick();require(!sim.remaining,"disabled segment read not drained");
   for(unsigned i=0;i<1000;++i)sim.tick();require(sim.word(Mailbox+16)!=1,"abandoned segmented frame completed");sim.v.enable=1;for(unsigned i=0;i<2000;++i)sim.tick();}
  sim.guardedBase=0;sim.guardedCount=0;sim.guardedSegmented=false;
  const auto small=synthetic(384);sim.run(small,2);
  for(size_t i=0;i<expected.size();++i){require(sim.word(Output+4*i)==expected[i],"legacy recovery after segmented abort");++pixelsChecked;}
  std::cout<<"SEGMENT_ABORT_PASS reset="<<reset<<" tail="<<tailCut<<" latency="<<latency<<'\n';
 }
 // Late helper overflow must close/drain a partial producer without copying.
 {Sim sim;setup(sim,true);Frame f;f.deadlineMs=30000;f.reset();f.textures.resize(TextureBytes/4,0);f.startStream();
  require(f.active && f.commandCapacity==8128,"zero-tail stream capacity");sim.guardedBase=f.commandBase;sim.guardedSegmented=true;
  for(const auto& c:synthetic(8129))f.append(c);
  require(!f.valid,"late overflow admitted");std::vector<uint32_t> destination(256*192,Canary);
  require(!f.submit(destination.data(),256) && !f.active,"late overflow did not drain");
  require(std::all_of(destination.begin(),destination.end(),[](auto v){return v==Canary;}),"late overflow copied partial output");++rejected;
 }
}
static int segmentedSimulationMain(int argc,char** argv)try{
 if(argc==2 && std::string(argv[1])=="--legacy-selftest")return original_simulation_main(1,argv);
 require((argc-1)%3==0,"arguments: commands textures expected groups");
 const auto expected=syntheticExpected();
 // Exact fixed/variable capacities, first overflow, maximum count, and every
 // possible 64-byte page alignment of the tail across the segment boundary.
 for(unsigned offset=0;offset<64;++offset)execute(synthetic(8145),std::vector<uint32_t>(offset*16,0),expected,true,true);
 execute(synthetic(16383),{},expected,true,false);
 execute(synthetic(8128),std::vector<uint32_t>(TextureBytes/4,0),expected,true,false);
 negativeAndAbort();
 unsigned fixtures=0,unfitted=0;
 for(int i=1;i<argc;i+=3){
  const auto commands=load<Command>(argv[i]);const auto textures=load<uint32_t>(argv[i+1]);const auto pixels=load<uint32_t>(argv[i+2]);
  const uint32_t tail=(Textures+uint32_t(textures.size()*4)+63)&~63u;
  if(commands.size()>segmentedCapacity(tail)){++unfitted;initialReject(commands.size(),tail);std::cout<<"SEGMENT_CAPACITY_REJECT row="<<fixtures++<<'\n';continue;}
  const auto candidate=execute(commands,textures,pixels,true,false);
  std::cout<<"SEGMENT_COST row="<<fixtures<<" commands="<<commands.size()<<" tail="<<tail<<" capacity="<<segmentedCapacity(tail)<<" segmented_cycles="<<candidate.cycles<<" segmented_reads="<<candidate.reads<<" segmented_beats="<<candidate.beats;
  if(commands.size()<=MaxCommands){const auto legacy=execute(commands,textures,pixels,false,false);std::cout<<" legacy_cycles="<<legacy.cycles<<" legacy_reads="<<legacy.reads<<" legacy_beats="<<legacy.beats;}
  std::cout<<'\n';execute(commands,textures,pixels,true,true);++fixtures;
 }
 std::cout<<"SEGMENT_TRANSPORT_PASS fixtures="<<fixtures<<" unfitted="<<unfitted<<" completed="<<completed<<" rejected="<<rejected<<" exact_pixels="<<pixelsChecked<<'\n';
 return 0;
}catch(const std::exception& error){std::cerr<<"FAIL "<<error.what()<<'\n';return 1;}
#ifndef FPGA3D_SEGMENTED_TEST_NO_MAIN
int main(int argc,char** argv){return segmentedSimulationMain(argc,argv);}
#endif
