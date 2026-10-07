// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
  static void osdRotation(Host &host, unsigned expected, bool message = false) {
    host.spi.history.clear();
    host.osd(true, message);
    const auto &transfer = host.spi.history.back();
    assert(transfer.select == Spi::OSD);
    assert(transfer.command == (message ? 0x49 : 0x41));
    assert(transfer.words == (std::vector<uint16_t>{0, 0, 0, 0, uint16_t(expected)}));
  }
  static void run(const fs::path &root) {
    fs::create_directories(root / "kit");
    fs::create_directories(root / "sd");
    std::ofstream(root / "sd/MiSTer.ini") << "[NDS]\nosd_rotate=2\n";
    std::ofstream(root / "kit/NDS_osd.cfg") << "0\n";
    Host host((root / "kit").string(), (root / "sd/games/NDS").string(), root / "sd");
    host.status=REQUIRED_STATUS | CRT_TIMING;
    host.sendstatus();
    host.cursor=2;
    assert(((host.status>>5)&3)==2);
    host.draw();
    assert(host.osd_rows[10] == host.frame.renderRow(10, " CRT Screen:            Main", true, nds_osd::arrow_right));
    assert(host.osd_rows[8] == host.frame.renderRow(8, "", false, nds_osd::arrow_right));
    assert(host.osd_rows[9] == host.frame.renderRow(9, " CRT Mode:                On", false, nds_osd::arrow_right));
    host.action(2); assert(((host.status>>5)&3)==3);
    host.draw();
    assert(host.osd_rows[10] == host.frame.renderRow(10, " CRT Screen:           Touch", true, nds_osd::arrow_right));
    host.action(2); assert(((host.status>>5)&3)==2);
    host.action(7); assert(((host.status>>5)&3)==3);
    host.status |= 1u<<7;
    host.draw();
    assert(host.osd_rows[10] == host.frame.renderRow(10, " CRT Screen:            Main", true, nds_osd::arrow_right));
    assert(host.osd_rows[12] == host.frame.renderRow(12, "", false, nds_osd::arrow_right));
    host.cursor=Host::LID_CURSOR; host.action(2); assert(host.lid_closed);
    host.saveSettings();
    Host restored((root / "kit").string(), (root / "sd/games/NDS").string(), root / "sd");
    assert(restored.status==host.status && (restored.status & CRT_TIMING));

    // Follow visual order in both directions, skip blank separators, wrap,
    // and retain the selected control when CRT mode changes the row order.
    const std::array<int, 12> crt_order{0, 1, 3, 4, 5, 6, 7, 8, 2, 9, 10, 11};
    host.cursor = 0;
    for (unsigned i = 1; i <= crt_order.size(); ++i) {
      host.action(1); assert(host.cursor == crt_order[i % crt_order.size()]);
    }
    for (unsigned i = 1; i <= crt_order.size(); ++i) {
      host.action(0); assert(host.cursor == crt_order[(crt_order.size() - i) % crt_order.size()]);
    }
    host.cursor = 8; host.action(2);
    assert(!(host.status & CRT_TIMING) && host.cursor == 8);
    host.draw();
    assert(host.osd_rows[9] == host.frame.renderRow(9, "", false, nds_osd::arrow_right));
    assert(host.osd_rows[10] == host.frame.renderRow(10, " CRT Mode:               Off", true, nds_osd::arrow_right));
    host.cursor = 0;
    for (int i = 1; i <= 12; ++i) { host.action(1); assert(host.cursor == i % 12); }
    for (int i = 1; i <= 12; ++i) { host.action(0); assert(host.cursor == (12 - i) % 12); }
    host.cursor = 8; host.action(2); host.action(1);
    assert(host.cursor == 2 && (host.status & CRT_TIMING));
    const auto before = host.status;
    host.action(2); assert((host.status ^ before) == (1u << 5));

    // INI and old forced-upright files must not override live video rotation.
    // Check normal menus, loading dialogs, each direction and invalid bits.
    for (unsigned mode : {0u, unsigned(CRT_TIMING)}) {
      host.status = REQUIRED_STATUS | mode;
      osdRotation(host, 0);
      host.cursor = 3; host.action(2);
      assert(((host.status >> 11) & 3) == 1);
      osdRotation(host, 3); osdRotation(host, 3, true);
      host.action(2);
      assert(((host.status >> 11) & 3) == 2);
      osdRotation(host, 1); osdRotation(host, 1, true);
      host.saveSettings();
      Host reloaded((root / "kit").string(), (root / "sd/games/NDS").string(), root / "sd");
      osdRotation(reloaded, 1);
      host.action(2); osdRotation(host, 0);
      host.status |= 3u << 11; osdRotation(host, 0);
    }
    // Touch Rotation corrects sideways games and must not turn the menu.
    host.status = REQUIRED_STATUS;
    host.cursor = Host::TOUCH_ROTATION_CURSOR; host.action(2);
    osdRotation(host, 0);
  }
};
int main() {
  const auto root=fs::temp_directory_path() / ("nds-display-test-" + std::to_string(getpid()));
  HostTest::run(root);
  fs::remove_all(root);
  std::cout << "PASS: grouped CRT menu, separator/navigation, saved screen selection, lid/reset spacing, live menu/loading rotation and legacy override isolation\n";
}
