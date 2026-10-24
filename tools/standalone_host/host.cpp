// SPDX-License-Identifier: GPL-3.0-only
// NDS experimental standalone host. Protocol derived from MiSTer Main (GPLv3).
// See THIRD_PARTY.md. Copyright 2026 NDS4MiSTer contributors.
#if defined(__linux__) && !defined(_TIME_BITS)
#define _TIME_BITS 64
#define _FILE_OFFSET_BITS 64
#endif
#include "firmware_media.h"
#include "game_clock.h"
#include "save_profiles.h"
#include "nand_save.h"
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
#include "fmv_castlevania.h"
#include "storage_job.h"
#include "storage_locations.h"
#include "system_menu.h"
#include "touch_rotation.h"
#include "touch_range.h"
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
static_assert(sizeof(std::time_t) >= 8, "Game clock needs 64-bit host time");
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
  // sys_top.v decodes ss1 & !ss0 for HDMI and ss1 & !ss2 for native
  // analog. With ss1 set, the added bit masks one OSD without selecting IO/FIO.
  static constexpr uint32_t OSD_HDMI = OSD | IO, OSD_ANALOG = OSD | FIO;
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
  uint32_t buttons() {
    const auto value = m[5];
    return value & 0x80000000 ? 0 : (value >> 29) & 3;
  }
};
#else
class Spi {
public:
  static constexpr uint32_t IO = 1u << 20, FIO = 1u << 18, OSD = 1u << 19;
  static constexpr uint32_t OSD_HDMI = OSD | IO, OSD_ANALOG = OSD | FIO;
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
  uint16_t default_firmware_flags = 0xe3c, default_firmware_op = 0;
  std::array<uint16_t,4> default_clock_words{{0x0100,0x0601,0,0}};
  uint16_t begin(uint32_t select, uint16_t command) {
    history.push_back({select, command, {}});
    selected = true;
    if (response) return response(select, command, 0, command);
    if (command == 0x45) return 0x4657;
    if (command == 0x47) return 0x5254;
    if (command == 0x40) {
      framebuffer_reply_index = 0;
      return framebufferWord();
    }
    return 0;
  }
  uint16_t word(uint16_t value) {
    history.back().words.push_back(value);
    if (response) return response(history.back().select, history.back().command, history.back().words.size(), value);
    if (history.back().command == 0x22) {
      const auto position=history.back().words.size();
      if(position<=4) default_clock_words[position-1]=value;
    }
    if (history.back().command == 0x47) {
      const auto position=history.back().words.size();
      return position==1 ? 0x101 : position>=2 && position<=5 ? default_clock_words[position-2] : 0;
    }
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
  std::array<int, ABS_CNT> mapping_rest{};
  bool mapping_pointer = false;
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
  bool game_clock_seeded = false, game_clock_pending = false, game_clock_failed = false;
  uint32_t game_clock_sequence = 0;
  uint64_t game_clock_request_ms = 0;
  nds_clock::Date game_clock_request_time{};
  std::function<nds_clock::Date()> game_clock_now = nds_clock::localNow;
  std::function<uint64_t()> game_clock_millis = ms;
  bool game_clock_fallback = false, game_clock_offline_saved = false;
  bool game_clock_checkpoint_pending = false;
  uint64_t game_clock_fallback_ms = 0;
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
  bool loading_preparing = false;
  uint64_t loading_started = 0, loading_next_animation = 0;
  bool browse_expand = true;
  nds_osd::Row browser_base{}, footer_base{};
  std::array<nds_osd::Row, 16> osd_rows{};
  std::array<bool, 16> osd_row_valid{};
  uint64_t idle_since = 0;
  VersionFooter version_footer;
  fs::path currentdir, rom_browser_dir, core_root = "/media/fat";
  std::string selected_core;
  bool menu = true, browser = false, core_browser = false,
       system_menu = false, display_menu = false, dirty = true;
  bool reset_confirm = false;
  bool lid_closed = false; // Session state, deliberately never saved to NDS_v1.CFG.
  bool screen_peek = false; // Temporary display override; status keeps the selection.
  bool direct_video_crt = true; // Shared with startup Advanced Options; CRT-safe default.
  bool video_flags_known = false;
  TouchRotation touch_rotation = TouchRotation::Normal;
  unsigned touch_range = 0; // 100%, stored separately from FPGA status/mappings.
  bool speed_hacks_available = false;
  unsigned speed_hacks = 0; // Internal configuration flags; applied on ROM load.
  static constexpr std::array<const char *, 8> SPEED_MODES{{"off", "lookup", "skip", "both",
      "bones", "lookup+bones", "skip+bones", "both+bones"}};
  static constexpr int TOUCH_ROTATION_CURSOR = 4, LID_CURSOR = 9,
                       RESET_CURSOR = 10, EXIT_CURSOR = 11,
                       SPLIT_CURSOR = 12, ANALOG_CURSOR = 13, DV_TARGET_CURSOR = 14,
                       DISPLAY_CURSOR = 15, TOUCH_RANGE_CURSOR = 16,
                       LAST_MAIN_CURSOR = TOUCH_RANGE_CURSOR;
  int mainMenuRow(int item) const {
    // Stable option identities keep status bits and saved settings unchanged.
    // Only the visible rows differ between the main and Display options pages.
    static constexpr std::array<int, LAST_MAIN_CURSOR + 1> standard{
        0, 1, 3, 4, 5, 6, 7, 8, 9, 12, 13, 15, 10, 11, -1, -1, 2};
    static constexpr std::array<int, LAST_MAIN_CURSOR + 1> crt{
        0, 1, 9, 3, 4, 5, 6, 7, 8, 12, 13, 15, 10, 11, -1, -1, 2};
    static constexpr std::array<int, LAST_MAIN_CURSOR + 1> independent{
        0, 1, 3, -1, -1, -1, -1, -1, -1, 8, 10, 15, -1, 4, -1, 5, 7};
    static constexpr std::array<int, LAST_MAIN_CURSOR + 1> display{
        -1, -1, -1, 1, 2, 3, 4, 5, -1, -1, -1, 15, -1, -1, 7, -1, -1};
    if (item < 0 || item > LAST_MAIN_CURSOR) return -1;
    if (item == DV_TARGET_CURSOR && !(video_flags & (1u << 10))) return -1;
    if (independent_outputs_supported) {
      if (item == ANALOG_CURSOR && (video_flags & (1u << 2))) return -1;
      return (display_menu ? display : independent)[item];
    }
    return ((status & CRT_TIMING) && !(status & INDEPENDENT_OUTPUTS) ? crt : standard)[item];
  }
  static int optionCursor(size_t option) {
    return option < 6 ? int(option) + 2 + (option >= 2) : int(option) + 6;
  }

  int nextMainMenuItem(int direction) const {
    int next = cursor;
    for (int item = 0; item <= LAST_MAIN_CURSOR; ++item)
      if (mainMenuRow(item) >= 0 &&
          (mainMenuRow(item) - mainMenuRow(cursor)) * direction > 0 &&
          (next == cursor ||
           (mainMenuRow(item) - mainMenuRow(next)) * direction < 0))
        next = item;
    return next != cursor ? next : direction > 0 ? (display_menu ? 3 : 0) : EXIT_CURSOR;
  }
  nds_video::Transmitter video_transmitter;
  nds_video::StablePacket video_packet;
  bool direct_video_metadata = false, video_osd_visible = false;
  bool video_write_failed = false;
  uint16_t video_flags = 0;
  bool independent_outputs_supported = false;
  void initializeVideoMetadata() {
    const auto signature = spi.begin(Spi::IO, 0x46);
    const auto flags = spi.word(0);
    const auto capability = spi.word(0);
    spi.end();
    independent_outputs_supported = signature == 0x4456 && capability == 0x5350;
    video_flags = signature == 0x4456 ? flags : 0;
    video_flags_known = true;
    // The initial status write masks split output until capability is known.
    // Select independent native analog immediately, including old CRT-Off
    // settings and non-DV1 sessions, without waiting for a menu change.
    sendstatus();
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
    auto geometry = nds_video::readGeometry(spi);
    geometry.native_menu_pixels = nds_video::readNativeMenuPixels(spi);
    if (!video_packet.ready(geometry, video_osd_visible, packet)) return;
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
  int board_press_mapping_step = -1;
  std::string mapping_pad;
  bool mapping_pending = false, mapping_ready = true;
  std::array<uint32_t, 32> new_map{};
  bool board_buttons_initialized = false, board_press_menu = false,
       board_press_mapping = false;
  uint32_t board_buttons_previous = 0, board_buttons_gesture = 0;
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
    if (independent_outputs_supported) status = independentDisplayStatus(status);
    status = cleanStatus(status);
    full_status[0] = status;
    atomicFile(fs::path(kit) / "NDS_v1.CFG", full_status.data(),
               sizeof(full_status));
    const std::string touch_config = "NDS-TouchRotation-v1\n" +
        std::string(TOUCH_ROTATION_NAMES[unsigned(touch_rotation)]) + "\n";
    atomicFile(fs::path(kit) / "NDS_touch.cfg", touch_config.data(), touch_config.size());
    const std::string stick_config = "NDS-StickRange-v1\n" +
        std::to_string(TOUCH_RANGE_PERCENT[touch_range]) + "\n";
    atomicFile(fs::path(kit) / "NDS_stick.cfg", stick_config.data(), stick_config.size());
    if (speed_hacks_available) {
      const std::string config = "NDS-SpeedHacks-v1\n" + std::to_string(speed_hacks) + "\n";
      atomicFile(fs::path(kit) / "NDS_speed.cfg", config.data(), config.size());
    }
    const std::string video_config = std::string("NDS-DirectVideo-v1\n") +
        (direct_video_crt ? "crt\n" : "retrotink\n");
    atomicFile(fs::path(kit) / "NDS_video.cfg", video_config.data(), video_config.size());
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
      if (game_clock_seeded) {
        // An explicitly requested diagnostic snapshot runs through the owner;
        // no second process competes for GPIO/SPI or changes the DS clock.
        const auto clock_begin=monotonic_us();
        const auto clock=flushGameClock();
        const auto date=nds_clock::unpack(clock.bytes);
        std::ostringstream diagnostic;
        diagnostic << "{\"date\":[";
        for(unsigned i=0;i<date.size();++i) diagnostic << (i ? "," : "") << date[i];
        diagnostic << "],\"write_sequence\":" << clock.sequence
                   << ",\"begin_us\":" << clock_begin << ",\"end_us\":" << monotonic_us() << '}';
        data.insert(data.rfind("\n}"), ",\n  \"game_clock\": " + diagnostic.str());
      }
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
                 << ",\"direct_video_target\":\"" << (direct_video_crt ? "crt" : "retrotink") << "\""
                 << ",\"selected_display_status\":" << selectedDisplayStatus()
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
    core_browser = recent_view = storage_choices = system_menu = display_menu = false;
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
            storage_choices = core_browser = system_menu = display_menu = false;
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
      if (game_clock_seeded) {
        try { serviceGameClock(); }
        catch (const std::exception &e) {
          if (!game_clock_failed) firmwareError("Game clock save failed", e.what());
          game_clock_failed = true;
        }
      }
    }
  }
  bool crtDirectVideo() const {
    return (video_flags & (1u << 10)) && direct_video_crt;
  }
  uint16_t selectedDisplayStatus() const {
    auto requested = uint16_t(status | REQUIRED_STATUS);
    if (independent_outputs_supported) requested = independentDisplayStatus(requested);
    else requested &= ~INDEPENDENT_OUTPUTS;
    // Keep the first host write safe before output discovery. Later, restrict
    // only HDMI Direct Video aimed at a CRT. Saved combined layouts survive
    // this wire-only override and return when the target is changed to Scaler.
    if (!video_flags_known || crtDirectVideo()) {
      requested |= CRT_TIMING;
      if (!(requested & (1u << 6))) requested = (requested & ~(3u << 5)) | (2u << 5);
    }
    return normalizeDisplayStatus(requested);
  }
  void changeDigitalLayout(int direction) {
    if (crtDirectVideo()) {
      const auto selected = selectedDisplayStatus();
      status = (status & ~(3u << 5)) | ((selected ^ (1u << 5)) & (3u << 5));
    } else {
      status = changeOption(status, CORE_OPTIONS[0], direction);
      if ((status & CRT_TIMING) && !(status & INDEPENDENT_OUTPUTS) && !(status & (1u << 6)))
        status = (status & ~(3u << 5)) | ((direction < 0 ? 3u : 2u) << 5);
    }
  }
  uint16_t liveStatus() const {
    const auto selected = selectedDisplayStatus();
    // Layouts 2/3 are the individual panels. Flipping bit 5 exchanges them
    // without changing timing, rotation, screen order or the saved selection.
    auto live = selected;
    if (screen_peek) {
      if (selected & (1u << 6)) live ^= 1u << 5;
      if (selected & INDEPENDENT_OUTPUTS) live ^= ANALOG_TOUCH;
    }
    // vga_scaler disables the FPGA's split scanout. In that mode the legacy
    // CRT flag would clamp the shared HDMI/scaled-VGA image to one panel.
    // Ignore it on the wire while keeping saved settings intact.
    if (video_flags_known && independent_outputs_supported && (video_flags & (1u << 2)) && !crtDirectVideo())
      live &= ~CRT_TIMING;
    return live;
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
    if (independent_outputs_supported) status = independentDisplayStatus(status);
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
    requireHostSaveProfile();
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
    if (!en) {
      spi.cmd(Spi::OSD, 0x40); // Hide both outputs and reset both row-height latches.
      return;
    }
    // Scaled HDMI follows Video Rotation. Native analog (and native Direct
    // Video) retains the unrotated game image, so its OSD stays upright.
    // VGA scaler mode already uses the HDMI image including its HDMI OSD.
    const unsigned rotation = (status >> 11) & 3;
    const uint16_t hdmi_rotation = rotation == 1 ? 3 : rotation == 2 ? 1 : 0;
    for (const auto &output : {std::pair{Spi::OSD_HDMI, hdmi_rotation},
                              std::pair{Spi::OSD_ANALOG, uint16_t(0)}}) {
      spi.begin(output.first, message_window ? 0x49 : 0x41);
      for (int i = 0; i < 4; i++)
        spi.word(0);
      spi.word(output.second);
      spi.end();
    }
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
    } else if (!system_menu && !display_menu) { // Keep the submenu Back footer visible.
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
    loading_preparing = false;
    osd(true, true);
  }
  void animateLoading(uint64_t now) {
    if (!loading_preparing || now < loading_next_animation) return;
    const auto elapsed = now - loading_started;
    line(4, loadingActivity(elapsed / 200));
    line(6, " Loading ROM... " + std::to_string(elapsed / 1000) + "s");
    loading_next_animation = now + 200;
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
      rows[3] = std::string(mapping_pending ? " Release: " : " Press: ") +
                button_names[mapping_step];
      if (!mapping_ready) rows[5] = " Release all controls";
      rows[7] = " Space/User: Skip";
      rows[8] = " Esc/OSD: Cancel";
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
      frame.setTitle(display_menu ? "Display options" : "NDS");
      if (!display_menu) {
        rows[0] = " " + std::string(LOAD_LABEL);
        rows[1] = " Boot DS firmware";
      }
      for (size_t i = 0; i < CORE_OPTIONS.size(); i++) {
        if (mainMenuRow(optionCursor(i)) < 0) continue;
        auto option = CORE_OPTIONS[i];
        if (i == 0 && (status & CRT_TIMING) && !(status & INDEPENDENT_OUTPUTS)) {
          option.label = "CRT Screen";
          const bool reversed = status & (1u << 7);
          option.values[2] = reversed ? "Touch" : "Main";
          option.values[3] = reversed ? "Main" : "Touch";
        }
        if (i == 0 && (status & INDEPENDENT_OUTPUTS)) {
          option.label = "Digital Layout";
          option.values = {"Side-by-side", "Top/bottom",
              (status & (1u << 7)) ? "Touch" : "Main",
              (status & (1u << 7)) ? "Main" : "Touch"};
        }
        if (option.shift == 13 && (status & INDEPENDENT_OUTPUTS)) {
          option.label = "Analog Timing";
          option.values = {"240p", "240p", "", ""};
        }
        rows[mainMenuRow(optionCursor(i))] = optionLabel(i == 0 ? selectedDisplayStatus() : status, option);
      }
      if (mainMenuRow(DV_TARGET_CURSOR) >= 0)
        rows[mainMenuRow(DV_TARGET_CURSOR)] = optionLabel(direct_video_crt ? 0 : 1,
            {0, 1, 2, "Direct Video Target", {"CRT", "Scaler"}});
      if (mainMenuRow(TOUCH_ROTATION_CURSOR) >= 0)
        rows[mainMenuRow(TOUCH_ROTATION_CURSOR)] = optionLabel(unsigned(touch_rotation),
          {0, 2, 3, "Touch Rotation", {"Normal", "90 CCW", "90 CW"}});
      if (mainMenuRow(DISPLAY_CURSOR) >= 0)
        rows[mainMenuRow(DISPLAY_CURSOR)] = " Display options            " + std::string(1, char(0x16));
      if (mainMenuRow(TOUCH_RANGE_CURSOR) >= 0)
        rows[mainMenuRow(TOUCH_RANGE_CURSOR)] = " Right Stick Range:     " +
            std::to_string(TOUCH_RANGE_PERCENT[touch_range]) + "%";
      if (mainMenuRow(LID_CURSOR) >= 0)
        rows[mainMenuRow(LID_CURSOR)] = lid_closed ? " Lid: Closed (Open)" : " Lid: Open (Close)";
      if (mainMenuRow(RESET_CURSOR) >= 0)
        rows[mainMenuRow(RESET_CURSOR)] = " Reset";
      rows[14] = message.empty() ? personal_settings_notice : message;
      rows[15] = (display_menu) ? "            back" : "            exit";
      selected = mainMenuRow(cursor);
    }
    const unsigned arrows = browser || mapping_step >= 0 || reset_confirm || recent_clear_confirm || firmware_error_dialog ? 0
                            : (system_menu || display_menu) ? nds_osd::arrow_left
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
    browser = system_menu = display_menu = reset_confirm = false;
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
          spi.cmd(Spi::IO, 0x3d, {0, expandTouchAnalog(rotateTouchAnalog(p.analog, touch_rotation), touch_range)});
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
        browser = system_menu = display_menu = false;
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
          touch_range = 0;
          speed_hacks = 0;
          direct_video_crt = true;
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
               ((browser && !core_browser) || (!system_menu && !display_menu && cursor == 0)))
        openRecents();
      dirty = true;
      return;
    }
    scroll_offset = 0;
    idle_since = ms();
    version_footer.reset(idle_since);
    next_scroll = idle_since + 1000;
    int count = browser ? (int)roms.size() : system_menu ? 6 : EXIT_CURSOR + 1;
    if ((a == 0 || a == 1) && count) {
      if (!browser && !system_menu)
        cursor = nextMainMenuItem(a == 0 ? -1 : 1);
      else
        cursor = (cursor + count + (a == 0 ? -1 : 1)) % count;
    }
    if (a == 3) {
      if (browser) {
        closeBrowser();
      } else if (display_menu) {
        display_menu = false;
        cursor = DISPLAY_CURSOR;
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
            mapping_pending = false;
            mapping_ready = mappingNeutral();
            repeat_action = -1;
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
      } else if (display_menu && (a == 5 || (a == 2 && cursor == EXIT_CURSOR))) {
        display_menu = false;
        cursor = DISPLAY_CURSOR;
      } else if (a == 6) {
        if (display_menu) return;
        // Main's generic core menu treats Right as page navigation even
        // when an option is selected. Values use Select or +/- instead.
        system_menu = true;
        cursor = 0;
      } else if (independent_outputs_supported && mainMenuRow(cursor) < 0) {
        return;
      } else if (cursor == TOUCH_RANGE_CURSOR &&
                 (a == 2 || a == 7 || a == 8)) {
        touch_range = (touch_range + TOUCH_RANGE_PERCENT.size() + (a == 7 ? -1 : 1)) % TOUCH_RANGE_PERCENT.size();
        message = " System > Save settings";
      } else if (a == 2 && cursor == DISPLAY_CURSOR) {
        display_menu = true;
        cursor = 3;
        message.clear();
      } else if ((a == 2 || a == 7 || a == 8) && cursor == DV_TARGET_CURSOR) {
        if (mainMenuRow(DV_TARGET_CURSOR) < 0) return;
        direct_video_crt = !direct_video_crt;
        sendstatus();
        message = " System > Save settings";
      } else if ((a == 2 || a == 7 || a == 8) && cursor == TOUCH_ROTATION_CURSOR) {
        touch_rotation = TouchRotation((unsigned(touch_rotation) + (a == 7 ? 2 : 1)) % 3);
        message.clear();
      } else if ((a == 2 || a == 7 || a == 8) && ((cursor >= 2 && cursor < LID_CURSOR) ||
                 cursor == SPLIT_CURSOR || cursor == ANALOG_CURSOR)) {
        const auto &o = CORE_OPTIONS[cursor >= SPLIT_CURSOR ? cursor - 6 :
                                    cursor - 2 - (cursor > TOUCH_ROTATION_CURSOR)];
        if (independent_outputs_supported &&
            (o.shift == 13 || o.shift == 14 ||
             (o.shift == 15 && (video_flags & (1u << 2))))) return;
        if (o.shift == 13 && (status & INDEPENDENT_OUTPUTS)) return;
        if (o.shift == 14 && !independent_outputs_supported) {
          message = "Core lacks split output support";
          dirty = true;
          return;
        }
        if (o.shift == 5) changeDigitalLayout(a == 7 ? -1 : 1);
        else status = changeOption(status, o, a == 7 ? -1 : 1);
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
        " display=" + std::to_string(display_menu) +
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
  void requireHostSaveProfile() {
    if (!(firmwareControl().flags & 0x400))
      throw std::runtime_error("This host requires the matching ARM-area FPGA core. Load the host and core from the same beta kit.");
  }
  void uploadSaveProfile(uint32_t code) {
    const std::array<uint8_t, 8> bytes = {uint8_t(code), uint8_t(code >> 8),
      uint8_t(code >> 16), uint8_t(code >> 24), nds_save_profile::lookup(code), 0, 0x51, 0x53};
    uploadAsset(8, bytes);
    waitFirmware(0xc00, 0xc00, 3000, "cartridge save profile upload");
  }
  void firmwareError(const std::string &title, const std::string &detail) {
    firmware_error_title = title;
    firmware_error_text = detail;
    firmware_error_dialog = true;
    menu = true;
    syncScreenPeek();
    browser = system_menu = display_menu = false;
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
  fs::path gameClockPath() const { return fs::path(kit) / "NDS_rtc.cfg"; }
  nds_clock::Snapshot clockTransfer(bool request) {
    nds_clock::Snapshot snapshot;
    try {
      if (spi.begin(Spi::IO, 0x47) != 0x5254)
        throw std::runtime_error("Game clock requires the host and FPGA from the same RTC beta kit");
      const auto flags = spi.word(request ? 1 : 0);
      if ((flags & 0xfffe) != 0x100)
        throw std::runtime_error("Unsupported game clock protocol");
      snapshot.ready = flags & 1;
      for (unsigned i=0;i<4;++i) {
        const auto word=spi.word(0);
        snapshot.bytes[i*2]=uint8_t(word);snapshot.bytes[i*2+1]=uint8_t(word>>8);
      }
      snapshot.sequence=spi.word(0);
      snapshot.sequence|=uint32_t(spi.word(0))<<16;
      spi.end();
      return snapshot;
    } catch (...) {spi.end();throw;}
  }
  nds_clock::Date gameClockNow() const {
    if (!game_clock_fallback) return game_clock_now();
    // Keep one reference basis for the entire offline session, even if NTP
    // corrects the system clock later. Never change MiSTer's system clock.
    return nds_clock::date(int64_t((game_clock_millis()-game_clock_fallback_ms)/1000));
  }
  void requestGameClock() {
    // Reference the wall clock at capture request, not at the later host poll.
    const auto now=gameClockNow();
    clockTransfer(true);
    game_clock_request_time=now;
    game_clock_request_ms=ms();
    game_clock_pending=true;
  }
  nds_clock::Snapshot waitGameClock() {
    const auto deadline=ms()+100;
    for (;;) {
      const auto snapshot=clockTransfer(false);
      if (snapshot.ready) return snapshot;
      if (ms()>=deadline) throw std::runtime_error("Game clock did not acknowledge its snapshot");
      usleep(100);
    }
  }
  void persistGameClock(const nds_clock::Snapshot &snapshot, bool checkpoint=false) {
    const bool save_checkpoint=game_clock_fallback && game_clock_offline_saved &&
                               (checkpoint || game_clock_checkpoint_pending);
    if (snapshot.sequence == game_clock_sequence &&
        !save_checkpoint) return;
    const auto date=nds_clock::unpack(snapshot.bytes);
    const auto offset=nds_clock::Offset::between(date,game_clock_request_time);
    const auto contents=game_clock_fallback ? nds_clock::Setting::savedOffline(date).serialize()
                                            : offset.serialize();
    game_clock_checkpoint_pending=save_checkpoint;
    atomicFile(gameClockPath(), contents.data(), contents.size());
    // Advance only after durable replacement. A failed write is retried using
    // the same timestamp/snapshot, rather than losing or skewing the edit.
    game_clock_sequence=snapshot.sequence;
    game_clock_offline_saved=game_clock_fallback;
    game_clock_checkpoint_pending=false;
    game_clock_failed=false;
    log(std::string(save_checkpoint ? "game clock checkpoint saved sequence=" : "game clock edit saved sequence=")+
        std::to_string(snapshot.sequence)+(game_clock_fallback ? " offline_calendar=1" :
        " offset_seconds="+std::to_string(offset.seconds)));
  }
  void serviceGameClock() {
    if (game_clock_pending) {
      const auto snapshot=clockTransfer(false);
      if (!snapshot.ready) {
        if (ms()-game_clock_request_ms>2000)
          throw std::runtime_error("Game clock snapshot timed out");
        return;
      }
      persistGameClock(snapshot);
      game_clock_pending=false;
    }
    requestGameClock();
  }
  nds_clock::Snapshot flushGameClock() {
    if (!game_clock_seeded) return {};
    if (game_clock_pending) {
      persistGameClock(waitGameClock());
      game_clock_pending=false;
    }
    requestGameClock();
    const auto snapshot=waitGameClock();
    persistGameClock(snapshot,true);
    game_clock_pending=false;
    return snapshot;
  }
  void seedGameClock() {
    if (game_clock_seeded) return;
    // Reject an old core before sending a seed or claiming functional RTC.
    clockTransfer(false);
    nds_clock::Setting setting;
    if (fs::exists(gameClockPath())) {
      std::ifstream file(gameClockPath());
      if (!file) throw std::runtime_error("Cannot read NDS_rtc.cfg");
      const std::string text((std::istreambuf_iterator<char>(file)),std::istreambuf_iterator<char>());
      if (file.bad()) throw std::runtime_error("Cannot read NDS_rtc.cfg");
      setting=nds_clock::Setting::parse(text);
    }
    nds_clock::Date basis;
    try {basis=game_clock_now();game_clock_fallback=false;}
    catch (const nds_clock::Unavailable &) {
      game_clock_fallback=true;game_clock_fallback_ms=game_clock_millis();
      basis=nds_clock::date(0);
    }
    const auto date=setting.offline ? setting.clock : setting.offset.apply(basis);
    const auto offset=nds_clock::Offset::between(date,basis);
    const auto bytes=nds_clock::pack(date);
    try {
      spi.begin(Spi::IO, 0x22);
      for (unsigned i=0;i<bytes.size();i+=2)
        spi.word(uint16_t(bytes[i]) | uint16_t(bytes[i+1])<<8);
      spi.end();
    } catch (...) {spi.end();throw;}
    requestGameClock();
    const auto snapshot=waitGameClock();
    const auto observed=nds_clock::seconds(nds_clock::unpack(snapshot.bytes));
    const auto expected=nds_clock::seconds(date);
    if (observed != expected && observed != (expected+1)%nds_clock::century_seconds)
      throw std::runtime_error("FPGA did not accept the game clock seed");
    if (setting.offline && !game_clock_fallback) {
      // The first valid-clock launch preserves the offline guest edit, then
      // resumes normal offset/elapsed-time behavior. Retain v2 on write failure.
      const auto contents=offset.serialize();
      atomicFile(gameClockPath(),contents.data(),contents.size());
    }
    game_clock_offline_saved=setting.offline && game_clock_fallback;
    game_clock_sequence=snapshot.sequence;
    game_clock_pending=false;
    game_clock_seeded=true;
    if (game_clock_fallback)
      log("MiSTer clock unavailable: using offline DS clock (default 2000-01-01 00:00:00); relaunch after setting MiSTer time");
    log("game clock seeded " + std::to_string(date[0]+2000)+"-"+std::to_string(date[1])+"-"+
        std::to_string(date[2])+" "+std::to_string(date[4])+":"+std::to_string(date[5])+":"+
        std::to_string(date[6])+" offset_seconds="+std::to_string(offset.seconds));
  }
  void bootFirmware() {
    ensureFirmware(); // All native source/storage validation precedes CPU hold.
    requireHostSaveProfile();
    firmwareControl(1);
    clearConsoleInputs();
    drain(450);
    flushFirmware();
    mountFirmware();
    beginLoading("DS firmware");
    uploadNativeFirmwareAssets();
    seedGameClock();
    firmwareControl(2);
    waitFirmware(0x43, 0x42, 3000, "native firmware release");
    native_firmware = true;
    menu = browser = system_menu = display_menu = false;
    recent_view = recent_clear_confirm = false;
    osd(false);
    log("native DS firmware CPUs released; firmware menu progress not yet verified");
  }
  void firmwareStorageFailure(const std::exception &error) {
    firmware_failed = true;
    try { firmwareControl(6); } catch (...) {}
    firmwareError("Firmware save failed", error.what());
  }
  uint32_t save_sector_limit = 2048;
  void mount(const std::string &rom, uint8_t save_type = 0) {
    fs::path name = fs::path(rom).filename();
    name.replace_extension(".sav");
    fs::path dest = fs::path(savedir) / name;
    // Both frontends use the same cartridge save. The one-time installation
    // carries over private test progress with backups; never import a stale
    // private copy here after normal MiSTer has advanced the shared save.
    // Match the normal frontend's durable cartridge writes, including on
    // an unexpected host exit. The renderer runs independently of this I/O.
    const uint32_t nand_bytes = nds_nand::bytes(save_type);
    if (nand_bytes) nds_nand::prepare(dest, nand_bytes, [&] {
      if (!running) throw std::runtime_error("NAND save initialization interrupted");
      beat();
    });
    const int incoming = open(dest.c_str(), O_RDWR | O_CREAT | O_DSYNC | O_CLOEXEC, 0644);
    require(incoming >= 0, "open shared save");
    struct stat st;
    if (fstat(incoming, &st) != 0 || st.st_size < 0 ||
        (nand_bytes ? st.st_size != nand_bytes : st.st_size > 1048576)) {
      close(incoming); throw std::runtime_error("save size");
    }
    if (save >= 0) {
      if (fdatasync(save) != 0) { close(incoming); throw std::runtime_error("sync outgoing save"); }
      close(save);
    }
    save = incoming;
    save_sector_limit = nand_bytes ? nand_bytes / 512 : 2048;
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
                ((c >> 9) & 63) == 0 && lba < (slot ? 512u : save_sector_limit),
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
        if (mapping_step >= 0 && it->id == mapping_pad) {
          mapping_step = -1;
          mapping_pending = false;
          message = "Controller disconnected";
          dirty = true;
        }
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
      p.mapping_pointer = properties[0] &
          ((1ul << INPUT_PROP_DIRECT) | (1ul << INPUT_PROP_POINTER));
      std::array<unsigned long, (KEY_CNT + property_bits - 1) / property_bits>
          keys{};
      if (ioctl(p.fd, EVIOCGKEY(sizeof(keys)), keys.data()) >= 0)
        for (unsigned code = 0; code < KEY_CNT; ++code)
          p.pressed[code] = keys[code / property_bits] &
                            (1ul << (code % property_bits));
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
        const auto &info = p.abs[a];
        const int64_t range = int64_t(info.maximum) - info.minimum;
        const bool centered = a == ABS_X || a == ABS_Y || a == ABS_RX ||
            a == ABS_RY || a == p.right_x || a == p.right_y ||
            (a >= ABS_HAT0X && a <= ABS_HAT3Y);
        // Sticks/hats return to center; separate triggers usually return to
        // an endpoint. Also retain centered/shared trigger axes and inverted
        // endpoint ranges. Capture this once at discovery, never mid-pull.
        p.mapping_rest[a] = !centered && int64_t(info.value) * 4 <=
                int64_t(info.minimum) * 4 + range ? info.minimum :
            !centered && int64_t(info.value) * 4 >=
                int64_t(info.maximum) * 4 - range ? info.maximum :
            int(int64_t(info.minimum) + range / 2);
      }
      p.pad = p.abs[ABS_X].maximum > p.abs[ABS_X].minimum;
      log(std::string("input ") + path + " " + name);
      pads.push_back(p);
    }
  }
  bool mappingNeutral() const {
    for (const auto &p : pads) {
      if (p.disconnected) continue;
      if (std::any_of(p.pressed.begin(), p.pressed.begin() + KEY_CNT,
                      [](bool held) { return held; })) return false;
      if (p.mapping_pointer) continue;
      for (unsigned axis = 0; axis < ABS_CNT; ++axis) {
        const auto &a = p.abs[axis];
        const int64_t range = int64_t(a.maximum) - a.minimum;
        // The release band is deliberately narrower than the press band.
        // Resting noise is harmless, but a half-released trigger cannot arm
        // the following prompt. Integer math also handles two-state hats.
        if (range > 0 && std::abs(int64_t(a.value) - p.mapping_rest[axis]) * 10 >
                            range) return false;
      }
    }
    return true;
  }
  void finishMappingReport() {
    if (mapping_step < 0 || mapping_ready || !mappingNeutral()) return;
    mapping_ready = true;
    if (mapping_pending) {
      mapping_pending = false;
      if (++mapping_step == int(button_names.size())) {
        if (!mapping_pad.empty()) {
          fs::create_directories(fs::path(kit) / "inputs");
          atomicFile(fs::path(kit) / "inputs" /
                         ("NDS_input_" + mapping_pad + "_v3.map"),
                     new_map.data(), sizeof(new_map));
          for (auto &pad : pads)
            if (pad.id == mapping_pad) pad.map = new_map;
        }
        mapping_step = -1;
        message.clear();
        // No physical control is held at this boundary. Do not carry a
        // pre-wizard menu/game button state into the newly saved mapping.
        for (auto &pad : pads) pad.joy = pad.menujoy = pad.combo = 0;
      }
    }
    dirty = true;
  }
  void mappingPress(Pad &p, int code) {
    if (code == KEY_ESC || code == KEY_F12) {
      mapping_step = -1;
      mapping_pending = false;
      dirty = true;
      return;
    }
    if (!mapping_ready) {
      // If the same trigger supplies a digital alias after its axis, retain
      // the button binding used by previous versions. Do not require a driver
      // to advertise or deliver that alias: an axis-only pull is sufficient.
      if (mapping_pending && mapping_pad == p.id) {
        auto &chosen = new_map[button_slots[mapping_step]];
        if ((code == BTN_TL2 && (chosen == 0x300 + ABS_Z * 2 ||
                                chosen == 0x301 + ABS_Z * 2)) ||
            (code == BTN_TR2 && (chosen == 0x300 + ABS_RZ * 2 ||
                                chosen == 0x301 + ABS_RZ * 2)))
          chosen = code;
      }
      return;
    }
    if (code != KEY_SPACE && mapping_pad.empty()) mapping_pad = p.id;
    if (code == KEY_SPACE || mapping_pad == p.id) {
      new_map[button_slots[mapping_step]] = code == KEY_SPACE ? 0 : code;
      mapping_pending = true;
      mapping_ready = false;
      dirty = true;
    }
  }
  void mappingSkip() {
    if (mapping_step < 0 || !mapping_ready || !mappingNeutral()) return;
    new_map[button_slots[mapping_step]] = 0;
    mapping_pending = true;
    mapping_ready = false;
    finishMappingReport(); // USER already completed its press/release gesture.
  }
  void boardButtons(uint32_t buttons) {
    // MiSTer GPIO bits: OSD=1, USER=2. Like Main's short-button gestures,
    // act on release. OSD toggles the menu; USER shares Space's unassigned-
    // input operation in the mapper and resets the console during gameplay.
    buttons &= 3;
    if (!board_buttons_initialized) {
      board_buttons_initialized = true;
      board_buttons_previous = buttons;
      return; // Ignore a button already held at standalone takeover.
    }
    if (buttons == board_buttons_previous) return;
    if (!board_buttons_previous && buttons) {
      board_buttons_gesture = buttons;
      board_press_menu = menu;
      board_press_mapping = mapping_step >= 0;
      board_press_mapping_step = mapping_step;
    } else if (buttons && board_buttons_gesture) {
      board_buttons_gesture |= buttons;
    }
    board_buttons_previous = buttons;
    if (buttons || !board_buttons_gesture) return;
    const auto gesture = board_buttons_gesture;
    board_buttons_gesture = 0;
    // Do not apply a release to a different menu/wizard entered while held.
    if (board_press_menu != menu || board_press_mapping != (mapping_step >= 0)) return;
    if (mapping_step >= 0) {
      if (gesture & 1) { // OSD wins a chord; cancel without saving the draft.
        mapping_step = -1;
        mapping_pending = false;
        dirty = true;
      } else if ((gesture & 2) && board_press_mapping_step == mapping_step) {
        mappingSkip();
      }
    } else if (gesture & 1) {
      action(4);
    } else if (!menu && (gesture & 2)) {
      // Use the same save/firmware-safe reset as the existing core menu.
      // Never forward a USER reset while the OSD owns input.
      try { reset(); }
      catch (const std::exception &e) { firmwareError("Cannot reset firmware", e.what()); }
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
      if (down) mappingPress(p, code);
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
      changeDigitalLayout(1);
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
          if (mapping_step >= 0) {
            mapping_step = -1;
            mapping_pending = false;
            message = "Input interrupted; define again";
            dirty = true;
          }
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
          if (e.code >= ABS_CNT) continue;
          p.abs[e.code].value = e.value;
          int rx = p.right_x, ry = p.right_y;
          if ((e.code == rx || e.code == ry) &&
              p.abs[e.code].maximum > p.abs[e.code].minimum) {
            p.touch_analog_valid = true;
            auto a = p.abs[e.code];
            const int64_t range = int64_t(a.maximum) - a.minimum;
            const int64_t offset = int64_t(e.value) * 2 - a.minimum - a.maximum;
            // Ignore the inner 3% of each half-axis before rounding to the
            // core's signed 8-bit coordinates. This also treats both center
            // values of an even-sized range (DualSense 127/128) as neutral.
            int value = offset * 100 >= -range * 3 && offset * 100 <= range * 3
                ? 0 : std::clamp(int((int64_t(e.value) - a.minimum) * 255 / range) -
                                     128, -128, 127);
            int shift = e.code == rx ? 0 : 8;
            const auto previous = p.analog;
            p.analog = (p.analog & ~(255 << shift)) | (uint8_t(value) << shift);
            if (!menu && p.analog != previous)
              spi.cmd(Spi::IO, 0x3d, {0, expandTouchAnalog(rotateTouchAnalog(p.analog, touch_rotation), touch_range)});
          }
          if (mapping_step >= 0) {
            const auto &a = p.abs[e.code];
            const int64_t range = int64_t(a.maximum) - a.minimum;
            const int rest = p.mapping_rest[e.code];
            const int64_t delta = int64_t(e.value) - rest;
            const bool endpoint = rest == a.minimum || rest == a.maximum;
            if (range > 0) {
              // Keep normal gameplay's synthesized key state current without
              // feeding its resting trigger direction into the wizard.
              const int center = (a.minimum + a.maximum) / 2;
              const int dz = std::max(0, (a.maximum - a.minimum) / 4);
              p.pressed[0x300 + e.code * 2] = e.value < center - dz;
              p.pressed[0x301 + e.code * 2] = e.value > center + dz;
            }
            // Analog-only triggers map the pull direction, never their
            // resting endpoint. All further events wait for full release.
            if (!p.mapping_pointer && range > 0 &&
                std::abs(delta) * 4 > range * (endpoint ? 3 : 1))
              mappingPress(p, 0x300 + e.code * 2 + (delta > 0));
            continue;
          }
          // Preserve the existing axis codes and gameplay thresholds.
          if (p.abs[e.code].maximum > p.abs[e.code].minimum) {
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
          // Finish only at a complete evdev report, after both the digital
          // and analog halves of a physical control have been released.
          finishMappingReport();
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
    speed_hacks_available = fs::is_regular_file(fs::path(kit) / "fmv/nsmb_hooks.json");
    if (speed_hacks_available) {
      std::ifstream config(fs::path(kit) / "NDS_speed.cfg");
      const std::string text((std::istreambuf_iterator<char>(config)), {});
      for (unsigned i=0;i<SPEED_MODES.size();++i)
        if (text == "NDS-SpeedHacks-v1\n" + std::to_string(i) + "\n") speed_hacks = i;
      if (const char *mode = std::getenv("NDS_NSMB_PATCH")) {
        speed_hacks = 0;
        for (unsigned i=0;i<SPEED_MODES.size();++i) if (std::strcmp(mode,SPEED_MODES[i]) == 0) speed_hacks=i;
      }
    }
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
    std::ifstream video_config(fs::path(kit) / "NDS_video.cfg", std::ios::binary);
    const std::string video_contents((std::istreambuf_iterator<char>(video_config)),
                                     std::istreambuf_iterator<char>());
    direct_video_crt = video_contents != "NDS-DirectVideo-v1\nretrotink\n";
    std::ifstream touch_config(fs::path(kit) / "NDS_touch.cfg");
    std::string touch_header, touch_value;
    if (std::getline(touch_config, touch_header) && touch_header == "NDS-TouchRotation-v1" &&
        std::getline(touch_config, touch_value))
      for (unsigned i = 0; i < 3; ++i)
        if (touch_value == TOUCH_ROTATION_NAMES[i]) touch_rotation = TouchRotation(i);
    std::ifstream stick_config(fs::path(kit) / "NDS_stick.cfg");
    const std::string stick_contents((std::istreambuf_iterator<char>(stick_config)),
                                     std::istreambuf_iterator<char>());
    for (unsigned i = 0; i < TOUCH_RANGE_PERCENT.size(); ++i)
      if (stick_contents == "NDS-StickRange-v1\n" + std::to_string(TOUCH_RANGE_PERCENT[i]) + "\n")
        touch_range = i;
    std::ifstream ini(sd_root / "MiSTer.ini");
    std::string text((std::istreambuf_iterator<char>(ini)),
                     std::istreambuf_iterator<char>());
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
    require(!live_main(), "another MiSTer process started");
    beginLoading(fs::path(path).filename().string());
    loading_preparing = true;
    loading_started = ms();
    loading_next_animation = 0;
    animateLoading(loading_started);
    clearConsoleInputs();
    drain(450);
    uint64_t next_main_check = 0;
    const auto service = [&] {
      if (!running) throw std::runtime_error("ROM load interrupted");
      if (ms() >= next_main_check) {
        require(!live_main(), "another MiSTer process started");
        next_main_check = ms() + 500;
      }
      sector();
      beat();
      animateLoading(ms());
    };
    const char* automatic_movies = std::getenv("NDS_FMV_AUTO");
    const bool prepare_movies = automatic_movies && std::strcmp(automatic_movies, "1") == 0;
    RomReader reader(path, (prepare_movies || (speed_hacks_available && speed_hacks)) ?
        (fs::path(kit) / "fmv").string() : std::string(), SPEED_MODES[speed_hacks], prepare_movies);
    // File validation and all CIFS reads run outside the SPI/heartbeat owner.
    const auto file_size = reader.size(service);
    loading_preparing = false;
    log(std::string(reader.framed() ? "ROM stream ready; verification pending after " :
                                    "ROM preparation completed in ") +
        std::to_string(ms() - loading_started) + " ms");
    line(6, " Loading ROM");
    loading_progress = -1;
    updateLoading(0, 1);
    const auto transfer_size = RomReader::transferSize(file_size);
    const auto storage_size = RomLayout::storageSize(file_size);
    // Reserve every destination before touching FIO. Large files use the
    // expanded windows; Linux console and graphics/control retain their owners.
    requireHostSaveProfile();
    if (RomLayout::extended(file_size) && !(firmwareControl().flags & 0x4000))
      throw std::runtime_error("Large ROM requires the matching 464 MiB cartridge-capable FPGA core");
    RomMapping mapping(file_size);
    firmwareControl(1);
    flushFirmware();
    uploadDirectGameAssets();
    seedGameClock();
    spi.cmd(Spi::FIO, 0x55, {RomLayout::index(file_size)});
    spi.cmd(Spi::FIO, 0x56, {0x2e4e, 0x4453});
    spi.cmd(Spi::FIO, 0x53, {255, uint16_t(file_size), uint16_t(file_size >> 16)});
    // Download's rising edge asks the save bridge to flush the outgoing cart.
    drain(100);
    size_t off = 0;
    if (reader.framed()) {
      // The worker can relocate files but never maps cartridge memory. Clear
      // every destination while the CPUs are held, including gaps and old ROMs.
      while (off < storage_size) {
        service();
        const auto chunk = mapping.at(off);
        const auto n = std::min<size_t>(262144, chunk.size);
        memset(chunk.data, 0xff, n);
        off += n;
      }
      reader.transferFramed(file_size, service,
          [&](uint64_t at, const unsigned char *data, size_t size) {
            while (size) {
              const auto chunk = mapping.at(at);
              const auto n = std::min<size_t>(size, chunk.size);
              memcpy(chunk.data, data, n);
              at += n; data += n; size -= n;
            }
          }, [&](uint64_t done, uint64_t total) { updateLoading(done, total); }, [&] {
            loading_preparing = true;
            loading_started = ms();
            loading_next_animation = 0;
            animateLoading(loading_started);
          });
      loading_preparing = false;
      loading_progress = -1;
      updateLoading(storage_size, storage_size);
      log("ROM streamed verification and preparation completed");
    } else {
    while (off < transfer_size) {
      const auto chunk = mapping.at(off);
      off += reader.read(chunk.data, std::min<size_t>(262144, std::min<uint64_t>(chunk.size, transfer_size - off)), service);
      updateLoading(off, storage_size);
    }
    reader.finish(file_size, service);
    }
    // The extended FPGA aperture always backs 464 MiB. A trimmed file must not
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
    line(6, " Starting game");
    __sync_synchronize();
    const char* movie_fast = std::getenv("NDS_FMV_COLOR_FAST");
    if (movie_fast && std::strcmp(movie_fast,"1") == 0) {
      const auto staged = mapping.at(0);
      const bool applied = nds_fmv::apply(static_cast<uint8_t*>(staged.data), staged.size, file_size);
      log(applied ? "FMV decoder fast paths applied to staged ACVE revision 0" :
                    "FMV decoder fast paths skipped: ROM identity or code differs");
      __sync_synchronize();
    }
    const auto *header = static_cast<const uint8_t *>(mapping.at(0).data);
    const uint32_t game_code = uint32_t(header[12]) | uint32_t(header[13]) << 8 |
                               uint32_t(header[14]) << 16 | uint32_t(header[15]) << 24;
    const uint64_t nand_base = (uint64_t(header[0x96]) | uint64_t(header[0x97]) << 8) << 17;
    mapping.reset();
    const uint8_t save_type = nds_save_profile::lookup(game_code);
    if (nds_nand::bytes(save_type)) {
      if (!(firmwareControl().flags & 0x1000))
        throw std::runtime_error("NAND cartridge saves require the matching NAND-capable FPGA core");
      // Older AXBJ cartridges lack this header field. Do not guess their
      // bank layout or touch their save until that variant is verified.
      if (!nand_base || uint64_t(nand_base) + nds_nand::bytes(save_type) > 0x08000000)
        throw std::runtime_error("Unsupported NAND cartridge save-region header; save preserved");
    }
    mount(path, save_type);
    spi.cmd(Spi::FIO, 0x53, {0});
    uploadSaveProfile(game_code);
    firmwareControl(3);
    waitFirmware(3, 0, 3000, "direct game boot release");
    native_firmware = false;
    game = path;
    currentdir = fs::path(path).parent_path();
    try { remember(path); }
    catch (const std::exception &e) { log(std::string("recent files: ") + e.what()); }
    menu = false;
    browser = system_menu = display_menu = false;
    recent_view = recent_clear_confirm = false;
    osd(false);
    log("ROM started " + path);
  }
  void run(unsigned seconds) {
    uint64_t end = seconds ? ms() + seconds * 1000ull : ~0ull;
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
      boardButtons(spi.buttons());
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
    if (game_clock_seeded) { firmwareControl(1); flushGameClock(); }
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
