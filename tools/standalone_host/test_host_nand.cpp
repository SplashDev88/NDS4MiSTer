// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
 static void run(const fs::path &root) {
  fs::create_directories(root/"kit");
  Host h((root/"kit").string(),(root/"games").string(),root);
  fs::create_directories(root/"games");
  RomMapping::test_iomem_path=(root/"iomem").string();
  std::ofstream(RomMapping::test_iomem_path)<<"00000000-1fefffff : System RAM\n";
  const auto rom=root/"games/guard.nds";
  std::array<char,512> header{};
  std::copy_n("UORE",4,header.data()+12); header[0x96]=0x50; header[0x97]=3;
  std::ofstream(rom,std::ios::binary).write(header.data(),header.size());
  h.mount("ordinary.nds",3);
  const int previous=h.save;
  const uint8_t sentinel=0x6b;
  assert(pwrite(previous,&sentinel,1,0)==1);
  const auto saves=root/"saves/NDS";
  std::ofstream(saves/"wrong.sav",std::ios::binary)<<"keep this file";
  bool rejected=false;
  try { h.mount("wrong.nds",9); } catch(const std::exception&) {rejected=true;}
  assert(rejected && h.save==previous && fs::file_size(saves/"wrong.sav")==14);
  // Exercise actual load ordering: missing FPGA capability and bad NAND
  // headers must fail before creating/mounting the incoming save.
  const auto rejected_load=[&](const std::string &reason) {
   bool caught=false;
   try{h.load(rom.string());}catch(const std::exception&e){caught=std::string(e.what()).find(reason)!=std::string::npos;}
   assert(caught && h.save==previous && !fs::exists(saves/"guard.sav"));
   assert(RomMapping::test_live_mappings==0);
  };
  rejected_load("NAND-capable FPGA");
  h.spi.default_firmware_flags|=0x1000;
  header[0x96]=header[0x97]=0;std::ofstream(rom,std::ios::binary).write(header.data(),header.size());
  rejected_load("save-region header");
  header[0x96]=0x50;header[0x97]=char(0x83);std::ofstream(rom,std::ios::binary).write(header.data(),header.size());
  rejected_load("save-region header"); // cannot wrap a malformed 33-bit base
  header[0x96]=0x50;header[0x97]=3;std::ofstream(rom,std::ios::binary).write(header.data(),header.size());
  h.load(rom.string());assert(h.game==rom && h.save_sector_limit==32768);
  assert(fs::file_size(saves/"guard.sav")==16777216);
  bool profile_sent=false;
  uint16_t index=0;
  for(const auto&t:h.spi.history) {
   if(t.select==Spi::FIO && t.command==0x55)index=t.words.at(0);
   if(t.select==Spi::FIO && t.command==0x54 && index==8) {
    assert(t.words==std::vector<uint16_t>({0x4f55,0x4552,9,0x5351}));profile_sent=true;
   }
  }
  assert(profile_sent);
  h.mount("wario.nds",9);
  assert(h.save_sector_limit==32768 && fs::file_size(saves/"wario.sav")==16777216);
  std::array<uint8_t,65536> chunk{};
  for(uint32_t offset=0;offset<16777216;offset+=chunk.size()) {
   assert(pread(h.save,chunk.data(),chunk.size(),offset)==ssize_t(chunk.size()));
   assert(std::all_of(chunk.begin(),chunk.end(),[](auto b){return b==0xff;}));
  }
  uint32_t lba=32767;unsigned operation=2;
  std::vector<uint16_t> returned;
  h.spi.response=[&](uint32_t select,uint16_t cmd,size_t pos,uint16_t data)->uint16_t {
   assert(select==Spi::IO);
   if(cmd==0x16) {
    if(pos==0)return uint16_t(0x8080|operation);
    if(pos==2)return uint16_t(lba);
    if(pos==3)return uint16_t(lba>>16);
   }
   if(cmd==0x18 && pos)return uint16_t(0x5a00|(pos-1));
   if(cmd==0x17 && pos)returned.push_back(data);
   return 0;
  };
  assert(h.sector()); operation=1;assert(h.sector());assert(returned.size()==256);
  for(unsigned i=0;i<256;++i)assert(returned[i]==(0x5a00|i));
  lba=32768;rejected=false;try{h.sector();}catch(const std::exception&){rejected=true;}assert(rejected);
  h.spi.response={};h.mount("wario.nds",9); // cold file reopen preserves the last sector
  uint16_t word=0;assert(pread(h.save,&word,2,16777216-2)==2 && word==0x5aff);
  h.mount("ordinary.nds",3);assert(h.save_sector_limit==2048);
  assert(pread(h.save,&word,1,0)==1 && (word&255)==sentinel);
  // Interrupted initialization leaves the destination absent (or empty), not
  // a wrong-size file that a later launch might mistake for saved progress.
  for(bool existed:{false,true}) {
   const auto dest=saves/(existed?"empty.sav":"new.sav");
   if(existed)std::ofstream(dest).close();
   int calls=0;rejected=false;
   try{nds_nand::prepare(dest,nds_nand::bytes(8),[&]{if(++calls==3)throw std::runtime_error("cancel");});}
   catch(const std::exception&){rejected=true;}
   assert(rejected && (existed?fs::file_size(dest)==0:!fs::exists(dest)));
   nds_nand::prepare(dest,nds_nand::bytes(8),[]{});
   assert(fs::file_size(dest)==8388608);
  }
  // A concurrent writer advancing an empty file must not be overwritten.
  const auto changed=saves/"changed.sav";std::ofstream(changed).close();
  rejected=false;bool advanced=false;
  try{nds_nand::prepare(changed,nds_nand::bytes(8),[&]{if(!advanced){std::ofstream(changed)<<"progress";advanced=true;}});}
  catch(const std::exception&){rejected=true;}
  assert(rejected && fs::file_size(changed)==8);
  for(const auto &p:fs::directory_iterator(saves))assert(p.path().string().find(".nand-new-")==std::string::npos);
  // An interrupted prior process may leave a temporary file, including
  // one bearing a reused PID. A retry must preserve it and still succeed.
  const auto retry=saves/"retry.sav";
  const auto stale=retry.string()+".nand-new-"+std::to_string(getpid());
  std::ofstream(stale)<<"unfinished";
  nds_nand::prepare(retry,nds_nand::bytes(8),[]{});
  assert(fs::file_size(retry)==8388608 && fs::file_size(stale)==10);
  std::cout<<"PASS: actual Host NAND mount/sector I/O, high-LBA persistence, strict bounds, FF initialization, cancellation, existing-file protection and ordinary-save return\n";
 }
};
int main(){char path[]="/tmp/nds-host-nand-XXXXXX";assert(mkdtemp(path));try{HostTest::run(path);}catch(...){fs::remove_all(path);throw;}fs::remove_all(path);}
