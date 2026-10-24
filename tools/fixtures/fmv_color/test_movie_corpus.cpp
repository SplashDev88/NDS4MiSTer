// SPDX-License-Identifier: GPL-3.0-or-later
// Compare complete original packets with the shipped receiver's trimmed packets.
// Inputs are locally owned assets and generated descriptor tables, never fixtures
// containing copyrighted video. Keep decoder contexts alive across movie changes.
#define NDS4MISTER_EXPERIMENTAL_FMV_VIDEO_DECODE 1
#define NDS4MISTER_EXPERIMENTAL_FMV_VX_DECODE 1
#include "FmvVideoDecoder.h"
#include <fstream>
#include <iostream>
#include <iomanip>
#include <vector>
#include <cassert>
#include <algorithm>
#include <string>
#include <chrono>
using namespace melonDS::ExperimentalFmv;
static unsigned u32(const unsigned char*p){return unsigned(p[0])|unsigned(p[1])<<8|unsigned(p[2])<<16|unsigned(p[3])<<24;}
static unsigned u16(const unsigned char*p){return p[0]|unsigned(p[1])<<8;}
static std::vector<unsigned char> read(const std::string&name,size_t offset=0,size_t size=0){std::ifstream f(name,std::ios::binary|std::ios::ate);assert(f);size_t n=f.tellg();assert(offset<=n);if(!size)size=n-offset;assert(size<=n-offset);f.seekg(offset);std::vector<unsigned char>b(size);f.read((char*)b.data(),size);assert(f);return b;}
int main(int argc,char**argv){
 assert(argc==2);std::ifstream plan(argv[1]);assert(plan);VideoDecoder receiver;
 std::string label,rom,descriptors,clampfile;size_t offset,size;unsigned total=0,assets=0;
 while(plan>>label>>std::quoted(rom)>>offset>>size>>std::quoted(descriptors)>>std::quoted(clampfile)){
  auto raw=read(rom,offset,size),rows=read(descriptors);bool vx=!memcmp(raw.data(),"VXDS",4);assert(vx||!memcmp(raw.data(),"MODS",4));unsigned count=u32(raw.data()+(vx?4:8));assert(rows.size()==count*16);
  std::vector<unsigned char>clamp;if(clampfile!="-"){clamp=read(clampfile);assert(clamp.size()==4096);}
  const unsigned char*lut=clamp.empty()?nullptr:clamp.data();unsigned quant=vx?u32(raw.data()+20):0;
  // Replay after completion tests a rewind into a reused reference-frame cache.
  for(unsigned pass=0;pass<2;pass++){
   auto*ctx=avcodec_alloc_context3(avcodec_find_decoder(vx?AV_CODEC_ID_ACTIMAGINE_VX:AV_CODEC_ID_MOBICLIP));assert(ctx);ctx->width=256;ctx->height=192;ctx->thread_count=1;
   if(vx){ctx->extradata=(unsigned char*)av_mallocz(4+AV_INPUT_BUFFER_PADDING_SIZE);ctx->extradata_size=4;memcpy(ctx->extradata,raw.data()+20,4);}
   assert(avcodec_open2(ctx,ctx->codec,nullptr)>=0);if(!vx)assert(nds_mobiclip_set_clamp(ctx,lut,lut?4096:0)>=0);
   auto*pkt=av_packet_alloc();auto*frame=av_frame_alloc();size_t pos=vx?48:52;unsigned frames=pass?std::min(count,8u):count;
   for(unsigned n=0;n<frames;n++){
    unsigned length=vx?u16(raw.data()+pos)-2:u32(raw.data()+pos)>>14;assert(pos+4+length<=raw.size());unsigned consumed=u32(rows.data()+n*16+4),stream=u32(rows.data()+n*16+8)>>16;assert(consumed<=length);
    assert(av_new_packet(pkt,length+(vx?4:0))>=0);if(vx)memset(pkt->data,0,4);memcpy(pkt->data+(vx?4:0),raw.data()+pos+4,length);
    assert(avcodec_send_packet(ctx,pkt)>=0&&avcodec_receive_frame(ctx,frame)>=0);unsigned key=0x02200000+(n%6)*49152;
    if(!receiver.Decode(n,key,raw.data()+pos+4,consumed,stream,lut,vx?1:0,quant)){std::cerr<<"receiver error "<<label<<" "<<n<<"\n";return 7;}
    const auto*out=receiver.Find(key,stream);assert(out);
    for(unsigned y=0;y<192;y++)assert(!memcmp(out->Pixels.data()+256*y,frame->data[0]+y*frame->linesize[0],256));
    for(unsigned y=0;y<96;y++)for(unsigned x=0;x<128;x++){
     assert(out->Pixels[49152+y*256+(vx?x*2:x+128)]==frame->data[1][y*frame->linesize[1]+x]);
     assert(out->Pixels[49152+y*256+(vx?x*2+1:x)]==frame->data[2][y*frame->linesize[2]+x]);
    }
    pos+=4+length;av_packet_unref(pkt);av_frame_unref(frame);++total;
   }
   av_packet_free(&pkt);av_frame_free(&frame);avcodec_free_context(&ctx);
  }
  std::cout<<label<<" "<<count<<" frames + restart PASS\n"<<std::flush;++assets;
 }
 assert(plan.eof());std::cout<<"PASS "<<assets<<" assets "<<total<<" frames, original packet pixels identical, reused buffers, transitions and restarts\n";
}
