// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
  static void run(const fs::path &root) {
    auto kit=root/"kit", sd=root/"sd";
    fs::create_directories(kit/"fmv");fs::create_directories(sd);
    unsetenv("NDS_NSMB_PATCH");
    {Host absent(kit.string(),(sd/"games/NDS").string(),sd);
     assert(!absent.speed_hacks_available && absent.speed_hacks==0);}
    std::ofstream(kit/"fmv/nsmb_hooks.json")<<"{}";
    std::ofstream(kit/"NDS_speed.cfg")<<"NDS-SpeedHacks-v1\n5\n";
    Host h(kit.string(),(sd/"games/NDS").string(),sd);
    assert(h.speed_hacks_available && h.speed_hacks==5);
    const auto status=h.status;
    // Installed hooks and enabled defaults must not add another menu page.
    h.independent_outputs_supported=true;
    const std::vector<int> order{0,1,2,Host::ANALOG_CURSOR,Host::DISPLAY_CURSOR,
      Host::TOUCH_RANGE_CURSOR,Host::LID_CURSOR,Host::RESET_CURSOR,Host::EXIT_CURSOR};
    h.cursor=0;
    for(unsigned i=1;i<=order.size();++i){h.action(1);assert(h.cursor==order[i%order.size()]);}
    for(unsigned i=1;i<=order.size();++i){h.action(0);assert(h.cursor==order[(order.size()-i)%order.size()]);}
    h.draw();
    assert(h.osd_rows[6]==h.frame.renderRow(6,"",false,nds_osd::arrow_right));
    assert(h.mainMenuRow(17)==-1);
    h.cursor=Host::DISPLAY_CURSOR;h.action(2);
    assert(h.display_menu && !h.system_menu);h.action(3);
    assert(!h.display_menu && h.cursor==Host::DISPLAY_CURSOR);
    h.action(6);assert(h.system_menu);h.action(5);assert(!h.system_menu);
    assert(h.status==status && h.speed_hacks==5);
    // The internal preset, developer override and saved configuration still work.
    for(unsigned mask=0;mask<Host::SPEED_MODES.size();++mask){
      h.speed_hacks=mask;h.saveSettings();
      Host restored(kit.string(),(sd/"games/NDS").string(),sd);
      assert(restored.speed_hacks==mask);
      setenv("NDS_NSMB_PATCH",Host::SPEED_MODES[mask],1);
      Host forced(kit.string(),(sd/"games/NDS").string(),sd);
      assert(forced.speed_hacks==mask);
      unsetenv("NDS_NSMB_PATCH");
    }
    std::ofstream(kit/"NDS_speed.cfg")<<"NDS-SpeedHacks-v1\n99\n";
    {Host malformed(kit.string(),(sd/"games/NDS").string(),sd);assert(malformed.speed_hacks==0);}
    std::cout<<"PASS: no speed submenu with hooks enabled; navigation, preset, save/reload and overrides preserved\n";
  }
};
int main(){char path[]="/tmp/nds-speed-hacks-XXXXXX";assert(mkdtemp(path));HostTest::run(path);fs::remove_all(path);}
