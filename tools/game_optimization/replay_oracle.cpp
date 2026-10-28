// SPDX-License-Identifier: GPL-3.0-or-later
#include "GPU_Soft.h"
#include "replay/GameQueryProfile.h"
#include "NDS.h"
#include "replay_memory_watch.h"
#include "replay_video_capture.h"
#include "replay_code_comparison.h"
#include <fstream>
#include <iostream>
#include <memory>
#include <vector>
#include <filesystem>
#include <cstdint>
#include <map>
#include <cstdlib>
#include <sstream>
#include <stdexcept>
#include <set>
namespace melonDS {
bool replay_profile_active=false;
unsigned replay_frame=0;
u64 replay_instructions[2]{};
std::map<u32,std::pair<u64,u32>> replay_samples[2];
std::vector<u32> replay_watches;
std::ofstream replay_watch;
NDS* replay_machine=nullptr;
ReplayMemoryWatch replay_memory;
std::ofstream replay_memory_output;
unsigned replay_memory_first_frame=0,replay_memory_last_frame=0xffffffffu;
std::ofstream replay_spu_output;
u64 replay_spu_writes=0,replay_spu_mixes=0;
struct RamBusTrace {
 bool enabled=false;u64 ordinal=0;std::ofstream output;
 std::vector<std::pair<u32,u32>> ranges;
 struct Instruction{bool valid=false;u32 pc=0,opcode=0;};Instruction last[2];
 bool matches(u32 address,unsigned width)const{
  if(!enabled)return false;
  for(auto range:ranges)if(u64(address)<range.second&&u64(range.first)<u64(address)+width/8)return true;
  return false;
 }
 void event(const char* kind,unsigned cpu,unsigned channel,u32 generation,unsigned width,u32 address,u32 value,const NDS& nds){
  const ARM& arm=cpu==0?static_cast<const ARM&>(nds.ARM9):static_cast<const ARM&>(nds.ARM7);
  u32 dmaMask=0,dmaSource=0,dmaDestination=0,dmaCount=0;
  for(unsigned n=0;n<8;++n)if(nds.DMAs[n].Executing){dmaMask|=1u<<n;dmaSource=nds.DMAs[n].CurSrcAddr;dmaDestination=nds.DMAs[n].CurDstAddr;dmaCount=nds.DMAs[n].RemCount;}
  output<<ordinal++<<','<<kind<<','<<replay_frame<<','<<replay_spu_mixes<<','<<nds.ARM9Timestamp<<','<<nds.ARM7Timestamp<<','<<cpu<<','<<channel<<','<<generation<<','<<width<<','<<std::hex<<address<<','<<value<<','<<dmaMask<<','<<dmaSource<<','<<dmaDestination<<','<<dmaCount<<','<<arm.R[15]<<','<<arm.CPSR<<','<<arm.CurInstr<<','<<last[cpu].pc<<','<<last[cpu].opcode<<std::dec<<','<<last[cpu].valid;
  for(unsigned n=0;n<15;++n)output<<','<<std::hex<<arm.R[n];output<<std::dec<<'\n';
 }
} replay_ram_bus;
void replay_ram_write(const NDS& nds,unsigned cpu,unsigned width,u32 address,u32 value){
 if(!replay_ram_bus.matches(address,width))return;
 replay_ram_bus.event("write",cpu,16,0,width,address,value,nds);
}
void replay_spu_mix(){if(replay_spu_output.is_open())++replay_spu_mixes;}
void replay_spu_write(unsigned width,u32 address,u32 value,u64 timestamp){
 if(!replay_spu_output.is_open())return;
 if(replay_ram_bus.enabled)replay_ram_bus.event("sound_control",1,16,0,width,address,value,*replay_machine);
 replay_spu_output<<replay_spu_writes++<<','<<replay_frame<<','<<timestamp<<','<<replay_spu_mixes<<','<<width<<','<<std::hex<<address<<','<<value<<std::dec<<'\n';
}
struct AudioSampleTrace {
 bool enabled=false;u32 generation[16]{};u64 fifoCount[16]{},sampleCount[16]{},outputCount[16]{},mixedCount=0;
 std::ofstream starts,fifo[16],samples[16],output[16],mixed;
 std::vector<std::pair<unsigned,unsigned>> outputFrames;
 bool captureOutput()const{for(auto range:outputFrames)if(replay_frame>=range.first&&replay_frame<range.second)return true;return false;}
 void record(std::ofstream& stream,u32 a,u32 b,u32 c,u32 d){
  char bytes[16];unsigned at=0;for(u32 word:{a,b,c,d})for(unsigned shift=0;shift<32;shift+=8)bytes[at++]=char(word>>shift);
  stream.write(bytes,sizeof(bytes));
 }
 u32 mixIndex()const{if(replay_spu_mixes>0xffffffffull)throw std::runtime_error("Audio trace mix index overflow");return u32(replay_spu_mixes);}
 void channel(unsigned n)const{if(n>=16)throw std::runtime_error("Invalid audio trace channel");}
} replay_audio;
void replay_spu_start(const SPUChannel& channel){
 if(!replay_audio.enabled)return;const unsigned n=channel.Num;replay_audio.channel(n);
 if(replay_audio.generation[n]==0xffffffffu)throw std::runtime_error("Audio trace generation overflow");
 ++replay_audio.generation[n];
 replay_audio.starts<<n<<','<<replay_audio.generation[n]<<','<<replay_frame<<','<<replay_audio.mixIndex()<<','<<std::hex<<channel.Cnt<<','<<channel.SrcAddr<<','<<channel.TimerReload<<','<<channel.LoopPos<<','<<channel.Length<<std::dec<<','<<int(channel.InterpType)<<'\n';
}
void replay_spu_fifo(unsigned channel,u32 address,u32 value){
 if(!replay_audio.enabled)return;replay_audio.channel(channel);
 if((address>>24)==2&&replay_ram_bus.matches(0x02000000u|(address&replay_machine->MainRAMMask),32))
  replay_ram_bus.event("sound_read",1,channel,replay_audio.generation[channel],32,0x02000000u|(address&replay_machine->MainRAMMask),value,*replay_machine);
 replay_audio.record(replay_audio.fifo[channel],replay_audio.generation[channel],replay_audio.mixIndex(),address,value);++replay_audio.fifoCount[channel];
}
void replay_spu_sample(unsigned channel,unsigned type,s32 position,s16 sample){
 if(!replay_audio.enabled)return;replay_audio.channel(channel);if(type>4)throw std::runtime_error("Invalid audio sample format");
 replay_audio.record(replay_audio.samples[channel],replay_audio.generation[channel],replay_audio.mixIndex(),u32(position),(type<<16)|u16(sample));++replay_audio.sampleCount[channel];
}
void replay_spu_channel_output(unsigned channel,s32 value,unsigned pan){
 if(!replay_audio.enabled||!replay_audio.captureOutput())return;replay_audio.channel(channel);
 replay_audio.record(replay_audio.output[channel],replay_audio.generation[channel],replay_audio.mixIndex(),u32(value),pan);++replay_audio.outputCount[channel];
}
void replay_spu_mixed_output(s16 left,s16 right){
 if(!replay_audio.enabled||!replay_audio.captureOutput())return;
 replay_audio.record(replay_audio.mixed,replay_frame,replay_audio.mixIndex(),u16(left),u16(right));++replay_audio.mixedCount;
}
struct BlockTrace {
 bool enabled=false,active=false;unsigned cpu=0,startFrame=0;u32 begin=0,end=0;
 struct Write{u32 pc;unsigned addressReg,valueReg;};std::vector<Write> writes;
 u64 hash=0,count=0,completed=0,restarted=0,unscopedWrites=0;
 std::ofstream output;
 void Observe(unsigned which,u32 pc,u32 opcode,const u32* r){
  if(!enabled||which!=cpu)return;
  if(pc==begin){if(active)++restarted;active=true;startFrame=replay_frame;hash=14695981039346656037ull;count=0;}
  for(const auto& site:writes)if(pc==site.pc){
   const u32 cpsr=cpu==0?replay_machine->ARM9.CPSR:replay_machine->ARM7.CPSR;
   if((cpsr&0x20)||opcode!=(0xe5800000u|(site.addressReg<<16)|(site.valueReg<<12)))throw std::runtime_error("Block trace requires an unconditional ARM STR [Rn] at the declared site");
   if(!active){++unscopedWrites;continue;}
   for(u32 word:{r[site.addressReg],r[site.valueReg]})for(unsigned shift=0;shift<32;shift+=8)hash=(hash^u8(word>>shift))*1099511628211ull;
   ++count;
  }
  if(pc==end&&active){
   output<<completed++<<','<<startFrame<<','<<replay_frame<<','<<count<<','<<hash;
   for(unsigned n=0;n<16;++n)output<<','<<std::hex<<r[n];
   output<<','<<(cpu==0?replay_machine->ARM9.CPSR:replay_machine->ARM7.CPSR)<<std::dec<<'\n';active=false;
  }
 }
} replay_block;
void replay_instruction(unsigned cpu,u32 pc,u32 op,const u32* r){
 if(replay_ram_bus.enabled)replay_ram_bus.last[cpu]={true,pc,op};
 if((++replay_instructions[cpu]&255)==0){auto& v=replay_samples[cpu][pc];++v.first;v.second=op;}
 if(cpu==0)for(auto w:replay_watches)if(pc==w){replay_watch<<replay_frame<<','<<std::hex<<pc;for(int i=0;i<16;++i)replay_watch<<','<<r[i];replay_watch<<std::dec<<'\n';}
 replay_block.Observe(cpu,pc,op,r);
 if(!replay_memory.sites.empty()&&replay_frame>=replay_memory_first_frame&&replay_frame<replay_memory_last_frame) {
  const auto& nds=*replay_machine;
  replay_memory.Observe(cpu,pc,op,r,cpu==0?nds.ARM9.CPSR:nds.ARM7.CPSR,replay_frame,
   {nds.MainRAM,nds.MainRAMMask,nds.ARM9.ITCMSize,nds.ARM9.DTCMBase,nds.ARM9.DTCMMask,nds.ARM9.DTCM},replay_memory_output);
 }
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
 u32 len=f.tellg();f.seekg(0);auto rom=std::make_unique<u8[]>(len);f.read((char*)rom.get(),len);if(!f)return 4;
 nds4mister::replay::GameQueryHeader header{};
 if(len<header.size())return 4;
 std::copy_n(rom.get(),header.size(),header.data());
 const auto selected=nds4mister::replay::read_game_query_profile([&](auto& value){value=header;return true;});
 // A private VirtualRom stream can replace only the in-memory load image.
 // Keep the original file's cartridge identity and boot name, as the native
 // virtual-loading path does. No patched cartridge file is needed.
 if(const char* input=std::getenv("NDS_REPLAY_VIRTUAL_STDIN")){
  if(std::string(input)!="1")return 4;
  unsigned char prefix[8]{};std::cin.read((char*)prefix,8);
  if(!std::cin||std::string((char*)prefix,4)!="VROM")return 4;
  const u32 virtualLen=u32(prefix[4])|(u32(prefix[5])<<8)|(u32(prefix[6])<<16)|(u32(prefix[7])<<24);
  if(virtualLen<header.size()||virtualLen>512u*1024u*1024u)return 4;
  auto image=std::make_unique<u8[]>(virtualLen);std::cin.read((char*)image.get(),virtualLen);
  if(!std::cin||std::cin.peek()!=std::char_traits<char>::eof())return 4;
  rom=std::move(image);len=virtualLen;
 }
 auto cart=NDSCart::ParseROM(std::move(rom),len,nullptr);if(!cart)return 5;
 std::ifstream s(argv[2],std::ios::binary|std::ios::ate);if(!s)return 6;
 std::vector<u8> save(s.tellg());s.seekg(0);s.read((char*)save.data(),save.size());cart->SetSaveMemory(save.data(),save.size());
 NDSArgs args;args.JIT=std::nullopt;auto nds=std::make_unique<NDS>(std::move(args),nullptr);
 replay_machine=nds.get();
 if(const char* path=std::getenv("NDS_REPLAY_RAM_BUS")){
#ifndef NDS_REPLAY_HAS_RAM_BUS
  return 8;
#else
  std::ifstream spec(path);std::string line;
  while(std::getline(spec,line)){
   std::istringstream row(line);u64 first,last;std::string extra;
   if(!(row>>std::hex>>first>>last)||(row>>extra)||first<0x02000000ull||last>0x02400000ull||first>=last)return 8;
   for(auto old:replay_ram_bus.ranges)if(first<old.second&&old.first<last)return 8;
   replay_ram_bus.ranges.emplace_back(u32(first),u32(last));
  }
  if(replay_ram_bus.ranges.empty()||replay_ram_bus.ranges.size()>16)return 8;
  replay_ram_bus.output.open(std::string(argv[3])+"/ram_bus.csv");if(!replay_ram_bus.output)return 8;
  replay_ram_bus.output<<"ordinal,kind,frame,mix_calls,arm9_timestamp,arm7_timestamp,cpu_context,channel,generation,width,address,value,dma_executing_mask,dma_source,dma_destination,dma_remaining,raw_r15,cpsr,current_opcode,last_profile_pc,last_profile_opcode,last_profile_valid";
  for(unsigned n=0;n<15;++n)replay_ram_bus.output<<",r"<<n;replay_ram_bus.output<<'\n';
  replay_ram_bus.enabled=true;
#endif
 }
 if(const char* enabled=std::getenv("NDS_REPLAY_SPU_WRITES")){
  if(std::string(enabled)!="1")return 8;
  replay_spu_output.open(std::string(argv[3])+"/spu_writes.csv");
  if(!replay_spu_output)return 8;
  replay_spu_output<<"ordinal,frame,arm7_timestamp,mix_calls,width,address,value\n";
 }
 if(const char* enabled=std::getenv("NDS_REPLAY_SPU_SAMPLES")){
  if(std::string(enabled)!="1"||!replay_spu_output.is_open())return 8;
  const std::string prefix=std::string(argv[3])+"/spu_";
  replay_audio.starts.open(prefix+"starts.csv");replay_audio.mixed.open(prefix+"mixed.bin",std::ios::binary);
  replay_audio.starts<<"channel,generation,frame,mix_calls,cnt,source,timer_reload,loop_bytes,length_bytes,interpolation\n";
  for(unsigned n=0;n<16;++n){
   replay_audio.fifo[n].open(prefix+"fifo_"+std::to_string(n)+".bin",std::ios::binary);
   replay_audio.samples[n].open(prefix+"samples_"+std::to_string(n)+".bin",std::ios::binary);
   replay_audio.output[n].open(prefix+"output_"+std::to_string(n)+".bin",std::ios::binary);
   if(!replay_audio.fifo[n]||!replay_audio.samples[n]||!replay_audio.output[n])return 8;
  }
  if(!replay_audio.starts||!replay_audio.mixed)return 8;
  if(const char* windows=std::getenv("NDS_REPLAY_SPU_OUTPUT_FRAMES")){
   std::istringstream list(windows);std::string value;
   while(std::getline(list,value,',')){
    const auto colon=value.find(':');if(colon==std::string::npos||value.find_first_not_of("0123456789:")!=std::string::npos||value.find(':',colon+1)!=std::string::npos)return 8;
    const auto first=std::stoull(value.substr(0,colon)),last=std::stoull(value.substr(colon+1));if(first>=last||last>frameCount)return 8;
    for(auto old:replay_audio.outputFrames)if(first<old.second&&old.first<last)return 8;
    replay_audio.outputFrames.emplace_back(unsigned(first),unsigned(last));
   }
   if(replay_audio.outputFrames.empty())return 8;
  }
  replay_audio.enabled=true;
 }
 nds->SetNDSCart(std::move(cart));nds->Reset();nds->GPU.GPU3D.SetIntegralTextureSpansEnabled(nds4mister::replay::castlevania_integral_texture_profile(selected)||nds4mister::replay::ecclesia_sprite_raster_profile(selected));nds->GPU.GPU3D.SetSpriteRasterSpansEnabled(nds4mister::replay::portrait_sprite_raster_profile(selected)||nds4mister::replay::ecclesia_sprite_raster_profile(selected)||nds4mister::replay::ffta2_raster_only_profile(selected));nds->SetupDirectBoot(std::filesystem::path(argv[1]).filename().string());nds->SPU.SetOutputSampleRate(48000);nds->RTC.SetDateTime(2026,10,24,12,0,0);static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(nds->GetRenderer()).Rend3D.get())->SetFullFrameCompletion(true);nds->Start();
 const std::string out=argv[3];
 if(const char* path=std::getenv("NDS_REPLAY_MEMORY_WATCH")) {
  std::ifstream spec(path);replay_memory.Load(spec);
  replay_memory_output.open(out+"/memory_watch.csv");
  replay_memory.Header(replay_memory_output);
  if(!replay_memory_output)return 8;
 }
 if(const char* window=std::getenv("NDS_REPLAY_MEMORY_WATCH_FRAMES")) {
  if(replay_memory.sites.empty())return 8;
  const std::string value(window);const auto colon=value.find(':');
  if(colon==std::string::npos||value.find_first_not_of("0123456789:")!=std::string::npos||value.find(':',colon+1)!=std::string::npos)return 8;
  const auto first=std::stoull(value.substr(0,colon)),last=std::stoull(value.substr(colon+1));
  if(first>=last||last>frameCount||first<profileStart)return 8;
  replay_memory_first_frame=unsigned(first);replay_memory_last_frame=unsigned(last);
 }
 std::ofstream log(out+"/frames.csv"),thumbs(out+"/thumbs.rgb",std::ios::binary),audio(out+"/audio.s16le",std::ios::binary);
 log<<"frame,timestamp,hash_top,hash_bottom,audio_samples,disp_a,disp_b\n";
 ReplayVideoCapture videoCapture;std::ofstream videoPixels,videoIndex;
 if(const char* ranges=std::getenv("NDS_REPLAY_VIDEO_FRAMES")){
  videoCapture.Load(ranges,frameCount);
  videoPixels.open(out+"/video_frames.bgra",std::ios::binary);videoIndex.open(out+"/video_frames.csv");
  if(!videoPixels||!videoIndex)return 8;
  videoCapture.Header(videoIndex);
 }
 struct Input{unsigned first,last,mask;};std::vector<Input> inputs;std::ifstream replay(argv[5]);Input v;while(replay>>v.first>>v.last>>std::hex>>v.mask>>std::dec)inputs.push_back(v);
 std::ifstream watches(argv[6]);u32 watch;while(watches>>std::hex>>watch)replay_watches.push_back(watch);replay_watch.open(out+"/watches.csv");
 std::ofstream state(out+"/state.csv");state<<"frame,arm9_insn,arm7_insn,mainram,itcm,dtcm,arm7wram,sharedwram,save\n";
 ReplayCodeComparison codeComparisons;
 std::ofstream normalized;
 if(const char* path=std::getenv("NDS_REPLAY_BLOCK_TRACE")){
  std::ifstream spec(path);std::string line;if(!std::getline(spec,line))return 8;
  std::istringstream header(line);std::string extra;
  if(!(header>>replay_block.cpu>>std::hex>>replay_block.begin>>replay_block.end)||(header>>extra)||replay_block.cpu>1||replay_block.begin==replay_block.end)return 8;
  while(std::getline(spec,line)){
   std::istringstream row(line);BlockTrace::Write site{};
   if(!(row>>std::hex>>site.pc>>std::dec>>site.addressReg>>site.valueReg)||(row>>extra)||site.addressReg>=15||site.valueReg>=15)return 8;
   for(const auto& old:replay_block.writes)if(old.pc==site.pc)return 8;
   replay_block.writes.push_back(site);
  }
  if(replay_block.writes.empty()||replay_block.writes.size()>16)return 8;
  replay_block.enabled=true;replay_block.output.open(out+"/block_trace.csv");
  replay_block.output<<"ordinal,start_frame,end_frame,writes,hash";for(unsigned n=0;n<16;++n)replay_block.output<<",r"<<n;replay_block.output<<",cpsr\n";
 }
 std::set<unsigned> checkpoints;
 if(const char* requested=std::getenv("NDS_REPLAY_CHECKPOINT_FRAMES")){
  std::istringstream list(requested);std::string value;
  while(std::getline(list,value,',')){
   if(value.empty()||value.find_first_not_of("0123456789")!=std::string::npos)return 8;
   size_t consumed=0;const auto frame=std::stoull(value,&consumed);
   if(consumed!=value.size()||frame>=frameCount)return 8;
   checkpoints.insert(unsigned(frame));
  }
  if(checkpoints.empty())return 8;
 }
 if(const char* path=std::getenv("NDS_REPLAY_CODE_COMPARISON")){
  std::ifstream specs(path);if(!specs)return 8;codeComparisons.Load(specs);
  normalized.open(out+"/code_normalized_state.csv");normalized<<"frame,mainram,original_code_regions,replacement_code_regions,unmatched_overlay_regions\n";
 }
 auto hash=[](const u8* p,size_t n){u64 h=14695981039346656037ull;for(size_t i=0;i<n;++i)h=(h^p[i])*1099511628211ull;return h;};
 for(unsigned frame=0;frame<frameCount;++frame){
  replay_profile_active=frame>=profileStart;replay_frame=frame;
  replay_instructions[0]=replay_instructions[1]=0;
  u32 keys=0xfff;for(auto i:inputs)if(frame>=i.first&&frame<i.last)keys&=~i.mask;nds->SetKeyMask(keys);
  nds->RunFrame();
  if(checkpoints.count(frame)){
   const auto prefix=out+"/checkpoint_"+std::to_string(frame)+"_";
   auto dump=[&](const char* name,const u8* data,size_t bytes){std::ofstream file(prefix+name+".bin",std::ios::binary);file.write((const char*)data,bytes);if(!file)throw std::runtime_error("Checkpoint write failed");};
   dump("mainram",nds->MainRAM,0x400000);dump("itcm",nds->ARM9.ITCM,0x8000);
   dump("dtcm",nds->ARM9.DTCM,0x4000);dump("arm7wram",nds->ARM7WRAM,0x10000);dump("sharedwram",nds->SharedWRAM,0x8000);
   std::ofstream cpu(prefix+"cpus.csv");cpu<<"cpu";for(int r=0;r<16;++r)cpu<<",r"<<r;cpu<<",cpsr\n";
   cpu<<"arm9";for(int r=0;r<16;++r)cpu<<','<<std::hex<<nds->ARM9.R[r];cpu<<','<<nds->ARM9.CPSR<<'\n';
   cpu<<"arm7";for(int r=0;r<16;++r)cpu<<','<<std::hex<<nds->ARM7.R[r];cpu<<','<<nds->ARM7.CPSR<<'\n';
   std::ofstream mapping(prefix+"tcm.csv");mapping<<"dtcm_base,dtcm_mask,itcm_size\n"<<std::hex<<nds->ARM9.DTCMBase<<','<<nds->ARM9.DTCMMask<<','<<nds->ARM9.ITCMSize<<'\n';
  }
  if(frame==2000||frame==2600){std::ofstream ram(out+"/mainram.bin",std::ios::binary);ram.write((char*)nds->MainRAM,0x400000);std::ofstream tcm(out+"/itcm.bin",std::ios::binary);tcm.write((char*)nds->ARM9.ITCM,0x8000);}
  std::vector<u8> canonical(nds->MainRAM,nds->MainRAM+0x400000);

  state<<frame<<','<<replay_instructions[0]<<','<<replay_instructions[1]<<','<<hash(canonical.data(),canonical.size())<<','<<hash(nds->ARM9.ITCM,0x8000)<<','<<hash(nds->ARM9.DTCM,0x4000)<<','<<hash(nds->ARM7WRAM,0x10000)<<','<<hash(nds->SharedWRAM,0x8000)<<','<<hash(nds->GetNDSSave(),nds->GetNDSSaveLength())<<'\n';
  if(!codeComparisons.regions.empty()){
   const auto counts=codeComparisons.Normalize(canonical);
   normalized<<frame<<','<<hash(canonical.data(),canonical.size())<<','<<counts.original<<','<<counts.replacement<<','<<counts.unmatchedOverlay<<'\n';
  }
  void*top=nullptr;void*bottom=nullptr;if(!nds->GPU.GetFramebuffers(&top,&bottom))return 7;
  if(checkpoints.count(frame)){
   std::ofstream pixels(out+"/checkpoint_"+std::to_string(frame)+"_screens.rgba",std::ios::binary);
   pixels.write((const char*)top,256*192*4);pixels.write((const char*)bottom,256*192*4);
   if(!pixels)throw std::runtime_error("Checkpoint framebuffer write failed");
  }
  uint64_t hashes[2]={14695981039346656037ull,14695981039346656037ull};
  for(int screen=0;screen<2;++screen){auto*pix=(u32*)(screen?bottom:top);
   for(unsigned i=0;i<256*192;++i)hashes[screen]=(hashes[screen]^pix[i])*1099511628211ull;
   for(int y=0;y<48;++y)for(int x=0;x<64;++x){u32 p=pix[(y*4+2)*256+x*4+2];char rgb[3]={(char)p,(char)(p>>8),(char)(p>>16)};thumbs.write(rgb,3);}
  }
  s16 buf[4096];int n=nds->SPU.ReadOutput(buf,2048);audio.write((char*)buf,n*4);
  videoCapture.Frame(frame,top,bottom,unsigned(n),hashes[0],hashes[1],videoPixels,videoIndex);
  log<<frame<<','<<nds->GetSysClockCycles(2)<<','<<hashes[0]<<','<<hashes[1]<<','<<n<<','<<nds->ARM9Read32(0x04000000)<<','<<nds->ARM9Read32(0x04001000)<<'\n';
  if(frame%120==0){std::ofstream pixels(out+"/frame_"+std::to_string(frame)+".rgba",std::ios::binary);pixels.write((char*)top,256*192*4);pixels.write((char*)bottom,256*192*4);std::cout<<frame<<std::endl;}
 }
 videoCapture.Finish(videoPixels,videoIndex);
 for(int cpu=0;cpu<2;++cpu){std::ofstream prof(out+"/pc"+std::to_string(cpu+1)+".csv");prof<<"pc,count,opcode\n";for(auto [pc,v]:replay_samples[cpu])prof<<std::hex<<pc<<std::dec<<","<<v.first<<","<<std::hex<<v.second<<"\n";}
 std::ofstream saveout(out+"/save.bin",std::ios::binary);saveout.write((char*)nds->GetNDSSave(),nds->GetNDSSaveLength());
 if(!replay_memory.sites.empty()) {
  std::ofstream summary(out+"/memory_watch_summary.csv");
  replay_memory.Finish(replay_memory_output,summary);
  std::ofstream window(out+"/memory_watch_window.csv");
  window<<"first_frame,last_frame_exclusive\n"<<std::max(profileStart,replay_memory_first_frame)<<','<<std::min(frameCount,replay_memory_last_frame)<<'\n';
 }
 if(replay_block.enabled){
  std::ofstream summary(out+"/block_trace_summary.csv");summary<<"completed,restarted,unscoped_writes,unfinished\n"<<replay_block.completed<<','<<replay_block.restarted<<','<<replay_block.unscopedWrites<<','<<replay_block.active<<'\n';
 }
 if(replay_spu_output.is_open()){
  if(!replay_spu_mixes)throw std::runtime_error("Audio trace requested without observed mix callbacks; use the instrumented SPU object");
  replay_spu_output.flush();if(!replay_spu_output)throw std::runtime_error("Audio trace write failed");
  std::ofstream summary(out+"/spu_trace_summary.csv");summary<<"writes,mix_calls\n"<<replay_spu_writes<<','<<replay_spu_mixes<<'\n';
 }
 if(replay_audio.enabled){
  auto flush=[](std::ofstream& stream){stream.flush();if(!stream)throw std::runtime_error("Audio sample trace write failed");};
  flush(replay_audio.starts);flush(replay_audio.mixed);
  std::ofstream summary(out+"/spu_sample_summary.csv");summary<<"channel,starts,fifo_words,decoded_samples,output_samples\n";
  u64 starts=0;for(unsigned n=0;n<16;++n){
   flush(replay_audio.fifo[n]);flush(replay_audio.samples[n]);flush(replay_audio.output[n]);starts+=replay_audio.generation[n];
   summary<<n<<','<<replay_audio.generation[n]<<','<<replay_audio.fifoCount[n]<<','<<replay_audio.sampleCount[n]<<','<<replay_audio.outputCount[n]<<'\n';
  }
  if(!starts)throw std::runtime_error("No observed audio starts; verify sample instrumentation and replay coverage");
  std::ofstream windows(out+"/spu_output_windows.csv");windows<<"first_frame,last_frame_exclusive\n";for(auto range:replay_audio.outputFrames)windows<<range.first<<','<<range.second<<'\n';
  std::ofstream mixed(out+"/spu_mixed_summary.csv");mixed<<"records\n"<<replay_audio.mixedCount<<'\n';
 }
}
