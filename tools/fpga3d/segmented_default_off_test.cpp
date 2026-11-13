// SPDX-License-Identifier: GPL-3.0-only
#define main original_simulation_main
#include "sim.cpp"
#undef main
#include "transport.h"
int main(int argc,char** argv)try{
 require(original_simulation_main(argc,argv)==0,"default-off legacy regression");
 Sim sim;sim.reset();sim.word(0x3fc00000)=0x31443348;sim.word(0x3fc00008)=17;
 bind(&sim.word(0x3fc00000),&sim.word(Output),true,true);segmentedCommandsEnabled=true;
 require(available() && !segmentedAvailable(),"legacy READY negotiated unsupported protocol");
 Frame frame;frame.reset();require(frame.commandCapacity==MaxCommands,"legacy initial capacity widened");
 const uint32_t done=sim.word(Mailbox+16);sim.rejectFrameReads=true;
 sim.word(Mailbox)=SegmentedMagic;sim.word(Mailbox+4)=1;sim.word(Mailbox+8)=0x80000000u|8129;sim.word(Mailbox+12)=17;sim.word(Mailbox+60)=Textures;
 for(unsigned i=0;i<5000;++i)sim.tick();require(sim.word(Mailbox+16)==done,"disabled experimental protocol consumed");
 sim.word(Mailbox+24)=SegmentedMagic;writeCombined=false;
 require(!segmentedAvailable(),"segmented protocol admitted without WC mapping");
 writeCombined=true;segmentedCommandsEnabled=false;
 require(!segmentedAvailable(),"segmented protocol admitted without experiment opt-in");
 std::cout<<"SEGMENT_DEFAULT_OFF_PASS\n";return 0;
}catch(const std::exception& error){std::cerr<<"FAIL "<<error.what()<<'\n';return 1;}
