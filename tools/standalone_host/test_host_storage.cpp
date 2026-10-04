// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
  static void finish(Host &h) {
    const auto end = ms() + 5000;
    while (h.storage_job) {
      assert(ms() < end);
      h.beat();
      h.pollStorage();
      usleep(1000);
    }
  }
  static void preview(Host &h, const char *name) {
    const char *out = std::getenv("NDS_STORAGE_PREVIEW_DIR");
    if (!out)
      return;
    h.draw();
    std::ofstream image(fs::path(out) / (std::string(name) + ".ppm"),
                        std::ios::binary);
    image << "P6\n256 128\n255\n";
    for (int y = 0; y < 128; ++y)
      for (int x = 0; x < 256; ++x) {
        const bool lit = (h.osd_rows[y / 8][x] >> (y % 8)) & 1;
        const char pixel[3] = {char(lit ? 255 : 20), char(lit ? 255 : 33),
                               char(lit ? 255 : 55)};
        image.write(pixel, 3);
      }
  }
  static void run(const fs::path &root) {
    const auto sd = root / "sd", kit = root / "kit", usb = root / "usb0",
               renumbered = root / "usb1";
    fs::create_directories(kit);
    fs::create_directories(sd / "games/NDS/Subfolder");
    std::ofstream(sd / "games/NDS/Subfolder/test.nds") << std::string(512, 'r');
    nds_storage::test_volumes = {{sd, "sd", "SD card"}};
    {
      Host h(kit.string(), (sd / "games/NDS").string(), sd);
      h.spi.history.clear();
      h.openGames();
      finish(h);
      assert(h.browser && !h.storage_choices &&
             h.storage_preferences.games.path == (sd / "games/NDS"));
      h.browseGames(sd / "games/NDS/Subfolder");
      finish(h);
      assert(h.storage_preferences.last == "Subfolder");
      assert(h.game_paths.back() == sd / "games/NDS/Subfolder/test.nds");
      assert(h.spi.history.empty());
    }
    Host h(kit.string(), (sd / "games/NDS").string(), sd);
    h.openGames();
    finish(h);
    assert(h.currentdir == sd / "games/NDS/Subfolder");
    h.closeBrowser();
    h.system_menu = true;
    h.cursor = 4;
    h.action(2);
    assert(h.storage_panel);
    preview(h, "storage");
    h.cursor = 0;
    h.action(2);
    finish(h);
    assert(h.storage_choices && h.storage_rows.size() == 2);
    h.action(2);
    finish(h);
    assert(h.storage_caption == "Games folder");
    h.action(3);
    assert(h.system_menu && h.cursor == 4);
    h.storage_panel = false;
    h.storage_choices = false;
    fs::create_directories(usb / "games/NDS");
    std::ofstream(usb / "games/NDS/USB.nds") << std::string(512, 'u');
    nds_storage::test_volumes.push_back({usb, "uuid:external-disk", "USB 0"});
    h.storage_preferences.games = {};
    h.openGames();
    finish(h);
    assert(h.storage_choices && h.storage_rows.size() == 3);
    preview(h, "choose-games");
    auto choice = std::find_if(
        h.storage_rows.begin(), h.storage_rows.end(),
        [&](const auto &r) { return r.label == (usb / "games/NDS").string(); });
    assert(choice != h.storage_rows.end());
    auto select = choice->select;
    select();
    finish(h);
    assert(h.storage_preferences.games.id == "uuid:external-disk");
    h.remember(usb / "games/NDS/USB.nds");
    assert(RecentFiles::read(h.recentConfig()).front().directory ==
           (usb / "games/NDS").string());
    fs::rename(usb, renumbered);
    nds_storage::test_volumes.back().path = renumbered;
    h.openGames();
    finish(h);
    assert(h.currentdir == renumbered / "games/NDS");
    h.openRecents();
    finish(h);
    assert(h.recent_available.front() &&
           h.recent_paths.front() == renumbered / "games/NDS/USB.nds");
    // Recent entries retain their own drive identity when the preferred games
    // folder changes. A different disk at the old mount must never win.
    const auto saved_games = h.storage_preferences.games;
    h.choosing_firmware = false;
    h.selectStorageFolder(sd / "games/NDS");
    finish(h);
    h.openRecents();
    finish(h);
    assert(h.recent_available.front() &&
           h.recent_paths.front() == renumbered / "games/NDS/USB.nds");
    fs::create_directories(usb / "games/NDS");
    std::ofstream(usb / "games/NDS/USB.nds") << std::string(512, 'x');
    nds_storage::test_volumes.push_back({usb, "uuid:wrong-disk", "USB 0"});
    h.openRecents();
    finish(h);
    assert(h.recent_available.front() &&
           h.recent_paths.front() == renumbered / "games/NDS/USB.nds");
    nds_storage::test_volumes.erase(nds_storage::test_volumes.begin() + 1);
    h.openRecents();
    finish(h);
    assert(!h.recent_available.front());
    nds_storage::test_volumes.pop_back();
    nds_storage::test_volumes.push_back(
        {renumbered, "uuid:external-disk", "USB 1"});
    h.storage_preferences.games = saved_games;
    h.saveStorage();
    const auto before =
        nds_storage::Preferences::read(h.storageConfig()).encode();
    nds_storage::test_volumes.pop_back();
    h.openGames();
    finish(h);
    assert(h.storage_choices && h.storage_caption == "Storage unavailable");
    preview(h, "missing-drive");
    assert(nds_storage::Preferences::read(h.storageConfig()).encode() ==
           before);
    const auto start = ms();
    h.startStorage(
        [] {
          sleep(5);
          return std::string();
        },
        [](const std::string &) {});
    h.action(3);
    assert(!h.storage_job && ms() - start < 100);
    assert(h.storage_panel && h.menu);
    // Choosing a BIOS folder never changes games, saves, or opens firmware.
    fs::create_directories(sd / "Original BIOS");
    h.choosing_firmware = true;
    h.selectStorageFolder(sd / "Original BIOS");
    finish(h);
    assert(h.storage_preferences.games.id == "uuid:external-disk");
    assert(h.storage_preferences.firmware.path == (sd / "Original BIOS"));
    assert(!h.firmware && h.savedir == (sd / "saves/NDS"));
    assert(h.firmwarePath() == sd / "saves/NDS/firmware.bin");
    h.spi.history.clear();
    h.requestFirmware();
    finish(h);
    assert(h.storage_choices && !h.firmware &&
           h.storage_detail.find("bios7.bin") != std::string::npos);
    for (const auto &t : h.spi.history)
      assert(t.select != Spi::FIO && t.command != 0x45);
    assert(!fs::exists(h.firmwarePath()));
    h.writeRecents({});
    assert(h.recentLocations().empty());
    nds_storage::test_volumes.clear();
  }
};
int main() {
  const auto root = fs::temp_directory_path() /
                    ("nds-host-storage-" + std::to_string(getpid()));
  fs::create_directories(root);
  HostTest::run(root);
  fs::remove_all(root);
  std::cout << "PASS: actual host auto discovery, multiple choices, remembered "
               "subfolder, USB renumbering, external recents, disconnect "
               "recovery, cancellation, separate BIOS and SD saves\n";
}
