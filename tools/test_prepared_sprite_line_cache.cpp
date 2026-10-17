// SPDX-License-Identifier: GPL-3.0-only
// Exercise exact prepared-sprite identity with OAM changes every line.
#define main original_cache_test_main
#include "../src/replay/EngineBLineCacheTest.cpp"
#undef main
static bool parallelTest=false;
static void configure(NDS& nds,bool cache,bool enabled){RendererSettings s{};s.ScaleFactor=1;s.PackedOutput=true;s.PairedBCache=cache;s.Parallel2D=cache&&parallelTest;s.PreparedSpriteLineReuse=enabled;nds.GetRenderer().SetRenderSettings(s);}
static void mutate(NDS& nds,unsigned f,unsigned y,bool after){
 auto& g=nds.GPU;
 // Disabled sprite 127 changes throughout every frame, independently of
 // the currently prepared line. Even no-op hardware writes get fresh hints.
 nds.ARM9Write16(0x070007fa,u16(f*19+y*3+unsigned(after)));
 g.MarkExternalRenderOAM(0x7fa,2);
 unsigned mode=(f/6)%14;
 if(y==0&&!after){
  for(unsigned i=0;i<128;++i)nds.ARM9Write16(0x07000400+i*8,0x0200);
  nds.ARM9Write32(0x04001000,0x00011100);nds.ARM9Write16(0x0400104c,0);g.GPU2D_B.Enabled=true;
  if(mode!=0){
   unsigned sy=mode==2?20+((f&1)?128:0):20;
   u16 attr0=u16(sy|0x2000|(mode==3?0x0800:0)|(mode==4?0x0100:0)|(mode==5?0x1000:0));
   nds.ARM9Write16(0x07000400,attr0);nds.ARM9Write16(0x07000402,0x4011);nds.ARM9Write16(0x07000404,0);
   if(mode==3){nds.ARM9Write32(0x04001000,0x00019100);nds.ARM9Write16(0x0400104a,0x213f);}
   if(mode==4){nds.ARM9Write16(0x07000406,0x100);nds.ARM9Write16(0x0700040e,0);nds.ARM9Write16(0x07000416,0);nds.ARM9Write16(0x0700041e,0x100);}
   if(mode==5)nds.ARM9Write16(0x0400104c,0x3300);
  }
  if(mode==9)nds.ARM9Write16(0x07000404,0x100); // Transparent tile, nonzero count.
  if(mode==10){nds.ARM9Write16(0x07000400,0x2814);nds.ARM9Write32(0x04001000,0x00019100);nds.ARM9Write16(0x0400104a,0x213f);}
  if(mode==11){nds.ARM9Write16(0x07000400,0x3014);nds.ARM9Write16(0x0400104c,0x3300);}
  g.MarkExternalRenderOAM(0x400,1024);
 }
 // Modify a live sprite after its preparation; this must affect future
 // phases only. Exercise entry/exit and affine matrix changes too.
 if(after&&mode!=0&&mode<8&&y<192){
  nds.ARM9Write16(0x07000402,u16(0x4000|((17+f*3+y)&0x1ff)));g.MarkExternalRenderOAM(0x402,2);
  if(mode==4){nds.ARM9Write16(0x07000406,u16(0x100+((f+y)&31)));g.MarkExternalRenderOAM(0x406,2);}
 }
 // Recompute a line with a different, discarded preparation, then restore
 // its original input. The cached identity must belong to the old output.
 if(mode==12&&after&&y<192){
  nds.ARM9Write16(0x07000402,0x4050);g.MarkExternalRenderOAM(0x402,2);
  nds.GetRenderer().DrawSprites(y);
  nds.ARM9Write16(0x07000402,0x4011);g.MarkExternalRenderOAM(0x402,2);
  nds.GetRenderer().DrawSprites(y);
 }
 if(mode==13&&y==50)g.CaptureEnable=true;
 if(mode==13&&y==55)g.CaptureEnable=false;
 if(mode==6&&y==40)g.GPU2D_B.Enabled=false;
 if(mode==6&&y==80)g.GPU2D_B.Enabled=true;
 if(mode==7){
  if(y==50){nds.ARM9Write16(0x05000422,u16(f*113));g.MarkExternalRenderPalette(0x422,2);}
  if(y==90){nds.ARM9Write32(0x06200020,f*17391);g.MarkExternalRenderVRAM(2);}
  if(y==110)nds.ARM9Write16(0x0400104c,0x0033);
  if(y==130)nds.ARM9Write16(0x0400106c,0x4008);
  if(y==160)nds.ARM9Write16(0x0400106c,0);
 }
}
int main(int argc,char** argv)try{
 bool direct=false;for(int i=1;i<argc;++i){if(std::string(argv[i])=="--direct")direct=true;else if(std::string(argv[i])=="--parallel")parallelTest=true;else throw std::runtime_error("bad argument");}auto plain=fixture(false,true),cached=fixture(true,true);unsigned hits=0,misses=0,emptyHits=0,disabledHits=0,nonemptyHits=0,transparentHits=0,windowHits=0,mosaicHits=0;bool enabled=true;configure(*cached,true,true);
 using Plane=std::array<u32,256*192+8>;auto output=std::make_unique<std::array<std::array<Plane,2>,2>>();for(auto& s:*output)for(auto& p:s)p.fill(0xDEADBEEF);std::array<Plane,2> prior{};
 for(unsigned f=0;f<168;++f){
  if(f==84||f==90){enabled=f==90;configure(*cached,true,enabled);}
  if(direct&&!cached->GetRenderer().SetExternalFramebuffers((*output)[f&1][0].data()+4,(*output)[f&1][1].data()+4))throw std::runtime_error("external output rejected");
  for(unsigned y=0;y<263;++y){
   for(auto* nds:{plain.get(),cached.get()}){mutate(*nds,f,y,false);phase(*nds,f,y,y==0?2:0);mutate(*nds,f,y,true);phase(*nds,f,y,1);}
   if(y>=192)continue;
   u32* a[2];u32* b[2];plain->GetRenderer().GetRenderedScanlines(y,&a[0],&a[1]);cached->GetRenderer().GetRenderedScanlines(y,&b[0],&b[1]);for(unsigned screen=0;screen<2;++screen)if(std::memcmp(a[screen],b[screen],256*sizeof(u32)))throw std::runtime_error("pixel mismatch f="+std::to_string(f)+" y="+std::to_string(y));
   bool ah=false,bh=false;cached->GetRenderer().GetExternalLineCacheResult(ah,bh);if(ah)throw std::runtime_error("A reused");hits+=bh;misses+=!bh;
   if(!enabled)disabledHits+=bh;
   if((!cached->GPU.GPU2D_B.Enabled||cached->GPU.CaptureEnable)&&bh)throw std::runtime_error("cache hit during disabled engine or capture f="+std::to_string(f)+" y="+std::to_string(y)+" enabled="+std::to_string(cached->GPU.GPU2D_B.Enabled)+" capture="+std::to_string(cached->GPU.CaptureEnable));
   u64 ahash[4],bhash[4];plain->GetRenderer().GetOBJBufferHashes(ahash);cached->GetRenderer().GetOBJBufferHashes(bhash);for(unsigned h=0;h<4;++h)if(ahash[h]!=bhash[h])throw std::runtime_error("post-composition OBJ state mismatch");
   if(f>=50&&f<54&&y>=20&&y<36){if(!bh)throw std::runtime_error("static nonempty sprite line missed");++nonemptyHits;}
   if(f>=56&&f<60&&y>=20&&y<36){if(!bh)throw std::runtime_error("transparent counted sprite missed");++transparentHits;}
   if(f>=62&&f<66&&y>=20&&y<36){if(!bh)throw std::runtime_error("static OBJ window line missed");++windowHits;}
   if(f>=68&&f<72&&y>=20&&y<36){if(!bh)throw std::runtime_error("static mosaic sprite line missed");++mosaicHits;}
   if(f>=2&&f<6&&y>=40){if(!bh)throw std::runtime_error("empty line missed with fresh irrelevant OAM");++emptyHits;}
  }
  if(direct){for(auto& p:(*output)[f&1])for(unsigned i=0;i<4;++i)if(p[i]!=0xDEADBEEF||p[p.size()-1-i]!=0xDEADBEEF)throw std::runtime_error("guard overwritten");if(f&&(*output)[(f^1)&1]!=prior)throw std::runtime_error("completed slot overwritten");prior=(*output)[f&1];cached->GetRenderer().SetExternalFramebuffers(nullptr,nullptr);}
 }
 if(hits<1000||misses<1000||disabledHits||emptyHits!=608||nonemptyHits!=64||transparentHits!=64||windowHits!=64||mosaicHits!=64)throw std::runtime_error("insufficient cache proof");std::cout<<"EMPTY_SPRITE_ORACLE_PASS direct="<<direct<<" parallel="<<parallelTest<<" frames=168 pixels="<<168*192*256*2<<" hits="<<hits<<" misses="<<misses<<" required_empty_hits="<<emptyHits<<" nonempty_hits="<<nonemptyHits<<" transparent_hits="<<transparentHits<<" window_hits="<<windowHits<<" mosaic_hits="<<mosaicHits<<" disabled_hits="<<disabledHits<<'\n';
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
