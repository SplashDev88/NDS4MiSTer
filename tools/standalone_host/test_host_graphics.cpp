// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
  static void run(const fs::path& root) {
    const auto kit = root/"kit", sd = root/"sd", control = root/"control";
    fs::create_directories(kit); fs::create_directories(sd);
    std::uint32_t value = nds4mister::GraphicsControl::AAOn;
    std::ofstream(control, std::ios::binary).write((const char*)&value, 4);
    setenv("NDS4MISTER_GRAPHICS_CONTROL", control.c_str(), 1);
    nds4mister::GraphicsControl reader;
    {
      Host h(kit.string(), (sd/"games/NDS").string(), sd);
      assert(h.anti_alias && reader.antiAlias());
      h.independent_outputs_supported = true;
      h.cursor = Host::DISPLAY_CURSOR; h.action(2);
      while (h.cursor != Host::AA_CURSOR) h.action(1);
      h.draw();
      assert(h.osd_rows[9] == h.frame.renderRow(9, " 3D Anti-aliasing:        On", true, nds_osd::arrow_left));
      const auto status = h.full_status;
      h.action(2);
      assert(!h.anti_alias && !reader.antiAlias() && h.full_status == status);
      assert(!fs::exists(kit/"NDS_graphics.cfg"));
      h.action(5); h.action(6); h.cursor = 3; h.action(2); // System > Save settings.
      assert(!h.system_menu && fs::exists(kit/"NDS_graphics.cfg"));
    }
    {
      Host h(kit.string(), (sd/"games/NDS").string(), sd);
      assert(!h.anti_alias && !reader.antiAlias());
      h.reset_confirm = true; h.cursor = 0; h.action(2);
      assert(h.anti_alias && reader.antiAlias());
    }
    {
      Host h(kit.string(), (sd/"games/NDS").string(), sd);
      assert(h.anti_alias && reader.antiAlias());
    }
    for (const char* invalid : {"", "NDS-Graphics-v2\naa=off\n", "NDS-Graphics-v1\naa=off\nextra"}) {
      std::ofstream(kit/"NDS_graphics.cfg") << invalid;
      Host h(kit.string(), (sd/"games/NDS").string(), sd);
      assert(h.anti_alias && reader.antiAlias());
    }
    unsetenv("NDS4MISTER_GRAPHICS_CONTROL");
    std::cout << "PASS: AA menu, live shared control, save/cold-load, reset and malformed/default settings\n";
  }
};
int main() { char path[] = "/tmp/nds-host-aa-XXXXXX"; assert(mkdtemp(path)); HostTest::run(path); fs::remove_all(path); }
