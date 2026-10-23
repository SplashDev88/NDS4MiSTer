// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>

struct HostTest {
  static uint16_t packed(int x, int y) {
    return uint8_t(x) | (uint16_t(uint8_t(y)) << 8);
  }
  static void emit(int fd, unsigned type, unsigned code, int value) {
    input_event event{};
    event.type = type; event.code = code; event.value = value;
    assert(write(fd, &event, sizeof(event)) == sizeof(event));
  }
  static std::vector<uint16_t> last(const Host &h, unsigned command) {
    for (auto it = h.spi.history.rbegin(); it != h.spi.history.rend(); ++it)
      if (it->select == Spi::IO && it->command == command) return it->words;
    assert(false && "missing SPI transfer"); return {};
  }
  static void poll(Host &h) { errno = 0; h.inputs(); }
  static void run(const fs::path &root) {
    // Default is byte-identical across the entire coordinate domain.
    for (unsigned raw = 0; raw <= 65535; ++raw) {
      assert(expandTouchAnalog(raw, 0) == raw);
      assert(expandTouchAnalog(raw, 99) == raw);
    }
    // Increasing reach must never wrap or reverse direction, and center stays still.
    for (unsigned range = 0; range < TOUCH_RANGE_PERCENT.size(); ++range) {
      int previous = -129;
      for (int x = -128; x <= 127; ++x) {
        const auto raw = expandTouchAnalog(packed(x, 0), range);
        assert(!(raw >> 8));
        const int value = (raw & 255) < 128 ? raw & 255 : int(raw & 255) - 256;
        assert(value >= previous && value >= -128 && value <= 127);
        previous = value;
      }
      assert(expandTouchAnalog(0, range) == 0);
      assert(expandTouchAnalog(packed(-128,127), range) == packed(-128,127));
    }
    const auto kit = root / "kit", sd = root / "sd";
    fs::create_directories(kit);
    Host h(kit.string(), (sd / "games/NDS").string(), sd);
    assert(h.touch_range == 0 && !fs::exists(kit / "NDS_stick.cfg"));
    int fds[2]; assert(pipe(fds) == 0);
    fcntl(fds[0], F_SETFL, O_NONBLOCK);
    Pad p; p.fd = fds[0]; p.pad = true;
    p.abs[ABS_RX] = p.abs[ABS_RY] = {128,0,255,0,0,0};
    h.pads.push_back(p); h.menu = false;
    const auto sample = [&](int x, int y) {
      emit(fds[1], EV_ABS, ABS_RX, x);
      emit(fds[1], EV_ABS, ABS_RY, y);
      emit(fds[1], EV_SYN, SYN_REPORT, 0); poll(h);
      return last(h, 0x3d);
    };
    // A stick reaching only ~70% on each diagonal misses corners by default.
    assert(sample(218,218) == (std::vector<uint16_t>{0,packed(90,90)}));
    h.togglemenu(); h.cursor = Host::TOUCH_RANGE_CURSOR;
    h.action(2); h.action(2); assert(h.touch_range == 2); // 150%
    h.togglemenu();
    assert(last(h, 0x3d) == (std::vector<uint16_t>{0,packed(127,127)}));
    assert(h.pads[0].analog == packed(90,90)); // Gain is never stored in the raw cache.
    for (unsigned rotation = 0; rotation < 3; ++rotation) {
      h.touch_rotation = TouchRotation(rotation);
      for (int x : {-90,90}) for (int y : {-90,90}) {
        // Expected corners in screen coordinates, including both TATE corrections.
        int ex = x, ey = y;
        if (rotation == 1) { ex = y; ey = -x; }
        if (rotation == 2) { ex = -y; ey = x; }
        assert(sample(x+128,y+128) == (std::vector<uint16_t>{0,
            packed(ex < 0 ? -128 : 127, ey < 0 ? -128 : 127)}));
      }
    }
    h.touch_rotation = TouchRotation::Normal;
    h.touch_range = 4;
    assert(sample(192,64) == (std::vector<uint16_t>{0,packed(127,-128)}));
    // Legacy input dead zone survives maximum gain, with both even-range centers.
    for (int center : {124,127,128,131})
      assert(sample(center,center) == (std::vector<uint16_t>{0,0}));
    // Different driver ranges (signed and unsigned) still normalize first.
    for (const auto &limits : {std::pair<int,int>{-32768,32767}, {0,1023}}) {
      h.pads[0].abs[ABS_RX].minimum = h.pads[0].abs[ABS_RY].minimum = limits.first;
      h.pads[0].abs[ABS_RX].maximum = h.pads[0].abs[ABS_RY].maximum = limits.second;
      assert(sample(limits.first,limits.second) == (std::vector<uint16_t>{0,packed(-128,127)}));
      assert(sample((limits.first+limits.second)/2,(limits.first+limits.second)/2) ==
             (std::vector<uint16_t>{0,0}));
    }
    // Mouse deltas and pen/button mappings are independent of right-stick gain.
    emit(fds[1], EV_REL, REL_X, 30); emit(fds[1], EV_REL, REL_Y, -20);
    emit(fds[1], EV_KEY, BTN_LEFT, 1); emit(fds[1], EV_SYN, SYN_REPORT, 0); poll(h);
    assert(last(h,4) == (std::vector<uint16_t>{9,30,20}));
    h.key(h.pads[0], KEY_UP, true); h.key(h.pads[0], KEY_SPACE, true); poll(h);
    assert(h.lastjoy == (8 | 4096));
    emit(fds[1], EV_SYN, SYN_DROPPED, 0); poll(h);
    assert(last(h,0x3d) == (std::vector<uint16_t>{0,0}) && h.lastjoy == 0);
    close(fds[1]);

    h.togglemenu(); h.touch_range = 0;
    const auto status = h.status; const auto full_status = h.full_status;
    // The range is edited directly on both current and legacy root menus.
    for (bool independent : {false,true}) {
      h.independent_outputs_supported = independent;
      h.cursor = 0;
      for (int n=0; h.cursor != Host::TOUCH_RANGE_CURSOR && n<20; ++n) h.action(1);
      assert(h.cursor == Host::TOUCH_RANGE_CURSOR);
      h.action(2); assert(h.touch_range == 1 && !h.display_menu && !h.system_menu);
      h.action(7); assert(h.touch_range == 0);
      const int row = independent ? 6 : 2;
      h.draw();
      assert(h.osd_rows[row] == h.frame.renderRow(row,
          " Right Stick Range:     100%",true,nds_osd::arrow_right));
      h.action(9); assert(!h.browser);
      h.action(6); assert(h.system_menu); // Right still opens System.
      h.action(5); assert(!h.system_menu && h.cursor == 0);
    }
    h.independent_outputs_supported = false;
    h.cursor = Host::TOUCH_RANGE_CURSOR; h.spi.history.clear(); h.action(7);
    assert(h.touch_range == 4); h.action(8); assert(h.touch_range == 0);
    h.action(2); h.action(2); assert(h.touch_range == 2 && h.spi.history.empty());
    assert(h.status == status && h.full_status == full_status);
    assert(!fs::exists(kit / "NDS_stick.cfg")); // Explicit Save settings only.
    h.draw();
    assert(h.osd_rows[2] == h.frame.renderRow(2," Right Stick Range:     150%",true,nds_osd::arrow_right));
    h.action(6); h.cursor=3; h.action(2);
    { Host restored(kit.string(), (sd/"games/NDS").string(), sd); assert(restored.touch_range==2); }
    h.action(6); h.cursor=2; h.action(2); h.action(0); h.action(2);
    assert(h.touch_range==0);
    { Host restored(kit.string(), (sd/"games/NDS").string(), sd); assert(restored.touch_range==0); }
    for (const char *bad : {"", "NDS-StickRange-v1\n999999999\n", "NDS-StickRange-v2\n150\n",
                           "NDS-StickRange-v1\n150\nextra", "NDS-StickRange-v1\n-100\n"}) {
      std::ofstream(kit/"NDS_stick.cfg") << bad;
      Host invalid(kit.string(), (sd/"games/NDS").string(), sd); assert(invalid.touch_range==0);
    }
    std::cout << "PASS: default identity, monotonic/clamped reach, short-stick corners, rotation, "
                 "evdev ranges/dead zone, mouse/buttons, menu return, persistence/reset/fallback\n";
  }
};
int main() {
  char path[] = "/tmp/nds-touch-range-XXXXXX"; assert(mkdtemp(path));
  HostTest::run(path); fs::remove_all(path);
}
