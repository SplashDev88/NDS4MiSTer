// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>

// Consumer model of the shipped rc12 arbiter, independent of host routing.
// SPI writes arrive separately; a mouse packet always wins ownership, while
// analog changes and a joystick Touch rising edge select the right stick.
struct TouchCore {
  bool mouse = false, joystick_down = false, mouse_down = false;
  uint16_t analog = 0;
  int mx = 128, my = 128;
  void consume(const std::vector<Spi::Transaction> &transfers) {
    for (const auto &t : transfers) {
      if (t.select != Spi::IO) continue;
      if (t.command == 2) {
        const bool down = t.words.at(0) & 4096;
        if (down && !joystick_down) mouse = false;
        joystick_down = down;
      } else if (t.command == 0x3d) {
        if (t.words.at(1) != analog) mouse = false;
        analog = t.words.at(1);
      } else if (t.command == 4) {
        mx = std::clamp(mx + int(int8_t(t.words.at(1))), 0, 255);
        my = std::clamp(my - int(int8_t(t.words.at(2))), 0, 255);
        mouse_down = t.words.at(0) & 1;
        mouse = true;
      }
    }
  }
  bool down() const { return mouse ? mouse_down : joystick_down; }
  int x() const { return mouse ? mx : int(int8_t(analog & 255)) + 128; }
  int y() const { return mouse ? my : int(int8_t(analog >> 8)) + 128; }
};

struct HostTest {
  static void emit(int fd, unsigned type, unsigned code, int value) {
    input_event event{}; event.type = type; event.code = code; event.value = value;
    assert(write(fd, &event, sizeof(event)) == sizeof(event));
  }
  static void run(const fs::path &root, bool mouse_first) {
    const auto kit = root / "kit", sd = root / "sd";
    fs::create_directories(kit);
    Host h(kit.string(), (sd / "games/NDS").string(), sd);
    int panel[2], mouse[2], second[2];
    assert(pipe(panel) == 0 && pipe(mouse) == 0 && pipe(second) == 0);
    for (int fd : {panel[0], mouse[0], second[0]}) fcntl(fd, F_SETFL, O_NONBLOCK);
    Pad pad; pad.fd = panel[0]; pad.id = "045e_028e";
    pad.path = (root / "panel").string(); std::ofstream(pad.path).put('x');
    pad.map[12] = BTN_THUMBR;
    // First reproduce an arcade panel with no right stick.
    Pad pointer; pointer.fd = mouse[0]; pointer.id = "13ba_0018";
    pointer.path = (root / "mouse").string(); std::ofstream(pointer.path).put('x');
    if (mouse_first) h.pads = {pointer, pad}; else h.pads = {pad, pointer};
    Pad pointer2; pointer2.fd = second[0];
    pointer2.path = (root / "mouse2").string(); std::ofstream(pointer2.path).put('x');
    h.pads.push_back(pointer2);
    h.menu = false; h.spi.history.clear();
    TouchCore core;
    const auto consume = [&] { core.consume(h.spi.history); h.spi.history.clear(); };
    const auto poll = [&] { errno = 0; h.inputs(); consume(); };
    const auto event = [&](int fd, unsigned type, unsigned code, int value) {
      emit(fd, type, code, value); emit(fd, EV_SYN, SYN_REPORT, 0); poll();
    };
    event(mouse[1], EV_REL, REL_X, 45);
    event(mouse[1], EV_REL, REL_Y, -30);
    assert(!core.down() && core.x() == 173 && core.y() == 98);
    event(panel[1], EV_KEY, BTN_THUMBR, 1);
    assert(core.down() && core.x() == 173 && core.y() == 98);
    assert(!(h.lastjoy & 4096));
    event(mouse[1], EV_REL, REL_X, -20);
    assert(core.down() && core.x() == 153 && core.y() == 98);
    event(panel[1], EV_KEY, BTN_THUMBR, 0);
    assert(!core.down() && core.x() == 153);

    // Physical mouse and mapped Touch release independently, including two mice.
    event(mouse[1], EV_KEY, BTN_LEFT, 1);
    event(panel[1], EV_KEY, BTN_THUMBR, 1);
    event(panel[1], EV_KEY, BTN_THUMBR, 0); assert(core.down());
    event(second[1], EV_KEY, BTN_LEFT, 1);
    event(mouse[1], EV_KEY, BTN_LEFT, 0); assert(core.down());
    event(second[1], EV_KEY, BTN_LEFT, 0); assert(!core.down());
    event(panel[1], EV_KEY, BTN_THUMBR, 1);
    event(mouse[1], EV_KEY, BTN_LEFT, 1);
    event(mouse[1], EV_KEY, BTN_LEFT, 0); assert(core.down());

    // Right-stick movement takes over even during a mapped-button drag.
    auto &p = h.pads[mouse_first ? 1 : 0];
    p.abs[ABS_RX] = p.abs[ABS_RY] = {128, 0, 255, 0, 0, 0};
    event(panel[1], EV_ABS, ABS_RX, 208);
    assert(core.down() && !core.mouse && core.x() == 208 && core.y() == 128);
    event(panel[1], EV_KEY, BTN_THUMBR, 0); assert(!core.down());
    event(panel[1], EV_KEY, BTN_THUMBR, 1); assert(core.down() && core.x() == 208);
    event(mouse[1], EV_REL, REL_Y, 10);
    assert(core.down() && core.mouse && core.x() == 153 && core.y() == 108);
    event(panel[1], EV_ABS, ABS_RX, 208); // unchanged reports must not take over
    assert(core.down() && core.mouse);
    event(panel[1], EV_KEY, BTN_THUMBR, 0); assert(!core.down());

    // Dead-zone jitter and gain-clamped changes do not move the FPGA stick.
    event(panel[1], EV_ABS, ABS_RX, 128);
    event(mouse[1], EV_KEY, BTN_LEFT, 1); event(mouse[1], EV_KEY, BTN_LEFT, 0);
    event(panel[1], EV_ABS, ABS_RX, 129); assert(core.mouse);
    h.touch_range = 4;
    event(panel[1], EV_ABS, ABS_RX, 208);
    event(mouse[1], EV_KEY, BTN_LEFT, 1); event(mouse[1], EV_KEY, BTN_LEFT, 0);
    event(panel[1], EV_ABS, ABS_RX, 220); assert(core.mouse);

    // Menu entry releases synthetic touch; closing preserves the mouse position.
    event(panel[1], EV_KEY, BTN_THUMBR, 1);
    h.togglemenu(); consume(); assert(!core.down());
    event(panel[1], EV_KEY, BTN_THUMBR, 0); assert(!core.down());
    h.togglemenu(); consume(); poll(); assert(!core.down());
    event(panel[1], EV_KEY, BTN_THUMBR, 1);
    assert(core.down() && core.x() == 153 && core.y() == 108);
    event(panel[1], EV_SYN, SYN_DROPPED, 0); assert(!core.down());
    event(mouse[1], EV_REL, REL_X, 1);
    event(panel[1], EV_KEY, BTN_THUMBR, 1); assert(core.down() && core.x() == 154);
    h.clearConsoleInputs(); consume(); poll(); assert(!core.down());

    // A real mouse click (without motion) also owns the hardware cursor.
    event(panel[1], EV_ABS, ABS_RX, 220);
    event(mouse[1], EV_KEY, BTN_LEFT, 1);
    event(mouse[1], EV_KEY, BTN_LEFT, 0);
    event(panel[1], EV_KEY, BTN_THUMBR, 1);
    assert(core.down() && core.mouse && core.x() == 154);
    // Remove the held-button device: no stuck synthesized mouse press.
    p.disconnected = true;
    const auto empty = root / "empty-input"; fs::create_directories(empty);
    h.scan(empty); consume(); poll(); assert(!core.down());
    assert(h.pads.size() == 2);
    close(panel[1]); close(mouse[1]); close(second[1]);
  }
};
int main() {
  char path[] = "/tmp/nds-touch-mouse-XXXXXX"; assert(mkdtemp(path));
  HostTest::run(fs::path(path) / "panel-first", false);
  HostTest::run(fs::path(path) / "mouse-first", true);
  fs::remove_all(path);
  std::cout << "PASS: issue 43 arcade panel + trackball, dragging, independent mouse buttons, "
               "both evdev orders, right-stick takeover, stationary reports, menu/reset/drop/disconnect\n";
}
