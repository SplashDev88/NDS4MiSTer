// SPDX-License-Identifier: GPL-3.0-only
// Export actual host transactions for the two-OSD RTL integration test.
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
struct HostTest {
  static void run(const fs::path &path) {
    const auto root = fs::temp_directory_path() / ("nds-dual-osd-" + std::to_string(getpid()));
    fs::create_directories(root / "kit");
    Host host((root / "kit").string(), (root / "sd/games/NDS").string(), root / "sd");
    std::ofstream out(path);
    // Scaled HDMI, DV1, DVI, DV2, framebuffer, scaled VGA on DV1,
    // older core and not-yet-discovered startup.
    const std::array<uint16_t, 8> flags{0, 1024, 1152, 9216, 5120, 1028, 1024, 1024};
    for (unsigned output = 0; output < flags.size(); ++output)
    for (unsigned crt : {0u, 1u})
      for (unsigned video = 0; video < 3; ++video)
        for (bool message : {false, true}) {
          host.video_flags = flags[output];
          host.video_flags_known = output != 7;
          host.independent_outputs_supported = output != 6;
          host.status = REQUIRED_STATUS | (crt ? CRT_TIMING : 0) | (video << 11);
          host.spi.history.clear();
          host.osd(false);
          const unsigned rows = message ? 8 : 16;
          for (unsigned y = 0; y < rows; ++y) {
            nds_osd::Row data{};
            for (unsigned x = 0; x < data.size(); ++x) data[x] = (y * 17) ^ x ^ (x >> 3);
            host.writeRow(y, data);
          }
          host.osd(true, message);
          out << video << ' ' << crt << ' ' << rows * 8 << ' ' << host.spi.history.size()
              << ' ' << (output == 1 || output == 5) << '\n';
          for (const auto &t : host.spi.history) {
            out << t.select << ' ' << t.command << ' ' << t.words.size();
            for (auto word : t.words) out << ' ' << word;
            out << '\n';
          }
        }
    assert(out.good());
    fs::remove_all(root);
  }
};
int main(int argc, char **argv) {
  assert(argc == 2);
  HostTest::run(argv[1]);
}
