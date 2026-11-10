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
      h.action(1);
      assert(h.cursor == Host::RESOLUTION_CURSOR);
      h.draw();
      assert(h.osd_rows[10] == h.frame.renderRow(10, " 3D Resolution:       Native", true, nds_osd::arrow_left));
      h.action(2);
      assert(h.half_rows && !h.anti_alias && reader.settings().halfRows);
      assert(!reader.antiAlias() && h.full_status == status);
      h.draw();
      assert(h.osd_rows[10] == h.frame.renderRow(10, " 3D Resolution:    Half Rows", true, nds_osd::arrow_left));
      // The next row is Back, and reverse navigation returns to resolution.
      h.action(1); assert(h.cursor == Host::EXIT_CURSOR);
      h.action(0); assert(h.cursor == Host::RESOLUTION_CURSOR);
      h.action(7); // Native, preserving AA Off.
      assert(!h.half_rows && !h.anti_alias && !reader.settings().halfRows);
      h.action(8); // Half Rows again.
      h.action(8); // 128x96.
      assert(h.quarter_3d && !h.half_rows && !h.anti_alias && reader.settings().quarter);
      h.draw();
      assert(h.osd_rows[10] == h.frame.renderRow(10, " 3D Resolution:       128x96", true, nds_osd::arrow_left));
      h.action(8); // Diagnostic Off; no stale Half Rows/AA setting.
      assert(h.render_off && !h.half_rows && !h.anti_alias && reader.settings().renderOff);
      h.draw();
      assert(h.osd_rows[10] == h.frame.renderRow(10, " 3D Resolution:   Off (test)", true, nds_osd::arrow_left));
      h.action(0); assert(h.cursor == Host::AA_CURSOR);
      h.action(2); // AA On restores native resolution.
      assert(h.anti_alias && !h.half_rows && !h.render_off && !reader.settings().halfRows && !reader.settings().renderOff);
      h.action(1); h.action(2); // Half Rows turns AA Off.
      assert(h.half_rows && !h.anti_alias && reader.settings().halfRows);
      assert(!fs::exists(kit/"NDS_graphics.cfg"));
      h.action(5); h.action(6); h.cursor = 3; h.action(2); // System > Save settings.
      assert(!h.system_menu && fs::exists(kit/"NDS_graphics.cfg"));
    }
    {
      Host h(kit.string(), (sd/"games/NDS").string(), sd);
      assert(!h.anti_alias && !reader.antiAlias() && h.half_rows && reader.settings().halfRows);
      h.reset_confirm = true; h.cursor = 0; h.action(2);
      assert(h.anti_alias && reader.antiAlias() && !h.half_rows && !reader.settings().halfRows);
    }
    {
      Host h(kit.string(), (sd/"games/NDS").string(), sd);
      assert(h.anti_alias && reader.antiAlias());
    }
    {
      std::ofstream(kit/"NDS_graphics.cfg") << "NDS-Graphics-v2\naa=off\nrows=quarter\n";
      Host h(kit.string(), (sd/"games/NDS").string(), sd);
      assert(h.quarter_3d && !h.half_rows && !h.anti_alias && reader.settings().quarter);
      h.saveSettings();
      h.reset_confirm = true; h.cursor = 0; h.action(2);
      assert(!h.quarter_3d && h.anti_alias && !reader.settings().quarter);
    }
    for (const char* valid : {"NDS-Graphics-v1\naa=off\n", "NDS-Graphics-v2\naa=off\nrows=native\n"}) {
      std::ofstream(kit/"NDS_graphics.cfg") << valid;
      Host h(kit.string(), (sd/"games/NDS").string(), sd);
      assert(!h.anti_alias && !h.half_rows && !reader.antiAlias() && !reader.settings().halfRows);
    }
    for (const char* invalid : {"", "NDS-Graphics-v2\naa=off\n", "NDS-Graphics-v1\naa=off\nextra",
          "NDS-Graphics-v2\naa=on\nrows=half\n", "NDS-Graphics-v2\naa=on\nrows=quarter\n", "NDS-Graphics-v2\naa=off\nrows=half\nextra"}) {
      std::ofstream(kit/"NDS_graphics.cfg") << invalid;
      Host h(kit.string(), (sd/"games/NDS").string(), sd);
      assert(h.anti_alias && reader.antiAlias() && !h.half_rows && !reader.settings().halfRows);
    }
    // A renderer mapping cannot mutate settings; invalid words fail to native/AA On.
    reader.set(false, true);
    assert(reader.antiAlias() && !reader.settings().halfRows);
    for (std::uint32_t invalid : {0u, 0x41410003u, 0xffffffffu}) {
      std::ofstream(control, std::ios::binary).write((const char*)&invalid, 4);
      assert(reader.antiAlias() && !reader.settings().halfRows);
    }
    unsetenv("NDS4MISTER_GRAPHICS_CONTROL");
    std::cout << "PASS: AA/resolution menu navigation, mutual exclusion, live control, save/cold-load, v1 migration, reset and invalid settings\n";
  }
};
int main() { char path[] = "/tmp/nds-host-aa-XXXXXX"; assert(mkdtemp(path)); HostTest::run(path); fs::remove_all(path); }
