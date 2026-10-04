// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include "test_rom_fixture.h"
#include <cassert>
#include <iostream>
#include <sys/wait.h>
static unsigned rom_test_metadata_delay = 0, rom_test_read_delay = 0;
static uint64_t rom_test_delay_offset = 0;
static uint64_t rom_test_error_offset = 262144;
static bool rom_test_read_error = false;
static std::string rom_test_observer;
static uint64_t rom_test_fill_next = 0;
static unsigned rom_test_fill_calls = 0;
static void delayed_rom_file(int fd, uint64_t off) {
  const auto delay = fd < 0 ? rom_test_metadata_delay : off == rom_test_delay_offset ? rom_test_read_delay : 0;
  const auto end = ms() + delay;
  uint64_t maximum_age = 0;
  while (ms() < end) {
    uint64_t beat = 0;
    std::ifstream("/tmp/nds-standalone-heartbeat") >> beat;
    if (beat) maximum_age = std::max(maximum_age, ms() - beat);
    usleep(10000);
  }
  if (delay) std::ofstream(rom_test_observer, std::ios::app) << maximum_age << '\n';
  if (fd >= 0 && off == rom_test_error_offset && rom_test_read_error) close(fd);
}
struct HostTest {
  static void finishStorage(Host &host) {
    const auto deadline=ms()+5000;
    while(host.storage_job){assert(ms()<deadline);host.beat();host.pollStorage();usleep(1000);}
  }
  static void rom_loading(const fs::path &root, bool slow) {
    const auto sd = root / "loader-sd", kit = root / "loader-kit";
    fs::create_directories(kit);
    const auto roms = sd / "games/NDS";
    fs::create_directories(roms);
    const auto path = roms / "loader.nds";
    RomMapping::test_iomem_path = (root / "iomem").string();
    std::ofstream(RomMapping::test_iomem_path) << "00000000-1fefffff : System RAM\n";
    std::ofstream(path, std::ios::binary) << std::string(512, 'x');
    Host h(kit.string(), roms.string(), sd);
    rom_test_observer = (root / "loader-heartbeat-observer.txt").string();
    RomReader::test_hook = delayed_rom_file;
    rom_test_metadata_delay = 250;
    rom_test_read_delay = slow ? 21500 : 250;
    running = 1;
    h.spi.history.clear();
    h.load(path.string());
    assert(h.game == path && !h.menu && h.loading_progress == 167);
    assert(RecentFiles::read(h.recentConfig()).size() == 1);
    std::vector<std::vector<uint16_t>> downloads;
    std::vector<std::vector<uint16_t>> indices;
    for (const auto &t : h.spi.history) {
      if (t.select == Spi::FIO && t.command == 0x53) downloads.push_back(t.words);
      if (t.select == Spi::FIO && t.command == 0x55) indices.push_back(t.words);
    }
    assert((downloads == std::vector<std::vector<uint16_t>>{{1, 0, 0}, {0}, {1, 0, 0}, {0}, {1, 0, 0}, {0}, {255, 512, 0}, {0}}));
    assert((indices == std::vector<std::vector<uint16_t>>{{4}, {5}, {7}, {3}}));
    uint64_t age, maximum_age = 0;
    std::ifstream observer(rom_test_observer);
    while (observer >> age) maximum_age = std::max(maximum_age, age);
    assert(maximum_age > 0 && maximum_age < 1000);
    std::cout << "PASS: actual Host::load metadata/read wait, heartbeat maximum_age_ms="
              << maximum_age << " injected_read_delay_ms=" << rom_test_read_delay << '\n';
    rom_test_metadata_delay = rom_test_read_delay = 0;
    const auto outgoing_save = h.save;
    const std::string saved_bytes(512, 's');
    assert(pwrite(outgoing_save, saved_bytes.data(), saved_bytes.size(), 0) == ssize_t(saved_bytes.size()));
    const auto verify_no_start = [&] {
      uint16_t index = 0;
      for (const auto &t : h.spi.history) {
        if (t.select == Spi::FIO && t.command == 0x55) index = t.words.at(0);
        assert(!(t.select == Spi::FIO && t.command == 0x53 && (index & 0xff) == 3 &&
                 t.words == std::vector<uint16_t>{0}));
      }
      assert(h.game == path && RecentFiles::read(h.recentConfig()).size() == 1);
      assert(h.save == outgoing_save);
      assert(RomMapping::test_live_mappings == 0);
      std::string current_save(saved_bytes.size(), '\0');
      assert(pread(h.save, current_save.data(), current_save.size(), 0) == ssize_t(current_save.size()));
      assert(current_save == saved_bytes);
    };
    const auto broken = roms / "broken.nds";
    std::ofstream(broken, std::ios::binary) << std::string(524288, 'x');
    rom_test_read_error = true;
    h.spi.history.clear();
    bool failed = false;
    try { h.load(broken.string()); }
    catch (const std::exception &e) { failed = std::string(e.what()).find("ROM read failed") != std::string::npos; }
    assert(failed);
    verify_no_start();
    assert(h.loading_progress > 0 && h.loading_progress < 167);
    assert(!fs::exists(sd / "saves/NDS/broken.sav"));
    rom_test_read_error = false;
    h.spi.history.clear();
    failed = false;
    try { h.load((roms / "missing.nds").string()); }
    catch (const std::exception &e) { failed = std::string(e.what()).find("open ROM") != std::string::npos; }
    assert(failed);
    for (const auto &t : h.spi.history) assert(t.select != Spi::FIO);
    verify_no_start();
    // SIGTERM cancels both blocked metadata and a read after download starts.
    signal(SIGTERM, stop);
    for (const bool metadata : {true, false}) {
      rom_test_metadata_delay = metadata ? 5000 : 0;
      rom_test_read_delay = metadata ? 0 : 5000;
      rom_test_delay_offset = 262144;
      const auto parent = getpid();
      const auto signaller = fork();
      assert(signaller >= 0);
      if (!signaller) { usleep(900000); kill(parent, SIGTERM); _exit(0); }
      h.spi.history.clear();
      const auto start = ms();
      failed = false;
      try { h.load(broken.string()); }
      catch (const std::exception &e) { failed = std::string(e.what()).find("ROM load interrupted") != std::string::npos; }
      assert(failed && ms() - start < 1500);
      verify_no_start();
      if (!metadata) assert(h.loading_progress > 0 && h.loading_progress < 167);
      assert(!fs::exists(sd / "saves/NDS/broken.sav"));
      int status;
      assert(waitpid(signaller, &status, 0) == signaller && WIFEXITED(status));
      running = 1;
    }
    rom_test_metadata_delay = rom_test_read_delay = 0;
    const auto large = roms / "large.nds", oversize = roms / "oversize.nds";
    largeRomFixture(large.c_str(), RomReader::max_file_size);
    std::ofstream(oversize).put('x');
    assert(truncate(oversize.c_str(), RomReader::max_file_size + 1) == 0);
    h.browse(roms);
    bool visible = false;
    for (const auto &entry : h.roms) {
      if (entry.name == "large.nds") visible = true;
      assert(entry.name != "oversize.nds");
    }
    assert(visible && h.usableRecent(large) && !h.usableRecent(oversize));
    const auto reject_large = [&](const char *expected, bool before_download) {
      h.spi.history.clear();
      bool rejected = false;
      try { h.load(large.string()); }
      catch (const std::exception &e) { rejected = std::string(e.what()).find(expected) != std::string::npos; }
      assert(rejected);
      verify_no_start();
      assert(!fs::exists(sd / "saves/NDS/large.sav"));
      if (before_download) {
        for (const auto &t : h.spi.history) assert(t.select != Spi::FIO);
        assert(h.loading_progress == 0);
      } else assert(h.loading_progress > 0 && h.loading_progress < 167);
    };
    for (const auto offset : {RomReader::max_transfer_size, RomReader::max_file_size - 1}) {
      romFixtureByte(large.c_str(), offset, 0);
      reject_large("above 316 MiB must be FF padding", true);
      romFixtureByte(large.c_str(), offset, 0xff);
    }
    rom_test_read_error = true;
    rom_test_error_offset = RomReader::max_transfer_size;
    reject_large("ROM read failed while checking padding", true);
    for (const auto offset : {2 * RomLayout::mib, 252 * RomLayout::mib, 256 * RomLayout::mib}) {
      rom_test_error_offset = offset;
      reject_large("ROM read failed", false);
    }
    rom_test_read_error = false;
    rom_test_error_offset = 262144;
    // Every destination must map before any FIO. A failure in the second or
    // third span must release earlier mappings and preserve the outgoing save.
    for (int span = 0; span < 3; ++span) {
      RomMapping::test_fail_mapping = span;
      reject_large("ROM mmap", true);
    }
    RomMapping::test_fail_mapping = -1;
    const auto good_iomem = RomMapping::test_iomem_path;
    RomMapping::test_iomem_path = "/does/not/exist";
    reject_large("readable, unredacted Linux memory map", true);
    RomMapping::test_iomem_path = good_iomem;
    std::ofstream(good_iomem) << "00000000-00000000 : System RAM\n";
    reject_large("readable, unredacted Linux memory map", true);
    std::ofstream(good_iomem) << "00000000-2fffffff : System RAM\n";
    reject_large("overlaps Linux System RAM", true);
    std::ofstream(good_iomem) << "00000000-1fefffff : System RAM\n";
    // Trimmed extended images still map/fill the whole backing, and a
    // cancellation during the bounded FF fill must never start a partial ROM.
    assert(truncate(large.c_str(), 256 * RomLayout::mib + 1) == 0);
    RomMapping::test_before_padding_write = [](uint64_t off) {
      assert(off >= 256 * RomLayout::mib + 1);
      running = 0;
    };
    reject_large("ROM load interrupted", false);
    RomMapping::test_before_padding_write = nullptr;
    running = 1;
    largeRomFixture(large.c_str(), RomReader::max_file_size);
    // Cancellation remains responsive while the worker checks omitted padding.
    rom_test_delay_offset = RomReader::max_transfer_size;
    rom_test_read_delay = 5000;
    const auto parent = getpid();
    const auto signaller = fork();
    assert(signaller >= 0);
    if (!signaller) { usleep(900000); kill(parent, SIGTERM); _exit(0); }
    const auto start = ms();
    reject_large("ROM load interrupted", true);
    assert(ms() - start < 1500);
    int signal_status;
    assert(waitpid(signaller, &signal_status, 0) == signaller && WIFEXITED(signal_status));
    running = 1;
    // A complete 512 MiB file transfers 316 MiB and retains the full size on
    // the wire, with heartbeat service during the pre-download padding check.
    rom_test_read_delay = slow ? 21500 : 250;
    h.spi.history.clear();
    h.load(large.string());
    downloads.clear();
    indices.clear();
    for (const auto &t : h.spi.history) {
      if (t.select == Spi::FIO && t.command == 0x53) downloads.push_back(t.words);
      if (t.select == Spi::FIO && t.command == 0x55) indices.push_back(t.words);
    }
    assert((downloads == std::vector<std::vector<uint16_t>>{{1, 0, 0}, {0}, {1, 0, 0}, {0}, {1, 0, 0}, {0}, {255, 0, 0x2000}, {0}}));
    assert((indices == std::vector<std::vector<uint16_t>>{{4}, {5}, {7}, {0x303}}));
    assert(h.game == large && h.loading_progress == 167);
    std::ifstream saved_file(sd / "saves/NDS/loader.sav", std::ios::binary);
    assert(std::string(std::istreambuf_iterator<char>(saved_file), {}) == saved_bytes);
    std::ifstream large_observer(rom_test_observer);
    maximum_age = 0;
    while (large_observer >> age) maximum_age = std::max(maximum_age, age);
    assert(maximum_age > 0 && maximum_age < 1000);
    assert(RomMapping::test_live_mappings == 0);
    std::cout << "PASS: 512 MiB load, browser/recents boundary, padding/map/partial failure and cancellation preserve saves; heartbeat maximum_age_ms="
              << maximum_age << '\n';
    rom_test_read_delay = 0;
    for (const uint64_t size : {128ull * 1024 * 1024, 128ull * 1024 * 1024 + 1,
                               256ull * 1024 * 1024, 256ull * 1024 * 1024 + 1}) {
      largeRomFixture(large.c_str(), size);
      h.spi.history.clear();
      h.load(large.string());
      indices.clear();
      for (const auto &t : h.spi.history)
        if (t.select == Spi::FIO && t.command == 0x55) indices.push_back(t.words);
      const uint16_t expected_index = size > 256ull * 1024 * 1024 ? 0x303 :
                                      size > 128ull * 1024 * 1024 ? 0x103 : 3;
      assert((indices == std::vector<std::vector<uint16_t>>{{4}, {5}, {7}, {expected_index}}));
    }
    std::cout << "PASS: legacy/LR1/512 protocol modes at both capacity boundaries\n";
    // Exercise actual Host::load against persistent file-backed physical DDR:
    // a full image leaves non-FF bytes, then a trimmed replacement clears all
    // backed bytes after its EOF. Neither mapping reconstruction nor a fresh
    // anonymous allocation can conceal stale data in this check.
    const auto physical_file = root / "physical-ddr";
    const int physical_fd = open(physical_file.c_str(), O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(physical_fd >= 0 && ftruncate(physical_fd, 0x40000000) == 0);
    RomMapping::test_memory_fd = physical_fd;
    largeRomFixture(large.c_str(), RomReader::max_file_size);
    h.load(large.string());
    unsigned char prior = 0;
    assert(pread(physical_fd, &prior, 1, 0x2bbfffff) == 1 && prior == 0x37);
    const auto trimmed = 256 * RomLayout::mib + 1;
    largeRomFixture(large.c_str(), trimmed);
    rom_test_fill_next = trimmed;
    rom_test_fill_calls = 0;
    RomMapping::test_before_padding_write = [](uint64_t off) {
      assert(off == rom_test_fill_next);
      rom_test_fill_next += std::min<uint64_t>(262144, RomLayout::max_transfer_size-off);
      ++rom_test_fill_calls;
    };
    h.load(large.string());
    assert(rom_test_fill_next == RomLayout::max_transfer_size && rom_test_fill_calls == 240);
    RomMapping::test_before_padding_write = nullptr;
    std::array<unsigned char, 262144> padding;
    for (uint64_t off = trimmed; off < RomLayout::max_transfer_size;) {
      const auto n = std::min<uint64_t>(padding.size(), RomLayout::max_transfer_size-off);
      assert(pread(physical_fd, padding.data(), n, 0x28000000 + off % (64 * RomLayout::mib)) == ssize_t(n));
      assert(std::all_of(padding.begin(), padding.begin()+n, [](unsigned char byte) { return byte == 0xff; }));
      off += n;
    }
    assert(RomMapping::test_live_mappings == 0);
    RomMapping::test_memory_fd = -1;
    close(physical_fd);
    fs::remove(physical_file);
    std::cout << "PASS: actual Host full512->trimmed load clears every backed byte beyond EOF in240bounded chunks\n";
    RomReader::test_hook = nullptr;
    rom_test_metadata_delay = rom_test_read_delay = 0;
    rom_test_delay_offset = 0;
    // Beat reaps any cancellation that completed after the loader unwound.
    usleep(10000);
    h.nextbeat = 0;
    h.beat();
    int status;
    assert(waitpid(-1, &status, WNOHANG) < 0 && errno == ECHILD);
    std::cout << "PASS: ROM errors/cancellation cannot start partial ROM; all workers reaped\n";
  }
  static void framebuffer_metadata(const fs::path &root) {
    const auto kit = root / "framebuffer-kit", sd = root / "framebuffer-sd";
    fs::create_directories(kit);
    Host h(kit.string(), (root / "roms").string(), sd);
    h.status = 0x1420;
    h.full_status[0] = 0x20; // Live status must override the saved first word.
    h.full_status[4] = 0xbeef;
    h.menu = false;
    h.lastjoy = 16;
    const auto prior_status = h.full_status;
    const auto prior_message = h.message;
    const auto prior_dirty = h.dirty;
    const auto file = kit / "framebuffer-metadata.json";
    auto read = [&]() {
      std::ifstream f(file);
      return std::string(std::istreambuf_iterator<char>(f), {});
    };
    h.spi.history.clear();
    framebuffer_metadata_requested = 0;
    h.serviceFramebufferMetadataRequest();
    assert(h.spi.history.empty() && !fs::exists(file));

    // Independent wire fixture: Main reads the command's CRC then ARX, ARY,
    // flags/format, width and height; sys_top adds base low/high and stride.
    h.spi.framebuffer_reply = {0x12ab, 0x1004, 0x1003, 0xc6, 384, 256,
                               0x1234, 0x2420, 1536};
    signal(SIGUSR1, request_framebuffer_metadata);
    raise(SIGUSR1);
    raise(SIGUSR1);
    assert(framebuffer_metadata_requested && h.spi.history.empty() && !fs::exists(file));
    const auto ends = h.spi.end_count;
    h.serviceFramebufferMetadataRequest();
    assert(!framebuffer_metadata_requested && !h.spi.selected);
    assert(h.spi.end_count == ends + 1 && h.spi.framebuffer_reply_index == 9);
    assert(h.spi.history.size() == 1);
    const auto &t = h.spi.history.front();
    assert(t.select == Spi::IO && t.command == 0x40);
    assert(t.words == std::vector<uint16_t>(8, 0));
    const auto first = read();
    for (const auto *field : {"\"schema_version\": 1", "\"request_sequence\": 1",
                             "\"change_hint_crc8\": 171", "\"base_address\": 606081588",
                             "\"raw_words\": [4100, 4099, 198, 384, 256, 4660, 9248, 1536]",
                             "\"host_status_words\": [5152, 0, 0, 0, 48879, 0, 0, 0]"})
      assert(first.find(field) != std::string::npos);
    auto number = [&](const char *name) {
      auto pos = first.find(std::string("\"") + name + "\": ");
      assert(pos != std::string::npos);
      return std::stoull(first.substr(first.find(':', pos) + 1));
    };
    assert(number("host_pid") == unsigned(getpid()));
    assert(number("started_monotonic_us") <= number("completed_monotonic_us"));
    assert(number("completed_monotonic_us") <= monotonic_us());
    assert(!fs::exists(file.string() + ".new"));
    h.serviceFramebufferMetadataRequest();
    assert(h.spi.history.size() == 1 && read() == first);

    // The complete serialization is valid JSON, with the wire order and masks
    // fixed independently of the production decoder. High base bits stay unsigned.
    FramebufferMetadata fixture{0x12ab, {0x1004, 0x1003, 0xc6, 384, 256,
                                        0x1234, 0x9420, 1536}};
    assert(fixture.json(7, 42, 100, 110, {5152, 0, 0, 0, 48879, 0, 0, 0}) ==
R"({
  "schema_version": 1,
  "request_sequence": 7,
  "host_pid": 42,
  "started_monotonic_us": 100,
  "completed_monotonic_us": 110,
  "command": 64,
  "command_reply": 4779,
  "change_hint_crc8": 171,
  "atomic_hardware_snapshot": false,
  "raw_words": [4100, 4099, 198, 384, 256, 4660, 37920, 1536],
  "aspect_x": 4,
  "aspect_y": 3,
  "aspect_xy_flag": true,
  "flags_format": 198,
  "local_framebuffer_enabled": true,
  "framebuffer_enabled": true,
  "format": 6,
  "width": 384,
  "height": 256,
  "base_address": 2485129780,
  "stride_bytes": 1536,
  "host_status_words": [5152, 0, 0, 0, 48879, 0, 0, 0]
}
)");

    // A command or data-word failure must deselect SPI, keep the last complete
    // file and consume the request without retries or entering a menu.
    for (const auto fail_at : {0, 5}) {
      h.spi.framebuffer_fail_at = fail_at;
      raise(SIGUSR1);
      h.serviceFramebufferMetadataRequest();
      assert(!h.spi.selected && !framebuffer_metadata_requested && read() == first);
      const auto transactions = h.spi.history.size();
      h.serviceFramebufferMetadataRequest();
      assert(h.spi.history.size() == transactions);
    }
    h.spi.framebuffer_fail_at = -1;
    // A file error occurs after SPI has been released, preserves the old JSON,
    // and cannot leave a repeating diagnostic in the gameplay loop.
    fs::create_directory(file.string() + ".new");
    raise(SIGUSR1);
    h.serviceFramebufferMetadataRequest();
    assert(!h.spi.selected && !framebuffer_metadata_requested && read() == first);
    fs::remove(file.string() + ".new");
    h.spi.framebuffer_reply = {0, 4, 3, 6, 256, 192, 0, 0x2400, 1024};
    raise(SIGUSR1);
    h.serviceFramebufferMetadataRequest();
    assert(read().find("\"request_sequence\": 5") != std::string::npos);
    assert(read().find("\"framebuffer_enabled\": false") != std::string::npos);
    assert(read().find("\"local_framebuffer_enabled\": false") != std::string::npos);
    assert(read().find("\"aspect_xy_flag\": false") != std::string::npos);
    assert(!h.menu && h.status == 0x1420 && h.full_status == prior_status);
    assert(h.lastjoy == 16 && h.message == prior_message && h.dirty == prior_dirty);
    assert(!fs::exists(kit / "NDS_v1.CFG"));
    for (const auto &transaction : h.spi.history)
      assert(transaction.select == Spi::IO && transaction.command == 0x40);
    std::cout << "PASS: framebuffer metadata request isolation, exact 0x40 wire fields, JSON, atomic replacement and failure cleanup\n";
  }
  static void layout_hotkey(const fs::path &root) {
    const auto kit = root / "layout-kit", sd = root / "layout-sd";
    fs::create_directories(kit / "inputs");
    fs::create_directories(sd / "config/inputs");
    Host h(kit.string(), (root / "roms").string(), sd);
    Pad p;
    p.id = "layout";
    p.map[4] = BTN_SOUTH;
    h.menu = false;
    h.status = (1 << 10) | (2 << 11) | (3 << 8) | (1 << 7) | (1 << 4);
    h.full_status[4] = 0xbeef;
    const auto baseline = h.status;
    const auto baseline_full = h.full_status;
    h.saveSettings();
    const auto saved_config = [&]() {
      std::ifstream f(kit / "NDS_v1.CFG", std::ios::binary);
      return std::string(std::istreambuf_iterator<char>(f), {});
    }();
    h.spi.history.clear();
    h.key(p, BTN_THUMBL, true);
    h.key(p, BTN_THUMBL, false);
    assert(h.status == baseline && h.spi.history.empty()); // Initially unassigned.
    p.map[13] = BTN_THUMBL | (uint32_t(BTN_THUMBR) << 16);
    h.key(p, BTN_SOUTH, true);
    for (unsigned press = 1; press <= 4; ++press) {
      h.spi.history.clear();
      h.key(p, BTN_THUMBL, true);
      assert(h.status == (baseline | ((press % 4) << 5)));
      assert(p.joy == 16 && !h.menu); // Held game A stays held; no DS hotkey bit.
      assert(h.spi.history.size() == 1);
      const auto &t = h.spi.history.front();
      assert(t.select == Spi::IO && t.command == 0x1e && t.words.size() == 8);
      assert(t.words[0] == h.status && !(t.words[0] & 1) && t.words[4] == 0xbeef);
      h.key(p, BTN_THUMBL, true); // Repeated key-down does not repeat the action.
      h.key(p, BTN_THUMBR, true); // An alternate held source is still one action.
      h.key(p, BTN_TR, true);
      h.key(p, BTN_TR, false);
      h.key(p, BTN_THUMBL, false);
      h.key(p, BTN_THUMBR, false);
      assert(h.spi.history.size() == 1 && p.joy == 16);
    }
    h.key(p, BTN_THUMBR, true); // Alternate binding works on its own.
    assert(h.status == (baseline | 32));
    h.key(p, BTN_THUMBR, false);
    h.menu = true;
    h.key(p, BTN_THUMBL, true);
    assert(h.status == (baseline | 32)); // Never changes layout inside menus.
    h.menu = false;
    h.key(p, BTN_THUMBL, true);
    assert(h.status == (baseline | 32)); // Closing the menu while held is inert.
    h.key(p, BTN_THUMBL, false);
    h.key(p, BTN_THUMBL, true);
    h.key(p, BTN_THUMBL, false);
    assert(h.status == (baseline | 64));
    assert(h.full_status[4] == baseline_full[4]);
    std::ifstream unchanged(kit / "NDS_v1.CFG", std::ios::binary);
    assert(std::string(std::istreambuf_iterator<char>(unchanged), {}) == saved_config);

    // Import existing controls without treating unused Main slots as shortcuts.
    const auto map_name = "NDS_input_layout_v3.map";
    auto normal_map = p.map;
    h.atomicFile(sd / "config/inputs" / map_name, normal_map.data(), sizeof(normal_map));
    h.readCoreMap(p, sd / "config/inputs");
    assert(p.map[4] == BTN_SOUTH && !p.map[13]);
    auto private_map = normal_map;
    private_map[13] = 0; // Previous standalone wizard only assigned 13 controls.
    h.atomicFile(kit / "inputs" / map_name, private_map.data(), sizeof(private_map));
    h.readCoreMap(p, sd / "config/inputs");
    assert(p.map == private_map);
    private_map[13] = BTN_THUMBL;
    h.atomicFile(kit / "inputs" / map_name, private_map.data(), sizeof(private_map));
    h.readCoreMap(p, sd / "config/inputs");
    assert(p.map == private_map);

    // The new final mapping prompt can be cancelled or skipped without changing
    // normal MiSTer maps. Skip saves the existing DS controls with no shortcut.
    h.pads.push_back(p);
    h.menu = true;
    h.mapping_step = 13;
    h.mapping_pad = p.id;
    h.new_map = private_map;
    assert(std::string(Host::button_names.back()) == "Cycle Video Layout");
    h.key(h.pads[0], KEY_ESC, true);
    h.key(h.pads[0], KEY_ESC, false);
    assert(h.mapping_step == -1);
    std::array<uint32_t, 32> persisted{};
    assert(Host::readmap(kit / "inputs" / map_name, persisted) && persisted == private_map);
    h.mapping_step = 13;
    h.key(h.pads[0], KEY_SPACE, true);
    h.key(h.pads[0], KEY_SPACE, false);
    assert(h.mapping_step == -1 && !h.pads[0].map[13]);
    private_map[13] = 0;
    assert(Host::readmap(kit / "inputs" / map_name, persisted) && persisted == private_map);
    assert(Host::readmap(sd / "config/inputs" / map_name, persisted) && persisted == normal_map);
    std::cout << "PASS: layout hotkey cycles/wraps once per press, menu suppression, status isolation, legacy maps and optional binding\n";
  }
  static void recents(const fs::path &root) {
    const auto sd = root / "recent-sd", kit = root / "recent-kit";
    const auto romdir = sd / "games/NDS";
    fs::create_directories(kit);
    fs::create_directories(romdir);
    for (const auto *name : {"First.nds", "Second.nds"})
      std::ofstream(romdir / name) << std::string(512, 'r');
    Host h(kit.string(), romdir.string(), sd);
    h.remember(romdir / "First.nds");
    h.remember(romdir / "Second.nds");
    auto recent = RecentFiles::read(h.recentConfig());
    assert(recent.size() == 2 && recent[0].name == "Second.nds");
    h.remember(romdir / "First.nds");
    recent = RecentFiles::read(h.recentConfig());
    assert(recent.size() == 2 && recent[0].directory == "games/NDS");
    assert(recent[0].label == "First");
    // Check the actual binary layout Main reads, including zero padding.
    std::ifstream raw(h.recentConfig(), std::ios::binary);
    std::string bytes((std::istreambuf_iterator<char>(raw)), {});
    assert(bytes.size() == 24576);
    assert(bytes.substr(0, 10) == std::string("games/NDS\0", 10));
    assert(bytes.substr(1024, 10) == std::string("First.nds\0", 10));
    assert(bytes.substr(1280, 6) == std::string("First\0", 6));
    // Both directions: import a record written in Main's layout.
    std::string main_bytes(24576, '\0');
    main_bytes.replace(0, 9, "games/NDS");
    main_bytes.replace(1024, 10, "Second.nds");
    main_bytes.replace(1280, 11, "Main choice");
    h.atomicFile(h.recentConfig(), main_bytes.data(), main_bytes.size());
    h.remember(romdir / "First.nds");
    recent = RecentFiles::read(h.recentConfig());
    assert(recent[1].label == "Main choice");
    Pad keyboard;
    keyboard.id = "keyboard";
    h.spi.history.clear();
    h.key(keyboard, KEY_GRAVE, true);
    h.key(keyboard, KEY_GRAVE, false);finishStorage(h);
    assert(h.browser && h.recent_view && !h.system_menu && h.cursor == 0);
    assert(h.spi.history.empty()); // opening history never resets/loads a ROM
    h.draw();
    nds_osd::Frame expected("Recent Files", charfont);
    assert(h.osd_rows[0] == expected.renderRow(0, " First", true));
    h.action(1);
    h.key(keyboard, KEY_BACKSPACE, true);
    h.key(keyboard, KEY_BACKSPACE, false);
    assert(h.recent_clear_confirm && h.cursor == 0);
    h.action(2); // No
    assert(h.recent_view && !h.recent_clear_confirm && h.cursor == 1);
    assert(RecentFiles::read(h.recentConfig()).size() == 2);
    // Removal after opening is harmless; disabled selection never touches FIO.
    fs::remove(romdir / "Second.nds");
    h.spi.history.clear();
    h.action(2);finishStorage(h);
    assert(h.recent_view && !h.recent_available[1] && h.spi.history.empty());
    h.action(3);
    assert(!h.browser && !h.recent_view && h.cursor == 0);
    Pad controller;
    controller.id = "controller";
    controller.system_map[10] = BTN_SELECT;
    h.key(controller, BTN_SELECT, true);
    h.key(controller, BTN_SELECT, false);finishStorage(h);
    assert(h.recent_view);
    h.key(keyboard, KEY_BACKSPACE, true);
    h.key(keyboard, KEY_BACKSPACE, false);
    h.action(1);
    h.action(2); // Yes, clear shared history
    assert(!h.recent_view && RecentFiles::read(h.recentConfig()).empty());
    assert(fs::exists(romdir / "First.nds"));
    // Unavailable/out-of-root entries are retained but cannot be loaded.
    h.writeRecents({{"../", "escape.nds", "Outside"}, {"games/NDS", "missing.nds", "Missing"}});
    h.openRecents();finishStorage(h);
    assert(h.recent_available == (std::vector<bool>{false, false}));
    h.action(3);
    h.recents_enabled = false;
    h.openRecents();finishStorage(h);
    assert(!h.recent_view);
    const auto saved = RecentFiles::encode(RecentFiles::read(h.recentConfig()));
    h.remember(romdir / "First.nds");
    assert(RecentFiles::encode(RecentFiles::read(h.recentConfig())) == saved);
    h.recents_enabled = true;
    // Corrupt history is never replaced with an empty list on update.
    std::ofstream(h.recentConfig(), std::ios::trunc) << "truncated";
    bool rejected = false;
    try { h.remember(romdir / "First.nds"); } catch (const std::exception &) { rejected = true; }
    assert(rejected && fs::file_size(h.recentConfig()) == 9);
    std::vector<RecentFile> bounded;
    for (int i = 0; i < 20; ++i)
      RecentFiles::prepend(bounded, {"games/NDS", std::to_string(i)+".nds", "Game"});
    assert(bounded.size() == 16 && bounded.back().name == "4.nds");
    RecentFiles::prepend(bounded, {"games/NDS", "4.nds", "Game"});
    assert(bounded.size() == 16 && bounded.front().name == "4.nds");
    assert(!recentEnabled("recents=0\n[Other]\nrecents=1\n"));
    assert(recentEnabled("recents=0\n[NDS]\nrecents=1\n"));
    std::cout << "PASS: Main-compatible recents, shortcuts, disabled files, clear confirmation, corrupt history\n";
  }
  static void legacy_engine_b_config(const fs::path &root) {
    for (bool private_config : {false, true}) {
      const auto base = root / (private_config ? "legacy-private" : "legacy-shared");
      const auto kit = base / "kit", sd = base / "sd";
      fs::create_directories(kit);
      fs::create_directories(sd / "config");
      const auto input = (private_config ? kit : sd / "config") / "NDS_v1.CFG";
      const std::array<uint16_t, 8> legacy{0x1020, 0, 0, 0, 0xdead};
      {
        std::ofstream file(input, std::ios::binary);
        file.write(reinterpret_cast<const char *>(legacy.data()), sizeof(legacy));
      }
      Host h(kit.string(), (root / "roms").string(), sd);
      assert(h.status == (legacy[0] | REQUIRED_STATUS));
      for (const auto &t : h.spi.history)
        if (t.command == 0x1e) assert(t.words[0] == h.status);
      h.spi.history.clear();
      h.status = 1; h.sendstatus(); // Required bit must not eat transient reset.
      assert(h.spi.history.back().words[0] == (1 | REQUIRED_STATUS));
      h.status = legacy[0]; h.saveSettings();
      auto expected = legacy; expected[0] |= REQUIRED_STATUS;
      std::array<uint16_t, 8> saved{};
      std::ifstream file(kit / "NDS_v1.CFG", std::ios::binary);
      assert(file.read(reinterpret_cast<char *>(saved.data()), sizeof(saved)));
      assert(saved == expected && h.status == expected[0]);
      if (!private_config) {
        std::ifstream original(input, std::ios::binary);
        assert(original.read(reinterpret_cast<char *>(saved.data()), sizeof(saved)));
        assert(saved == legacy); // Shared/imported settings are never rewritten.
      }
    }
    std::cout << "PASS: legacy Engine B Off normalized on import/save/status, reset and other settings preserved\n";
  }
  static void run(const fs::path &root) {
    Host host(root.string(), (root / "roms").string(), root / "sd");
    assert(host.status == REQUIRED_STATUS);
    // Unavailable System rows cannot become cursor stops. Navigation is
    // OSD-only, fits Reboot/Exit on the same page, and wraps to Core.
    host.action(6);
    const int main_rows[] = {0, 2, 11, 12, 14, 15};
    const int scroll_down[] = {0, 0, 0, 0, 0, 0};
    for (int i = 0; i < 6; ++i) {
      assert(host.cursor == i && host.system_menu);
      host.spi.history.clear();
      host.draw();
      assert(host.system_first == scroll_down[i]);
      const auto view = systemMenuView(host.system_rows, host.cursor, host.system_first);
      assert(view.selected + view.first == main_rows[i]);
      assert(!view.rows[view.selected].disabled);
      for (const auto &t : host.spi.history) assert(t.select == Spi::OSD);
      host.action(1);
    }
    host.draw();
    assert(host.cursor == 0 && host.system_first == 0);
    host.action(0);
    host.draw();
    assert(host.cursor == 5 && host.system_first == 0);
    host.action(5);
    assert(!host.system_menu && host.cursor == 0);
    // Right opens the adjacent System page from EVERY core row. It must
    // never change an option or pulse reset. Left returns to Load NDS.
    for (int row = 0; row < 9; ++row) {
      host.cursor = row;
      host.spi.history.clear();
      host.action(6);
      assert(host.system_menu && host.cursor == 0 && host.status == REQUIRED_STATUS);
      assert(host.spi.history.empty());
      host.action(5);
      assert(!host.system_menu && host.menu && host.cursor == 0);
    }
    // Match Main's top-aligned core rows, centered exit and page arrow;
    // the removed System folder must not leave a row or a cursor stop.
    host.spi.history.clear();
    host.draw();
    nds_osd::Frame expected("NDS", charfont);
    for (const auto &t : host.spi.history) {
      if (t.select != Spi::OSD || t.command < 0x20 || t.command > 0x2f) continue;
      unsigned row = t.command & 15;
      std::string text;
      if (!row) text = " " + std::string(LOAD_LABEL);
      else if (row == 1) text = " Boot DS firmware";
      else if (row >= 3 && row <= 7) text = optionLabel(0, CORE_OPTIONS[row-3]);
      else if (row == 9) text = " Reset";
      else if (row == 15) text = "            exit";
      auto bytes = expected.renderRow(row, text, row == 0, nds_osd::arrow_right);
      assert(t.words == std::vector<uint16_t>(bytes.begin(), bytes.end()));
    }
    host.cursor = 7;
    host.action(1);
    assert(host.cursor == 8);
    host.action(1);
    assert(host.cursor == 0);
    host.action(0);
    assert(host.cursor == 8);
    host.action(2);
    assert(!host.menu);
    host.togglemenu();
    // Native counter option and rotation: no Engine B cursor or reset writes.
    host.cursor = 5;
    host.action(2);
    assert(host.status == (16 | REQUIRED_STATUS));
    for (const auto &t : host.spi.history)
      if (t.select == Spi::IO && t.command == 0x1e)
        assert(!t.words.empty() && !(t.words[0] & 1));
    host.cursor = 6;
    host.action(7);
    assert((host.status & 6144) == 4096);
    host.full_status[4] = 0xdead;
    host.saveSettings();
    auto config = root / "NDS_v1.CFG";
    assert(fs::file_size(config) == 16);
    {
      Host reloaded(root.string(), (root / "roms").string(), root / "sd");
      assert(reloaded.status == host.status);
      assert(reloaded.full_status[4] == 0xdead);
    }
    // The same file is visible across frontend sessions. Old private copies
    // must never roll shared progress back after the normal frontend writes.
    fs::create_directories(root / "saves");
    std::ofstream(root / "saves/a.sav") << "stale private";
    const auto shared = root / "sd/saves/NDS/a.sav";
    std::ofstream(shared) << "normal progress";
    host.mount((root / "roms/a.nds").string());
    char save_bytes[64]{};
    assert(pread(host.save, save_bytes, sizeof(save_bytes), 0) == 15);
    assert(std::string(save_bytes, 15) == "normal progress");
    assert(pwrite(host.save, "shared progress", 15, 0) == 15);
    host.mount((root / "roms/Z.NDS").string());
    {
      std::ifstream normal(shared);
      std::string content((std::istreambuf_iterator<char>(normal)), {});
      assert(content == "shared progress");
      std::ofstream(shared, std::ios::trunc) << "normal advanced";
    }
    host.mount((root / "roms/a.nds").string());
    assert(pread(host.save, save_bytes, sizeof(save_bytes), 0) == 15);
    assert(std::string(save_bytes, 15) == "normal advanced");
    assert(fs::file_size(root / "saves/a.sav") == 13);
    // Reset confirmation defaults to No and must not touch status, saves or
    // config before consent. Yes restores options but keeps both engines on.
    const auto before_reset = host.full_status;
    const auto before_status = host.status;
    host.system_menu = true;
    host.cursor = 2;
    host.spi.history.clear();
    host.action(2);
    assert(host.reset_confirm && host.cursor == 1);
    assert(host.spi.history.empty());
    host.draw();
    nds_osd::Frame reset_frame("Reset", charfont);
    assert(host.osd_rows[1] == reset_frame.renderRow(1, "       Reset settings?"));
    assert(host.osd_rows[4] == reset_frame.renderRow(4, "             no", true));
    host.action(2); // No.
    assert(!host.reset_confirm && host.system_menu && host.cursor == 2);
    assert(host.full_status == before_reset && host.status == before_status);
    host.action(2);
    host.action(0);
    host.action(3); // Back also cancels even with Yes selected.
    assert(!host.reset_confirm && host.full_status == before_reset);
    host.action(2);
    host.action(0);
    host.spi.history.clear();
    host.action(2); // Yes.
    assert(!host.reset_confirm && !host.system_menu && host.cursor == 0);
    assert(host.status == REQUIRED_STATUS &&
           host.full_status == (std::array<uint16_t, 8>{REQUIRED_STATUS}));
    for (const auto &t : host.spi.history) {
      assert(t.command != 0x53);
      if (t.command == 0x1e) assert(!(t.words[0] & 1));
    }
    {
      Host reloaded(root.string(), (root / "roms").string(), root / "sd");
      assert(reloaded.full_status == (std::array<uint16_t, 8>{REQUIRED_STATUS}));
    }
    host.full_status = before_reset;
    host.status = before_status;
    host.saveSettings();
    // Folder sorting, size limits, root confinement and missing-root recovery.
    host.browse(root / "roms");
    assert(host.roms.size() == 3);
    assert(host.roms[0].directory && host.roms[0].name == "nested");
    assert(host.roms[1].name == "a.nds" && host.roms[2].name == "Z.NDS");
    host.browse(root / "roms/nested");
    assert(host.roms.front().name == "..");
    host.browse(root / "not-present");
    assert(host.roms.size() == 1);
    host.browser = true;
    host.roms.resize(25);
    host.cursor = 0;
    host.action(6);
    assert(host.browser && !host.system_menu && host.cursor == 16);
    host.action(6);
    assert(host.cursor == 24);
    host.action(5);
    assert(host.cursor == 8);
    host.action(3);
    assert(!host.browser && host.cursor == 0);
    host.action(6);
    host.cursor = 5;
    host.action(3);
    assert(!host.system_menu && host.cursor == 0);
    // Alternative mapped source release must not cancel another held source.
    Pad p;
    p.id = "test";
    p.map[4] = BTN_SOUTH | (uint32_t(BTN_EAST) << 16);
    p.menu_map[4] = BTN_EAST;
    p.system_map[4] = BTN_EAST;
    p.system_map[5] = BTN_SOUTH;
    p.system_map[21] = BTN_TL;
    p.system_map[22] = BTN_TR;
    p.menu_map[3] = 0x322;
    p.map[3] = 0x322;
    host.menu = false;
    host.key(p, BTN_SOUTH, true);
    assert(p.joy & 16);
    host.key(p, BTN_EAST, true);
    host.key(p, BTN_SOUTH, false);
    assert(p.joy & 16);
    host.key(p, BTN_EAST, false);
    assert(!(p.joy & 16));
    host.key(p, 0x322, true);
    assert(p.joy & 8);
    host.key(p, 0x322, false);
    assert(!(p.joy & 8));
    // Custom OSD combination opens; generic confirm works despite game A swap.
    host.key(p, BTN_TL, true);
    assert(!host.menu);
    host.key(p, BTN_TR, true);
    assert(host.menu);
    host.key(p, BTN_TL, false);
    host.key(p, BTN_TR, false);
    host.cursor = 5;
    host.key(p, BTN_EAST, true);
    assert(!(host.status & 16));
    host.key(p, BTN_EAST, false);
    // Moving analog under menu must be resent on close.
    p.touch_analog_valid = true;
    p.analog = 0x127e;
    host.pads.push_back(p);
    host.togglemenu();
    bool sent = false;
    for (const auto &t : host.spi.history)
      if (t.command == 0x3d && t.words == std::vector<uint16_t>({0, 0x127e}))
        sent = true;
    assert(sent);
    // Short map files never partially replace accepted mapping.
    std::array<uint32_t, 32> map{};
    map.fill(0xbeef);
    std::ofstream(root / "short.map").put('x');
    assert(!Host::readmap(root / "short.map", map));
    assert(map[0] == 0xbeef);
    // Core map wizard writes only kit/inputs; no normal maps are touched.
    host.menu = true;
    host.mapping_step = 0;
    host.mapping_pad.clear();
    host.new_map.fill(0);
    for (int i = 0; i < 14; i++) {
      host.key(host.pads[0], BTN_0 + i, true);
      host.key(host.pads[0], BTN_0 + i, false);
    }
    assert(host.mapping_step == -1);
    assert(fs::file_size(root / "inputs/NDS_input_test_v3.map") == 128);
    assert(host.pads[0].map[12] == BTN_0 + 12);
    assert(host.pads[0].map[13] == BTN_0 + 13);
    // Actual OSD SPI: shrink the 16-row picker BEFORE writing an 8-row
    // message, use Main's OSD_MSG flag, and restore highres on reopening.
    host.browser = true;
    host.browse(root / "roms");
    host.draw();
    host.spi.history.clear();
    host.beginLoading("Example.nds");
    assert(host.spi.history.front().command == 0x40);
    assert(host.spi.history.back().command == 0x49);
    int loading_rows = 0;
    for (const auto &t : host.spi.history) {
      if (t.command >= 0x20 && t.command <= 0x2f) {
        assert(t.command < 0x28 && t.words.size() == 256);
        ++loading_rows;
      }
    }
    assert(loading_rows == 8);
    host.spi.history.clear();
    host.updateLoading(500, 1000);
    assert(host.spi.history.size() == 1 && host.spi.history[0].command == 0x24);
    host.updateLoading(500, 1000);
    assert(host.spi.history.size() == 1);
    host.osd(false);
    host.browser = false;
    host.cursor = 0;
    host.draw();
    bool highres = false;
    for (const auto &t : host.spi.history) if (t.command == 0x2f) highres = true;
    assert(highres);
    host.spi.history.clear();
    host.animateMenu(host.idle_since + 9999);
    assert(host.spi.history.empty());
    host.animateMenu(host.idle_since + 10000);
    assert(host.spi.history.size() == 1 && host.spi.history[0].command == 0x2f);
    host.menu = false;
    host.spi.history.clear();
    host.animateMenu(host.idle_since + 13938);
    assert(host.spi.history.empty());
    host.menu = true;
    host.action(1);
    host.draw();
    assert(host.osd_rows[15] == host.frame.renderRow(15, "            exit", false, nds_osd::arrow_right));
    host.cursor = 9;
    host.draw();
    assert(host.osd_rows[15] == host.frame.renderRow(15, "            exit", true, nds_osd::arrow_right));
    host.action(6);
    assert(host.system_menu);
    host.draw();
    host.spi.history.clear();
    host.animateMenu(host.idle_since + 30000);
    host.animateMenu(host.idle_since + 60000);
    assert(host.spi.history.empty()); // Main System footer never scrolls.
    // System/Core opens a real picker. Browsing/cancelling must preserve the
    // running game, settings and ROM directory, and must never write ROM SPI.
    host.core_root = root / "cores";
    fs::create_directories(host.core_root / "_Console");
    for (const auto *name : {"A.RBF", "B.mra", "C.mgl", "ignore.nds", "ignore.txt"})
      std::ofstream(host.core_root / "_Console" / name) << "test core";
    fs::create_symlink(root / "roms/a.nds", host.core_root / "_Console/escape.rbf");
    host.currentdir = root / "roms/nested";
    const auto prior_dir = host.currentdir;
    const auto prior_status = host.status;
    host.system_menu = true;
    host.cursor = 0;
    host.spi.history.clear();
    host.action(2);
    assert(host.browser && host.core_browser && host.system_menu && running);
    assert(host.roms.size() == 4 && host.roms[0].name == "..");
    assert(host.roms[1].name == "A.RBF" && host.roms[2].name == "B.mra" && host.roms[3].name == "C.mgl");
    assert(host.spi.history.empty() && host.status == prior_status);
    host.action(3);
    assert(!host.browser && !host.core_browser && host.system_menu && running);
    assert(host.currentdir == prior_dir);
    host.action(2);
    host.action(2); // parent to the SD root; no parent entry above it
    assert(host.currentdir == host.core_root && host.roms.size() == 1);
    assert(host.roms[0].name == "_Console");
    host.togglemenu();
    assert(!host.menu && !host.core_browser && host.currentdir == prior_dir);
    host.togglemenu();
    host.action(6);
    host.action(2);
    host.cursor = 1;
    host.action(2);
    assert(!running && host.selected_core == fs::canonical(host.core_root / "_Console/A.RBF"));
    assert(!fs::exists(root / "core-request.txt"));
    host.run(0); // clean exit drains/syncs before making the handoff request
    std::ifstream request(root / "core-request.txt");
    std::string target;
    std::getline(request, target);
    assert(target == host.selected_core);
    for (const auto &t : host.spi.history) assert(t.select != Spi::FIO);
    running = 1;
    std::cout << "PASS: "
                 "realHostcode/menu/browse/privateconfig/mappings/"
                 "analoghandoff tests\n";
  }
};
static void parent_death_test(bool before_arm) {
  assert(prctl(PR_SET_CHILD_SUBREAPER, 1) == 0);
  int info[2];
  assert(pipe(info) == 0);
  pid_t supervisor = fork();
  assert(supervisor >= 0);
  if (supervisor == 0) {
    close(info[0]);
    pid_t expected = getpid();
    pid_t child = fork();
    if (child == 0) {
      pid_t self = getpid();
      assert(write(info[1], &self, sizeof(self)) == sizeof(self));
      signal(SIGTERM, stop);
      running = 1;
      if (before_arm)
        usleep(100000);
      try {
        tie_to_parent(expected);
      } catch (...) {
        _exit(before_arm ? 0 : 3);
      }
      char ready = 'r';
      assert(write(info[1], &ready, 1) == 1);
      for (int i = 0; i < 300 && running; i++)
        usleep(10000);
      _exit(!running ? 0 : 4);
    }
    if (before_arm)
      _exit(0);
    for (;;)
      pause();
  }
  close(info[1]);
  pid_t child = 0;
  assert(read(info[0], &child, sizeof(child)) == sizeof(child));
  if (!before_arm) {
    char ready;
    assert(read(info[0], &ready, 1) == 1 && ready == 'r');
    kill(supervisor, SIGKILL);
  }
  int status = 0;
  assert(waitpid(supervisor, &status, 0) == supervisor);
  assert(waitpid(child, &status, 0) == child);
  assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
  close(info[0]);
  std::cout << "PASS: supervisor death " << (before_arm ? "before" : "after")
            << " host parent-death signal armed\n";
}
int main(int argc, char **) {
  parent_death_test(false);
  parent_death_test(true);
  char dir[] = "/tmp/nds-standalone-host-test-XXXXXX";
  assert(mkdtemp(dir));
  fs::path root = dir;
  fs::create_directories(root / "roms/nested");
  for (const auto *name : {"a.nds", "Z.NDS", "nested/child.nds"}) {
    std::ofstream f(root / "roms" / name);
    f << std::string(512, 'x');
  }
  std::ofstream(root / "roms/not-a-rom.txt") << "x";
  std::ofstream(root / "roms/short.nds") << "x";
  fs::create_symlink("/etc", root / "roms/outside");
  HostTest::legacy_engine_b_config(root);
  HostTest::run(root);
  HostTest::recents(root);
  HostTest::layout_hotkey(root);
  HostTest::framebuffer_metadata(root);
  HostTest::rom_loading(root, argc > 1);
  fs::remove_all(root);
}
