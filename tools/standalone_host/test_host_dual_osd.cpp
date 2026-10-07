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
    for (unsigned crt : {0u, 1u})
      for (unsigned video = 0; video < 3; ++video)
        for (bool message : {false, true}) {
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
          out << video << ' ' << crt << ' ' << rows * 8 << ' ' << host.spi.history.size() << '\n';
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
