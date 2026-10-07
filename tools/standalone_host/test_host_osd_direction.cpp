// SPDX-License-Identifier: GPL-3.0-only
// Export actual host OSD commands for test_osd_loading_rotation.py's RTL
// pixel checks. Expected geometry there comes from the user-facing direction.
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
struct HostTest {
  static void run(const fs::path &output) {
    const auto root = fs::temp_directory_path() /
        ("nds-osd-direction-" + std::to_string(getpid()));
    fs::create_directories(root / "kit");
    Host host((root / "kit").string(), (root / "sd/games/NDS").string(), root / "sd");
    assert(std::string(CORE_OPTIONS[1].values[1]) == "90 CCW");
    assert(std::string(CORE_OPTIONS[1].values[2]) == "90 CW");
    std::ofstream trace(output);
    for (unsigned crt : {0u, 1u})
      for (unsigned video = 0; video < 3; ++video)
        for (bool message : {false, true}) {
          host.status = REQUIRED_STATUS | (crt ? CRT_TIMING : 0) | (video << 11);
          host.spi.history.clear();
          host.osd(true, message);
          const auto &transfer = host.spi.history.back();
          assert(transfer.select == Spi::OSD && transfer.words.size() == 5);
          trace << video << ' ' << crt << ' ' << transfer.command << ' '
                << transfer.words[4] << '\n';
        }
    assert(trace.good());
    fs::remove_all(root);
  }
};
int main(int argc, char **argv) {
  assert(argc == 2);
  HostTest::run(argv[1]);
}
