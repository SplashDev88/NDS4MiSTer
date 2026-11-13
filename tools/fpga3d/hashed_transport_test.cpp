// SPDX-License-Identifier: GPL-3.0-only
#define FPGA3D_SEGMENTED_TEST_NO_MAIN
#include "segmented_transport_test.cpp"

static void sameSession(Sim& sim,const std::vector<Command>& commands,
                        const std::vector<uint32_t>& textures,
                        const std::vector<uint32_t>& expected,bool segmented,bool hashed){
 segmentedCommandsEnabled=segmented;hashedTexturesEnabled=hashed;
 Frame f;f.deadlineMs=30000;f.reset();f.commands=commands;f.textures=textures;
 require(f.start(),"same-session start");
 require(f.segmented==segmented && f.hashed==(hashed && !segmented),"same-session selection");
 require(sim.word(Mailbox)==(segmented?SegmentedMagic:hashed?HashedMagic:Magic),"same-session request");
 sim.guardedBase=f.commandBase;sim.guardedSegmented=f.segmented;sim.guardedCount=commands.size();
 std::vector<uint32_t> output(256*192+16,Canary);
 require(f.submit(output.data()+8,256),"same-session completion");
 for(size_t i=0;i<output.size();++i){
  const bool visible=i>=8 && i<output.size()-8;
  require(output[i]==(visible?expected[i-8]:Canary),"same-session stale pixel/mode");
  if(visible)++pixelsChecked;
 }
 ++completed;
}

int main(int argc,char** argv)try{
#ifdef HASH_CAPABILITY_DISABLED
 Sim sim;setup(sim,false,true);sim.rejectFrameReads=true;
 sim.word(Mailbox)=HashedMagic;sim.word(Mailbox+4)=42;sim.word(Mailbox+8)=0x80000000u|384;
 sim.word(Mailbox+12)=17;sim.word(Mailbox+60)=Commands;
 const auto before=sim.word(Mailbox+16);
 for(unsigned i=0;i<10000;++i)sim.tick();
 require(sim.word(Mailbox+16)==before,"disabled hash protocol accepted");
 sim.rejectFrameReads=false;sim.run(synthetic(384),43);
 require(!hashingAvailable(),"helper negotiated disabled hash capability");
 sameSession(sim,synthetic(384),{},syntheticExpected(),false,false);
 std::cout<<"HASH_DISABLED_PASS exact_pixels="<<pixelsChecked<<'\n';return 0;
#else
 if(argc==2 && std::string(argv[1])=="--legacy-selftest")return original_simulation_main(1,argv);
 // All former segmented boundaries, capacity and reset cases must still pass
 // against a core advertising the expanded capability.
 require(segmentedSimulationMain(argc,argv)==0,"segmented regression suite");
 require((argc-1)%3==0,"fixture groups");
 for(uint32_t count:{8129u,16383u,16384u,0x40004000u})initialReject(count,Commands,17,HashedMagic);
 initialReject(384,Commands,18,HashedMagic);
 for(uint32_t base:{Textures+8,0x3fe00040u,0xbfd40000u})initialReject(384,base,17,HashedMagic);
 // New mode keeps the full ordinary maximum, including streamed publication.
 execute(synthetic(MaxCommands),{},syntheticExpected(),false,true,64,true);
 unsigned rows=0,skipped=0;
 for(int i=1;i<argc;i+=3,++rows){
  auto commands=load<Command>(argv[i]);auto textures=load<uint32_t>(argv[i+1]);auto expected=load<uint32_t>(argv[i+2]);
  if(commands.size()>MaxCommands){++skipped;continue;}
  const auto direct=execute(commands,textures,expected,false,false);
  const auto hashed=execute(commands,textures,expected,false,false,0,true);
  execute(commands,textures,expected,false,true,0,true);
  std::cout<<"HASH_COST row="<<rows<<" commands="<<commands.size()<<" direct_cycles="<<direct.cycles<<" hashed_cycles="<<hashed.cycles
           <<" direct_texture_reads="<<direct.textureReads<<" hashed_texture_reads="<<hashed.textureReads<<'\n';
  // One persistent session alternates all advertised modes. Both opt-ins
  // deliberately select ordinary segmented mode, so later jobs cannot leak
  // the previous hash selection through retained cache state.
  if(rows==9){
   Sim sim;setup(sim,false);
   for(unsigned mode:{1u,0u,1u,2u,1u,3u,0u})
    sameSession(sim,commands,textures,expected,mode>=2,mode==1 || mode==3);
   for(bool reset:{false,true}){
    Sim aborted;setup(aborted,false,true);Frame f;f.deadlineMs=30000;f.reset();f.commands=commands;f.textures=textures;
    require(f.start() && f.hashed,"abort hash start");f.publish();
    aborted.guardedBase=f.commandBase;aborted.guardedSegmented=false;aborted.guardedCount=commands.size();
    unsigned budget=8000000;
    while(!(aborted.remaining && aborted.readat>=Textures && aborted.readat<f.commandBase) && budget--)aborted.tick();
    require(budget,"hash abort texture DMA not reached");
    if(reset){aborted.word(Mailbox+24)=0;aborted.reset();}
    else{
     aborted.v.enable=0;unsigned drain=0;while(aborted.remaining && drain++<10000)aborted.tick();require(!aborted.remaining,"hash disable failed to drain read");
     for(unsigned j=0;j<1000;++j)aborted.tick();require(aborted.word(Mailbox+16)!=f.sequence,"abandoned hash request completed");
     aborted.v.enable=1;for(unsigned j=0;j<2000;++j)aborted.tick();
    }
    f.active=false;aborted.guardedBase=0;aborted.guardedCount=0;
    sameSession(aborted,commands,textures,expected,false,false);
    sameSession(aborted,commands,textures,expected,false,true);
   }
  }
 }
 std::cout<<"HASH_TRANSPORT_PASS fixtures="<<rows<<" legacy_oversize_skipped="<<skipped<<" completed="<<completed<<" rejected="<<rejected<<" exact_pixels="<<pixelsChecked<<'\n';return 0;
#endif
}catch(const std::exception& error){std::cerr<<"FAIL "<<error.what()<<'\n';return 1;}
