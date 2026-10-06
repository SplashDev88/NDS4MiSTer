// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
  static void run(const fs::path &root) {
    fs::create_directories(root / "kit");
    fs::create_directories(root / "sd");
    std::ofstream(root / "sd/MiSTer.ini") << "[NDS]\nosd_rotate=2\n";
    std::ofstream(root / "kit/NDS_osd.cfg") << "0\n";
    Host host((root / "kit").string(), (root / "sd/games/NDS").string(), root / "sd");
    host.status=REQUIRED_STATUS | CRT_TIMING;
    assert(host.rotation==0);
    host.sendstatus();
    host.cursor=2;
    assert(((host.status>>5)&3)==2);
    host.draw();
    assert(host.osd_rows[3] == host.frame.renderRow(3, " CRT Screen:            Main", true, nds_osd::arrow_right));
    host.action(2); assert(((host.status>>5)&3)==3);
    host.draw();
    assert(host.osd_rows[3] == host.frame.renderRow(3, " CRT Screen:           Touch", true, nds_osd::arrow_right));
    host.action(2); assert(((host.status>>5)&3)==2);
    host.action(7); assert(((host.status>>5)&3)==3);
    host.status |= 1u<<7;
    host.draw();
    assert(host.osd_rows[3] == host.frame.renderRow(3, " CRT Screen:            Main", true, nds_osd::arrow_right));
    assert(host.osd_rows[12] == host.frame.renderRow(12, "", false, nds_osd::arrow_right));
    host.cursor=Host::LID_CURSOR; host.action(2); assert(host.lid_closed);
    host.saveSettings();
    Host restored((root / "kit").string(), (root / "sd/games/NDS").string(), root / "sd");
    assert(restored.status==host.status && (restored.status & CRT_TIMING));
  }
};
int main() {
  const auto root=fs::temp_directory_path() / ("nds-display-test-" + std::to_string(getpid()));
  HostTest::run(root);
  fs::remove_all(root);
  std::cout << "PASS: CRT menu physical screen labels, switch directions, saved selection and lid/reset spacing\n";
}
