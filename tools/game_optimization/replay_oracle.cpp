// SPDX-License-Identifier: GPL-3.0-or-later
#include "GPU_Soft.h"
#include "replay/GameQueryProfile.h"
#include "NDS.h"
#include <fstream>
#include <iostream>
#include <memory>
#include <vector>
#include <filesystem>
#include <cstdint>
#include <map>
namespace melonDS {
bool replay_profile_active=false;
unsigned replay_frame=0;
u64 replay_instructions[2]{};
std::map<u32,std::pair<u64,u32>> replay_samples[2];
std::vector<u32> replay_watches;
std::ofstream replay_watch;
void replay_instruction(unsigned cpu,u32 pc,u32 op,const u32* r){
 if((++replay_instructions[cpu]&255)==0){auto& v=replay_samples[cpu][pc];++v.first;v.second=op;}
 if(cpu==0)for(auto w:replay_watches)if(pc==w){replay_watch<<replay_frame<<','<<std::hex<<pc;for(int i=0;i<16;++i)replay_watch<<','<<r[i];replay_watch<<std::dec<<'\n';}
}
}
using namespace melonDS;
int main(int argc,char**argv) {
 if(argc!=7 && argc!=8)return 2;
 const unsigned frameCount = std::stoul(argv[4]);
 if (frameCount < 2601) { std::cerr << "At least 2601 frames are required for both RAM checkpoints\n"; return 2; }
 if (!std::filesystem::is_regular_file(argv[5]) || !std::filesystem::is_regular_file(argv[6])) return 2;
 const unsigned profileStart = argc==8 ? std::stoul(argv[7]) : 0;
 std::filesystem::create_directories(argv[3]);
 std::ifstream f(argv[1],std::ios::binary|std::ios::ate);if(!f)return 3;
 const u32 len=f.tellg();f.seekg(0);auto rom=std::make_unique<u8[]>(len);f.read((char*)rom.get(),len);if(!f)return 4;
 nds4mister::replay::GameQueryHeader header{};
 if(len<header.size())return 4;
 std::copy_n(rom.get(),header.size(),header.data());
 const auto selected=nds4mister::replay::read_game_query_profile([&](auto& value){value=header;return true;});
 auto cart=NDSCart::ParseROM(std::move(rom),len,nullptr);if(!cart)return 5;
 std::ifstream s(argv[2],std::ios::binary|std::ios::ate);if(!s)return 6;
 std::vector<u8> save(s.tellg());s.seekg(0);s.read((char*)save.data(),save.size());cart->SetSaveMemory(save.data(),save.size());
 NDSArgs args;args.JIT=std::nullopt;auto nds=std::make_unique<NDS>(std::move(args),nullptr);
 nds->SetNDSCart(std::move(cart));nds->Reset();nds->GPU.GPU3D.SetIntegralTextureSpansEnabled(nds4mister::replay::castlevania_integral_texture_profile(selected));nds->SetupDirectBoot(std::filesystem::path(argv[1]).filename().string());nds->SPU.SetOutputSampleRate(48000);nds->RTC.SetDateTime(2026,10,24,12,0,0);static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(nds->GetRenderer()).Rend3D.get())->SetFullFrameCompletion(true);nds->Start();
 const std::string out=argv[3];
 std::ofstream log(out+"/frames.csv"),thumbs(out+"/thumbs.rgb",std::ios::binary),audio(out+"/audio.s16le",std::ios::binary);
 log<<"frame,timestamp,hash_top,hash_bottom,audio_samples,disp_a,disp_b\n";
 struct Input{unsigned first,last,mask;};std::vector<Input> inputs;std::ifstream replay(argv[5]);Input v;while(replay>>v.first>>v.last>>std::hex>>v.mask>>std::dec)inputs.push_back(v);
 std::ifstream watches(argv[6]);u32 watch;while(watches>>std::hex>>watch)replay_watches.push_back(watch);replay_watch.open(out+"/watches.csv");
 std::ofstream state(out+"/state.csv");state<<"frame,arm9_insn,arm7_insn,mainram,itcm,dtcm,arm7wram,sharedwram,save\n";
 auto hash=[](const u8* p,size_t n){u64 h=14695981039346656037ull;for(size_t i=0;i<n;++i)h=(h^p[i])*1099511628211ull;return h;};
 for(unsigned frame=0;frame<frameCount;++frame){
  replay_profile_active=frame>=profileStart;replay_frame=frame;
  replay_instructions[0]=replay_instructions[1]=0;
  u32 keys=0xfff;for(auto i:inputs)if(frame>=i.first&&frame<i.last)keys&=~i.mask;nds->SetKeyMask(keys);
  nds->RunFrame();
  if(frame==2000||frame==2600){std::ofstream ram(out+"/mainram.bin",std::ios::binary);ram.write((char*)nds->MainRAM,0x400000);std::ofstream tcm(out+"/itcm.bin",std::ios::binary);tcm.write((char*)nds->ARM9.ITCM,0x8000);}
  std::vector<u8> canonical(nds->MainRAM,nds->MainRAM+0x400000);

  state<<frame<<','<<replay_instructions[0]<<','<<replay_instructions[1]<<','<<hash(canonical.data(),canonical.size())<<','<<hash(nds->ARM9.ITCM,0x8000)<<','<<hash(nds->ARM9.DTCM,0x4000)<<','<<hash(nds->ARM7WRAM,0x10000)<<','<<hash(nds->SharedWRAM,0x8000)<<','<<hash(nds->GetNDSSave(),nds->GetNDSSaveLength())<<'\n';
  void*top=nullptr;void*bottom=nullptr;if(!nds->GPU.GetFramebuffers(&top,&bottom))return 7;
  uint64_t hashes[2]={14695981039346656037ull,14695981039346656037ull};
  for(int screen=0;screen<2;++screen){auto*pix=(u32*)(screen?bottom:top);
   for(unsigned i=0;i<256*192;++i)hashes[screen]=(hashes[screen]^pix[i])*1099511628211ull;
   for(int y=0;y<48;++y)for(int x=0;x<64;++x){u32 p=pix[(y*4+2)*256+x*4+2];char rgb[3]={(char)p,(char)(p>>8),(char)(p>>16)};thumbs.write(rgb,3);}
  }
  s16 buf[4096];int n=nds->SPU.ReadOutput(buf,2048);audio.write((char*)buf,n*4);
  log<<frame<<','<<nds->GetSysClockCycles(2)<<','<<hashes[0]<<','<<hashes[1]<<','<<n<<','<<nds->ARM9Read32(0x04000000)<<','<<nds->ARM9Read32(0x04001000)<<'\n';
  if(frame%120==0){std::ofstream pixels(out+"/frame_"+std::to_string(frame)+".rgba",std::ios::binary);pixels.write((char*)top,256*192*4);pixels.write((char*)bottom,256*192*4);std::cout<<frame<<std::endl;}
 }
 for(int cpu=0;cpu<2;++cpu){std::ofstream prof(out+"/pc"+std::to_string(cpu+1)+".csv");prof<<"pc,count,opcode\n";for(auto [pc,v]:replay_samples[cpu])prof<<std::hex<<pc<<std::dec<<","<<v.first<<","<<std::hex<<v.second<<"\n";}
 std::ofstream saveout(out+"/save.bin",std::ios::binary);saveout.write((char*)nds->GetNDSSave(),nds->GetNDSSaveLength());
}
