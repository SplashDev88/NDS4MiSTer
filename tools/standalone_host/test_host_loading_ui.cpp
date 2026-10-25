// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>

struct HostTest {
  static void preview(const Host &host, const fs::path &path, unsigned rows) {
    std::ofstream out(path, std::ios::binary);
    out << "P6\n256 " << rows * 8 << "\n255\n";
    for (unsigned y = 0; y < rows * 8; ++y)
      for (unsigned x = 0; x < 256; ++x) {
        const bool on = host.osd_rows[y / 8][x] & (1u << (y % 8));
        const char pixel[3] = {char(on ? 255 : 0), char(on ? 255 : 0), char(on ? 255 : 0)};
        out.write(pixel, 3);
      }
    assert(out.good());
  }
  static void run(const fs::path &output) {
    const auto root = fs::temp_directory_path() / ("nds-loading-ui-" + std::to_string(getpid()));
    fs::create_directories(root / "kit");
    Host host((root / "kit").string(), (root / "sd/games/NDS").string(), root / "sd");
    host.beginLoading("Chrono Trigger.nds");
    const auto initial = host.osd_rows;
    host.updateLoading(3500, 10000); // Source verified, preparation still pending.
    assert(host.loading_progress < 167);
    preview(host, output.string() + "-preparing.ppm", 8);
    host.updateLoading(6000, 10000);
    const auto bar = host.osd_rows[4];
    host.updateLoading(500, 10000); // A fallback cannot restart the visual bar.
    assert(host.osd_rows[4] == bar);
    host.updateLoading(9900, 10000);
    assert(host.loading_progress < 167); // Validation/boot release still pending.
    for (int row = 0; row < 8; ++row)
      if (row != 4) assert(host.osd_rows[row] == initial[row]);
    assert(host.osd_rows[6] == host.frame.renderRow(6));
    assert(host.osd_rows[7] == host.frame.renderRow(7));
    host.updateLoading(10000, 10000);
    assert(host.loading_progress == 167);
    host.beginLoading("New Super Mario Bros.nds");
    assert(host.loading_progress == 0);
    host.updateLoading(8000, 10000);
    preview(host, output.string() + "-loading.ppm", 8);

    host.menu = true;
    host.independent_outputs_supported = true;
    host.personal_settings_notice.clear();
    host.cursor = Host::TOUCH_RANGE_CURSOR;
    host.message = "old notice";
    host.action(2);
    assert(host.touch_range == 1 && host.message.empty());
    host.saveSettings();
    assert(host.message.empty());
    std::ifstream saved(root / "kit/NDS_stick.cfg");
    assert(std::string(std::istreambuf_iterator<char>(saved), {}) == "NDS-StickRange-v1\n125\n");
    host.draw();
    assert(host.osd_rows[14] == host.frame.renderRow(14));
    preview(host, output.string() + "-right-stick.ppm", 16);
    fs::remove_all(root);
  }
};
int main(int argc, char **argv) {
  assert(argc == 2);
  HostTest::run(argv[1]);
  puts("PASS stock loading rows, monotonic progress and completion boundary; right-stick persistence without footer notices");
}
