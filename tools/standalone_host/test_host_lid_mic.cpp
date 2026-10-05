// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>

struct HostTest {
  static void ignoredLidShortcuts(Host &host, Pad &pad) {
    const bool before = host.lid_closed;
    for (const int code : {BTN_THUMBL, BTN_THUMBR, KEY_F10}) {
      host.key(pad, code, true);
      host.key(pad, code, true);
      host.key(pad, code, false);
      host.inputs();
      assert(host.lid_closed == before &&
             "legacy lid bindings and F10 must never toggle the lid");
    }
  }
  static void closeThroughMenu(Host &host) {
    if (!host.menu) host.togglemenu();
    host.cursor = Host::LID_CURSOR;
    if (!host.lid_closed) host.action(2);
    assert(host.lid_closed && host.menu);
    host.togglemenu();
    assert(!host.menu && host.lid_closed);
  }
  static void run(const fs::path &root) {
    const auto kit = root / "kit", sd = root / "sd";
    fs::create_directories(kit / "inputs");
    fs::create_directories(sd / "config/inputs");
    Host h(kit.string(), (sd / "games/NDS").string(), sd);
    Pad p;
    p.id = "lidmic";
    p.fd = open("/dev/null", O_RDONLY);
    p.map[4] = BTN_SOUTH;
    p.map[14] = BTN_THUMBL | (uint32_t(BTN_THUMBR) << 16);
    p.map[15] = BTN_TL2;
    h.pads.push_back(p);
    auto &pad = h.pads[0];
    assert(!h.lid_closed && h.lastjoy == 0 && h.menu);
    const auto saved = h.status;
    h.menu = false;
    ignoredLidShortcuts(h, pad);
    h.key(pad, BTN_SOUTH, true);
    h.key(pad, BTN_TL2, true);
    h.inputs();
    assert(h.lastjoy == (Host::MIC_MASK | 16));
    h.togglemenu();
    h.inputs();
    assert(h.menu && h.lastjoy == 0); // Menus silence the microphone.
    ignoredLidShortcuts(h, pad);
    h.cursor = Host::LID_CURSOR;
    h.action(2);
    h.inputs();
    assert(h.lid_closed && h.menu && h.lastjoy == Host::LID_MASK);
    ignoredLidShortcuts(h, pad);
    h.draw();
    assert(h.status == saved); // Lid state never changes saved display options.
    h.togglemenu();
    h.inputs();
    assert(h.lastjoy == (Host::LID_MASK | Host::MIC_MASK | 16));
    ignoredLidShortcuts(h, pad);
    h.key(pad, BTN_TL2, false);
    h.inputs();
    assert(h.lastjoy == (Host::LID_MASK | 16));
    h.togglemenu();
    h.cursor = Host::LID_CURSOR;
    h.action(2);
    assert(!h.lid_closed && h.menu && !h.lastjoy);
    h.togglemenu();
    h.key(pad, KEY_F11, true);
    h.inputs();
    assert(h.lastjoy == (Host::MIC_MASK | 16));
    h.key(pad, KEY_F11, false);
    h.inputs();
    assert(h.lastjoy == 16);

    closeThroughMenu(h);
    h.key(pad, KEY_F11, true);
    h.inputs();
    assert(h.lid_closed && (h.lastjoy & Host::MIC_MASK));
    h.clearConsoleInputs();
    h.inputs();
    assert(!h.lid_closed && !h.lastjoy && !pad.joy);
    for (bool pressed : pad.pressed) assert(!pressed);
    // Actual reset and ROM load paths also clear the menu's closed-lid state.
    closeThroughMenu(h);
    h.key(pad, KEY_F11, true);
    h.inputs();
    h.reset();
    h.inputs();
    assert(!h.lid_closed && !h.lastjoy);
    RomMapping::test_iomem_path = (root / "iomem").string();
    std::ofstream(RomMapping::test_iomem_path) << "00000000-1fefffff : System RAM\n";
    const auto rom = root / "test.nds";
    std::ofstream(rom) << std::string(512, 'x');
    closeThroughMenu(h);
    h.key(pad, KEY_F11, true);
    h.inputs();
    h.load(rom.string());
    h.inputs();
    assert(!h.lid_closed && !h.lastjoy);

    // Dropped evdev events cannot leave a held microphone behind.
    close(pad.fd);
    int fds[2];
    assert(pipe(fds) == 0);
    pad.fd = fds[0];
    fcntl(pad.fd, F_SETFL, O_NONBLOCK);
    h.key(pad, KEY_F11, true);
    h.inputs();
    assert(h.lastjoy == Host::MIC_MASK);
    input_event event{};
    event.type = EV_SYN;
    event.code = SYN_DROPPED;
    assert(write(fds[1], &event, sizeof(event)) == sizeof(event));
    h.inputs();
    assert(!h.lastjoy && !pad.joy);
    close(fds[1]);

    auto map = pad.map;
    map[13] = BTN_TR2;
    map[14] = BTN_THUMBL | (uint32_t(BTN_THUMBR) << 16);
    map[15] = BTN_TL2;
    const auto name = "NDS_input_lidmic_v3.map";
    h.atomicFile(sd / "config/inputs" / name, map.data(), sizeof(map));
    h.readCoreMap(pad, sd / "config/inputs");
    assert(pad.map[4] == BTN_SOUTH && !pad.map[13] && !pad.map[14] && !pad.map[15]);
    // Legacy private maps retain their exact format and working layout/mic
    // slots. Their former lid slot is ignored even when nonzero in the file.
    h.atomicFile(kit / "inputs" / name, map.data(), sizeof(map));
    h.readCoreMap(pad, sd / "config/inputs");
    assert(pad.map == map);
    h.menu = false;
    ignoredLidShortcuts(h, pad);
    h.key(pad, BTN_TL2, true);
    h.inputs();
    assert(!h.lid_closed && h.lastjoy == Host::MIC_MASK);
    h.key(pad, BTN_TL2, false);
    h.inputs();
    assert(!h.lastjoy);

    static_assert(Host::button_names.size() == 15);
    assert(std::string(Host::button_names[13]) == "Cycle Video Layout");
    assert(std::string(Host::button_names[14]) == "Blow into Mic");
    assert(Host::button_slots[13] == 13 && Host::button_slots[14] == 15);
    for (const char *label : Host::button_names)
      assert(std::string(label) != "Toggle Lid");
    h.menu = true;
    h.mapping_step = 14;
    h.mapping_pad = pad.id;
    h.new_map = map;
    h.new_map[14] = 0;
    h.key(pad, BTN_TL2, true);
    h.key(pad, BTN_TL2, false);
    assert(h.mapping_step == -1 && pad.map[13] == BTN_TR2 &&
           pad.map[14] == 0 && pad.map[15] == BTN_TL2);
    std::array<uint32_t, 32> persisted{};
    assert(Host::readmap(kit / "inputs" / name, persisted) && persisted == pad.map);
    assert(fs::file_size(kit / "inputs" / name) == 128);
    // Skipping the new final prompt clears microphone slot 15, not slot 14.
    h.mapping_step = 14;
    h.new_map = pad.map;
    h.key(pad, KEY_SPACE, true);
    h.key(pad, KEY_SPACE, false);
    assert(h.mapping_step == -1 && !pad.map[14] && !pad.map[15]);
    assert(Host::readmap(kit / "inputs" / name, persisted) && persisted == pad.map);
    ignoredLidShortcuts(h, pad);
    Host fresh(kit.string(), (sd / "games/NDS").string(), sd);
    assert(!fresh.lid_closed && !fresh.lastjoy && fresh.menu);
    std::cout << "PASS menu-only lid, ignored legacy bindings/F10, microphone "
                 "hold/release, reset/load/fresh launch, 32-word map ABI and "
                 "microphone prompt retaining slot 15\n";
  }
};

int main() {
  char directory[] = "/tmp/nds-lid-mic-host-XXXXXX";
  assert(mkdtemp(directory));
  HostTest::run(directory);
  fs::remove_all(directory);
}
