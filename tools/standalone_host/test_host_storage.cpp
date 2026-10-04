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
  static void select(Host &h, const std::string &name) {
    const auto it = std::find_if(h.roms.begin(), h.roms.end(),
                                 [&](const auto &e) { return e.name == name; });
    assert(it != h.roms.end());
    h.cursor = int(it - h.roms.begin());
    h.action(2);
    finish(h);
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
      assert(h.browser && !h.storage_choices && h.roms.front().name == "..");
      assert(h.storage_preferences.games.path == (sd / "games/NDS"));
      assert(std::none_of(h.roms.begin(), h.roms.end(), [](const auto &e) {
        return e.name == "Change location";
      }));
      select(h, "Subfolder");
      assert(h.currentdir == sd / "games/NDS/Subfolder");
      assert(h.storage_preferences.games.path == h.currentdir &&
             h.storage_preferences.last == ".");
      assert(h.spi.history.empty());
      preview(h, "games-parent");
    }
    Host h(kit.string(), (sd / "games/NDS").string(), sd);
    h.openGames();
    finish(h);
    assert(h.currentdir == sd / "games/NDS/Subfolder");
    // A user can ascend out of games/NDS into the normal storage hierarchy.
    select(h, "..");
    assert(h.currentdir == sd / "games/NDS");
    select(h, "..");
    assert(h.currentdir == sd / "games");
    select(h, "..");
    assert(h.currentdir == sd);
    fs::create_directories(usb / "games/NDS");
    std::ofstream(usb / "games/NDS/USB.nds") << std::string(512, 'u');
    nds_storage::test_volumes.push_back({usb, "uuid:external-disk", "USB 0"});
    select(h, "..");
    assert(h.storage_devices && h.roms.front().name == "..");
    assert(h.roms.size() == 3);
    preview(h, "devices");
    select(h, usb.string());
    assert(h.currentdir == usb);
    select(h, "games");
    select(h, "NDS");
    assert(h.currentdir == usb / "games/NDS" &&
           h.storage_preferences.games.id == "uuid:external-disk");
    h.remember(usb / "games/NDS/USB.nds");
    fs::rename(usb, renumbered);
    nds_storage::test_volumes.back().path = renumbered;
    h.openGames();
    finish(h);
    assert(h.currentdir == renumbered / "games/NDS");
    h.openRecents();
    finish(h);
    assert(h.recent_available.front() &&
           h.recent_paths.front() == renumbered / "games/NDS/USB.nds");
    const auto saved_games = h.storage_preferences.games;
    h.browseGames(sd / "games/NDS");
    finish(h);
    h.openRecents();
    finish(h);
    assert(h.recent_available.front() &&
           h.recent_paths.front() == renumbered / "games/NDS/USB.nds");
    fs::create_directories(usb / "games/NDS");
    std::ofstream(usb / "games/NDS/USB.nds") << std::string(512, 'x');
    nds_storage::test_volumes.erase(nds_storage::test_volumes.begin() + 1);
    nds_storage::test_volumes.push_back({usb, "uuid:wrong-disk", "USB 0"});
    h.openRecents();
    finish(h);
    assert(!h.recent_available.front());
    h.storage_preferences.games = saved_games;
    h.saveStorage();
    const auto before =
        nds_storage::Preferences::read(h.storageConfig()).encode();
    h.openGames();
    finish(h);
    assert(h.storage_choices && h.storage_caption == "Storage unavailable");
    assert(nds_storage::Preferences::read(h.storageConfig()).encode() ==
           before);
    preview(h, "missing-drive");
    h.action(3);
    assert(!h.browser && !h.storage_choices && h.cursor == 0);
    const auto start = ms();
    h.startStorage(
        [] {
          sleep(5);
          return std::string();
        },
        [](const std::string &) {});
    h.action(3);
    assert(!h.storage_job && ms() - start < 100 && h.menu && !h.browser &&
           !h.system_menu);
    // BIOS browser uses the same parent/device flow and a separate default.
    nds_storage::test_volumes.back() = {renumbered, "uuid:external-disk",
                                        "USB 1"};
    fs::create_directories(renumbered / "Original BIOS");
    std::ofstream(renumbered / "Original BIOS/firmware.bin").put('x');
    std::ofstream(renumbered / "Original BIOS/bios7.bin").put('x');
    std::ofstream(renumbered / "Original BIOS/other.nds")
        << std::string(512, 'r');
    h.openFirmwareBrowser();
    finish(h);
    assert(h.choosing_firmware && h.currentdir == renumbered / "games/NDS");
    select(h, "..");
    select(h, "..");
    select(h, "Original BIOS");
    assert(h.roms.size() == 2 && h.roms[1].name == "firmware.bin" &&
           h.roms[1].literal);
    assert(!h.firmware && h.storage_preferences.games.path == saved_games.path);
    const auto firmwareLocation = h.storage_preferences.firmware;
    preview(h, "firmware-parent");
    h.action(3);
    assert(h.cursor == 1 && !h.browser);
    h.openFirmwareBrowser();
    finish(h);
    assert(h.currentdir == renumbered / "Original BIOS");
    h.spi.history.clear();
    select(h, "firmware.bin");
    assert(h.storage_choices && !h.firmware &&
           h.storage_detail.find("bios7.bin") != std::string::npos);
    for (const auto &t : h.spi.history)
      assert(t.select != Spi::FIO && t.command != 0x45);
    assert(!fs::exists(h.firmwarePath()) && h.savedir == (sd / "saves/NDS"));
    assert(h.firmwarePath() == sd / "saves/NDS/firmware.bin");
    // Missing drive or cancellation never erases either remembered location.
    assert(h.storage_preferences.firmware.path == firmwareLocation.path);
    h.action(3);
    h.openGames();
    finish(h);
    assert(!h.choosing_firmware && h.currentdir == renumbered / "games/NDS");
    h.chooseStorageVolumes();
    finish(h);
    select(h, "..");
    assert(!h.browser && h.cursor == 0);
    assert(std::none_of(h.system_rows.begin(), h.system_rows.end(),
                        [](const auto &r) {
                          return r.text.find("Storage") != std::string::npos;
                        }));
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
  std::cout << "PASS: parent-only game/firmware browsing, separate remembered "
               "folders, cross-device navigation, no Storage menu, USB "
               "renumbering, Recent Files identity, disconnect/cancel recovery "
               "and unchanged SD saves\n";
}
