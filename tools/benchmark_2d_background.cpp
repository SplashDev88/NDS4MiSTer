// Fixed GPU-state 2D benchmark. Fixtures are local test data, never bundled.
#include "Args.h"
#include "NDS.h"
#include "Savestate.h"
#include <fstream>
#include <iostream>
#include <memory>
#include <vector>
#include <array>
#include <cstring>
#include <ctime>
using namespace melonDS;
static double now(){timespec t;clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t);return t.tv_sec+t.tv_nsec*1e-9;}
static u64 hash(const u32* p,size_t n){u64 h=1469598103934665603ULL;for(size_t i=0;i<n;i++){h^=p[i];h*=1099511628211ULL;}return h;}
int main(int argc,char**argv)try{
 if(argc!=7)return 2;setenv("NDS_GPU_AFFINE_TILE_CACHE",argv[6],1);setenv("NDS_GPU_SPRITE_SETUP_CACHE",argv[3],1);setenv("NDS_GPU_SPRITE_BATCH",argv[4],1);
 bool direct=std::stoi(argv[5]);std::ifstream f(argv[1],std::ios::binary|std::ios::ate);if(!f)return 3;auto len=f.tellg();f.seekg(0);std::vector<u8>data(len);f.read((char*)data.data(),len);
 NDSArgs args;args.JIT=std::nullopt;auto nds=std::make_unique<NDS>(std::move(args));nds->Reset();RendererSettings rs{};rs.Threaded=false;rs.ScaleFactor=1;rs.FullFrame3D=true;rs.PackedOutput=true;nds->GetRenderer().SetRenderSettings(rs);
 Savestate in(data.data(),data.size(),false);nds->GPU.DoSavestate(&in);if(in.Error)return 4;auto&g=nds->GPU;auto&r=nds->GetRenderer();g.SetSpriteOAMWriteTracking(true);g.GPU2D_A.Enabled=g.GPU2D_B.Enabled=true;nds->PowerControl9=0x020f|(g.ScreenSwap?0x8000:0);g.CaptureEnable=false;g.CaptureCnt=0;g.GPU3D.SetEnabled(true,true);g.GPU3D.RenderFrameIdentical=false;r.Start3DRendering();r.Finish3DRendering();
 for(auto* e : {&g.GPU2D_A,&g.GPU2D_B}) {std::cerr<<"engine="<<e->Num<<" dispcnt="<<std::hex<<e->DispCnt<<std::dec;for(unsigned b=0;b<4;b++)std::cerr<<" bg"<<b<<"="<<std::hex<<e->BGCnt[b]<<std::dec;for(unsigned b=0;b<2;b++)std::cerr<<" aff"<<b<<"="<<e->BGRotA[b]<<","<<e->BGRotC[b];std::cerr<<'\n';}
 const int n=std::stoi(argv[2]);if(n<1||n>10000)return 5;auto output=std::make_unique<std::array<std::array<u32,256*192>,2>>();
 auto render=[&]{
#if defined(NDS_BENCH_DIRECT)
  if(direct&&!r.SetExternalFramebuffers((*output)[0].data(),(*output)[1].data()))throw std::runtime_error("targets rejected");
#else
  if(direct)throw std::runtime_error("direct unavailable in baseline");
#endif
  for(unsigned y=0;y<263;y++){
   unsigned vb=y>=192&&y<262;
   if(!g.ApplyExternalRendererPhase(y==0?2:0,y,y,vb,vb,0,true,false,true)||
      !g.ApplyExternalRendererPhase(1,y,y,vb|2,vb|2,0,true,false,true))throw std::runtime_error("phase rejected");
   if(y<192&&!direct){u32 *a,*b;if(!r.GetRenderedScanlines(y,&a,&b))throw std::runtime_error("no row");std::memcpy((*output)[0].data()+y*256,a,1024);std::memcpy((*output)[1].data()+y*256,b,1024);}
  }
#if defined(NDS_BENCH_DIRECT)
  r.SetExternalFramebuffers(nullptr,nullptr);
#endif
 };render();render();
 bool varied=false;for(auto&plane:*output)for(auto v:plane)if(v!=plane[0])varied=true;
 if(!varied)throw std::runtime_error("flat fixture cannot qualify performance");
 auto h0=hash((*output)[0].data(),256*192),h1=hash((*output)[1].data(),256*192);double start=now();for(int i=0;i<n;i++)render();double elapsed=now()-start;
 if(h0!=hash((*output)[0].data(),256*192)||h1!=hash((*output)[1].data(),256*192))return 6;
 std::cout<<"{\"frames\":"<<n<<",\"cache\":"<<argv[3]<<",\"batch\":"<<argv[4]<<",\"direct\":"<<direct<<",\"cpu_seconds\":"<<elapsed<<",\"hashes\":["<<h0<<','<<h1<<"]}\n";
}catch(std::exception&e){std::cerr<<e.what()<<'\n';return 10;}
