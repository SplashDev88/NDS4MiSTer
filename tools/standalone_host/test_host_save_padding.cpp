// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>

struct HostTest {
  static std::string bytes(const fs::path &path) {
    std::ifstream in(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>()};
  }
  static void write(const fs::path &path, const std::string &data) {
    std::ofstream(path, std::ios::binary).write(data.data(), data.size());
  }
  static uint64_t mounted(Host &h) {
    for (auto it = h.spi.history.rbegin(); it != h.spi.history.rend(); ++it)
      if (it->select == Spi::IO && it->command == 0x1d) {
        assert(it->words.size() == 4);
        uint64_t size = 0;
        for (unsigned i = 0; i < 4; ++i) size |= uint64_t(it->words[i]) << (16*i);
        return size;
      }
    assert(false); return 0;
  }
  static void run(const fs::path &root, const char *fixture) {
    fs::create_directories(root/"kit");
    Host h((root/"kit").string(), (root/"games").string(), root);
    const auto path = root/"saves/NDS/Dawn.sav";
    std::string original(65536, char(0xff));
    for (size_t i = 0; i < 8192; ++i) original[i] = char(i*37);
    if (fixture) { original = bytes(fixture); assert(original.size() == 65536); }
    write(path, original);
    h.mount("Dawn.nds", nds_save_profile::lookup(0x45564341));
    assert(mounted(h) == 8192 && h.save_sector_limit == 16);
    assert(bytes(path) == original); // Mount never trims or rewrites a save.

    unsigned op = 1, lba = 0;
    std::vector<uint16_t> readback;
    h.spi.response = [&](uint32_t select, uint16_t cmd, size_t pos, uint16_t data)->uint16_t {
      assert(select == Spi::IO);
      if (cmd == 0x16) {
        if (pos == 0) return uint16_t(0x8080 | op);
        if (pos == 2) return uint16_t(lba);
        if (pos == 3) return uint16_t(lba >> 16);
      }
      if (cmd == 0x17 && pos) readback.push_back(data);
      if (cmd == 0x18 && pos) return uint16_t(0xa500 | (pos-1));
      return 0;
    };
    assert(h.sector() && readback.size() == 256);
    assert(memcmp(readback.data(), original.data(), 512) == 0);
    op = 2; lba = 15; assert(h.sector());
    const auto saved = bytes(path);
    assert(saved.size() == original.size() && saved.substr(8192) == original.substr(8192));
    assert(saved.substr(0,7680) == original.substr(0,7680));
    for (unsigned i=0;i<256;++i) {
      assert(uint8_t(saved[7680+2*i]) == uint8_t(i));
      assert(uint8_t(saved[7681+2*i]) == 0xa5);
    }
    lba = 16; bool rejected=false;
    try { h.sector(); } catch (const std::exception &) { rejected=true; }
    assert(rejected && bytes(path) == saved); // Never write into the padding.
    h.spi.response = {};
    h.mount("Dawn.nds",2); assert(mounted(h)==8192 && bytes(path)==saved);
    std::array<char,512> last{};
    assert(pread(h.save,last.data(),last.size(),7680)==512);
    assert(memcmp(last.data(),saved.data()+7680,512)==0); // Real file reopen.

    const int previous = h.save;
    const auto bad = root/"saves/NDS/Bad.sav";
    for (unsigned offset : {8192u, 65535u}) {
      auto data=original; data[offset]=0;
      write(bad,data); h.spi.history.clear(); rejected=false;
      try { h.mount("Bad.nds",2); } catch(const std::exception &e) {
        rejected=std::string(e.what()).find("original file preserved")!=std::string::npos;
      }
      assert(rejected && h.save==previous && h.spi.history.empty() && bytes(bad)==data);
    }
    for (size_t length : {size_t(1),size_t(512),size_t(8191),size_t(1048577)}) {
      const std::string data(length,char(0xff)); write(bad,data); rejected=false;
      try {h.mount("Bad.nds",2);} catch(const std::exception &){rejected=true;}
      assert(rejected && h.save==previous && bytes(bad)==data);
    }
    // Existing supported formats retain their exact wire protocol.
    write(bad,std::string(8192,char(0x61)));h.mount("Bad.nds",3);
    assert(mounted(h)==8192 && h.save_sector_limit==128);
    for (uint8_t type=1;type<=7;++type) {
      const auto size=nds_cartridge_save::capacity(type);
      write(bad,std::string(size,char(0x42)));h.mount("Bad.nds",type);
      assert(mounted(h)==size && h.save_sector_limit==size/512);
      write(bad,"");h.mount("Bad.nds",type);assert(mounted(h)==0);
    }
    write(bad,original);
    unsigned calls=0; rejected=false;
    try { nds_cartridge_save::mountedSize(h.save,original.size(),2,[&]{++calls;throw std::runtime_error("interrupted");}); }
    catch(const std::exception &){rejected=true;}
    assert(rejected && calls==1 && bytes(bad)==original);
    rejected=false;
    try {nds_cartridge_save::mountedSize(-1,65536,2,[]{});}catch(const std::exception &){rejected=true;}
    assert(rejected);
    // The real game loader must reject ambiguous data before releasing the
    // guest CPUs, rather than booting a game whose saving cannot work.
    fs::create_directories(root/"games");
    std::string rom(512,0);rom.replace(12,4,"ACVE");
    write(root/"games/Bad.nds",rom);
    auto ambiguous=original;ambiguous.back()=0;
    write(bad,ambiguous);h.spi.history.clear();rejected=false;
    try {h.load((root/"games/Bad.nds").string());}
    catch(const std::exception &e) {
      rejected=std::string(e.what()).find("Extra save data")!=std::string::npos;
    }
    assert(rejected && h.game.empty() && bytes(bad)==ambiguous);
    for(const auto &t:h.spi.history)
      assert(!(t.select==Spi::IO && t.command==0x45 &&
               !t.words.empty() && t.words[0]==3));
    write(bad,original);h.load((root/"games/Bad.nds").string());
    assert(h.game==root/"games/Bad.nds" && mounted(h)==8192 && bytes(bad)==original);
    std::cout << "PASS: padded Dawn mount, persisted writes and reopen, tail preservation, bounds, malformed saves, exact/empty capacities, short migration and read/interruption failures\n";
  }
};
int main(int argc,char **argv) {
  char path[]="/tmp/nds-save-padding-XXXXXX"; assert(mkdtemp(path));
  try { HostTest::run(path,argc>1?argv[1]:nullptr); }
  catch (...) {fs::remove_all(path);throw;}
  fs::remove_all(path);
}
