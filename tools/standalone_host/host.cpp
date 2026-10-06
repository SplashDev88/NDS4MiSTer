// SPDX-License-Identifier: GPL-3.0-only
// NDS experimental standalone host. Protocol derived from MiSTer Main (GPLv3).
// See THIRD_PARTY.md. Copyright 2026 NDS4MiSTer contributors.
#include "firmware_media.h"
#include "font.h"
#include "framebuffer_metadata.h"
#include "freebios_media.h"
#include "menu_model.h"
#include "menu_presentation.h"
#include "osd_frame.h"
#include "personal_profile.h"
#include "recent_files.h"
#include "rom_mapping.h"
#include "rom_reader.h"
#include "storage_job.h"
#include "storage_locations.h"
#include "system_menu.h"
#include "touch_rotation.h"
#include "direct_video.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <functional>
#include <linux/input.h>
#include <map>
#include <memory>
#include <optional>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>
namespace fs = std::filesystem;
using Clock = std::chrono::steady_clock;
static volatile sig_atomic_t running = 1;
static volatile sig_atomic_t framebuffer_metadata_requested = 0;
static void stop(int) { running = 0; }
static void request_framebuffer_metadata(int) { framebuffer_metadata_requested = 1; }
static uint64_t monotonic_us() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             Clock::now().time_since_epoch()).count();
}
static uint64_t ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             Clock::now().time_since_epoch())
      .count();
}
static void require(bool ok, const std::string &s) {
  if (!ok)
    throw std::runtime_error(s + ": " + strerror(errno));
}
static void tie_to_parent(pid_t parent) {
  require(prctl(PR_SET_PDEATHSIG, SIGTERM) == 0, "parent death signal");
  require(getppid() == parent && running, "supervisor already exited");
}
static void log(const std::string &s) {
  printf("%llu %s\n", (unsigned long long)ms(), s.c_str());
  fflush(stdout);
}
static bool live_main() {
  for (auto &e : fs::directory_iterator("/proc")) {
    std::ifstream f(e.path() / "comm");
    std::string s;
    std::getline(f, s);
    if (s == "MiSTer") {
      std::ifstream stat(e.path() / "stat");
      std::string text;
      std::getline(stat, text);
      auto end = text.rfind(") ");
      if (end != std::string::npos && text.size() > end + 2 &&
          text[end + 2] != 'Z')
        return true;
    }
  }
  return false;
}
#ifndef STANDALONE_TEST
class Spi {
  int fd = -1;
  volatile uint32_t *m = nullptr;
  uint32_t g = 0;
  static constexpr uint32_t STROBE = 1u << 17, CS = (7u << 18);
  void wr(uint32_t x) {
    g = x;
    m[4] = x;
  }

public:
  static constexpr uint32_t IO = 1u << 20, FIO = 1u << 18, OSD = 1u << 19;
  Spi() {
    std::ifstream core("/tmp/CORENAME");
    std::string core_name;
    std::getline(core, core_name);
    require(core_name == "NDS", "NDS FPGA must be loaded before taking SPI");
    require(!live_main(), "MiSTer must be stopped before taking SPI");
    fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    require(fd >= 0, "/dev/mem");
    m = (volatile uint32_t *)mmap(nullptr, 4096, PROT_READ | PROT_WRITE,
                                  MAP_SHARED, fd, 0xff706000);
    require(m != MAP_FAILED, "GPIO mmap");
    g = m[4];
    wr((g & ~(CS | STROBE)) | 0x80000000);
  }
  ~Spi() {
    if (m && m != MAP_FAILED) {
      wr((g & ~(CS | STROBE)) | 0x80000000);
      munmap((void *)m, 4096);
    }
    if (fd >= 0)
      close(fd);
  }
  uint16_t word(uint16_t v) {
    uint32_t low = (g & ~(65535u | STROBE)) | v;
    wr(low);
    wr(low | STROBE);
    auto wait = [&](bool high) {
      unsigned spins = 0;
      uint64_t deadline = 0;
      uint32_t r;
      do {
        r = m[5];
        if (r & 0x80000000)
          throw std::runtime_error("FPGA not ready");
        if (++spins % 256 == 0) {
          auto t = ms();
          if (!deadline)
            deadline = t + 100;
          else if (t > deadline)
            throw std::runtime_error("SPI timeout");
        }
      } while (bool(r & STROBE) != high);
      return r;
    };
    wait(true);
    wr(low);
    return uint16_t(wait(false));
  }
  uint16_t begin(uint32_t select, uint16_t cmd) {
    wr((g & ~CS) | select | 0x80000000);
    return word(cmd);
  }
  void end() { wr(g & ~CS); }
  void cmd(uint32_t select, uint16_t cmd,
           std::initializer_list<uint16_t> data = {}) {
    begin(select, cmd);
    for (auto d : data)
      word(d);
    end();
  }
  uint32_t buttons() { return (m[5] >> 29) & 3; }
};
#else
class Spi {
public:
  static constexpr uint32_t IO = 1u << 20, FIO = 1u << 18, OSD = 1u << 19;
  struct Transaction {
    uint32_t select;
    uint16_t command;
    std::vector<uint16_t> words;
  };
  std::vector<Transaction> history;
  std::vector<uint16_t> framebuffer_reply;
  size_t framebuffer_reply_index = 0;
  int framebuffer_fail_at = -1;
  std::function<uint16_t(uint32_t, uint16_t, size_t, uint16_t)> response;
  bool selected = false;
  unsigned end_count = 0;
  uint16_t default_firmware_flags = 0x23c, default_firmware_op = 0;
  uint16_t begin(uint32_t select, uint16_t command) {
    history.push_back({select, command, {}});
    selected = true;
    if (response) return response(select, command, 0, command);
    if (command == 0x45) return 0x4657;
    if (command == 0x40) {
      framebuffer_reply_index = 0;
      return framebufferWord();
    }
    return 0;
  }
  uint16_t word(uint16_t value) {
    history.back().words.push_back(value);
    if (response) return response(history.back().select, history.back().command, history.back().words.size(), value);
    if (history.back().command == 0x45) {
      if (history.back().words.size() == 1) { default_firmware_op = value; return default_firmware_flags; }
      if (history.back().words.size() == 2) {
        if (default_firmware_op == 1) default_firmware_flags |= 1;
        if (default_firmware_op == 3) default_firmware_flags &= ~3;
      }
      return 0;
    }
    if (history.back().command == 0x40) return framebufferWord();
    return 0;
  }
  uint16_t framebufferWord() {
    if (int(framebuffer_reply_index) == framebuffer_fail_at)
      throw std::runtime_error("mock framebuffer SPI failure");
    const auto i = framebuffer_reply_index++;
    return i < framebuffer_reply.size() ? framebuffer_reply[i] : 0;
  }
  void end() { selected = false; ++end_count; }
  void cmd(uint32_t select, uint16_t command,
           std::initializer_list<uint16_t> data = {}) {
    begin(select, command);
    for (auto d : data)
      word(d);
    end();
  }
  uint32_t buttons() { return 0; }
};
#endif
struct Pad {
  int fd = -1;
  std::string path;
  uint32_t joy = 0, menujoy = 0;
  unsigned combo = 0;
  std::string id;
  std::array<uint32_t, 32> map{}, system_map{}, menu_map{};
  std::array<bool, 1024> pressed{};
  int right_x = ABS_RX, right_y = ABS_RY;
  std::array<input_absinfo, ABS_CNT> abs{};
  std::array<bool, 2> digital_trigger{};
  bool disconnected = false;
  int x = 0, y = 0;
  uint16_t analog = 0;
  unsigned mouse = 0, lastmouse = 0;
  bool pad = false, touch_analog_valid = false;
};
class Host {
  friend struct HostTest;
  Spi spi;
  nds_osd::Frame frame{"NDS", charfont};
  std::string kit, romdir, savedir;
  fs::path sd_root;
  nds_storage::Preferences storage_preferences;
  std::unique_ptr<StorageJob> storage_job;
  bool storage_quiet = false;
  std::function<void(const std::string &)> storage_done;
  std::function<void(const std::string &)> storage_error;
  bool storage_choices = false, choosing_firmware = false,
       storage_devices = false;
  struct StorageChoice {
    std::string label;
    std::function<void()> select;
  };
  std::vector<StorageChoice> storage_rows;
  std::vector<fs::path> game_paths;
  std::string storage_caption = "Storage", storage_detail;
  int save = -1, heartbeat = -1;
  std::string game;
  std::optional<nds_firmware::Media> firmware;
  bool native_firmware = false, firmware_slot_mounted = false;
  bool firmware_rtc_seeded = false;
  bool firmware_failed = false, firmware_error_dialog = false;
  std::string firmware_error_title, firmware_error_text, personal_settings_notice;
  uint64_t next_firmware_poll = 0;
  // Opt-in troubleshooting only. No firmware bytes or personal profile fields.
  bool firmware_diagnostics = false;
  uint64_t firmware_read_requests = 0, firmware_write_requests = 0;
  uint64_t firmware_reads_completed = 0, firmware_writes_durable = 0;
  uint32_t firmware_last_lba = 0;
  unsigned firmware_last_operation = 0, firmware_unique_lbas_logged = 0;
  std::array<bool, 512> firmware_lba_logged{};
  uint16_t status = 0;
  std::array<uint16_t, 8> full_status{};
  std::vector<Pad> pads;
  std::vector<BrowserEntry> roms;
  int browser_first = 0, browser_selected_row = -1, loading_progress = -1;
  bool browse_expand = true;
  nds_osd::Row browser_base{}, footer_base{};
  std::array<nds_osd::Row, 16> osd_rows{};
  std::array<bool, 16> osd_row_valid{};
  uint64_t idle_since = 0;
  VersionFooter version_footer;
  fs::path currentdir, rom_browser_dir, core_root = "/media/fat";
  std::string selected_core;
  bool menu = true, browser = false, core_browser = false,
       system_menu = false, dirty = true;
  bool reset_confirm = false;
  bool lid_closed = false; // Session state, deliberately never saved to NDS_v1.CFG.
  bool screen_peek = false; // Temporary display override; status keeps the selection.
  TouchRotation touch_rotation = TouchRotation::Normal;
  static constexpr int TOUCH_ROTATION_CURSOR = 4, LID_CURSOR = 9,
                       RESET_CURSOR = 10, EXIT_CURSOR = 11;
  nds_video::Transmitter video_transmitter;
  nds_video::StablePacket video_packet;
  bool direct_video_metadata = false, video_osd_visible = false;
  bool video_write_failed = false;
  uint16_t video_flags = 0;
  void initializeVideoMetadata() {
    const auto signature = spi.begin(Spi::IO, 0x46);
    const auto flags = spi.word(0);
    spi.end();
    if (signature != 0x4456) return;
    video_flags = flags;
    if (!(flags & (1u << 10))) return;
    direct_video_metadata = video_transmitter.openInheritedBus();
    log(direct_video_metadata ? "DV1 metadata handoff ready" :
        "DV1 metadata unavailable: Main bus or DV1 packet missing");
  }
  void serviceVideoMetadata() {
    if (!direct_video_metadata) return;
    std::array<uint8_t, 31> packet{};
    if (!video_packet.ready(nds_video::readGeometry(spi), video_osd_visible, packet)) return;
    if (video_transmitter.writePacket(packet)) {
      video_packet.acknowledge(packet);
      video_write_failed = false;
    } else if (!video_write_failed) {
      log("DV1 metadata write failed; retrying");
      video_write_failed = true;
    }
  }
  std::vector<SystemMenuRow> system_rows;
  int system_first = 0;
  bool recent_view = false, recent_clear_confirm = false, recents_enabled = true;
  int recent_cursor = 0;
  std::vector<RecentFile> recent_entries;
  std::vector<fs::path> recent_paths;
  std::vector<bool> recent_available;
  int mapping_step = -1;
  std::string mapping_pad;
  std::array<uint32_t, 32> new_map{};
  static constexpr unsigned GAME_BUTTON_COUNT = 13;
  static constexpr unsigned VIDEO_LAYOUT_BUTTON = GAME_BUTTON_COUNT;
  static constexpr unsigned RESERVED_LID_SLOT = GAME_BUTTON_COUNT + 1;
  static constexpr unsigned MIC_BUTTON = GAME_BUTTON_COUNT + 2;
  static constexpr unsigned SCREEN_PEEK_BUTTON = GAME_BUTTON_COUNT + 3;
  static constexpr uint32_t LID_MASK = 1u << 13, MIC_MASK = 1u << 14;
  static constexpr std::array<const char *, GAME_BUTTON_COUNT + 3> button_names = {
      "Right", "Left", "Down", "Up",     "A",     "B",    "X",
      "Y",     "L",    "R",    "Select", "Start", "Touch", "Cycle Video Layout",
      "Blow into Mic", "Screen Peek"};
  // Keep the persisted 32-word mapping ABI: layout remains slot 13 and mic
  // remains slot 15. Slot 14 held the removed lid shortcut and is now ignored;
  // peek uses the previously unused slot 16.
  static constexpr std::array<unsigned, button_names.size()> button_slots = {
      0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, VIDEO_LAYOUT_BUTTON, MIC_BUTTON,
      SCREEN_PEEK_BUTTON};
  int cursor = 0, repeat_action = -1, repeat_code = -1;
  std::string repeat_pad;
  uint64_t next_repeat = 0, next_scroll = 0;
  unsigned scroll_offset = 0;
  uint32_t lastjoy = ~0u;
  uint64_t nextscan = 0, nextbeat = 0;
  int rotation = 0;
  uint64_t reads = 0, writes = 0;
  uint64_t framebuffer_snapshot_sequence = 0;
  std::string message;
  static bool readmap(const fs::path &file, std::array<uint32_t, 32> &map) {
    std::ifstream stream(file, std::ios::binary);
    std::array<uint32_t, 32> temp{};
    if (!stream.read((char *)temp.data(), sizeof(temp)) || stream.peek() != EOF)
      return false;
    map = temp;
    return true;
  }
  void readCoreMap(Pad &p, const fs::path &config) {
    const auto name = "NDS_input_" + p.id + "_v3.map";
    if (!readmap(config / name, p.map)) readmap(config.parent_path() / name, p.map);
    // These standalone-only bindings have no meaning in an imported Main map.
    // Load private maps unchanged so existing layout/mic slots remain usable.
    p.map[VIDEO_LAYOUT_BUTTON] = p.map[RESERVED_LID_SLOT] = p.map[MIC_BUTTON] =
        p.map[SCREEN_PEEK_BUTTON] = 0;
    readmap(fs::path(kit) / "inputs" / name, p.map);
  }
  void atomicFile(const fs::path &path, const void *data, size_t size) {
    auto temp = path.string() + ".new";
    int fd = open(temp.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    require(fd >= 0, "create settings");
    size_t done = 0;
    while (done < size) {
      auto n = write(fd, (const char *)data + done, size - done);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) break;
      done += size_t(n);
    }
    bool ok = done == size && fsync(fd) == 0;
    close(fd);
    require(ok, "save settings");
    fs::rename(temp, path);
    int directory = open(path.parent_path().c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    require(directory >= 0, "open config directory");
    ok = fsync(directory) == 0;
    close(directory);
    require(ok, "sync config directory");
  }
  void saveSettings() {
    status = cleanStatus(status);
    full_status[0] = status;
    atomicFile(fs::path(kit) / "NDS_v1.CFG", full_status.data(),
               sizeof(full_status));
    const std::string touch_config = "NDS-TouchRotation-v1\n" +
        std::string(TOUCH_ROTATION_NAMES[unsigned(touch_rotation)]) + "\n";
    atomicFile(fs::path(kit) / "NDS_touch.cfg", touch_config.data(), touch_config.size());
    message = "Settings saved";
  }
  void serviceFramebufferMetadataRequest() {
    if (!framebuffer_metadata_requested) return;
    // Coalesce requests. Signals only set the flag, never access SPI/files.
    // Clear before work so a request during this snapshot remains pending.
    framebuffer_metadata_requested = 0;
    const auto sequence = ++framebuffer_snapshot_sequence;
    try {
      const auto begin_us = monotonic_us();
      const auto metadata = FramebufferMetadata::read(spi);
      const auto end_us = monotonic_us();
      auto live_status = full_status;
      live_status[0] = liveStatus();
      auto data = metadata.json(sequence, unsigned(getpid()), begin_us,
                                end_us, live_status);
      if (firmware_diagnostics) {
        // This explicit snapshot runs inside the SPI owner's normal loop.
        // A diagnostic failure must not change firmware state or block video metadata.
        std::ostringstream diagnostic;
        diagnostic << "{\"read_requests\":" << firmware_read_requests
                   << ",\"write_requests\":" << firmware_write_requests
                   << ",\"reads_completed\":" << firmware_reads_completed
                   << ",\"writes_durable\":" << firmware_writes_durable
                   << ",\"last_lba\":" << firmware_last_lba
                   << ",\"last_operation\":" << firmware_last_operation
                   << ",\"unique_lbas_logged\":" << firmware_unique_lbas_logged;
        try {
          const auto state = firmwareControl();
          diagnostic << ",\"controller_status_available\":true,\"flags\":" << state.flags
                     << ",\"sequence\":" << state.sequence << ",\"error\":" << state.error;
          log("firmware diagnostic snapshot flags=" + std::to_string(state.flags) +
              " sequence=" + std::to_string(state.sequence) + " error=" + std::to_string(state.error) +
              " reads=" + std::to_string(firmware_reads_completed) +
              " writes_durable=" + std::to_string(firmware_writes_durable) +
              " last_lba=" + std::to_string(firmware_last_lba));
        } catch (const std::exception &error) {
          diagnostic << ",\"controller_status_available\":false";
          log(std::string("firmware diagnostic status unavailable: ") + error.what());
        }
        diagnostic << '}';
        data.insert(data.rfind("\n}"), ",\n  \"firmware_diagnostics\": " + diagnostic.str());
      }
      atomicFile(fs::path(kit) / "framebuffer-metadata.json", data.data(), data.size());
      const auto video = nds_video::readGeometry(spi);
      std::ostringstream video_json;
      video_json << "{\"width\":" << video.width << ",\"height\":" << video.height
                 << ",\"pixel_repeat\":" << video.repeat << ",\"de_h\":" << video.left
                 << ",\"de_v\":" << video.top << ",\"line_ticks_100mhz\":" << video.line_ticks
                 << ",\"frame_ticks_100mhz\":" << video.frame_ticks
                 << ",\"output_flags\":" << video_flags
                 << ",\"dv1_metadata_active\":" << (direct_video_metadata ? "true" : "false") << "}\n";
      const auto video_text = video_json.str();
      atomicFile(fs::path(kit) / "video-output-metadata.json", video_text.data(), video_text.size());
      log("framebuffer metadata snapshot=" + std::to_string(sequence));
    } catch (const std::exception &e) {
      // Diagnostics must not force recovery or repeatedly retry a failed read.
      log("framebuffer metadata snapshot=" + std::to_string(sequence) +
          " failed: " + e.what());
    }
  }
  fs::path storageConfig() const { return sd_root / "config/NDS_storage.cfg"; }
  void saveStorage() {
    const auto data = storage_preferences.encode();
    fs::create_directories(storageConfig().parent_path());
    atomicFile(storageConfig(), data.data(), data.size());
  }
  void showStorageChoices(std::string title, std::vector<StorageChoice> rows) {
    storage_caption = std::move(title);
    storage_detail.clear();
    storage_rows = std::move(rows);
    storage_choices = true;
    browser = core_browser = recent_view = false;
    cursor = browser_first = 0;
    dirty = true;
  }
  void storageFailure(const std::string &error,
                      const std::function<void()> &retry) {
    log("storage: " + error);
    showStorageChoices("Storage unavailable",
                       {{"Retry", retry},
                        {"Browse...", [this] { chooseStorageVolumes(); }},
                        {"Back", [this] {
                           storage_choices = false;
                           closeBrowser();
                           dirty = true;
                         }}});
    storage_detail = error;
  }
  void startStorage(const std::function<std::string()> &work,
                    std::function<void(const std::string &)> done,
                    std::function<void(const std::string &)> error = {},
                    bool quiet = false) {
    storage_job.reset();
    storage_quiet = quiet;
    storage_done = std::move(done);
    storage_error = std::move(error);
    try {
      storage_job = std::make_unique<StorageJob>(work);
    } catch (const std::exception &e) {
      if (storage_error)
        storage_error(e.what());
      else
        message = e.what();
    }
    dirty = true;
  }
  void pollStorage() {
    if (!storage_job)
      return;
    try {
      auto result = storage_job->poll();
      if (!result)
        return;
      storage_job.reset();
      auto done = std::move(storage_done);
      dirty = true;
      if (done)
        done(*result);
    } catch (const std::exception &e) {
      storage_job.reset();
      storage_done = {};
      auto error = std::move(storage_error);
      dirty = true;
      if (error)
        error(e.what());
      else
        storageFailure(e.what(), [this] { chooseStorageVolumes(); });
    }
  }
  // Both Load *.NDS and Boot DS firmware use the normal file browser.
  // The empty parent at a mounted volume's root leads to the device list;
  // its own ".." returns to the NDS menu rather than exposing Linux internals.
  void finishStorageBrowser() {
    browser = true;
    core_browser = recent_view = storage_choices = system_menu = false;
    cursor = browser_first = 0;
    scroll_offset = 0;
    next_scroll = ms() + 1000;
    dirty = true;
  }
  void chooseStorageVolumes() {
    const auto sd = sd_root;
    startStorage(
        [sd] {
          nds_storage::Fields fields;
          for (const auto &v : nds_storage::volumes(sd)) {
            fields.push_back(v.path.string());
            fields.push_back(v.path == sd ? "fat"
                             : v.path.parent_path() == "/media"
                                 ? v.path.filename().string()
                                 : v.path.string());
          }
          return nds_storage::pack(fields);
        },
        [this](const std::string &data) {
          const auto f = nds_storage::unpack(data);
          roms = {{"..", true}};
          game_paths = {fs::path{}};
          for (size_t i = 0; i + 1 < f.size(); i += 2) {
            roms.push_back({f[i + 1], true});
            game_paths.emplace_back(f[i]);
          }
          storage_devices = true;
          currentdir.clear();
          finishStorageBrowser();
        });
  }
  void discoverGames() {
    const auto sd = sd_root;
    startStorage(
        [sd] {
          nds_storage::Fields f;
          for (const auto &l : nds_storage::discover(nds_storage::volumes(sd)))
            f.push_back(l.path);
          return nds_storage::pack(f);
        },
        [this](const std::string &data) {
          const auto f = nds_storage::unpack(data);
          if (f.size() == 1)
            browseGames(f.front());
          else
            chooseStorageVolumes();
        },
        [this](const std::string &error) {
          storageFailure(error, [this] { discoverGames(); });
        });
  }
  void openGames() {
    choosing_firmware = false;
    // Only this session's running cartridge overrides the remembered folder.
    // A fresh host has no game and keeps the normal top-of-folder selection.
    if (!game.empty() && !native_firmware) {
      browseGames(fs::path(game).parent_path());
      return;
    }
    if (storage_preferences.games.empty()) {
      discoverGames();
      return;
    }
    const auto pref = storage_preferences;
    const auto sd = sd_root;
    startStorage(
        [pref, sd] {
          const auto root =
              nds_storage::resolve(pref.games, nds_storage::volumes(sd));
          // Accept the first candidate's root + last-subfolder format as well.
          auto dir = root / pref.last;
          std::error_code ec;
          if (!fs::is_directory(dir, ec))
            dir = root;
          return dir.string();
        },
        [this](const std::string &data) { browseGames(data); },
        [this](const std::string &error) {
          storageFailure(error, [this] { openGames(); });
        });
  }
  void openFirmware() {
    choosing_firmware = true;
    if (storage_preferences.firmware.empty()) {
      openFirmwareBrowser(true);
      return;
    }
    const auto location = storage_preferences.firmware;
    const auto sd = sd_root;
    // Probe removable/network storage in the cancellable reader, never in
    // the SPI owner. Missing files open the browser without holding the game.
    startStorage(
        [location, sd] {
          const auto source =
              nds_storage::resolve(location, nds_storage::volumes(sd));
          bool ready = true;
          for (const char *name : {"bios7.bin", "bios9.bin", "firmware.bin"}) {
            std::error_code ec;
            if (!fs::is_regular_file(source / name, ec))
              ready = false;
          }
          return nds_storage::pack({source.string(), ready ? "1" : "0"});
        },
        [this](const std::string &data) {
          const auto f = nds_storage::unpack(data);
          if (f.at(1) == "1")
            requestFirmware();
          else
            browseGames(f.at(0));
        },
        [this](const std::string &error) {
          log("remembered firmware unavailable: " + error);
          chooseStorageVolumes();
        }, true);
  }
  void openFirmwareBrowser(bool browse_unavailable = false) {
    choosing_firmware = true;
    const auto pref = storage_preferences;
    const auto sd = sd_root;
    const auto fallback = romdir;
    startStorage(
        [pref, sd, fallback] {
          const auto &location =
              pref.firmware.empty() ? pref.games : pref.firmware;
          return location.empty()
                     ? fallback
                     : nds_storage::resolve(location, nds_storage::volumes(sd))
                           .string();
        },
        [this](const std::string &data) { browseGames(data); },
        [this, browse_unavailable](const std::string &error) {
          if (browse_unavailable)
            chooseStorageVolumes();
          else
            storageFailure(error, [this] { openFirmwareBrowser(); });
        });
  }
  void browseGames(const fs::path &path) {
    const auto sd = sd_root;
    const bool firmwareMode = choosing_firmware;
    startStorage(
        [path, sd, firmwareMode] {
          const auto volumes = nds_storage::volumes(sd);
          const auto location = nds_storage::locate(path, volumes);
          const auto listing = nds_storage::directory(
              location.path, location.volume, false, firmwareMode);
          fs::path parent;
          const auto up = fs::path(location.path).parent_path();
          try {
            (void)nds_storage::owner(up, volumes);
            parent = up;
          } catch (const std::exception &) {
          }
          auto f = location.fields();
          f.push_back(parent.string());
          f.insert(f.end(), listing.begin() + 1, listing.end());
          return nds_storage::pack(f);
        },
        [this, firmwareMode](const std::string &data) {
          const auto f = nds_storage::unpack(data);
          const auto location = nds_storage::Location::parse(f);
          currentdir = location.path;
          roms = {{"..", true}};
          game_paths = {fs::path(f.at(4))};
          for (size_t i = 5; i + 1 < f.size(); i += 2) {
            roms.push_back({f[i], f[i + 1] == "1", firmwareMode});
            game_paths.push_back(currentdir / f[i]);
          }
          const auto previous = storage_preferences.encode();
          if (firmwareMode)
            storage_preferences.firmware = location;
          else {
            storage_preferences.games = location;
            storage_preferences.last = ".";
            romdir = location.path;
          }
          if (previous != storage_preferences.encode())
            saveStorage();
          storage_devices = false;
          finishStorageBrowser();
          if (!firmwareMode && !native_firmware && !game.empty()) {
            const auto active = fs::path(game).lexically_normal();
            for (size_t i = 0; i < game_paths.size(); ++i)
              if (!roms[i].directory && game_paths[i].lexically_normal() == active) {
                cursor = int(i);
                break;
              }
          }
        },
        [this, path](const std::string &error) {
          storageFailure(error, [this, path] { browseGames(path); });
        });
  }
  void requestFirmware() {
    choosing_firmware = true;
    const auto preferences = storage_preferences;
    const auto sd = sd_root;
    const auto fallback = romdir;
    startStorage(
        [preferences, sd, fallback] {
          const auto locations = nds_storage::volumes(sd);
          const auto &pref = preferences.firmware.empty()
                                 ? preferences.games
                                 : preferences.firmware;
          const auto source = pref.empty()
                                  ? fs::path(fallback)
                                  : nds_storage::resolve(pref, locations);
          const auto originals = nds_firmware::Media::readOriginals(source);
          nds_storage::Fields f;
          for (const auto *bytes :
               {&originals.bios7, &originals.bios9, &originals.firmware})
            f.emplace_back(reinterpret_cast<const char *>(bytes->data()),
                           bytes->size());
          for (const auto &id : originals.identities) {
            f.push_back(std::to_string(id.first));
            f.push_back(std::to_string(id.second));
          }
          return nds_storage::pack(f);
        },
        [this](const std::string &data) {
          auto f = nds_storage::unpack(data);
          if (f.size() != 9)
            throw std::runtime_error("Incomplete firmware read");
          nds_firmware::Media::Originals originals;
          originals.bios7.assign(f[0].begin(), f[0].end());
          originals.bios9.assign(f[1].begin(), f[1].end());
          originals.firmware.assign(f[2].begin(), f[2].end());
          for (size_t i = 3; i < 9; i += 2)
            originals.identities.emplace_back(std::stoull(f[i]),
                                              std::stoull(f[i + 1]));
          if (firmware)
            firmware->setOriginals(std::move(originals));
          else
            firmware.emplace(nds_firmware::Media::openPrepared(
                std::move(originals), firmwarePath()));
          storage_choices = false;
          try {
            bootFirmware();
          } catch (const std::exception &e) {
            firmwareError("Cannot boot DS firmware", e.what());
          }
        },
        [this](const std::string &error) {
          log("firmware source: " + error);
          showStorageChoices("BIOS/firmware unavailable",
                             {{"Retry", [this] { requestFirmware(); }},
                              {"Browse...", [this] { openFirmwareBrowser(); }},
                              {"Back", [this] {
                                 storage_choices = false;
                                 closeBrowser();
                                 dirty = true;
                               }}});
          storage_detail = error;
          firmware_error_text = error;
        }, true);
  }
  void drawStorage() {
    frame.setTitle(storage_job ? "Reading storage" : storage_caption);
    if (storage_job) {
      for (int y = 0; y < 16; ++y)
        line(y,
             y == 6    ? " Reading storage..."
             : y == 15 ? "           Cancel"
                       : "",
             y == 15);
    } else {
      std::array<std::string, 16> rows{};
      for (size_t i = 0; i < 8 && i * 28 < storage_detail.size(); ++i)
        rows[i + 1] = " " + storage_detail.substr(i * 28, 28);
      for (size_t i = 0; i < storage_rows.size() && i < 4; ++i)
        rows[i + 11] = " " + storage_rows[i].label;
      for (int y = 0; y < 16; ++y)
        line(y, rows[y], y == cursor + 11);
    }
    osd(true);
    dirty = false;
  }
  bool storageAction(int a) {
    if (!storage_job && !storage_choices)
      return false;
    if (storage_job) {
      if ((!storage_quiet && a == 2) || a == 3 || a == 4) {
        storage_job.reset();
        storage_done = {};
        storage_error = {};
        storage_choices = false;
        closeBrowser();
        dirty = true;
      }
      return true;
    }
    if (a == 3 || a == 4) {
      storage_choices = false;
      closeBrowser();
      dirty = true;
      return true;
    }
    const auto count = int(storage_rows.size());
    if (a == 0 && count)
      cursor = (cursor + count - 1) % count;
    if (a == 1 && count)
      cursor = (cursor + 1) % count;
    if (a == 2 && count) {
      auto select = storage_rows.at(cursor).select;
      select();
    }
    dirty = true;
    return true;
  }
  fs::path recentConfig() const {
    return sd_root / "config" /
        ("NDS_recent_" + std::to_string(LOAD_RECENT_INDEX) + ".cfg");
  }
  std::map<std::string, nds_storage::Location> recentLocations() const {
    const auto file = sd_root / "config/NDS_recent_locations.cfg";
    std::ifstream in(file);
    if (!in)
      return {};
    const auto fields = nds_storage::unpack(
        std::string(std::istreambuf_iterator<char>(in), {}));
    if (fields.size() % 5 || fields.size() > 80)
      throw std::runtime_error("Invalid recent storage locations");
    std::map<std::string, nds_storage::Location> result;
    for (size_t i = 0; i < fields.size(); i += 5)
      result[fields[i]] = nds_storage::Location::parse(fields, i + 1);
    return result;
  }
  void rememberLocation(const fs::path &path,
                        const std::vector<RecentFile> &entries) {
    auto locations = recentLocations();
    const auto directory = fs::absolute(path).parent_path().lexically_normal();
    const auto volumes = nds_storage::volumes(sd_root);
    const auto &volume = nds_storage::owner(directory, volumes);
    locations[directory.string()] = {
        directory.string(), volume.path.string(), volume.id,
        directory.lexically_relative(volume.path).string()};
    std::map<std::string, nds_storage::Location> kept;
    for (const auto &entry : entries) {
      auto p = fs::path(entry.directory);
      if (!p.is_absolute())
        p = sd_root / p;
      auto it = locations.find(p.lexically_normal().string());
      if (it != locations.end())
        kept.insert(*it);
    }
    nds_storage::Fields fields;
    for (const auto &[key, location] : kept) {
      fields.push_back(key);
      auto f = location.fields();
      fields.insert(fields.end(), f.begin(), f.end());
    }
    const auto data = nds_storage::pack(fields);
    fs::create_directories(sd_root / "config");
    atomicFile(sd_root / "config/NDS_recent_locations.cfg", data.data(),
               data.size());
  }
  void writeRecents(const std::vector<RecentFile> &entries) {
    const auto data = RecentFiles::encode(entries);
    fs::create_directories(recentConfig().parent_path());
    atomicFile(recentConfig(), data.data(), data.size());
    if (entries.empty()) {
      const auto empty = nds_storage::pack({});
      atomicFile(sd_root / "config/NDS_recent_locations.cfg", empty.data(),
                 empty.size());
    }
  }
  void remember(const fs::path &path) {
    if (!recents_enabled) return;
    // Share Main's list; reload before updating, so switching frontends never
    // discards the other frontend's history. A bad list is left untouched.
    auto entries = RecentFiles::read(recentConfig());
    auto dir = fs::absolute(path).parent_path().lexically_relative(sd_root);
    if (dir.empty() || *dir.begin() == "..")
      dir = fs::absolute(path).parent_path();
    RecentFiles::prepend(entries, {dir.string(), path.filename().string(), path.stem().string()});
    rememberLocation(path, entries);
    writeRecents(entries);
  }
  bool usableRecent(const fs::path &path) const {
    std::error_code ec;
    const auto canonical = fs::canonical(path, ec);
    if (ec)
      return false;
    try {
      (void)nds_storage::owner(canonical, nds_storage::volumes(sd_root));
    } catch (...) {
      return false;
    }
    auto ext = path.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    if (ext != ".nds" || !fs::is_regular_file(canonical, ec) || ec)
      return false;
    const auto size = fs::file_size(canonical, ec);
    return !ec && RomReader::validSize(size);
  }
  void openRecents() {
    choosing_firmware = false;
    if (!recents_enabled)
      return;
    try {
      recent_entries = RecentFiles::read(recentConfig());
      if (recent_entries.empty()) {
        message = " No recent files";
        return;
      }
      recent_paths.clear();
      recent_available.clear();
      roms.clear();
      for (const auto &entry : recent_entries) {
        auto path = fs::path(entry.directory) / entry.name;
        if (!path.is_absolute())
          path = sd_root / path;
        recent_paths.push_back(path);
        roms.push_back({entry.label, false});
      }
      auto paths = recent_paths;
      const auto pref = storage_preferences.games;
      const auto identities = recentLocations();
      startStorage(
          [this, paths, pref, identities] {
            nds_storage::Fields result;
            fs::path resolved;
            try {
              if (!pref.empty())
                resolved =
                    nds_storage::resolve(pref, nds_storage::volumes(sd_root));
            } catch (...) {
            }
            const auto volumes = nds_storage::volumes(sd_root);
            for (auto path : paths) {
              bool found = true;
              const auto identity = identities.find(
                  path.parent_path().lexically_normal().string());
              if (identity != identities.end()) {
                try {
                  path = nds_storage::resolve(identity->second, volumes) /
                         path.filename();
                } catch (...) {
                  found = false;
                }
              } else if (!resolved.empty() &&
                         nds_storage::inside(path, pref.path))
                path = resolved / path.lexically_relative(pref.path);
              result.push_back(path.string());
              result.push_back(found && usableRecent(path) ? "1" : "0");
            }
            return nds_storage::pack(result);
          },
          [this](const std::string &data) {
            const auto f = nds_storage::unpack(data);
            for (size_t i = 0; i + 1 < f.size(); i += 2) {
              recent_paths[i / 2] = f[i];
              recent_available.push_back(f[i + 1] == "1");
            }
            browser = recent_view = true;
            storage_choices = core_browser = system_menu = false;
            cursor = browser_first = 0;
            scroll_offset = 0;
            next_scroll = ms() + 1000;
            dirty = true;
          });
    } catch (const std::exception &e) {
      message = " Cannot read recent files";
      log(e.what());
    }
  }
  void loadRecent() {
    const auto selected = cursor;
    if (!recent_available.at(selected))
      return;
    const auto path = recent_paths.at(selected);
    const auto records = recentLocations();
    const auto &entry = recent_entries.at(selected);
    auto original = fs::path(entry.directory);
    if (!original.is_absolute())
      original = sd_root / original;
    const auto record = records.find(original.lexically_normal().string());
    const auto identity =
        record == records.end() ? nds_storage::Location{} : record->second;
    startStorage(
        [this, path, identity] {
          if (!identity.empty()) {
            try {
              if (nds_storage::resolve(identity,
                                       nds_storage::volumes(sd_root)) !=
                  path.parent_path())
                return std::string("0");
            } catch (...) {
              return std::string("0");
            }
          }
          return std::string(usableRecent(path) ? "1" : "0");
        },
        [this, path, selected](const std::string &result) {
          recent_available.at(selected) = result == "1";
          if (result == "1") {
            try {
              load(path.string());
            } catch (const std::exception &e) {
              firmwareError("Cannot load game", e.what());
            }
          }
        });
  }
  void browse(const fs::path &where) {
    const auto root = fs::weakly_canonical(core_browser ? core_root : fs::path(romdir));
    currentdir = fs::weakly_canonical(where);
    roms.clear();
    if (currentdir != root)
      roms.push_back({"..", true});
    std::vector<BrowserEntry> entries;
    std::error_code ec;
    for (auto &e : fs::directory_iterator(currentdir, ec)) {
      beat();
      if (e.path().filename().string().front() == '.')
        continue;
      auto target = fs::weakly_canonical(e.path(), ec);
      if (ec)
        continue;
      auto relative = target.lexically_relative(root);
      if (relative.empty() || *relative.begin() == "..")
        continue;
      if (e.is_directory(ec))
        entries.push_back({e.path().filename().string(), true});
      else if (e.is_regular_file(ec)) {
        std::string ext = e.path().extension().string();
        std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
        auto size = e.file_size(ec);
        const bool accepted = core_browser
            ? (ext == ".rbf" || ext == ".mra" || ext == ".mgl") && size > 0
            : ext == ".nds" && RomReader::validSize(size);
        if (!ec && accepted)
          entries.push_back({e.path().filename().string(), false});
      }
    }
    std::sort(entries.begin(), entries.end(),
              [](const BrowserEntry &a, const BrowserEntry &b) {
                if (a.directory != b.directory)
                  return a.directory;
                std::string x = a.name, y = b.name;
                std::transform(x.begin(), x.end(), x.begin(), ::tolower);
                std::transform(y.begin(), y.end(), y.begin(), ::tolower);
                return x < y;
              });
    roms.insert(roms.end(), entries.begin(), entries.end());
    cursor = 0;
    browser_first = 0;
    scroll_offset = 0;
    next_scroll = ms() + 1000;
    dirty = true;
  }
  void openCoreBrowser() {
    rom_browser_dir = currentdir;
    browser = core_browser = true;
    const auto console = core_root / "_Console";
    browse(fs::is_directory(console) ? console : core_root);
  }
  void closeBrowser() {
    const bool was_firmware = choosing_firmware && !core_browser;
    choosing_firmware = storage_devices = false;
    if (core_browser) currentdir = rom_browser_dir;
    system_menu = core_browser;
    browser = core_browser = recent_view = recent_clear_confirm = false;
    cursor = was_firmware ? 1 : 0;
  }
  void selectCore(const fs::path &path) {
    const auto target = fs::canonical(path);
    const auto relative = target.lexically_relative(fs::canonical(core_root));
    const auto name = target.string();
    auto ext = target.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), ::tolower);
    require(!relative.empty() && *relative.begin() != ".." &&
                fs::is_regular_file(target) && fs::file_size(target) > 0 &&
                (ext == ".rbf" || ext == ".mra" || ext == ".mgl") &&
                name.find_first_of("\r\n") == std::string::npos && name.size() < 1000,
            "selected core");
    // The supervisor consumes this only after a clean exit. run() drains
    // cartridge writes and persists the request before releasing SPI.
    selected_core = name;
    running = 0;
    log("core selected " + name);
  }
  void beat() {
    uint64_t t = ms();
    if (t >= nextbeat) {
      RomReader::reap();
      StorageJob::reap();
      std::string s = std::to_string(t);
      require(pwrite(heartbeat, s.data(), s.size(), 0) == (ssize_t)s.size(),
              "heartbeat write");
      require(ftruncate(heartbeat, s.size()) == 0, "heartbeat truncate");
      nextbeat = t + 500;
      serviceVideoMetadata();
    }
  }
  uint16_t liveStatus() const {
    const auto selected = normalizeDisplayStatus(status | REQUIRED_STATUS);
    // Layouts 2/3 are the individual panels. Flipping bit 5 exchanges them
    // without changing timing, rotation, screen order or the saved selection.
    return screen_peek && (selected & (1u << 6)) ? selected ^ (1u << 5) : selected;
  }
  void syncScreenPeek() {
    bool held = false;
    if (!menu)
      for (const auto &p : pads) {
        if (p.disconnected) continue;
        const auto binding = p.map[SCREEN_PEEK_BUTTON];
        const unsigned lo = binding & 65535, hi = binding >> 16;
        held |= p.pressed[KEY_F10] ||
                (lo && lo < p.pressed.size() && p.pressed[lo]) ||
                (hi && hi < p.pressed.size() && p.pressed[hi]);
      }
    const auto before = liveStatus();
    screen_peek = held;
    if (liveStatus() != before) sendstatus();
  }
  void sendstatus() {
    // Preserve transient reset bit0 while overriding legacy Engine B Off.
    status = normalizeDisplayStatus(status | REQUIRED_STATUS);
    spi.begin(Spi::IO, 0x1e);
    spi.word(liveStatus());
    for (int i = 1; i < 8; i++)
      spi.word(full_status[i]);
    spi.end();
  }
  void joy(uint32_t j) {
    if (lid_closed) j |= LID_MASK;
    if (j != lastjoy) {
      spi.cmd(Spi::IO, 2, {uint16_t(j), uint16_t(j >> 16)});
      lastjoy = j;
    }
  }
  void toggleLid() {
    lid_closed = !lid_closed;
    joy(menu ? 0 : (lastjoy & ~LID_MASK));
    dirty = true;
    log(lid_closed ? "lid closed" : "lid opened");
  }
  void clearConsoleInputs() {
    lid_closed = false;
    // A reset/new ROM must not inherit a held microphone or DS button.
    for (auto &p : pads) {
      p.pressed.fill(false);
      p.joy = p.menujoy = p.combo = 0;
    }
    syncScreenPeek();
    neutralInput();
  }
  void reset() {
    firmwareControl(1);
    clearConsoleInputs();
    flushFirmware();
    if (native_firmware) uploadNativeFirmwareAssets();
    else uploadDirectGameAssets();
    drain(450);
    status |= 1;
    sendstatus();
    usleep(20000);
    status &= ~1;
    sendstatus();
    firmwareControl(native_firmware ? 2 : 3);
    waitFirmware(native_firmware ? 0x43 : 3, native_firmware ? 0x42 : 0,
                 3000, "reset release");
    log("reset");
  }
  void osd(bool en, bool message_window = false) {
    video_osd_visible = en;
    if (!en) osd_row_valid.fill(false); // disable also clears FPGA highres
    spi.begin(Spi::OSD, en ? (message_window ? 0x49 : 0x41) : 0x40);
    if (en) {
      for (int i = 0; i < 4; i++)
        spi.word(0);
      spi.word(rotation == 1 ? 3 : rotation == 2 ? 1 : 0);
    }
    spi.end();
  }
  void writeRow(int y, const nds_osd::Row &bytes) {
    if (osd_row_valid[y] && osd_rows[y] == bytes) return;
    spi.begin(Spi::OSD, 0x20 | y);
    for (auto byte : bytes)
      spi.word(byte);
    spi.end();
    osd_rows[y] = bytes;
    osd_row_valid[y] = true;
  }
  void line(int y, std::string s, bool inverse = false, unsigned arrows = 0) {
    writeRow(y, frame.renderRow(y, s, inverse, arrows));
  }
  void drawBrowser() {
    if (recent_view) {
      frame.setTitle("Recent Files");
      browser_selected_row = cursor;
      for (int row = 0; row < 16; ++row) {
        std::string text;
        if (row < int(recent_entries.size())) {
          const auto &name = recent_entries[row].label;
          text = " " + name.substr(0, 27);
          if (name.size() > 27) text += char(22);
          if (!recent_available[row]) text.insert(text.begin(), char(0x0b));
        }
        auto bytes = frame.renderRow(row, text, row == cursor);
        writeRow(row, bytes);
        if (row == cursor) browser_base = bytes;
      }
      return;
    }
    frame.setTitle(core_browser        ? "Cores"
                   : choosing_firmware ? "Firmware"
                                       : "Select");
    const auto view = browserView(roms, cursor, browser_first, browse_expand, core_browser);
    browser_first = view.first;
    browser_selected_row = view.selected_row;
    for (int row = 0; row < 16; ++row) {
      const auto bytes = frame.renderRow(row, view.rows[row], view.selected[row], 0, view.markers[row]);
      writeRow(row, bytes);
      if (row == browser_selected_row) browser_base = bytes;
    }
  }
  void animateMenu(uint64_t now) {
    if (!menu || storage_job || storage_choices || mapping_step >= 0 ||
        reset_confirm || recent_clear_confirm || firmware_error_dialog)
      return;
    if (browser) {
      if (roms.empty() || browser_selected_row < 0 || now < next_scroll) return;
      if (recent_view) {
        const auto name = " " + recent_entries[cursor].label;
        if (!recent_available[cursor] || name.size() <= 28) return;
        scroll_offset = (scroll_offset + 1) % ((name.size() + 10) * 8);
        next_scroll = now + 10;
        writeRow(cursor, frame.scrollRow(cursor, browser_base, name, scroll_offset, 232, true));
        return;
      }
      const auto &entry = roms[cursor];
      const auto name = browserName(entry, core_browser);
      if (entry.directory ? name.size() <= 21 : name.size() <= 28 || (browse_expand && name.size() < 55)) return;
      scroll_offset = (scroll_offset + 1) % ((name.size() + 10) * 8);
      next_scroll = now + 10;
      writeRow(browser_selected_row, frame.scrollRow(browser_selected_row, browser_base,
               name, scroll_offset, entry.directory ? 176 : 232, true));
    } else if (!system_menu) { // Main's System page sets helptext_idx = 0.
      if (auto footer = version_footer.advance(frame, footer_base, CORE_VERSION, now))
        writeRow(15, *footer);
    }
  }
  void beginLoading(const std::string &name) {
    // Disabling first clears the FPGA high-resolution latch from the 16-row
    // picker. Write ONLY rows 0..7 before enabling Main's message mode.
    osd(false);
    osd_row_valid.fill(false);
    frame.setTitle("Loading", 8);
    const auto rows = loadingRows(name, 0);
    for (int row = 0; row < 8; ++row) line(row, rows[row]);
    loading_progress = 0;
    osd(true, true);
  }
  void updateLoading(uint64_t done, uint64_t total) {
    const auto progress = loadingProgress(done, total);
    if (progress == loading_progress) return;
    loading_progress = progress;
    line(4, loadingBar(progress));
  }
  void drawSystem() {
    frame.setTitle("System");
    const auto view = systemMenuView(system_rows, cursor, system_first);
    system_first = view.first;
    for (int y = 0; y < 16; ++y) {
      const auto &row = view.rows[y];
      const auto text = row.disabled ? std::string(1, char(0x0b)) + row.text : row.text;
      writeRow(y, frame.renderRow(y, text, y == view.selected, row.arrows, view.markers[y]));
    }
    osd(true);
    dirty = false;
  }
  void draw() {
    if (!menu)
      return;
    if (storage_job || storage_choices) {
      if (storage_job && storage_quiet) {
        // Known firmware goes straight from the current menu to its normal
        // boot progress; do not flash a picker or generic storage overlay.
        dirty = false;
        return;
      }
      drawStorage();
      return;
    }
    if (browser && !recent_clear_confirm && !firmware_error_dialog) {
      drawBrowser();
      osd(true);
      dirty = false;
      return;
    }
    if (system_menu && mapping_step < 0 && !reset_confirm && !recent_clear_confirm && !firmware_error_dialog) {
      drawSystem();
      return;
    }
    std::array<std::string, 16> rows{};
    int selected = -1;
    if (firmware_error_dialog) {
      frame.setTitle("Firmware");
      rows[1] = " " + firmware_error_title;
      std::string remaining = firmware_error_text;
      for (unsigned row = 3; row < 14 && !remaining.empty(); ++row) {
        size_t length = std::min<size_t>(28, remaining.size());
        if (length < remaining.size()) {
          const auto space = remaining.rfind(' ', length);
          if (space != std::string::npos && space) length = space;
        }
        rows[row] = " " + remaining.substr(0, length);
        remaining.erase(0, length);
        while (!remaining.empty() && remaining.front() == ' ') remaining.erase(0, 1);
      }
      rows[15] = "       Return to menu";
      selected = 15;
    } else if (mapping_step >= 0) {
      frame.setTitle("Define buttons");
      rows[3] = " Press: " + std::string(button_names[mapping_step]);
      rows[7] = " Space: Skip    Esc: Cancel";
      rows[10] = " Saved for standalone only";
      rows[12] = " System mappings are retained";
    } else if (recent_clear_confirm) {
      frame.setTitle("Recent Files");
      rows[6] = "        Clear the List?";
      rows[8] = "             No";
      rows[9] = "             Yes";
      selected = cursor == 0 ? 8 : 9;
    } else if (reset_confirm) {
      frame.setTitle("Reset");
      rows[1] = "       Reset settings?";
      rows[3] = "             yes";
      rows[4] = "             no";
      selected = cursor == 0 ? 3 : 4;
    } else {
      frame.setTitle("NDS");
      rows[0] = " " + std::string(LOAD_LABEL);
      rows[1] = " Boot DS firmware";
      for (size_t i = 0; i < CORE_OPTIONS.size(); i++) {
        auto option = CORE_OPTIONS[i];
        if (i == 0 && (status & CRT_TIMING)) {
          option.label = "CRT Screen";
          const bool reversed = status & (1u << 7);
          option.values[2] = reversed ? "Touch" : "Main";
          option.values[3] = reversed ? "Main" : "Touch";
        }
        rows[i + 3 + (i >= 2)] = optionLabel(status, option);
      }
      rows[5] = optionLabel(unsigned(touch_rotation),
          {0, 2, 3, "Touch Rotation", {"Normal", "90 CCW", "90 CW"}});
      rows[11] = lid_closed ? " Lid: Closed (Open)" : " Lid: Open (Close)";
      rows[13] = " Reset";
      rows[14] = message.empty() ? personal_settings_notice : message;
      rows[15] = "            exit";
      selected = cursor <= 1 ? cursor
                 : cursor < LID_CURSOR ? cursor + 1
                 : cursor == LID_CURSOR ? 11
                 : cursor == RESET_CURSOR ? 13
                               : 15;
    }
    const unsigned arrows = browser || mapping_step >= 0 || reset_confirm || recent_clear_confirm || firmware_error_dialog ? 0
                            : system_menu ? nds_osd::arrow_left
                                          : nds_osd::arrow_right;
    for (int i = 0; i < 16; i++)
      line(i, rows[i], i == selected, arrows);
    footer_base = frame.renderRow(15, rows[15], selected == 15, arrows);
    osd(true);
    dirty = false;
  }
  void neutralInput() {
    spi.cmd(Spi::IO, 4, {8, 0, 0});
    joy(0);
  }
  void togglemenu() {
    neutralInput();
    menu = !menu;
    syncScreenPeek();
    if (core_browser) closeBrowser();
    browser = system_menu = reset_confirm = false;
    recent_view = recent_clear_confirm = choosing_firmware = storage_devices =
        false;
    mapping_step = -1;
    cursor = 0;
    dirty = true;
    message.clear();
    repeat_action = -1;
    scroll_offset = 0;
    idle_since = ms();
    version_footer.reset(idle_since);
    osd(menu);
    if (!menu)
      for (const auto &p : pads)
        if (p.touch_analog_valid) {
          spi.cmd(Spi::IO, 0x3d, {0, rotateTouchAnalog(p.analog, touch_rotation)});
          break;
        }
    log(menu ? "menu opened" : "menu closed");
  }
  void action(int a) { // up, down, accept, back, menu, left, right, minus, plus, recent
    if (storageAction(a))
      return;
    if (firmware_error_dialog) {
      if (a == 2 || a == 3 || a == 4) {
        firmware_error_dialog = false;
        menu = true;
        browser = system_menu = false;
        cursor = 1;
        dirty = true;
      }
      return;
    }
    if (a == 4) {
      togglemenu();
      return;
    }
    if (!menu || mapping_step >= 0)
      return;
    if (recent_clear_confirm) {
      if (a == 0 || a == 1) cursor ^= 1;
      if (a == 2 || a == 3) {
        const bool accepted = a == 2 && cursor == 1;
        recent_clear_confirm = false;
        cursor = recent_cursor;
        if (accepted) {
          try {
            writeRecents({});
            closeBrowser();
          } catch (const std::exception &e) {
            log(e.what());
            message = " Cannot clear recent files";
          }
        }
      }
      dirty = true;
      return;
    }
    if (reset_confirm) {
      if (a == 0 || a == 1) cursor ^= 1;
      if (a == 2 || a == 3) {
        const bool accepted = a == 2 && cursor == 0;
        reset_confirm = false;
        system_menu = !accepted;
        cursor = accepted ? 0 : 2;
        if (accepted) {
          // Reset frontend options without pulsing reset; both engines stay on.
          status = REQUIRED_STATUS;
          full_status.fill(0);
          touch_rotation = TouchRotation::Normal;
          saveSettings();
          sendstatus();
          message = "Defaults restored";
        }
      }
      dirty = true;
      return;
    }
    if (a == 9) {
      if (recent_view) closeBrowser();
      else if (!choosing_firmware &&
               ((browser && !core_browser) || (!system_menu && cursor == 0)))
        openRecents();
      dirty = true;
      return;
    }
    scroll_offset = 0;
    idle_since = ms();
    version_footer.reset(idle_since);
    next_scroll = idle_since + 1000;
    int count = browser ? (int)roms.size() : system_menu ? 6 : EXIT_CURSOR + 1;
    if (a == 0 && count)
      cursor = (cursor + count - 1) % count;
    if (a == 1 && count)
      cursor = (cursor + 1) % count;
    if (a == 3) {
      if (browser) {
        closeBrowser();
      } else if (system_menu) {
        system_menu = false;
        cursor = 0;
      } else
        togglemenu();
    }
    if (a == 2 || a == 5 || a == 6 || a == 7 || a == 8) {
      if (browser) {
        if (a == 2 && !roms.empty()) {
          if (recent_view) {
            try { loadRecent(); }
            catch (const std::exception &e) { firmwareError("Cannot load recent game", e.what()); }
          } else {
            auto entry = roms.at(cursor);
            auto path = currentdir / entry.name;
            if (!core_browser && game_paths.size() == roms.size()) {
              path = game_paths.at(cursor);
              if (path.empty()) {
                if (storage_devices)
                  closeBrowser();
                else
                  chooseStorageVolumes();
              } else if (entry.directory)
                browseGames(path);
              else if (choosing_firmware)
                requestFirmware();
              else {
                try {
                  load(path.string());
                } catch (const std::exception &e) {
                  firmwareError("Cannot load game", e.what());
                }
              }
            } else if (entry.directory)
              browse(path);
            else if (core_browser) selectCore(path);
            else {
              try { load(path.string()); }
              catch (const std::exception &e) { firmwareError("Cannot load game", e.what()); }
            }
          }
        } else if (a == 5 || a == 6) {
          if (count)
            cursor = std::clamp(cursor + (a == 5 ? -16 : 16), 0, count - 1);
        }
      } else if (system_menu) {
        if (a == 2)
          switch (cursor) {
          case 0:
            openCoreBrowser();
            break;
          case 1:
            mapping_step = 0;
            mapping_pad.clear();
            new_map.fill(0);
            break;
          case 2:
            reset_confirm = true;
            cursor = 1; // Main defaults to No.
            break;
          case 3:
            saveSettings();
            system_menu = false;
            cursor = 0;
            break;
          case 4:
            running = 0;
            break;
          case 5:
            togglemenu();
            break;
          }
        else if (a == 5) {
          system_menu = false;
          cursor = 0;
        }
      } else if (a == 6) {
        // Main's generic core menu treats Right as page navigation even
        // when an option is selected. Values use Select or +/- instead.
        system_menu = true;
        cursor = 0;
      } else if ((a == 2 || a == 7 || a == 8) && cursor == TOUCH_ROTATION_CURSOR) {
        touch_rotation = TouchRotation((unsigned(touch_rotation) + (a == 7 ? 2 : 1)) % 3);
        message.clear();
      } else if ((a == 2 || a == 7 || a == 8) && cursor >= 2 && cursor < LID_CURSOR) {
        const auto &o = CORE_OPTIONS[cursor - 2 - (cursor > TOUCH_ROTATION_CURSOR)];
        status = changeOption(status, o, a == 7 ? -1 : 1);
        if (o.shift == 5 && (status & CRT_TIMING) && !(status & (1u << 6)))
          status = (status & ~(3u << 5)) | ((a == 7 ? 3u : 2u) << 5);
        sendstatus();
        message.clear();
      } else if (a == 2) {
        switch (cursor) {
        case 0:
          openGames();
          break;
        case 1:
          openFirmware();
          break;
        case LID_CURSOR:
          toggleLid();
          break;
        case RESET_CURSOR:
          try { reset(); togglemenu(); }
          catch (const std::exception &e) { firmwareError("Cannot reset firmware", e.what()); }
          break;
        case EXIT_CURSOR:
          togglemenu();
          break;
        }
      }
    }
    log("menu selection=" + std::to_string(cursor) + " browser=" +
        std::to_string(browser) + " system=" + std::to_string(system_menu) +
        " status=" + std::to_string(status));
    dirty = true;
  }
  struct FirmwareStatus {
    uint16_t flags = 0, sequence = 0, error = 0;
  };
  FirmwareStatus firmwareControl(uint16_t operation = 0, uint16_t argument = 0) {
    try {
      const auto magic = spi.begin(Spi::IO, 0x45);
      if (magic != 0x4657)
        throw std::runtime_error("This FPGA core does not support DS firmware boot");
      FirmwareStatus result;
      result.flags = spi.word(operation);
      result.sequence = spi.word(argument);
      result.error = spi.word(0);
      spi.end();
      return result;
    } catch (...) { spi.end(); throw; }
  }
  void firmwareError(const std::string &title, const std::string &detail) {
    firmware_error_title = title;
    firmware_error_text = detail;
    firmware_error_dialog = true;
    menu = true;
    syncScreenPeek();
    browser = system_menu = false;
    recent_view = recent_clear_confirm = choosing_firmware = storage_devices =
        false;
    mapping_step = -1;
    neutralInput();
    dirty = true;
    log(title + ": " + detail);
  }
  fs::path firmwarePath() const {
    return sd_root / "saves/NDS/firmware.bin";
  }
  void ensureFirmware() {
    if (firmware_failed)
      throw std::runtime_error("Firmware storage failed. Correct the storage problem and restart standalone; saved copies were preserved.");
    if (!firmware) {
      const auto &pref = storage_preferences.firmware.empty()
                             ? storage_preferences.games
                             : storage_preferences.firmware;
      const auto source =
          pref.empty()
              ? fs::path(romdir)
              : nds_storage::resolve(pref, nds_storage::volumes(sd_root));
      firmware.emplace(nds_firmware::Media::open(source, firmwarePath()));
    }
    if (firmware) {
      const auto profile = firmware->profile();
      // The experimental FPGA TSC currently supplies pixel<<4 samples. Do not
      // silently rewrite the user's physical calibration to make it fit.
      const auto identity = [](const nds_firmware::CalibrationAxis &axis) {
        return axis.pixel1 != axis.pixel2 && axis.adc1 == unsigned(axis.pixel1) * 16 &&
               axis.adc2 == unsigned(axis.pixel2) * 16;
      };
      if (!identity(profile.x) || !identity(profile.y))
        throw std::runtime_error("This firmware's touch calibration is not supported by this experimental core. Original data was preserved.");
      if (profile.nonadjacent_counters)
        log("firmware profile uses native primary-copy selection for nonadjacent counters");
    }
  }
  void mountFirmware() {
    if (!firmware || firmware_slot_mounted) return;
    const uint64_t size = nds_firmware::image_size;
    spi.begin(Spi::IO, 0x1d);
    for (unsigned i = 0; i < 4; ++i) spi.word(uint16_t(size >> (16 * i)));
    spi.end();
    spi.cmd(Spi::IO, 0x1c, {2});
    firmware_slot_mounted = true;
  }
  FirmwareStatus waitFirmware(uint16_t mask, uint16_t desired, unsigned timeout,
                              const char *description) {
    const auto deadline = ms() + timeout;
    for (;;) {
      if (!running) throw std::runtime_error("Firmware operation interrupted");
      if (firmware_failed) throw std::runtime_error("Firmware storage failed; saved copies were preserved");
      beat();
      sector();
      const auto state = firmwareControl();
      if (state.flags & 0x80)
        throw std::runtime_error("Firmware controller error " + std::to_string(state.error));
      if ((state.flags & mask) == desired) return state;
      if (ms() >= deadline) throw std::runtime_error(std::string("Timed out waiting for ") + description);
      usleep(1000);
    }
  }
  void flushFirmware() {
    if (!firmware_slot_mounted) return;
    if (firmware_failed) throw std::runtime_error("Firmware save failed; restart standalone after correcting storage");
    firmwareControl(4);
    waitFirmware(0x120, 0x20, 10000, "firmware settings to reach disk");
  }
  template<class Container> void uploadAsset(uint16_t index, const Container &bytes) {
    if (bytes.empty() || (bytes.size() & 1))
      throw std::runtime_error("Invalid firmware asset size");
    try {
      spi.cmd(Spi::FIO, 0x55, {index});
      // Normal FIO transfers carry the starting byte address, not file length.
      spi.cmd(Spi::FIO, 0x53, {1, 0, 0});
      for (size_t offset = 0; offset < bytes.size(); offset += 512) {
        if (!running) throw std::runtime_error("Firmware asset load interrupted");
        beat();
        spi.begin(Spi::FIO, 0x54);
        for (size_t i = offset; i < std::min(bytes.size(), offset + 512); i += 2)
          spi.word(uint16_t(bytes[i]) | uint16_t(bytes[i + 1]) << 8);
        spi.end();
      }
      spi.cmd(Spi::FIO, 0x53, {0});
    } catch (...) {
      // End even an incomplete epoch so a retry has a fresh download edge.
      // The held controller rejects the short asset and never releases CPUs.
      spi.end();
      try { spi.cmd(Spi::FIO, 0x53, {0}); } catch (...) { spi.end(); }
      throw;
    }
  }
  void uploadNativeFirmwareAssets() {
    ensureFirmware();
    uploadAsset(4, firmware->bios7());
    uploadAsset(5, firmware->bios9());
    const auto profile = firmware->profile();
    std::array<uint8_t, 120> bytes{};
    const uint32_t checksums = uint32_t(profile.data_gfx_crc) | uint32_t(profile.gui_wifi_crc) << 16;
    for (unsigned i = 0; i < 4; ++i) {
      bytes[i] = uint8_t(profile.user_offset >> (8 * i));
      bytes[i + 4] = uint8_t(checksums >> (8 * i));
    }
    std::copy(profile.bytes.begin(), profile.bytes.end(), bytes.begin() + 8);
    uploadAsset(6, bytes);
    waitFirmware(0x1c, 0x1c, 3000, "BIOS and user profile upload");
  }
  void uploadDirectGameAssets() {
    // No native Media import, BIOS files or calibration validation for games.
    // When leaving GUI, the caller has already held and durably flushed it.
    const auto personal = firmware ? nds_firmware::projectPersonalImage(firmware->image())
                                   : nds_firmware::readGamePersonalProfile(firmwarePath());
    personal_settings_notice = personal.warning.empty() ? "" : " Built-in personal settings";
    if (!personal.warning.empty()) log(personal.warning);
    uploadAsset(4, nds_firmware::freebios7);
    uploadAsset(5, nds_firmware::freebios9);
    uploadAsset(7, personal.pages);
    // Bit9 is the new exact512-byte direct upload's completion acknowledgement.
    // An older core cannot release with an ignored upload/stale native profile.
    waitFirmware(0x21c, 0x21c, 3000, "built-in BIOS and personal settings upload");
  }
  void seedFirmwareClock() {
    if (firmware_rtc_seeded) return;
    const auto now = std::time(nullptr);
    std::tm date{};
    if (now == std::time_t(-1) || !localtime_r(&now, &date) ||
        date.tm_year < 100 || date.tm_year > 199)
      throw std::runtime_error("Set the MiSTer clock to a date between 2000 and 2099 before booting DS firmware");
    const auto bcd = [](unsigned value) { return uint8_t((value / 10) * 16 + value % 10); };
    const std::array<uint8_t, 8> bytes{{bcd(unsigned(date.tm_year - 100)),
        bcd(unsigned(date.tm_mon + 1)), bcd(unsigned(date.tm_mday)),
        bcd(unsigned(date.tm_wday)), bcd(unsigned(date.tm_hour)),
        bcd(unsigned(date.tm_min)), bcd(unsigned(std::min(date.tm_sec, 59))), 0}};
    try {
      spi.begin(Spi::IO, 0x22);
      for (unsigned i = 0; i < bytes.size(); i += 2)
        spi.word(uint16_t(bytes[i]) | uint16_t(bytes[i + 1]) << 8);
      spi.end();
    } catch (...) { spi.end(); throw; }
    // Native date edits remain authoritative for this standalone session.
    // Guest resets and subsequent game/native transitions never reseed RTC.
    firmware_rtc_seeded = true;
  }
  void bootFirmware() {
    ensureFirmware(); // All native source/storage validation precedes CPU hold.
    firmwareControl(1);
    clearConsoleInputs();
    drain(450);
    flushFirmware();
    mountFirmware();
    beginLoading("DS firmware");
    uploadNativeFirmwareAssets();
    seedFirmwareClock();
    firmwareControl(2);
    waitFirmware(0x43, 0x42, 3000, "native firmware release");
    native_firmware = true;
    menu = browser = system_menu = false;
    recent_view = recent_clear_confirm = false;
    osd(false);
    log("native DS firmware CPUs released; firmware menu progress not yet verified");
  }
  void firmwareStorageFailure(const std::exception &error) {
    firmware_failed = true;
    try { firmwareControl(6); } catch (...) {}
    firmwareError("Firmware save failed", error.what());
  }
  void mount(const std::string &rom) {
    if (save >= 0) {
      require(fdatasync(save) == 0, "sync outgoing save");
      close(save);
      save = -1;
    }
    fs::path name = fs::path(rom).filename();
    name.replace_extension(".sav");
    fs::path dest = fs::path(savedir) / name;
    // Both frontends use the same cartridge save. The one-time installation
    // carries over private test progress with backups; never import a stale
    // private copy here after normal MiSTer has advanced the shared save.
    // Match the normal frontend's durable cartridge writes, including on
    // an unexpected host exit. The renderer runs independently of this I/O.
    save = open(dest.c_str(), O_RDWR | O_CREAT | O_DSYNC | O_CLOEXEC, 0644);
    require(save >= 0, "open shared save");
    struct stat st;
    require(fstat(save, &st) == 0 && st.st_size <= 1048576, "save size");
    uint64_t n = st.st_size;
    spi.begin(Spi::IO, 0x1d);
    for (int i = 0; i < 4; i++)
      spi.word(n >> (16 * i));
    spi.end();
    spi.cmd(Spi::IO, 0x1c, {1});
  }
  void recordFirmwareRequest(unsigned operation, uint32_t lba) {
    if (!firmware_diagnostics) return;
    firmware_last_lba = lba;
    firmware_last_operation = operation;
    if (operation == 1) ++firmware_read_requests;
    if (operation == 2) ++firmware_write_requests;
    // Bound boot tracing even if guest firmware reads the complete flash.
    if (lba < firmware_lba_logged.size() && !firmware_lba_logged[lba] &&
        firmware_unique_lbas_logged < 32) {
      firmware_lba_logged[lba] = true;
      ++firmware_unique_lbas_logged;
      log("firmware diagnostic request op=" + std::to_string(operation) +
          " lba=" + std::to_string(lba));
    }
  }
  bool sector() {
    auto c = spi.begin(Spi::IO, 0x16);
    int op = c & 3;
    if (!op) {
      spi.end();
      return false;
    }
    spi.word(0);
    uint32_t lba = spi.word(0);
    lba |= uint32_t(spi.word(0)) << 16;
    spi.end();
    const unsigned slot = (c >> 2) & 15;
    require((c & 0x8000) && slot <= 1 && ((c >> 6) & 7) == 2 &&
                ((c >> 9) & 63) == 0 && lba < (slot ? 512u : 2048u),
            "unsupported SD request");
    if (slot == 1) {
      if (firmware_failed) return false;
      recordFirmwareRequest(unsigned(op), lba);
      try {
        if (!firmware || !firmware_slot_mounted)
          throw std::runtime_error("Firmware sector requested without a mounted working image");
        if (op == 1) {
          const auto bytes = firmware->readSector(lba);
          spi.begin(Spi::IO, 0x117);
          for (unsigned i = 0; i < bytes.size(); i += 2)
            spi.word(uint16_t(bytes[i]) | uint16_t(bytes[i + 1]) << 8);
          spi.end();
          if (firmware_diagnostics) ++firmware_reads_completed;
        } else if (op == 2) {
          nds_firmware::Sector bytes{};
          spi.begin(Spi::IO, 0x118);
          for (unsigned i = 0; i < bytes.size(); i += 2) {
            const auto word = spi.word(0);
            bytes[i] = uint8_t(word);
            bytes[i + 1] = uint8_t(word >> 8);
          }
          spi.end();
          // SD acknowledgement transfers bytes only. The cache keeps dirty
          // state until the matching explicit durable-completion operation.
          const auto state = firmwareControl();
          if (!(state.flags & 0x100))
            throw std::runtime_error("Firmware write has no pending commit sequence");
          firmware->commitSector(lba, bytes);
          firmwareControl(5, state.sequence);
          if (firmware_diagnostics) ++firmware_writes_durable;
        } else throw std::runtime_error("Simultaneous firmware read and write");
        return true;
      } catch (const std::exception &e) {
        spi.end();
        firmwareStorageFailure(e);
        return false;
      }
    }
    require(save >= 0, "SD request without shared save");
    std::array<uint16_t, 256> b;
    b.fill(0xffff);
    if (op == 2) {
      spi.begin(Spi::IO, 0x18);
      for (auto &w : b)
        w = spi.word(0);
      spi.end();
      ssize_t n = pwrite(save, b.data(), 512, (off_t)lba * 512);
      require(n == 512, "save write");
      writes++;
    } else if (op == 1) {
      ssize_t n = pread(save, b.data(), 512, (off_t)lba * 512);
      require(n >= 0, "save read");
      spi.begin(Spi::IO, 0x17);
      for (auto w : b)
        spi.word(w);
      spi.end();
      reads++;
    } else {
      throw std::runtime_error("simultaneous SD read/write");
    }
    return true;
  }
  void drain(unsigned duration) {
    auto end = ms() + duration;
    while (ms() < end) {
      sector();
      beat();
      usleep(1000);
    }
    if (save >= 0)
      require(fdatasync(save) == 0, "save flush");
  }
  void scan(const fs::path &input_dir = "/dev/input") {
    nextscan = ms() + 1500;
    for (auto it = pads.begin(); it != pads.end();)
      if (it->disconnected || !fs::exists(it->path)) {
        if (it->lastmouse)
          spi.cmd(Spi::IO, 4, {8, 0, 0});
        if (it->touch_analog_valid)
          spi.cmd(Spi::IO, 0x3d, {0, 0});
        if (repeat_pad == it->id)
          repeat_action = -1;
        close(it->fd);
        it = pads.erase(it);
      } else
        ++it;
    for (auto &e : fs::directory_iterator(input_dir)) {
      auto path = e.path().string();
      if (e.path().filename().string().rfind("event", 0) != 0)
        continue;
      if (std::any_of(pads.begin(), pads.end(),
                      [&](const Pad &p) { return p.path == path; }))
        continue;
      Pad p;
      p.path = path;
      p.fd = open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
      if (p.fd < 0)
        continue;
      input_id id{};
      ioctl(p.fd, EVIOCGID, &id);
      char name[256] = {};
      ioctl(p.fd, EVIOCGNAME(sizeof(name)), name);
      if (std::string(name) == "MiSTer virtual input") {
        close(p.fd);
        continue;
      }
      // DualSense/DS4 sensors use ABS_RX/RY for gyro readings, on a separate
      // evdev node with the same controller ID. They are not right sticks.
      // Filter by the kernel property so USB/Bluetooth gamepad nodes remain
      // usable and sensor noise cannot overwrite touch coordinates or buttons.
      constexpr unsigned property_bits = sizeof(unsigned long) * 8;
      std::array<unsigned long, (INPUT_PROP_CNT + property_bits - 1) / property_bits>
          properties{};
      if (ioctl(p.fd, EVIOCGPROP(sizeof(properties)), properties.data()) >= 0 &&
          (properties[INPUT_PROP_ACCELEROMETER / property_bits] &
           (1ul << (INPUT_PROP_ACCELEROMETER % property_bits)))) {
        close(p.fd);
        continue;
      }
      std::array<unsigned long, (KEY_CNT + property_bits - 1) / property_bits>
          keys{};
      if (ioctl(p.fd, EVIOCGBIT(EV_KEY, sizeof(keys)), keys.data()) >= 0)
        for (unsigned side = 0; side < p.digital_trigger.size(); ++side) {
          unsigned code = side ? BTN_TR2 : BTN_TL2;
          p.digital_trigger[side] = keys[code / property_bits] &
                                    (1ul << (code % property_bits));
        }
      p.system_map = {0x321,      0x320,     0x323,     0x322,  BTN_EAST,
                      BTN_SOUTH,  BTN_NORTH, BTN_WEST,  BTN_TL, BTN_TR,
                      BTN_SELECT, BTN_START, BTN_THUMBR};
      p.system_map[21] = BTN_SELECT;
      p.system_map[22] = BTN_START;
      p.system_map[24] = 2u << 16 | ABS_X;
      p.system_map[25] = 2u << 16 | ABS_Y;
      p.system_map[26] = 2u << 16 | ABS_RX;
      p.system_map[27] = 2u << 16 | ABS_RY;
      p.system_map[28] = 2u << 16 | ABS_X;
      p.system_map[29] = 2u << 16 | ABS_Y;
      char idtext[32];
      snprintf(idtext, sizeof(idtext), "%04x_%04x", id.vendor, id.product);
      p.id = idtext;
      fs::path config = "/media/fat/config/inputs";
      if (!readmap(config / ("input_" + p.id + "_v3.map"), p.system_map))
        readmap(config.parent_path() / ("input_" + p.id + "_v3.map"),
                p.system_map);
      if (!p.system_map[22])
        p.system_map[22] = p.system_map[21];
      p.map.fill(0);
      std::copy_n(p.system_map.begin(), 12, p.map.begin());
      p.map[12] = BTN_THUMBR;
      // Main adds primary analog-stick directions as alternative D-pad codes.
      for (int axis = 0; axis < 2; axis++)
        if (p.system_map[28 + axis]) {
          unsigned code = 0x300 + 2 * (p.system_map[28 + axis] & 65535);
          int minus = axis ? 3 : 1, plus = axis ? 2 : 0;
          p.map[minus] = (p.map[minus] & 65535) | (code << 16);
          p.map[plus] = (p.map[plus] & 65535) | ((code + 1) << 16);
        }
      p.menu_map = p.map;
      readCoreMap(p, config);
      for (int axis = 0; axis < 2; axis++) {
        uint32_t primary = p.system_map[28 + axis],
                 first = p.system_map[24 + axis],
                 second = p.system_map[26 + axis];
        auto selected = primary == first    ? second
                        : primary == second ? first
                                            : second;
        if ((selected >> 16) == 2)
          (axis ? p.right_y : p.right_x) = selected & 65535;
      }
      for (int a = 0; a < ABS_CNT; a++) {
        ioctl(p.fd, EVIOCGABS(a), &p.abs[a]);
      }
      p.pad = p.abs[ABS_X].maximum > p.abs[ABS_X].minimum;
      log(std::string("input ") + path + " " + name);
      pads.push_back(p);
    }
  }
  void key(Pad &p, int code, bool down) {
    if (code < 0 || code >= (int)p.pressed.size())
      return;
    auto held = [&](uint32_t m) {
      unsigned lo = m & 65535, hi = m >> 16;
      return (lo && lo < p.pressed.size() && p.pressed[lo]) ||
             (hi && hi < p.pressed.size() && p.pressed[hi]);
    };
    const bool layout_was_held = held(p.map[VIDEO_LAYOUT_BUTTON]);
    bool changed = p.pressed[code] != down;
    p.pressed[code] = down;
    if (!changed)
      return;
    if (!down && code == repeat_code && p.id == repeat_pad)
      repeat_action = -1;
    if (mapping_step >= 0) {
      if (!down)
        return;
      if (code == KEY_ESC || code == KEY_F12) {
        mapping_step = -1;
        dirty = true;
        return;
      }
      if (code != KEY_SPACE && mapping_pad.empty())
        mapping_pad = p.id;
      if (code == KEY_SPACE || mapping_pad == p.id) {
        new_map[button_slots[mapping_step]] = code == KEY_SPACE ? 0 : code;
        if (++mapping_step == int(button_names.size())) {
          if (!mapping_pad.empty()) {
            fs::create_directories(fs::path(kit) / "inputs");
            atomicFile(fs::path(kit) / "inputs" /
                           ("NDS_input_" + mapping_pad + "_v3.map"),
                       new_map.data(), sizeof(new_map));
            for (auto &pad : pads)
              if (pad.id == mapping_pad)
                pad.map = new_map;
          }
          mapping_step = -1;
          message.clear();
        }
        dirty = true;
      }
      return;
    }
    uint32_t oldmenu = p.menujoy;
    p.joy = 0;
    p.menujoy = 0;
    for (unsigned i = 0; i < GAME_BUTTON_COUNT; i++) {
      if (held(p.map[i]))
        p.joy |= 1u << i;
      if (held(p.menu_map[i]))
        p.menujoy |= 1u << i;
    }
    static const int codes[13] = {
        KEY_RIGHT,      KEY_LEFT,  KEY_DOWN, KEY_UP, KEY_X,
        KEY_Z,          KEY_S,     KEY_A,    KEY_Q,  KEY_W,
        KEY_RIGHTSHIFT, KEY_ENTER, KEY_SPACE};
    for (int i = 0; i < 13; i++)
      if (p.pressed[codes[i]])
        p.joy |= 1u << i;
    if (held(p.map[MIC_BUTTON]) || p.pressed[KEY_F11]) p.joy |= MIC_MASK;
    unsigned oldcombo = p.combo;
    p.combo = 0;
    for (int i = 0; i < 2; i++) {
      unsigned keycode = p.system_map[21 + i] & 65535;
      if (keycode && keycode < p.pressed.size() && p.pressed[keycode])
        p.combo |= 1u << i;
    }
    if (down && (code == KEY_F12 || code == BTN_MODE ||
                 (p.combo == 3 && oldcombo != 3))) {
      action(4);
      return;
    }
    if (!menu && down && !layout_was_held && held(p.map[VIDEO_LAYOUT_BUTTON])) {
      // Only update the live Video Layout field. No reset, config writes,
      // OSD traffic, or extra DS button bit is needed for this host action.
      status = changeOption(status, CORE_OPTIONS[0], 1);
      sendstatus();
    }
    if (!menu || !down)
      return;
    if (!reset_confirm && !recent_clear_confirm &&
        (code == KEY_GRAVE || mappedButton(p.system_map[10], code))) {
      action(9); // Main maps system Select through JOY_R2 to KEY_GRAVE.
      return;
    }
    if (recent_view && !recent_clear_confirm && code == KEY_BACKSPACE) {
      recent_clear_confirm = true;
      recent_cursor = cursor;
      cursor = 0; // No, matching Main.
      repeat_action = -1;
      dirty = true;
      return;
    }
    if (recent_view && !recent_clear_confirm && (code == KEY_HOME || code == KEY_END)) {
      cursor = code == KEY_HOME ? 0 : int(recent_entries.size()) - 1;
      scroll_offset = 0;
      next_scroll = ms() + 1000;
      dirty = true;
      return;
    }
    if (browser && (code == KEY_PAGEUP || code == KEY_PAGEDOWN)) {
      action(code == KEY_PAGEUP ? 5 : 6);
      return;
    }
    if (browser && !recent_clear_confirm) {
      static const int lettercodes[] = {
          KEY_A, KEY_B, KEY_C, KEY_D, KEY_E, KEY_F, KEY_G, KEY_H, KEY_I,
          KEY_J, KEY_K, KEY_L, KEY_M, KEY_N, KEY_O, KEY_P, KEY_Q, KEY_R,
          KEY_S, KEY_T, KEY_U, KEY_V, KEY_W, KEY_X, KEY_Y, KEY_Z};
      for (int i = 0; i < 26; i++)
        if (code == lettercodes[i]) {
          for (size_t offset = 1; offset <= roms.size(); offset++) {
            size_t index = (cursor + offset) % roms.size();
            if (!roms[index].name.empty() &&
                ::tolower((unsigned char)roms[index].name[0]) == 'a' + i) {
              cursor = index;
              scroll_offset = 0;
              next_scroll = ms() + 1000;
              dirty = true;
              return;
            }
          }
        }
    }
    auto navigate = [&](int a) {
      action(a);
      repeat_action = a;
      repeat_code = code;
      repeat_pad = p.id;
      next_repeat = ms() + 350;
    };
    unsigned confirm = p.system_map[23] & 65535, back = p.system_map[23] >> 16;
    if (!confirm)
      confirm = p.system_map[4] & 65535;
    if (!back)
      back = p.system_map[5] & 65535;
    if (code == KEY_UP || ((p.menujoy & 8) && !(oldmenu & 8)))
      navigate(0);
    else if (code == KEY_DOWN || ((p.menujoy & 4) && !(oldmenu & 4)))
      navigate(1);
    else if (code == KEY_ENTER || (unsigned)code == confirm)
      action(2);
    else if (code == KEY_ESC || (unsigned)code == back)
      action(3);
    else if (code == KEY_LEFT || ((p.menujoy & 2) && !(oldmenu & 2)))
      navigate(5);
    else if (code == KEY_RIGHT || ((p.menujoy & 1) && !(oldmenu & 1)))
      navigate(6);
    else if (code == KEY_MINUS || code == KEY_KPMINUS)
      action(7);
    else if (code == KEY_EQUAL || code == KEY_KPPLUS)
      action(8);
  }
  void inputs() {
    uint32_t j = 0;
    for (auto &p : pads) {
      input_event e;
      while (read(p.fd, &e, sizeof(e)) == sizeof(e)) {
        if (e.type == EV_SYN && e.code == SYN_DROPPED) {
          p.joy = p.menujoy = p.combo = 0;
          p.pressed.fill(false);
          p.analog = 0;
          spi.cmd(Spi::IO, 0x3d, {0, 0});
          spi.cmd(Spi::IO, 4, {8, 0, 0});
          p.mouse = 0;
          p.x = p.y = 0;
        } else if (e.type == EV_KEY && e.value != 2) {
          if (e.code >= BTN_LEFT && e.code <= BTN_MIDDLE) {
            unsigned bit = 1u << (e.code - BTN_LEFT);
            p.mouse = e.value ? p.mouse | bit : p.mouse & ~bit;
          } else
            key(p, e.code, e.value != 0);
        } else if (e.type == EV_ABS) {
          int rx = p.right_x, ry = p.right_y;
          if ((e.code == rx || e.code == ry) &&
              p.abs[e.code].maximum > p.abs[e.code].minimum) {
            p.touch_analog_valid = true;
            auto a = p.abs[e.code];
            int value = std::clamp((int)((int64_t(e.value) - a.minimum) * 255 /
                                         (a.maximum - a.minimum)) -
                                       128,
                                   -128, 127);
            int shift = e.code == rx ? 0 : 8;
            p.analog = (p.analog & ~(255 << shift)) | (uint8_t(value) << shift);
            if (!menu)
              spi.cmd(Spi::IO, 0x3d, {0, rotateTouchAnalog(p.analog, touch_rotation)});
          }
          // A DualSense trigger reports both a button and an analog axis.
          // During mapping use the button's press/release edge only: treating
          // the axis as a centered stick also maps its rest and full-pull ends.
          // Keep the old axis codes outside the wizard for existing mappings.
          const bool duplicate_trigger = mapping_step >= 0 &&
              ((e.code == ABS_Z && p.digital_trigger[0]) ||
               (e.code == ABS_RZ && p.digital_trigger[1]));
          if (!duplicate_trigger && e.code < ABS_CNT &&
              p.abs[e.code].maximum > p.abs[e.code].minimum) {
            auto a = p.abs[e.code];
            int center = (a.minimum + a.maximum) / 2;
            int dz = std::max(0, (a.maximum - a.minimum) / 4);
            key(p, 0x300 + e.code * 2, e.value < center - dz);
            key(p, 0x301 + e.code * 2, e.value > center + dz);
          }
        } else if (e.type == EV_REL) {
          if (e.code == REL_X)
            p.x += e.value;
          if (e.code == REL_Y)
            p.y -= e.value;
        } else if (e.type == EV_SYN && e.code == SYN_REPORT) {
          if (!menu && (p.x || p.y || p.mouse != p.lastmouse)) {
            // PS/2 Y points upward; rotate in screen coordinates, then convert
            // back for the core's mouse protocol. Buttons remain unchanged.
            auto [dx, dy] = rotateTouch(std::clamp(p.x, -127, 127),
                                      -std::clamp(p.y, -127, 127), touch_rotation);
            int x = dx, y = -dy;
            spi.cmd(
                Spi::IO, 4,
                {uint16_t(8 | p.mouse | (x < 0 ? 16 : 0) | (y < 0 ? 32 : 0)),
                 uint16_t(uint8_t(x)), uint16_t(uint8_t(y))});
          }
          p.lastmouse = p.mouse;
          p.x = p.y = 0;
        }
      }
      if (errno == ENODEV) {
        p.disconnected = true;
        p.joy = 0;
        p.pressed.fill(false);
        p.analog = 0;
        spi.cmd(Spi::IO, 0x3d, {0, 0});
        if (repeat_pad == p.id)
          repeat_action = -1;
        if (p.lastmouse)
          spi.cmd(Spi::IO, 4, {8, 0, 0});
        p.mouse = p.lastmouse = 0;
        nextscan = 0;
      }
      j |= p.joy;
    }
    syncScreenPeek();
    joy(menu ? 0 : j);
  }

public:
  Host(std::string k, std::string r, fs::path sd = "/media/fat")
      : kit(k), romdir(r), savedir((sd / "saves/NDS").string()), sd_root(sd) {
    core_root = sd_root;
    const char *diagnostics = std::getenv("NDS_FIRMWARE_DIAGNOSTICS");
    firmware_diagnostics = diagnostics && std::strcmp(diagnostics, "1") == 0;
    fs::create_directories(savedir);
#ifdef STANDALONE_TEST
    // Fixture tests must never touch a running standalone session's heartbeat.
    heartbeat = open((fs::path(kit) / "test-heartbeat").c_str(),
                     O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
#else
    heartbeat = open("/tmp/nds-standalone-heartbeat",
                     O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
#endif
    require(heartbeat >= 0, "heartbeat");
    auto cfgpath = fs::path(kit) / "NDS_v1.CFG";
    if (!fs::exists(cfgpath))
      cfgpath = sd_root / "config/NDS_v1.CFG";
    std::ifstream cfg(cfgpath, std::ios::binary);
    cfg.read((char *)full_status.data(), sizeof(full_status));
    status = cleanStatus(full_status[0]);
    std::ifstream touch_config(fs::path(kit) / "NDS_touch.cfg");
    std::string touch_header, touch_value;
    if (std::getline(touch_config, touch_header) && touch_header == "NDS-TouchRotation-v1" &&
        std::getline(touch_config, touch_value))
      for (unsigned i = 0; i < 3; ++i)
        if (touch_value == TOUCH_ROTATION_NAMES[i]) touch_rotation = TouchRotation(i);
    std::ifstream ini(sd_root / "MiSTer.ini");
    std::string text((std::istreambuf_iterator<char>(ini)),
                     std::istreambuf_iterator<char>());
    rotation = osdRotation(text);
    // A private display kit can use an upright menu on a CRT while the
    // user's regular NDS setup retains its portrait-monitor INI setting.
    std::ifstream osd_config(fs::path(kit) / "NDS_osd.cfg");
    std::string osd_override;
    if (std::getline(osd_config, osd_override) && osd_override.size() == 1 &&
        osd_override[0] >= '0' && osd_override[0] <= '2')
      rotation = osd_override[0] - '0';
    browse_expand = browserExpand(text);
    recents_enabled = recentEnabled(text);
    system_rows = systemMenuRows(systemMenuOptions(text, sd_root / "config/NDS_afilter.cfg"));
    idle_since = ms();
    version_footer.reset(idle_since);
    currentdir = fs::path(romdir);
    try {
      storage_preferences = nds_storage::Preferences::read(storageConfig());
    } catch (const std::exception &e) {
      log(e.what());
      message = "Storage settings need reselecting";
    }
    sendstatus();
    joy(0);
    initializeVideoMetadata();
    log(std::string(CORE_VERSION) + " standalone host ready status=" + std::to_string(status));
  }
  ~Host() {
    for (auto &p : pads)
      close(p.fd);
    if (save >= 0) {
      fdatasync(save);
      close(save);
    }
    if (heartbeat >= 0)
      close(heartbeat);
  }
  void load(const std::string &path) {
    log("loading " + path);
    beginLoading(fs::path(path).filename().string());
    clearConsoleInputs();
    drain(450);
    const auto service = [&] {
      if (!running) throw std::runtime_error("ROM load interrupted");
      sector();
      beat();
    };
    RomReader reader(path);
    // File validation and all CIFS reads run outside the SPI/heartbeat owner.
    const auto file_size = reader.size(service);
    const auto transfer_size = RomReader::transferSize(file_size);
    const auto storage_size = RomLayout::storageSize(file_size);
    // Reserve every destination before touching FIO. Large files use the
    // separate rotated bank; graphics/control memory keeps its existing owner.
    RomMapping mapping(file_size);
    firmwareControl(1);
    flushFirmware();
    uploadDirectGameAssets();
    spi.cmd(Spi::FIO, 0x55, {RomLayout::index(file_size)});
    spi.cmd(Spi::FIO, 0x56, {0x2e4e, 0x4453});
    spi.cmd(Spi::FIO, 0x53, {255, uint16_t(file_size), uint16_t(file_size >> 16)});
    // Download's rising edge asks the save bridge to flush the outgoing cart.
    drain(100);
    size_t off = 0;
    while (off < transfer_size) {
      const auto chunk = mapping.at(off);
      off += reader.read(chunk.data, std::min<size_t>(262144, std::min<uint64_t>(chunk.size, transfer_size - off)), service);
      updateLoading(off, storage_size);
    }
    // The extended FPGA aperture always backs316MiB. A trimmed file must not
    // expose a prior cartridge's bytes between its EOF and that boundary.
    while (off < storage_size) {
#ifdef STANDALONE_TEST
      if (RomMapping::test_before_padding_write) RomMapping::test_before_padding_write(off);
#endif
      service();
      const auto chunk = mapping.at(off);
      const auto n = std::min<size_t>(262144, chunk.size);
      memset(chunk.data, 0xff, n);
      off += n;
      updateLoading(off, storage_size);
    }
    service();
    __sync_synchronize();
    mapping.reset();
    mount(path);
    spi.cmd(Spi::FIO, 0x53, {0});
    firmwareControl(3);
    waitFirmware(3, 0, 3000, "direct game boot release");
    native_firmware = false;
    game = path;
    currentdir = fs::path(path).parent_path();
    try { remember(path); }
    catch (const std::exception &e) { log(std::string("recent files: ") + e.what()); }
    menu = false;
    browser = system_menu = false;
    recent_view = recent_clear_confirm = false;
    osd(false);
    log("ROM started " + path);
  }
  void run(unsigned seconds) {
    uint64_t end = seconds ? ms() + seconds * 1000ull : ~0ull;
    uint32_t oldbuttons = 0;
    unsigned loops = 0;
    while (running && ms() < end) {
      beat();
      if (ms() >= nextscan) {
        require(!live_main(), "another MiSTer process started");
        scan();
      }
      inputs();
      if (storage_job)
        pollStorage();
      serviceFramebufferMetadataRequest();
      for (int i = 0; i < 4; i++)
        if (!sector())
          break;
      if (native_firmware && firmware_slot_mounted && !firmware_failed && ms() >= next_firmware_poll) {
        next_firmware_poll = ms() + 250;
        try {
          const auto state = firmwareControl();
          if (state.flags & 0x80)
            throw std::runtime_error("Firmware controller error " + std::to_string(state.error));
        } catch (const std::exception &e) { firmwareStorageFailure(e); }
      }
      uint32_t b = spi.buttons();
      if ((b & 1) && !(oldbuttons & 1))
        action(4);
      oldbuttons = b;
      if (menu && repeat_action >= 0 && ms() >= next_repeat) {
        action(repeat_action);
        next_repeat = ms() + 90;
      }
      if (dirty)
        draw();
      if (menu) animateMenu(ms());
      if (++loops % 500 == 0 && save >= 0)
        require(fdatasync(save) == 0, "save sync");
      std::vector<pollfd> fds;
      for (auto &p : pads)
        fds.push_back({p.fd, POLLIN, 0});
      poll(fds.data(), fds.size(), 2);
    }
    // Neutral input first; service delayed dirty-sector requests before handing
    // off.
    clearConsoleInputs();
    if (firmware_slot_mounted && !firmware_failed) {
      // A clean exit may follow SIGTERM (running=0); flush still owns SPI.
      const auto previous = running;
      running = 1;
      try { firmwareControl(1); flushFirmware(); }
      catch (...) { running = previous; throw; }
      running = previous;
    }
    drain(500);
    osd(false);
    if (save >= 0) require(fdatasync(save) == 0, "sync save before core handoff");
    if (!selected_core.empty())
      atomicFile(fs::path(kit) / "core-request.txt", selected_core.data(), selected_core.size());
    log("clean exit reads=" + std::to_string(reads) +
        " writes=" + std::to_string(writes));
  }
};
int main(int argc, char **argv) {
  signal(SIGTERM, stop);
  signal(SIGINT, stop);
  signal(SIGHUP, SIG_IGN);
  signal(SIGUSR1, request_framebuffer_metadata);
  try {
    require(argc >= 3,
            "usage: host KIT ROMDIR [ROM] [SECONDS] [SUPERVISOR_PID]");
    if (argc > 5) {
      pid_t parent = pid_t(std::stol(argv[5]));
      tie_to_parent(parent);
    }
    int lock = open("/tmp/nds-standalone-host.lock",
                    O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    require(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0, "host lock");
    require(running, "supervisor exited before host start");
    Host h(argv[1], argv[2]);
    if (argc > 3 && strcmp(argv[3], "-"))
      h.load(argv[3]);
    h.run(argc > 4 ? atoi(argv[4]) : 0);
    return 0;
  } catch (const std::exception &e) {
    fprintf(stderr, "standalone host failed: %s\n", e.what());
    return 1;
  }
}
