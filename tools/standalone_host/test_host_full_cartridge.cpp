// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include "test_rom_fixture.h"
#include <cassert>
#include <iostream>

struct HostTest {
  static void run(const fs::path &root) {
    const auto sd=root/"sd", kit=root/"kit", roms=sd/"games/NDS";
    fs::create_directories(kit);fs::create_directories(roms);
    RomMapping::test_iomem_path=(root/"iomem").string();
    std::ofstream(RomMapping::test_iomem_path)<<"00000000-1fefffff : System RAM\n";
    const auto path=roms/"full.nds";
    const auto tail=RomReader::max_transfer_size;
    largeRomFixture(path.c_str(),tail+37);
    romFixtureByte(path.c_str(),tail,0x5a);
    romFixtureByte(path.c_str(),tail+36,0x81);
    Host h(kit.string(),roms.string(),sd);running=1;
    h.spi.default_firmware_flags|=0x4000;
    bool rejected=false;
    try {h.load(path.string());}
    catch(const std::exception&e){rejected=std::string(e.what()).find("FF padding")!=std::string::npos;}
    assert(rejected && h.game.empty());
    for(const auto&t:h.spi.history)assert(t.select!=Spi::FIO);
    assert(!fs::exists(sd/"saves/NDS/full.sav"));
    // A capable FPGA that has not acknowledged the final tail cannot boot
    // or create a save, even after every host byte was sent.
    h.spi.history.clear();h.spi.default_firmware_flags|=0x8000;
    rejected=false;
    try {h.load(path.string());}
    catch(const std::exception&e){rejected=std::string(e.what()).find("SDRAM upload incomplete")!=std::string::npos;}
    assert(rejected && h.game.empty() && !fs::exists(sd/"saves/NDS/full.sav"));
    h.spi.history.clear();h.spi.default_firmware_flags|=0x2000;
    h.load(path.string());
    assert(h.game==path && !h.menu && fs::exists(sd/"saves/NDS/full.sav"));
    uint16_t index=0;uint64_t uploaded=0;unsigned releases=0,tail_starts=0;
    for(const auto&t:h.spi.history){
      if(t.select==Spi::FIO && t.command==0x55)index=t.words.at(0);
      if(t.select==Spi::FIO && t.command==0x53 && index==0xf03 && t.words.at(0)==255){
        // These words are the hps_io write address, not the file length.
        assert((t.words==std::vector<uint16_t>{255,0,0}));++tail_starts;
      }
      if(t.select==Spi::FIO && t.command==0x54 && index==0xf03){
        for(const auto word:t.words){
          const auto expected=uploaded==0?0xff5a:uploaded==36?0xff81:0xffff;
          assert(word==expected);uploaded+=2;
        }
      }
      if(t.select==Spi::IO && t.command==0x45 && !t.words.empty() && t.words[0]==3)++releases;
    }
    assert(uploaded==48*RomLayout::mib && releases==1 && tail_starts==1 && RomMapping::test_live_mappings==0);
    assert(fs::file_size(path)==tail+37);
    // A normal large padded ROM on the new core retains the existing DDR
    // protocol and sends no cartridge bytes over the slow SPI path.
    largeRomFixture(path.c_str(),RomReader::max_file_size);
    h.spi.history.clear();h.load(path.string());index=0;uploaded=0;
    bool old_mode=false;
    for(const auto&t:h.spi.history){
      if(t.select==Spi::FIO && t.command==0x55){index=t.words.at(0);old_mode|=index==0xb03;}
      if(t.select==Spi::FIO && t.command==0x54 && (index&63)==3)uploaded+=t.words.size()*2;
    }
    assert(old_mode && !uploaded);
    std::cout<<"PASS: full cartridge capability gate, failed SDRAM commit preserves save, exact odd tail, FF clearing, one release, ordinary DDR path unchanged\n";
  }
};
int main(){char root[]="/tmp/nds-full-cart-XXXXXX";assert(mkdtemp(root));HostTest::run(root);fs::remove_all(root);}
