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
    event.type = type;
    event.code = code;
    event.value = value;
    assert(write(fd, &event, sizeof(event)) == sizeof(event));
  }
  static void poll(Host &host) { errno = 0; host.inputs(); }
  static std::vector<uint16_t> last(const Host &host, unsigned command) {
    for (auto it = host.spi.history.rbegin(); it != host.spi.history.rend(); ++it)
      if (it->select == Spi::IO && it->command == command) return it->words;
    assert(false && "expected input SPI command");
    return {};
  }
  static void run(const fs::path &root) {
    const auto kit = root / "kit", sd = root / "sd";
    fs::create_directories(kit);
    Host host(kit.string(), (sd / "games/NDS").string(), sd);
    assert(host.touch_rotation == TouchRotation::Normal);
    assert(!fs::exists(kit / "NDS_touch.cfg"));
    int fds[2];
    assert(pipe(fds) == 0);
    fcntl(fds[0], F_SETFL, O_NONBLOCK);
    Pad pad;
    pad.fd = fds[0];
    pad.right_x = ABS_RX;
    pad.right_y = ABS_RY;
    pad.abs[ABS_RX] = pad.abs[ABS_RY] = {128, 0, 255, 0, 0, 0};
    host.pads.push_back(pad);
    host.menu = false;
    // Independent, explicit expectations in screen coordinates: up/down/left/right.
    const std::array<std::pair<int, int>, 4> input{{{0,-64},{0,64},{-64,0},{64,0}}};
    const std::array<std::array<std::pair<int, int>, 4>, 3> expected{{
        input,
        {{{-64,0},{64,0},{0,64},{0,-64}}},
        {{{64,0},{-64,0},{0,-64},{0,64}}}
    }};
    for (unsigned video = 0; video < 3; ++video) {
      host.status = REQUIRED_STATUS | (video << 11);
      const auto status = host.status;
      for (unsigned rotation = 0; rotation < 3; ++rotation) {
        host.touch_rotation = TouchRotation(rotation);
        for (unsigned d = 0; d < input.size(); ++d) {
          const auto [x, y] = input[d];
          const auto [ex, ey] = expected[rotation][d];
          host.spi.history.clear();
          emit(fds[1], EV_ABS, ABS_RX, x + 128);
          emit(fds[1], EV_ABS, ABS_RY, y + 128);
          emit(fds[1], EV_SYN, SYN_REPORT, 0);
          poll(host);
          assert(last(host, 0x3d) == (std::vector<uint16_t>{0, packed(ex, ey)}));
          assert(host.pads[0].analog == packed(x, y)); // Never rotate cached raw input twice.
          host.spi.history.clear();
          emit(fds[1], EV_REL, REL_X, x);
          emit(fds[1], EV_REL, REL_Y, y);
          emit(fds[1], EV_KEY, BTN_LEFT, 1);
          emit(fds[1], EV_SYN, SYN_REPORT, 0);
          poll(host);
          assert(last(host, 4) == (std::vector<uint16_t>{
              uint16_t(9 | (ex < 0 ? 16 : 0) | (-ey < 0 ? 32 : 0)),
              uint8_t(ex), uint8_t(-ey)}));
          assert(host.status == status);
        }
      }
    }
    // Reproduce the reported game orientation: native up appears left.
    // CW correction sends right for an up input; the sideways game maps right to up.
    host.touch_rotation = TouchRotation::Clockwise;
    emit(fds[1], EV_ABS, ABS_RX, 128);
    emit(fds[1], EV_ABS, ABS_RY, 64);
    poll(host);
    assert(last(host, 0x3d) == (std::vector<uint16_t>{0, packed(64, 0)}));
    host.togglemenu();
    host.spi.history.clear();
    emit(fds[1], EV_ABS, ABS_RX, 0);
    emit(fds[1], EV_ABS, ABS_RY, 128);
    poll(host);
    for (const auto &transfer : host.spi.history) assert(transfer.command != 0x3d);
    host.togglemenu();
    assert(last(host, 0x3d) == (std::vector<uint16_t>{0, packed(0, -128)}));
    emit(fds[1], EV_ABS, ABS_RY, 0);
    poll(host);
    assert(last(host, 0x3d) == (std::vector<uint16_t>{0, packed(127, -128)}));
    emit(fds[1], EV_ABS, ABS_RX, 128);
    emit(fds[1], EV_ABS, ABS_RY, 128);
    poll(host);
    assert(last(host, 0x3d) == (std::vector<uint16_t>{0, 0}));
    emit(fds[1], EV_REL, REL_X, 2000);
    emit(fds[1], EV_REL, REL_Y, -2000);
    emit(fds[1], EV_KEY, BTN_LEFT, 0);
    emit(fds[1], EV_SYN, SYN_REPORT, 0);
    poll(host);
    assert(last(host, 4) == (std::vector<uint16_t>{40, 127, uint8_t(-127)}));
    // Game/menu D-pad, touch press and microphone remain in their original slots.
    host.key(host.pads[0], KEY_UP, true);
    host.key(host.pads[0], KEY_SPACE, true);
    host.key(host.pads[0], KEY_F11, true);
    poll(host);
    assert(host.lastjoy == (8 | 4096 | Host::MIC_MASK));
    emit(fds[1], EV_SYN, SYN_DROPPED, 0);
    poll(host);
    assert(last(host, 0x3d) == (std::vector<uint16_t>{0, 0}));
    assert(!host.lastjoy);
    close(fds[1]);

    host.togglemenu();
    host.touch_rotation = TouchRotation::Normal;
    host.cursor = Host::TOUCH_ROTATION_CURSOR;
    const auto status = host.status;
    const auto full_status = host.full_status;
    host.spi.history.clear();
    host.action(2);
    assert(host.touch_rotation == TouchRotation::Counterclockwise);
    host.action(8);
    assert(host.touch_rotation == TouchRotation::Clockwise);
    host.action(2);
    assert(host.touch_rotation == TouchRotation::Normal);
    host.action(7);
    assert(host.touch_rotation == TouchRotation::Clockwise);
    assert(host.spi.history.empty()); // Host option never resets/reconfigures FPGA.
    assert(host.status == status && host.full_status == full_status);
    assert(!fs::exists(kit / "NDS_touch.cfg"));
    host.draw();
    assert(host.osd_rows[5] == host.frame.renderRow(5, " Touch Rotation:       90 CW", true, nds_osd::arrow_right));
    assert(host.osd_rows[11] == host.frame.renderRow(11, "", false, nds_osd::arrow_right));
    host.saveSettings();
    {
      Host restored(kit.string(), (sd / "games/NDS").string(), sd);
      assert(restored.touch_rotation == TouchRotation::Clockwise && restored.status == status);
    }
    // Reset settings restores native input and persists it without a core reset.
    host.system_menu = true;
    host.cursor = 2;
    host.action(2);
    host.action(0);
    host.action(2);
    assert(host.touch_rotation == TouchRotation::Normal);
    {
      Host restored(kit.string(), (sd / "games/NDS").string(), sd);
      assert(restored.touch_rotation == TouchRotation::Normal);
    }
    std::ofstream(kit / "NDS_touch.cfg") << "NDS-TouchRotation-v1\ninvalid\n";
    Host invalid(kit.string(), (sd / "games/NDS").string(), sd);
    assert(invalid.touch_rotation == TouchRotation::Normal);
    std::cout << "PASS: touch rotation actual evdev/SPI in all video orientations, "
                 "Ninja Gaiden direction correction, mouse buttons/signs/clamping, "
                 "analog endpoints/center/menu restore, game buttons/mic/drop isolation, "
                 "menu cycling/spacing, save/reload/reset and invalid settings\n";
  }
};

int main() {
  char directory[] = "/tmp/nds-touch-rotation-XXXXXX";
  assert(mkdtemp(directory));
  HostTest::run(directory);
  fs::remove_all(directory);
}
