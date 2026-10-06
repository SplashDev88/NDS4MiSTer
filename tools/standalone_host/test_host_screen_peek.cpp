// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>

struct HostTest {
  static std::string bytes(const fs::path &path) {
    std::ifstream f(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(f), {});
  }
  static size_t statusWrites(const Host &h) {
    return std::count_if(h.spi.history.begin(), h.spi.history.end(), [](const auto &t) {
      return t.select == Spi::IO && t.command == 0x1e;
    });
  }
  static uint16_t wireStatus(const Host &h) {
    for (auto i = h.spi.history.rbegin(); i != h.spi.history.rend(); ++i)
      if (i->select == Spi::IO && i->command == 0x1e) {
        assert(i->words.size() == 8);
        for (unsigned n = 1; n < 8; ++n) assert(i->words[n] == h.full_status[n]);
        return i->words[0];
      }
    assert(false && "No status sent to FPGA");
    return 0;
  }
  static void key(Host &h, unsigned pad, int code, bool down) {
    h.key(h.pads[pad], code, down);
    errno = 0;
    h.inputs();
  }
  static void run(const fs::path &root) {
    const auto kit = root / "kit", sd = root / "sd";
    fs::create_directories(kit / "inputs");
    fs::create_directories(sd / "config/inputs");
    Host h(kit.string(), (sd / "games/NDS").string(), sd);
    for (unsigned n = 0; n < 2; ++n) {
      Pad p;
      p.id = "peek" + std::to_string(n);
      p.fd = open("/dev/null", O_RDONLY);
      p.map[4] = BTN_SOUTH;
      p.map[13] = BTN_TR;
      p.map[14] = BTN_TL; // Old lid slot must remain ignored.
      p.map[16] = BTN_THUMBL | (uint32_t(BTN_THUMBR) << 16);
      h.pads.push_back(p);
    }
    h.menu = false;
    h.full_status[3] = 0x1234;
    h.full_status[7] = 0xbeef;

    // Every single-panel variant keeps unrelated display fields, held DS
    // buttons and all 128 status bits; a peek never writes persistent settings.
    for (unsigned crt : {0u, unsigned(CRT_TIMING)})
      for (unsigned layout : {2u, 3u})
        for (unsigned order : {0u, 1u << 7})
          for (unsigned rotation : {0u, 1u, 2u}) {
            h.status = REQUIRED_STATUS | crt | (layout << 5) | order | (rotation << 11);
            h.saveSettings();
            const auto selected = h.status;
            const auto saved = bytes(kit / "NDS_v1.CFG");
            const auto full = h.full_status;
            h.sendstatus();
            key(h, 0, BTN_SOUTH, true);
            const auto count = statusWrites(h);
            key(h, 0, BTN_THUMBL, true);
            assert(wireStatus(h) == (selected ^ 32));
            assert(h.status == selected && h.full_status == full && h.lastjoy == 16);
            assert(statusWrites(h) == count + 1);
            key(h, 0, BTN_THUMBL, true); // Repeats and polling add no SPI traffic.
            key(h, 0, BTN_THUMBR, true);
            key(h, 0, BTN_THUMBL, false);
            assert(statusWrites(h) == count + 1);
            key(h, 0, BTN_THUMBR, false);
            assert(wireStatus(h) == selected && statusWrites(h) == count + 2);
            assert(bytes(kit / "NDS_v1.CFG") == saved && h.lastjoy == 16);
            key(h, 0, BTN_SOUTH, false);
          }

    // Both-screen layouts are inert even for the fixed keyboard shortcut.
    for (unsigned layout : {0u, 1u}) {
      h.status = REQUIRED_STATUS | (layout << 5);
      h.sendstatus();
      const auto count = statusWrites(h);
      key(h, 0, KEY_F10, true);
      key(h, 0, KEY_F10, false);
      assert(statusWrites(h) == count && wireStatus(h) == h.status && !h.lastjoy);
    }
    h.status = REQUIRED_STATUS | CRT_TIMING | 64;
    h.sendstatus();
    const auto selected = h.status;
    key(h, 0, BTN_TL, true);
    assert(wireStatus(h) == selected); // No accidental reuse of the lid mapping.
    key(h, 0, BTN_TL, false);
    key(h, 0, KEY_F10, true);
    key(h, 1, BTN_THUMBL, true);
    key(h, 0, KEY_F10, false);
    assert(wireStatus(h) == (selected ^ 32) && !h.lastjoy);
    key(h, 1, BTN_THUMBL, false);
    assert(wireStatus(h) == selected);

    // Opening the menu restores the selected panel immediately. Releasing
    // inside the menu and closing it cannot leave the temporary panel active.
    key(h, 0, KEY_F10, true);
    h.togglemenu();
    assert(h.menu && wireStatus(h) == selected);
    key(h, 0, KEY_F10, false);
    h.togglemenu();
    assert(!h.menu && wireStatus(h) == selected);
    key(h, 0, KEY_F10, true);
    h.firmwareError("Test", "Menu must restore selected panel");
    assert(h.menu && wireStatus(h) == selected);
    h.firmware_error_dialog = false;
    key(h, 0, KEY_F10, false);
    h.togglemenu();

    // Layout cycling while peeking changes the underlying choice; releasing
    // returns to that new choice instead of an obsolete cached selection.
    key(h, 0, KEY_F10, true);
    key(h, 0, BTN_TR, true);
    key(h, 0, BTN_TR, false);
    assert(h.status == (selected ^ 32) && wireStatus(h) == selected);
    key(h, 0, KEY_F10, false);
    assert(wireStatus(h) == h.status);

    // Reset/new-ROM/exit share this clearing path. It also prevents held
    // inputs from reactivating peek until the next physical press.
    key(h, 0, KEY_F10, true);
    h.clearConsoleInputs();
    h.inputs();
    assert(wireStatus(h) == h.status && !h.screen_peek);
    key(h, 0, KEY_F10, true);
    h.reset();
    assert(wireStatus(h) == h.status && !h.screen_peek && !(h.status & 1));

    // Dropped event streams and controller removal cannot leave peek stuck.
    int fds[2];
    assert(pipe(fds) == 0);
    close(h.pads[0].fd);
    h.pads[0].fd = fds[0];
    fcntl(fds[0], F_SETFL, O_NONBLOCK);
    key(h, 0, KEY_F10, true);
    input_event event{};
    event.type = EV_SYN;
    event.code = SYN_DROPPED;
    assert(write(fds[1], &event, sizeof(event)) == sizeof(event));
    h.inputs();
    assert(wireStatus(h) == h.status && !h.screen_peek);
    close(fds[1]);
    key(h, 0, KEY_F10, true);
    key(h, 1, BTN_THUMBL, true);
    h.pads[0].disconnected = true;
    h.inputs();
    assert(wireStatus(h) == (h.status ^ 32));
    h.pads[1].disconnected = true;
    h.inputs();
    assert(wireStatus(h) == h.status && !h.screen_peek);
    h.clearConsoleInputs();
    for (auto &p : h.pads) p.disconnected = false;

    // Peek has its own appended prompt and ABI slot. Imported Main mappings
    // cannot accidentally activate it; private maps keep the old controls.
    static_assert(Host::SCREEN_PEEK_BUTTON == 16);
    assert(std::string(Host::button_names.back()) == "Screen Peek");
    assert(Host::button_slots.back() == 16);
    auto &pad = h.pads[0];
    const auto name = "NDS_input_" + pad.id + "_v3.map";
    const auto map = pad.map;
    h.atomicFile(sd / "config/inputs" / name, map.data(), sizeof(map));
    h.readCoreMap(pad, sd / "config/inputs");
    assert(pad.map[4] == BTN_SOUTH && !pad.map[16]);
    h.menu = true;
    h.mapping_step = 15;
    h.mapping_pad = pad.id;
    h.new_map = map;
    key(h, 0, BTN_THUMBR, true);
    key(h, 0, BTN_THUMBR, false);
    assert(h.mapping_step == -1 && pad.map[16] == BTN_THUMBR);
    for (unsigned i = 0; i < 32; ++i) if (i != 16) assert(pad.map[i] == map[i]);
    std::array<uint32_t, 32> persisted{};
    assert(Host::readmap(kit / "inputs" / name, persisted) && persisted == pad.map);
    assert(fs::file_size(kit / "inputs" / name) == 128);
    h.readCoreMap(pad, sd / "config/inputs");
    assert(pad.map == persisted);
    h.mapping_step = 15;
    h.new_map = pad.map;
    key(h, 0, KEY_SPACE, true);
    key(h, 0, KEY_SPACE, false);
    assert(h.mapping_step == -1 && !pad.map[16]);

    // Even an explicit save during a peek persists the chosen panel, and
    // restarting the host starts with that panel and no held peek state.
    h.menu = false;
    key(h, 0, KEY_F10, true);
    h.saveSettings();
    Host fresh(kit.string(), (sd / "games/NDS").string(), sd);
    assert(!fresh.screen_peek && wireStatus(fresh) == h.status);
    assert(fresh.full_status == h.full_status);
  }
};
int main() {
  char directory[] = "/tmp/nds-screen-peek-XXXXXX";
  assert(mkdtemp(directory));
  HostTest::run(directory);
  fs::remove_all(directory);
  std::cout << "PASS: temporary panel peek, release/menus/reset/disconnect, CRT, "
               "multiple held bindings, layout changes, saved selection and map compatibility\n";
}
