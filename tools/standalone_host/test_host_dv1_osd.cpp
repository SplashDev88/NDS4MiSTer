// SPDX-License-Identifier: GPL-3.0-only
// Real host transactions, including rejected output modes and startup fallback.
#define STANDALONE_TEST
#define main standalone_unused_main
#ifndef HOST_TEST_SOURCE
#define HOST_TEST_SOURCE "host.cpp"
#endif
#include HOST_TEST_SOURCE
#undef main
#include <cassert>
#include <iostream>

struct HostTest {
  static void run(const fs::path &root) {
    fs::create_directories(root / "kit");
    Host h((root / "kit").string(), (root / "sd/games/NDS").string(), root / "sd");
    unsigned cases = 0;
    for (unsigned bits = 0; bits < 32; ++bits)
      for (bool known : {false, true})
        for (bool supported : {false, true})
          for (unsigned rotation = 0; rotation < 4; ++rotation)
            for (bool message : {false, true}) {
              const bool dv1 = bits & 1, dvi = bits & 2, dv2 = bits & 4;
              const bool framebuffer = bits & 8, scaled_vga = bits & 16;
              h.video_flags = (dv1 << 10) | (dvi << 7) | (dv2 << 13) |
                              (framebuffer << 12) | (scaled_vga << 2);
              h.video_flags_known = known;
              h.independent_outputs_supported = supported;
              h.status = REQUIRED_STATUS | (rotation << 11);
              h.spi.history.clear();
              h.osd(true, message);
              const auto &digital = h.spi.history.at(0);
              const auto &native = h.spi.history.at(1);
              const uint16_t turn = rotation == 1 ? 3 : rotation == 2 ? 1 : 0;
              const bool rotates = known && supported && dv1 && !dvi && !dv2 && !framebuffer;
              assert(digital.select == Spi::OSD_HDMI && native.select == Spi::OSD_ANALOG);
              assert(digital.command == (message ? 0x49 : 0x41) && native.command == digital.command);
              assert(digital.words == (std::vector<uint16_t>{0, 0, 0, 0, turn}));
              assert(native.words == (std::vector<uint16_t>{0, 0, 0, 0, uint16_t(rotates ? turn : 0)}));
              h.spi.history.clear(); h.osd(false);
              assert(h.spi.history.size() == 1 && h.spi.history[0].select == Spi::OSD &&
                     h.spi.history[0].command == 0x40 && h.spi.history[0].words.empty());
              ++cases;
            }
    std::cout << "PASS: DV1 menu rotation, loading, HDMI/native fallback and broadcast close: "
              << cases << " cases\n";
  }
};
int main() {
  char directory[] = "/tmp/nds-dv1-osd-XXXXXX";
  assert(mkdtemp(directory));
  HostTest::run(directory); fs::remove_all(directory);
}
