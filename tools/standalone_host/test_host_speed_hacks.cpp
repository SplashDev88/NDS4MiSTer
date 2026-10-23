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
     absent.independent_outputs_supported=true;
     assert(absent.mainMenuRow(Host::SPEED_CURSOR)==-1);}
    std::ofstream(kit/"fmv/nsmb_hooks.json")<<"{}";
    Host h(kit.string(),(sd/"games/NDS").string(),sd);
    h.independent_outputs_supported=true;
    assert(h.speed_hacks==0 && h.mainMenuRow(Host::SPEED_CURSOR)==9);
    h.cursor=0;for(int i=0;i<20 && h.cursor!=Host::SPEED_CURSOR;++i)h.action(1);
    assert(h.cursor==Host::SPEED_CURSOR);
    h.action(2);assert(h.speed_menu && h.cursor==0);
    auto status=h.status;
    h.action(2);assert(h.speed_hacks==1);
    h.action(1);h.action(8);assert(h.speed_hacks==3);
    h.action(7);assert(h.speed_hacks==1);
    h.action(0);h.action(7);assert(h.speed_hacks==0);
    h.action(0);assert(h.cursor==Host::EXIT_CURSOR);
    h.action(1);assert(h.cursor==0);
    h.action(6);assert(h.speed_menu && !h.system_menu);
    h.action(9);assert(!h.browser);
    h.action(2);h.action(1);h.action(2);assert(h.speed_hacks==3);
    h.draw();
    assert(h.osd_rows[7]==h.frame.renderRow(7," Reload game to apply",false,nds_osd::arrow_left));
    h.action(3);assert(!h.speed_menu && h.cursor==Host::SPEED_CURSOR);
    h.action(2);h.action(5);assert(!h.speed_menu && h.cursor==Host::SPEED_CURSOR);
    h.action(2);h.action(4);assert(!h.speed_menu && !h.menu);
    assert(h.status==status && !fs::exists(kit/"NDS_speed.cfg"));
    h.saveSettings();
    {Host restored(kit.string(),(sd/"games/NDS").string(),sd);assert(restored.speed_hacks==3);}
    std::ofstream(kit/"NDS_speed.cfg")<<"NDS-SpeedHacks-v1\n99\n";
    {Host malformed(kit.string(),(sd/"games/NDS").string(),sd);assert(malformed.speed_hacks==0);}
    setenv("NDS_NSMB_PATCH","lookup",1);
    {Host forced(kit.string(),(sd/"games/NDS").string(),sd);assert(forced.speed_hacks==1);}
    unsetenv("NDS_NSMB_PATCH");
    std::cout<<"PASS: independent flags, navigation, pending-only behavior, save/reload and malformed defaults\n";
  }
};
int main(){char path[]="/tmp/nds-speed-hacks-XXXXXX";assert(mkdtemp(path));HostTest::run(path);fs::remove_all(path);}
