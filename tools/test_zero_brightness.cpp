// SPDX-License-Identifier: GPL-3.0-only
// Actual scanline-path differential; private access is confined to this test.
#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <mutex>
#include <sstream>
#include <thread>
#include <vector>
#include <chrono>
#include <ctime>
#define private public
#include "NDS.h"
#include "GPU_Soft.h"
#undef private
using namespace melonDS;
static u32 state=0x5130ac7u;
static u32 rnd(){state^=state<<13;state^=state>>17;state^=state<<5;return state;}
static u64 checks=0,cases=0,hits=0,hash=1469598103934665603ULL;
static void compare(const u32* a,const u32* b,const std::string& label){
 for(unsigned x=0;x<256;++x){if(a[x]!=b[x]){std::ostringstream s;s<<"mismatch "<<label<<" x="<<x<<" reference="<<std::hex<<a[x]<<" candidate="<<b[x];throw std::runtime_error(s.str());}hash=(hash^a[x])*1099511628211ULL;++checks;}++cases;
}
static void setupEnv(){
 unsetenv("NDS4MISTER_DUAL_CORE_3D");unsetenv("NDS4MISTER_ADAPTIVE_RASTER_SPLIT");unsetenv("NDS4MISTER_RASTER_BAND_QUEUE");
 setenv("NDS4MISTER_DISABLE_3D_AA","1",1);setenv("NDS4MISTER_TEXTURE_HISTORY","1",1);
}
static std::unique_ptr<NDS> makeNDS(){NDSArgs a;a.JIT=std::nullopt;auto n=std::make_unique<NDS>(std::move(a));n->Reset();return n;}
static void policyChecks(){
 struct Choice { const char* value; bool profile,expected; };
 const Choice choices[]={{nullptr,false,false},{nullptr,true,true},{"auto",false,false},{"auto",true,true},{"0",true,false},{"1",false,true},{"invalid",true,false}};
 for(unsigned engine=0;engine<2;++engine)for(const auto& c:choices){
  if(c.value)setenv("NDS4MISTER_ZERO_BRIGHTNESS",c.value,1);else unsetenv("NDS4MISTER_ZERO_BRIGHTNESS");
  auto n=makeNDS();auto& p=static_cast<SoftRenderer&>(n->GetRenderer());auto& a=engine?n->GPU.GPU2D_B:n->GPU.GPU2D_A;
  a.SetZeroBrightnessEnabled(c.profile);a.Enabled=true;a.ForcedBlank=0;a.DispCnt=0x10000;a.LayerEnable=0;a.OBJEnable=0;a.BlendCnt=0xbf;a.EVY=0;
  SoftRenderer2D renderer(a,p);renderer.Reset();renderer.NumSprites=0;alignas(16)std::array<u32,256> output{},three{};p.Output3D=three.data();renderer.DrawScanline_BGOBJ(0,output.data());
  if((renderer.ZeroBrightnessHits!=0)!=c.expected)throw std::runtime_error("zero brightness policy/override selection");
  if(!c.value||std::strcmp(c.value,"auto")==0){a.SetZeroBrightnessEnabled(!c.profile);const auto before=renderer.ZeroBrightnessHits;renderer.DrawScanline_BGOBJ(0,output.data());if((renderer.ZeroBrightnessHits!=before)==c.profile)throw std::runtime_error("zero brightness policy switch not observed");}
 }
 unsetenv("NDS4MISTER_ZERO_BRIGHTNESS");std::cout<<"ZERO_BRIGHTNESS_POLICY_PASS choices=14 dynamic_auto=1\n";
}
static void synthetic(){
 auto n=makeNDS();auto& g=n->GPU;auto& p=static_cast<SoftRenderer&>(n->GetRenderer());
 alignas(16) std::array<u32,256> three{},out0{},out1{};p.Output3D=three.data();
 for(auto& v:g.Palette)v=rnd();
 for(unsigned engine=0;engine<2;++engine){
  auto& a=engine?g.GPU2D_B:g.GPU2D_A;SoftRenderer2D ref(a,p),opt(a,p);ref.Reset();opt.Reset();ref.ZeroBrightness=false;opt.ZeroBrightness=true;
  u8* vram;u32 mask;a.GetBGVRAM(vram,mask);for(u32 i=0;i<=mask;++i)vram[i]=rnd();
  for(unsigned slot=0;slot<4;++slot)for(unsigned pal=0;pal<16;++pal){u16* data=a.GetBGExtPal(slot,pal);for(unsigned i=0;i<256;++i)data[i]=rnd();}
  auto* objpal=a.GetOBJExtPal();for(unsigned i=0;i<4096;++i)objpal[i]=rnd();
  // All 8 BG modes, all 256 background priority combinations. Additional
  // variants cover mosaic, transparent 3D positions, all sprite priorities,
  // windows, effects, capture, BG0 disabled, and engine B fallback.
  for(unsigned test=0;test<8*256*32;++test){
   const unsigned mode=test%8,priorities=(test/8)%256,variant=test/(8*256);
   a.Enabled=true;a.ForcedBlank=0;a.DispCnt=0x10008u|mode;a.LayerEnable=31;a.OBJEnable=1;
   if(variant&1)a.DispCnt|=1u<<30;
   a.BGMosaicSize[0]=(variant%4==0)?rnd()%16:0;a.BGMosaicSize[1]=rnd()%16;a.BGMosaicLine=rnd()%192;
   a.OBJMosaicSize[0]=(variant%5==0)?rnd()%16:0;a.OBJMosaicSize[1]=0;
   for(unsigned bg=0;bg<4;++bg){a.BGCnt[bg]=((priorities>>(bg*2))&3)|(rnd()&0xfffc);a.BGXPos[bg]=rnd()%512;a.BGYPos[bg]=rnd()%512;}
   for(unsigned bg=0;bg<2;++bg){a.BGXRefInternal[bg]=s32(rnd()%131072)-32768;a.BGYRefInternal[bg]=s32(rnd()%131072)-32768;a.BGRotA[bg]=(variant&2)?256:s16(rnd());a.BGRotC[bg]=(variant&2)?0:s16(rnd());}
   a.BlendCnt=(variant&1)?0xff:0xbf;a.EVA=rnd()%17;a.EVB=rnd()%17;a.EVY=0;
   if(variant==16)a.EVY=rnd()%16+1;
   if(variant==17)a.BlendCnt&=~(1u<<(priorities%6));
   if(variant==18)a.BlendCnt|=1u<<(8+priorities%6);
   if(variant==19)a.BlendCnt=(priorities&1)?0x7f:0x3f;
   if(variant>=24){a.BlendCnt=rnd()&0x3fff;a.EVY=rnd()%17;}
   g.CaptureEnable=variant==16;
   if(variant==17)a.LayerEnable&=~1;
   if(variant==18)a.DispCnt&=~8;

   if(variant==20){a.DispCnt|=0xe000;a.Win0Active=1;a.Win1Active=1;a.Win0Coords[0]=19;a.Win0Coords[1]=203;a.Win1Coords[0]=227;a.Win1Coords[1]=11;for(auto& v:a.WinCnt)v=rnd()&63;}
   if(variant>=24)a.LayerEnable=rnd()&31;
   ref.NumSprites=opt.NumSprites=(variant%7)?128:0;
   for(unsigned x=0;x<256;++x){
    const unsigned alpha=(variant>=12&&variant<=15&&x==(priorities+(variant-12)*63)%256)?(priorities%31):31;
    three[x]=(rnd()&0x3f3f3f)|(alpha<<24);
    const u32 flags[]={0x10000000u,0x80000000u,0xc0000000u,0xcf000000u};
    u32 obj=(rnd()&0x7fff)|SoftRenderer2D::OBJ_DirectColor|SoftRenderer2D::OBJ_IsOpaque|((x%4)<<16)|flags[(x/4)%4];
    if(x%7==0)obj=0;else if(variant&4)obj|=SoftRenderer2D::OBJ_Mosaic;
    ref.OBJLine[x]=opt.OBJLine[x]=obj;ref.OBJWindow[x]=opt.OBJWindow[x]=x%7==0;
   }
   a.SetZeroBrightnessEnabled(test%7!=0);
   opt.ZeroBrightness=test%3==0 ? -1 : (test%11==0 ? 0 : 1);
   ref.StandardPaletteChecked=opt.StandardPaletteChecked=false;
   const auto win0=a.Win0Active,win1=a.Win1Active;
   ref.DrawScanline_BGOBJ(test%192,out0.data());const auto after0=a.Win0Active,after1=a.Win1Active;
   a.Win0Active=win0;a.Win1Active=win1;const auto before=opt.ZeroBrightnessHits;opt.DrawScanline_BGOBJ(test%192,out1.data());
   if(a.Win0Active!=after0||a.Win1Active!=after1)throw std::runtime_error("window state differs");
   bool expect=(opt.ZeroBrightness<0 ? a.ZeroBrightnessEnabled() : opt.ZeroBrightness!=0) && !(a.DispCnt&0xe000) && a.EVY==0 && (a.BlendCnt&0x3fbf)==0xbf;
   if((opt.ZeroBrightnessHits!=before)!=expect)throw std::runtime_error("eligibility mismatch case="+std::to_string(test));
   hits+=expect;compare(out0.data(),out1.data(),"synthetic engine="+std::to_string(engine)+" case="+std::to_string(test));
   if(std::memcmp(ref.OBJLine,opt.OBJLine,sizeof(ref.OBJLine)))throw std::runtime_error("sprite mosaic state differs");
  }
 }
 if(hits<10000)throw std::runtime_error("insufficient zero-brightness cases");
 std::cout<<"ZERO_BRIGHTNESS_SYNTHETIC_PASS cases="<<cases<<" pixels="<<checks<<" hits="<<hits<<" hash="<<hash<<'\n';
}
static double cpuSeconds(){timespec t{};clock_gettime(CLOCK_PROCESS_CPUTIME_ID,&t);return t.tv_sec+t.tv_nsec*1e-9;}
static void saved(const char* path,int integral,int sprite,unsigned benchFrames=0){
 std::ifstream in(path,std::ios::binary|std::ios::ate);if(!in||in.tellg()<=0||in.tellg()>64000000)throw std::runtime_error("bad snapshot");auto len=in.tellg();in.seekg(0);std::vector<u8> bytes(static_cast<size_t>(len));in.read(reinterpret_cast<char*>(bytes.data()),len);if(!in)throw std::runtime_error("short snapshot");
 auto n=makeNDS();auto& g=n->GPU;auto& p=static_cast<SoftRenderer&>(n->GetRenderer());
 RendererSettings settings{};settings.Threaded=false;settings.ScaleFactor=1;settings.FullFrame3D=true;settings.PackedOutput=true;p.SetRenderSettings(settings);
 Savestate snap(bytes.data(),bytes.size(),false);g.DoSavestate(&snap);if(snap.Error)throw std::runtime_error("load failure");p.Finish3DRendering();
 g.GPU3D.SetEnabled(true,true);g.GPU3D.SetExternalCommandReplay(true);g.GPU3D.SetIntegralTextureSpansEnabled(integral);g.GPU3D.SetSpriteRasterSpansEnabled(sprite);g.GPU3D.RenderFrameIdentical=false;p.Start3DRendering();p.Finish3DRendering();
 struct Row {std::array<u32,256> three,obj;std::array<u8,256> window;u32 sprites;u8 win0,win1;};
 std::vector<Row> rows(192);std::array<u64,2> engineHits{};
 for(unsigned engine=0;engine<2;++engine){auto& a=engine?g.GPU2D_B:g.GPU2D_A;a.Enabled=true;SoftRenderer2D ref(a,p),opt(a,p);ref.Reset();opt.Reset();ref.ZeroBrightness=false;opt.ZeroBrightness=true;
  for(unsigned line=0;line<192;++line){g.VCount=line;p.Output3D=p.Get3DScanline(line);a.UpdateWindows(line);ref.DrawSprites(line);opt.DrawSprites(line);auto& row=rows[line];std::copy(p.Output3D,p.Output3D+256,row.three.begin());std::copy(ref.OBJLine,ref.OBJLine+256,row.obj.begin());std::copy(ref.OBJWindow,ref.OBJWindow+256,row.window.begin());row.sprites=ref.NumSprites;row.win0=a.Win0Active;row.win1=a.Win1Active;const auto win0=a.Win0Active,win1=a.Win1Active;ref.DrawScanline(line);std::array<u32,256> expected;std::copy(std::begin(p.Output2D[engine]),std::end(p.Output2D[engine]),expected.begin());const auto after0=a.Win0Active,after1=a.Win1Active;a.Win0Active=win0;a.Win1Active=win1;opt.DrawScanline(line);if(a.Win0Active!=after0||a.Win1Active!=after1)throw std::runtime_error("saved window state differs");compare(expected.data(),p.Output2D[engine],"saved engine="+std::to_string(engine)+" line="+std::to_string(line));
   u64 a0,a1,b0,b1;ref.GetOBJBufferHashes(a0,a1);opt.GetOBJBufferHashes(b0,b1);if(a0!=b0||a1!=b1)throw std::runtime_error("saved sprite state differs");
  }engineHits[engine]=opt.ZeroBrightnessHits;
  if(benchFrames&&engine==0){
   std::array<double,2> cpu{};std::array<u64,2> result{};alignas(8) std::array<u32,256> output{};
   for(unsigned method=0;method<2;++method){
    ref.ZeroBrightness=method!=0;
    auto batch=[&](unsigned frames){u64 sum=0;for(unsigned frame=0;frame<frames;++frame)for(unsigned line=0;line<192;++line){auto& row=rows[line];g.VCount=line;p.Output3D=row.three.data();a.Win0Active=row.win0;a.Win1Active=row.win1;ref.NumSprites=row.sprites;std::memcpy(ref.OBJLine,row.obj.data(),sizeof(ref.OBJLine));std::memcpy(ref.OBJWindow,row.window.data(),sizeof(ref.OBJWindow));ref.StandardPaletteChecked=false;ref.DrawScanline_BGOBJ(line,output.data());sum+=output[(frame+line)&255];}return sum;};
    batch(16);const auto start=cpuSeconds();result[method]=batch(benchFrames);cpu[method]=cpuSeconds()-start;
   }
   if(result[0]!=result[1])throw std::runtime_error("benchmark output differs");
   std::cout<<std::setprecision(12)<<"ZERO_BRIGHTNESS_BENCH frames="<<benchFrames<<" baseline_cpu_seconds="<<cpu[0]<<" candidate_cpu_seconds="<<cpu[1]<<" ratio="<<cpu[1]/cpu[0]<<" checksum="<<result[0]<<'\n';
  }
 }
 std::cout<<"ZERO_BRIGHTNESS_SAVED_PASS cases="<<cases<<" pixels="<<checks<<" hits_a="<<engineHits[0]<<" hits_b="<<engineHits[1]<<" hash="<<hash<<'\n';
}
int main(int argc,char** argv)try{setupEnv();if(argc==1){policyChecks();synthetic();}else if(argc==4||argc==5)saved(argv[1],std::stoi(argv[2]),std::stoi(argv[3]),argc==5?std::stoul(argv[4]):0);else return 2;}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
