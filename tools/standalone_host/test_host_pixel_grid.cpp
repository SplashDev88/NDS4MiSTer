// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
  static void discover(Host &h, bool core=true, bool mode=true) {
    h.spi.response=[core,mode](uint32_t, uint16_t cmd, size_t i, uint16_t) {
      if(cmd==0x46) return uint16_t(i==0 ? 0x4456 : i==1 ? 0 : 0x5350);
      if(cmd==0x4a && core) return uint16_t(i==0 ? 0x5047 : 0x100 | unsigned(mode));
      return uint16_t(0);
    };
    h.initializeVideoMetadata();
  }
  static unsigned writes(const Host &h) {
    unsigned count=0;
    for(const auto &t:h.spi.history)
      if(t.command==0x4a && !t.words.empty() && (t.words[0]&0xfffc)==0x5040) ++count;
    return count;
  }
  static void run(const fs::path &root) {
    const auto kit=root/"kit",sd=root/"sd";
    fs::create_directories(kit);fs::create_directories(sd);
    {
      Host h(kit.string(),(sd/"games/NDS").string(),sd);
      assert(h.pixel_grid==0 && !h.pixel_grid_available);
      const auto status=h.full_status;
      discover(h,false); const auto previous=writes(h);
      assert(!h.pixel_grid_supported && h.mainMenuRow(Host::PIXEL_GRID_CURSOR)<0);
      h.sendPixelGrid();assert(writes(h)==previous); // Old FPGA never receives writes.
      discover(h);assert(h.pixel_grid_supported && h.pixel_grid_available);
      h.cursor=Host::DISPLAY_CURSOR;h.action(2);
      while(h.cursor!=Host::PIXEL_GRID_CURSOR)h.action(1);
      h.draw();
      assert(h.osd_rows[11]==h.frame.renderRow(11," Pixel Grid:             Off",true,nds_osd::arrow_left));
      h.action(1);assert(h.cursor==Host::EXIT_CURSOR);
      h.action(0);assert(h.cursor==Host::PIXEL_GRID_CURSOR);
      for(unsigned i=1;i<=4;++i) {
        const auto n=writes(h);h.action(2);
        assert(h.pixel_grid==i%4 && writes(h)==n+1);
        assert(h.spi.history.back().words==std::vector<uint16_t>{uint16_t(0x5040|h.pixel_grid)});
      }
      h.action(7);assert(h.pixel_grid==3);h.action(8);assert(h.pixel_grid==0);
      h.action(2);h.action(2);assert(h.pixel_grid==2 && h.full_status==status);
      assert(!fs::exists(kit/"NDS_pixel_grid.cfg"));
      h.action(5);h.action(6);h.cursor=3;h.action(2); // System > Save settings.
      assert(fs::exists(kit/"NDS_pixel_grid.cfg"));
    }
    {
      Host h(kit.string(),(sd/"games/NDS").string(),sd);
      assert(h.pixel_grid==2);discover(h,true,false);
      h.display_menu=true;
      assert(h.mainMenuRow(Host::PIXEL_GRID_CURSOR)<0); // DV/1440p hidden, preference retained.
      const auto n=writes(h);h.cursor=Host::PIXEL_GRID_CURSOR;h.action(2);
      assert(h.pixel_grid==2 && writes(h)==n);
      h.saveSettings();
    }
    {
      Host h(kit.string(),(sd/"games/NDS").string(),sd);
      assert(h.pixel_grid==2);discover(h);
      h.reset_confirm=true;h.cursor=0;h.action(2);
      assert(h.pixel_grid==0);
      bool off=false;
      for(const auto &t:h.spi.history)
        if(t.command==0x4a && t.words==std::vector<uint16_t>{0x5040}) off=true;
      assert(off);
    }
    {
      Host h(kit.string(),(sd/"games/NDS").string(),sd);assert(h.pixel_grid==0);
    }
    for(const std::string bad:{"", "NDS-PixelGrid-v1\n4\n", "NDS-PixelGrid-v1\n-1\n",
        "NDS-PixelGrid-v2\n2\n", "NDS-PixelGrid-v1\n2\nextra\n"}) {
      std::ofstream(kit/"NDS_pixel_grid.cfg",std::ios::binary)<<bad;
      Host h(kit.string(),(sd/"games/NDS").string(),sd);assert(h.pixel_grid==0);
    }
    std::cout<<"PASS: Pixel Grid capability, real menu navigation, four strengths, SPI isolation, explicit save, reload, reset, unsupported modes and malformed settings\n";
  }
};
int main(){char path[]="/tmp/nds-pixel-grid-XXXXXX";assert(mkdtemp(path));HostTest::run(path);fs::remove_all(path);}
