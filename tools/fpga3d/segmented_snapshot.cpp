// SPDX-License-Identifier: GPL-3.0-only
// Production saved-GPU command producer and CPU transport through actual RTL.
// Native analysis only; memory is ordinary vectors, with no hardware access.
#define SEGMENTED_TRANSPORT_EXPERIMENT 1
#define main original_simulation_main
#include "sim.cpp"
#undef main
#include "Args.h"
#include "NDS.h"
#include "Savestate.h"
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include <memory>
using namespace melonDS;
static Sim* activeSimulation=nullptr;
static fpga3d::Frame* activeFrame=nullptr;
static void advance(){
 require(activeSimulation && activeFrame,"missing simulated transport owner");
 auto& sim=*activeSimulation;
 sim.guardedBase=activeFrame->commandBase;sim.guardedSegmented=activeFrame->segmented;
 sim.guardedCount=sim.word(Mailbox+8)&0x7fffffff;
 sim.tick();
}
int main(int argc,char** argv)try{
 require(argc==4,"snapshot integral sprite arguments required");
 unsetenv("NDS4MISTER_DUAL_CORE_3D");unsetenv("NDS4MISTER_ADAPTIVE_RASTER_SPLIT");unsetenv("NDS4MISTER_RASTER_BAND_QUEUE");
 setenv("NDS4MISTER_TEXTURE_HISTORY","1",1);setenv("NDS4MISTER_DISABLE_3D_AA","1",1);
 std::ifstream input(argv[1],std::ios::binary|std::ios::ate);require(bool(input),"snapshot missing");
 const auto len=input.tellg();require(len>0 && len<64*1024*1024,"snapshot bounds");input.seekg(0);
 std::vector<u8> data(static_cast<size_t>(len));input.read(reinterpret_cast<char*>(data.data()),len);require(bool(input),"snapshot read");
 auto loadSnapshot=[&]{
  NDSArgs args;args.JIT=std::nullopt;auto n=std::make_unique<NDS>(std::move(args));n->Reset();
  RendererSettings settings{};settings.Threaded=false;settings.ScaleFactor=1;settings.FullFrame3D=true;settings.PackedOutput=true;n->GetRenderer().SetRenderSettings(settings);
  Savestate in(data.data(),data.size(),false);n->GPU.DoSavestate(&in);require(!in.Error,"snapshot decode");n->GetRenderer().Finish3DRendering();auto& g=n->GPU.GPU3D;
  g.SetEnabled(true,true);g.SetExternalCommandReplay(true);g.SetIntegralTextureSpansEnabled(std::stoi(argv[2]));g.SetSpriteRasterSpansEnabled(std::stoi(argv[3]));g.RenderFrameIdentical=false;return n;
 };
 auto render=[](NDS& n){n.GetRenderer().Start3DRendering();n.GetRenderer().Finish3DRendering();};
 fpga3d::bind(nullptr,nullptr,false);auto reference=loadSnapshot();render(*reference);std::vector<u32> expected;
 for(unsigned y=0;y<192;++y){auto p=reference->GetRenderer().Get3DScanline(y);expected.insert(expected.end(),p,p+256);}
 unsigned acceptedFrames=0,fallbackFrames=0;
 for(unsigned format=0;format<2;++format){
  auto candidate=loadSnapshot();auto& soft=*static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(candidate->GetRenderer()).Rend3D.get());
  Sim sim;sim.reset();sim.word(0x3fc00000)=0x31443348;sim.word(0x3fc00008)=17;
  fpga3d::poisonedSession=0;fpga3d::segmentedCommandsEnabled=true;fpga3d::packedTexturesEnabled=format;
  fpga3d::adaptiveAdmission=true;fpga3d::textureTrafficGuard=false;
  soft.FullFrameCompletion=true;soft.FpgaFrame.deadlineMs=30000;
  activeSimulation=&sim;activeFrame=&soft.FpgaFrame;fpga3d::segmentedTestProgress=advance;
  const auto completedBefore=fpga3d::completedFrames;
  fpga3d::bind(&sim.word(0x3fc00000),&sim.word(Output),true,true);render(*candidate);fpga3d::bind(nullptr,nullptr,false);
  const bool accepted=fpga3d::completedFrames>completedBefore;
  if(accepted)++acceptedFrames;else ++fallbackFrames;
  for(unsigned y=0;y<192;++y)require(!std::memcmp(expected.data()+256*y,candidate->GetRenderer().Get3DScanline(y),1024),"production producer/RTL pixels differ from native");
  const auto& f=soft.FpgaFrame;require(!f.active,"snapshot producer remained active");
  std::cout<<"SEGMENT_SNAPSHOT format="<<format<<" accepted="<<accepted<<" valid="<<f.valid<<" commands="<<f.commandCount()<<" textures="<<f.textures.size()*4<<" capacity="<<f.commandCapacity<<" transport_error="<<f.transportError<<" failure="<<fpga3d::outcomeNames[unsigned(f.failure)]<<" cycles="<<sim.cycles<<'\n';
  fpga3d::segmentedTestProgress=nullptr;activeSimulation=nullptr;activeFrame=nullptr;
 }
 std::cout<<"SEGMENT_SNAPSHOT_PASS accepted="<<acceptedFrames<<" fallback="<<fallbackFrames<<" exact_pixels=98304\n";return 0;
}catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}
