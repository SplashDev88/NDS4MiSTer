// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
  static void discover(Host &h, uint16_t flags) {
    h.spi.response=[flags](uint32_t, uint16_t cmd, size_t i, uint16_t) {
      return uint16_t(cmd!=0x46 ? 0 : i==0 ? 0x4456 : i==1 ? flags : 0x5350);
    };
    h.initializeVideoMetadata();
  }
  static void cycle(Host &h, const std::vector<int> &order) {
    assert(h.cursor==order[0]);
    for(unsigned i=1;i<=order.size();++i){h.action(1);assert(h.cursor==order[i%order.size()]);}
    for(unsigned i=1;i<=order.size();++i){h.action(0);assert(h.cursor==order[(order.size()-i)%order.size()]);}
  }
  static std::string bytes(const fs::path &p) {
    std::ifstream f(p,std::ios::binary);return {std::istreambuf_iterator<char>(f),{}};
  }
  static void run(const fs::path &root) {
    const auto kit=root/"kit",sd=root/"sd";
    fs::create_directories(kit);fs::create_directories(sd);
    const std::string cfg("\x40\xe4\0\0\0\0\0\0\0\0\0\0\0\0\0\0",16);
    std::ofstream(kit/"NDS_v1.CFG",std::ios::binary).write(cfg.data(),cfg.size());
    Host h(kit.string(),(sd/"games/NDS").string(),sd);
    for(uint16_t flags : {uint16_t(0),uint16_t(1<<10),uint16_t(1<<2)}) {
      discover(h,flags);
      const auto status=h.status,live=h.liveStatus();
      h.cursor=0;h.draw();
      assert(h.osd_rows[2]==h.frame.renderRow(2,"",false,nds_osd::arrow_right));
      assert(h.osd_rows[5]==h.frame.renderRow(5," Display options            " + std::string(1,char(0x16)),false,nds_osd::arrow_right));
      std::vector<int> order{0,1,2};if(!(flags&(1<<2)))order.push_back(Host::ANALOG_CURSOR);
      order.insert(order.end(),{Host::DISPLAY_CURSOR,Host::LID_CURSOR,Host::RESET_CURSOR,Host::EXIT_CURSOR});
      cycle(h,order);
      for(int back : {2,3,5,4}) {
        // Reach the submenu only using the real public navigation path.
        while(h.cursor!=Host::DISPLAY_CURSOR)h.action(1);
        h.action(2);assert(h.display_menu && !h.system_menu && h.cursor==3);
        std::vector<int> sub{3,4,5,6,7};if(flags&(1<<10))sub.push_back(Host::DV_TARGET_CURSOR);sub.push_back(Host::EXIT_CURSOR);
        cycle(h,sub);
        h.action(6);assert(h.display_menu && !h.system_menu && h.cursor==3);
        h.action(9);assert(!h.browser); // Recent shortcut cannot open from submenu.
        h.draw();assert(h.osd_rows[15]==h.frame.renderRow(15,"            back",false,nds_osd::arrow_left));
        assert((h.mainMenuRow(Host::DV_TARGET_CURSOR)>=0)==bool(flags&(1<<10)));
        if(back==2){h.action(0);assert(h.cursor==Host::EXIT_CURSOR);}
        h.action(back);
        if(back==4){assert(!h.menu && !h.display_menu);h.action(4);assert(h.cursor==0);}
        else assert(h.menu && !h.display_menu && h.cursor==Host::DISPLAY_CURSOR);
      }
      assert(h.status==status && h.liveStatus()==live && bytes(kit/"NDS_v1.CFG")==cfg);
      // Main Right still opens the standard System page. Mapping is concise.
      h.action(6);assert(h.system_menu && !h.display_menu && h.cursor==0);
      h.action(1);h.action(2);assert(h.mapping_step==0);
      h.draw();
      assert(h.osd_rows[7]==h.frame.renderRow(7," Space/User: Skip"));
      assert(h.osd_rows[8]==h.frame.renderRow(8," Esc/OSD: Cancel"));
      for(int row : {10,12})assert(h.osd_rows[row]==h.frame.renderRow(row,""));
      h.boardButtons(0);h.boardButtons(1);h.boardButtons(0);
      assert(h.mapping_step<0 && h.system_menu && !h.display_menu);
      h.action(5);assert(!h.system_menu && h.cursor==0);
    }
    // Reach/edit every advanced setting, restore it, verify no disk writes.
    discover(h,1<<10);h.cursor=Host::DISPLAY_CURSOR;h.action(2);
    const auto initial=h.status;const auto touch=h.touch_rotation;
    for(int item : {3,4,5,6,7,Host::DV_TARGET_CURSOR}) {
      h.cursor=item;h.action(2);h.action(7);
      assert(h.status==initial && h.touch_rotation==touch && h.direct_video_crt);
    }
    assert(bytes(kit/"NDS_v1.CFG")==cfg && !fs::exists(kit/"NDS_video.cfg"));
    std::cout<<"PASS: real menu entry, wrap/skip, all return paths, OSD close, System/mapping, output-dependent rows, all advanced options and settings preservation\n";
  }
};
int main(){char path[]="/tmp/nds-display-menu-XXXXXX";assert(mkdtemp(path));HostTest::run(path);fs::remove_all(path);}
