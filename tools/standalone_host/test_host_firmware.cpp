// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define STANDALONE_FIRMWARE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include "test_firmware_fixture.h"
#include <cassert>
#include <deque>
#include <iostream>
using namespace firmware_fixture;

struct HostTest {
  static void finishStorage(Host &host) {
    const auto deadline=ms()+5000;
    while(host.storage_job){assert(ms()<deadline);host.beat();host.pollStorage();usleep(1000);}
  }
  static void bootFromMenu(Host &host, bool browse = false) {
    host.cursor=1;host.action(2);finishStorage(host);
    if(!browse){assert(!host.browser);return;}
    assert(host.browser&&host.choosing_firmware);
    const auto it=std::find_if(host.roms.begin(),host.roms.end(),[](const auto&e){return e.name=="firmware.bin";});
    assert(it!=host.roms.end());host.cursor=int(it-host.roms.begin());host.action(2);finishStorage(host);
  }
  struct FakeFirmware {
    struct Request { unsigned slot, op; uint32_t lba; nds_firmware::Sector data; };
    Host &host;
    std::deque<Request> requests;
    uint16_t flags = 0x20, sequence = 7, error = 0, operation = 0;
    uint16_t index = 0;
    nds_firmware::Bytes asset, profile, game_pages;
    unsigned durable_acks = 0, clock_seeds = 0;
    std::array<uint16_t, 4> clock_words{};
    bool write_transferred = false, fail_upload = false, suppress_direct_ready = false;
    std::function<void()> before_ack;
    explicit FakeFirmware(Host &h) : host(h) {
      host.spi.response = [&](auto select, auto cmd, auto position, auto value) {
        return respond(select, cmd, position, value);
      };
    }
    ~FakeFirmware() { host.spi.response = {}; }
    uint16_t respond(uint32_t select, uint16_t cmd, size_t position, uint16_t value) {
      if (select == Spi::FIO) {
        if (cmd == 0x55 && position == 1) index = value;
        if (cmd == 0x53 && position == 1) {
          if (value) {
            asset.clear();
            if (index == 4) flags &= ~4;
            if (index == 5) flags &= ~8;
            if (index == 6 || index == 7) flags &= ~0x210;
          } else if (index >= 4 && index <= 7) {
            const size_t expected = index == 4 ? 16384 : index == 5 ? 4096 : index == 6 ? 120 : 512;
            if (asset.size() == expected) {
              if (index == 7) {
                game_pages = asset;
                flags |= suppress_direct_ready ? 0x10 : 0x210;
              } else {
                flags |= uint16_t(1u << (index - 2));
                if (index == 6) profile = asset;
              }
            } else assert(fail_upload);
          }
        }
        if (cmd == 0x54 && position) {
          if (fail_upload) throw std::runtime_error("injected asset transfer failure");
          asset.push_back(uint8_t(value)); asset.push_back(uint8_t(value >> 8));
        }
        return 0;
      }
      if (select != Spi::IO) return 0;
      if (cmd == 0x45) {
        if (!position) return 0x4657;
        if (position == 1) { operation = value; return flags; }
        if (position == 2) {
          if (operation == 1) { flags = (flags | 1) & ~0x80; error = 0; }
          if (operation == 2) { assert(clock_seeds == 1); assert((flags & 0x5c) == 0x5c); flags = (flags | 2) & ~1; }
          if (operation == 3) { assert((flags & 0x23c) == 0x23c); flags &= ~3; }
          if (operation == 4 && requests.empty()) flags |= 0x20;
          if (operation == 5) {
            assert(value == sequence && (flags & 0x100) && write_transferred);
            if (before_ack) before_ack();
            ++durable_acks;
            flags = (flags | 0x20) & ~0x100;
            requests.pop_front();
          }
          if (operation == 6) { flags |= 0x81; error = 6; }
          return sequence;
        }
        return error;
      }
      if (cmd == 0x22 && position) {
        assert(position <= 4);
        clock_words[position - 1] = value;
        if (position == 4) ++clock_seeds;
      }
      if (cmd == 0x1c && position == 1 && value == 2) flags |= 0x40;
      if (cmd == 0x16 && !requests.empty()) {
        const auto &r = requests.front();
        if (!position) return uint16_t(0x8080 | r.slot << 2 | r.op);
        if (position == 2) return uint16_t(r.lba);
        if (position == 3) return uint16_t(r.lba >> 16);
      }
      if (cmd == 0x118 && position) {
        auto &r = requests.front();
        const size_t offset = 2 * (position - 1);
        if (position == 256) { flags = (flags | 0x100) & ~0x20; write_transferred = true; }
        return uint16_t(r.data[offset]) | uint16_t(r.data[offset + 1]) << 8;
      }
      if (cmd == 0x117 && position) {
        const auto &r = requests.front();
        const size_t offset = 2 * (position - 1);
        assert(value == (uint16_t(r.data[offset]) | uint16_t(r.data[offset + 1]) << 8));
        if (position == 256) requests.pop_front();
      }
      return 0;
    }
  };
  static void sources(const fs::path &directory) {
    fs::create_directories(directory);
    writeBytes(directory / "bios7.bin", syntheticBios(16384, 0x5a, 0x1280f0d5));
    writeBytes(directory / "bios9.bin", syntheticBios(4096, 0xc3, 0x2ab23573));
    writeBytes(directory / "firmware.bin", syntheticFirmware());
  }
  static void run(const fs::path &root) {
    const auto sd = root / "sd", kit = root / "kit";
    fs::create_directories(sd / "games/NDS"); fs::create_directories(kit);
    unsetenv("NDS_FIRMWARE_DIAGNOSTICS");
    Host host(kit.string(), (sd / "games/NDS").string(), sd);
    assert(!host.firmware_diagnostics);
    assert(host.firmwarePath() == sd / "saves/NDS/firmware.bin");
    setenv("NDS_FIRMWARE_DIAGNOSTICS", "1", 1);
    { Host opt_in(kit.string(), (sd / "games/NDS").string(), sd); assert(opt_in.firmware_diagnostics); }
    setenv("NDS_FIRMWARE_DIAGNOSTICS", "0", 1);
    { Host opt_out(kit.string(), (sd / "games/NDS").string(), sd); assert(!opt_out.firmware_diagnostics); }
    unsetenv("NDS_FIRMWARE_DIAGNOSTICS");
    // Mere menu entry never needs optional originals or touches firmware IO.
    assert(!host.firmware);
    host.spi.history.clear();host.cursor=1;host.action(2);finishStorage(host);
    assert(host.menu&&host.browser&&host.choosing_firmware&&!host.firmware);
    assert(host.roms.size()==1&&host.roms.front().name=="..");
    for(const auto&t:host.spi.history)assert(t.select!=Spi::FIO&&t.command!=0x45);
    host.draw();assert(!host.spi.selected);
    host.action(3);assert(!host.browser&&host.cursor==1);
    // A legacy nested folder is now explicitly browseable, but never chosen
    // implicitly. Selecting a top-level firmware with missing BIOS is an error.
    sources(sd/"games/NDS/firmware");
    host.action(2);finishStorage(host);
    assert(!host.firmware&&host.roms.size()==2&&host.roms[1].name=="firmware");
    host.action(3);
    writeBytes(sd/"games/NDS/firmware.bin",syntheticFirmware());
    host.spi.history.clear();bootFromMenu(host,true);
    assert(host.storage_choices&&!host.firmware);
    assert(host.firmware_error_text.find((sd/"games/NDS/bios7.bin").string())!=std::string::npos);
    assert(!fs::exists(host.firmwarePath()));
    for(const auto&t:host.spi.history)assert(t.select!=Spi::FIO&&t.command!=0x45);
    host.action(3);
    sources(sd/"games/NDS");
    const auto original=readBytes(sd/"games/NDS/firmware.bin");
    FakeFirmware device(host);
    host.spi.history.clear();bootFromMenu(host);
    assert(host.native_firmware && !host.menu && host.firmware_slot_mounted);
    assert(!host.firmware_error_dialog && host.firmware->image() == original);
    assert(readBytes(sd / "saves/NDS/firmware.bin") == original);
    assert(fs::exists(sd / "saves/NDS/firmware.bin.lock"));
    assert(!fs::exists(sd / "saves/NDS/firmware"));
    assert(host.firmware_rtc_seeded && device.clock_seeds == 1);
    std::array<unsigned, 8> clock{};
    for (unsigned i = 0; i < 8; ++i) {
      const auto byte = uint8_t(device.clock_words[i / 2] >> (8 * (i % 2)));
      assert((byte & 15) <= 9 && (byte >> 4) <= 9);
      clock[i] = (byte >> 4) * 10 + (byte & 15);
    }
    assert(clock[1] >= 1 && clock[1] <= 12 && clock[2] >= 1 && clock[2] <= 31);
    assert(clock[3] <= 6 && clock[4] <= 23 && clock[5] <= 59 && clock[6] <= 59 && !clock[7]);
    assert(!fs::exists(sd / "saves/NDS/firmware.sav"));
    assert(device.profile.size() == 120);
    assert(device.profile[0] == 0 && device.profile[1] == 0xfe && device.profile[2] == 3);
    assert(std::equal(original.begin() + user, original.begin() + user + 0x70, device.profile.begin() + 8));
    std::vector<uint16_t> indices;
    for (const auto &t : host.spi.history) if (t.select == Spi::FIO) {
      if (t.command == 0x55) indices.push_back(t.words.at(0));
      if (t.command == 0x53 && t.words[0]) assert(t.words == std::vector<uint16_t>({1, 0, 0}));
    }
    assert(indices == std::vector<uint16_t>({4, 5, 6}));
    // Diagnostics off: explicit video metadata never adds a firmware query.
    host.spi.history.clear(); framebuffer_metadata_requested = 1;
    host.serviceFramebufferMetadataRequest();
    assert(host.spi.history.size() == 1 && host.spi.history[0].command == 0x40);
    const auto metadataPath = kit / "framebuffer-metadata.json";
    const auto metadataText = [&] {
      const auto bytes = readBytes(metadataPath);
      return std::string(bytes.begin(), bytes.end());
    };
    assert(metadataText().find("firmware_diagnostics") == std::string::npos);
    // Readback is served from the same durable work image; opt-in must not
    // change even one SD transaction or insert a status query into servicing.
    host.spi.history.clear();
    device.requests.push_back({1, 1, 0, host.firmware->readSector(0)});
    assert(host.sector() && device.requests.empty());
    const auto quietRead = host.spi.history;
    assert(host.firmware_read_requests == 0 && host.firmware_reads_completed == 0);
    host.firmware_diagnostics = true;
    host.spi.history.clear();
    device.requests.push_back({1, 1, 0, host.firmware->readSector(0)});
    assert(host.sector() && device.requests.empty());
    assert(host.spi.history.size() == quietRead.size());
    for (size_t i = 0; i < quietRead.size(); ++i) {
      assert(host.spi.history[i].select == quietRead[i].select);
      assert(host.spi.history[i].command == quietRead[i].command);
      assert(host.spi.history[i].words == quietRead[i].words);
    }
    assert(host.firmware_read_requests == 1 && host.firmware_reads_completed == 1);
    assert(host.firmware_last_lba == 0 && host.firmware_unique_lbas_logged == 1);
    host.spi.history.clear(); framebuffer_metadata_requested = 1;
    host.serviceFramebufferMetadataRequest();
    assert(host.spi.history.size() == 2 && host.spi.history[0].command == 0x40 &&
           host.spi.history[1].command == 0x45);
    assert(metadataText().find("\"controller_status_available\":true") != std::string::npos);
    assert(metadataText().find("\"reads_completed\":1") != std::string::npos);
    assert(metadataText().find("\"flags\":" + std::to_string(device.flags)) != std::string::npos);
    assert(metadataText().find("\"sequence\":7") != std::string::npos);
    // Native edit: no durable ack until the file really contains the new name.
    auto next = original; put16(next, user + 0x106, 'Z'); put16(next, user + 0x170, 9); checksum(next, 1);
    nds_firmware::Sector sector{}; std::copy_n(next.begin() + user, 512, sector.begin());
    device.requests.push_back({1, 2, 511, sector}); device.flags &= ~0x20;
    device.before_ack = [&] {
      assert(readBytes(host.firmwarePath()) == next);
      assert(host.firmware_write_requests == 1 && host.firmware_writes_durable == 0);
    };
    host.flushFirmware();
    assert(device.requests.empty() && device.durable_acks == 1);
    assert(readBytes(sd / "saves/NDS/firmware.bin.previous") == original);
    for (const auto &entry : fs::directory_iterator(sd / "saves/NDS"))
      assert(entry.path().filename().string().find(".tmp.") == std::string::npos);
    assert(host.firmware_writes_durable == 1 && host.firmware_last_lba == 511 &&
           host.firmware_last_operation == 2 && host.firmware_unique_lbas_logged == 2);
    assert(host.firmware->profile().bytes[6] == 'Z');
    device.before_ack = {};
    // Direct restoration uses FreeBIOS and only projected personal fields in FIO7.
    const auto gamePath = sd / "games/NDS/game.nds";
    writeBytes(gamePath, nds_firmware::Bytes(512, 0x5a));
    const nds_firmware::Bytes cartSave(512, 0x3c);
    writeBytes(sd / "saves/NDS/game.sav", cartSave);
    host.load(gamePath.string());
    assert(!host.native_firmware && host.game == gamePath && !host.menu);
    assert(readBytes(sd / "saves/NDS/game.sav") == cartSave);
    assert(device.game_pages.size() == 512 && device.game_pages[6] == 'Z');
    assert(device.game_pages[0x58] == nds_firmware::builtin_user_pages[0x58]);
    const auto &history = host.spi.history;
    size_t last7 = 0, last9 = 0;
    for (size_t i = 0; i < history.size(); ++i) if (history[i].select == Spi::FIO && history[i].command == 0x55) {
      if (history[i].words[0] == 4) last7 = i;
      if (history[i].words[0] == 5) last9 = i;
    }
    assert(history[last7 + 2].words[0] == (uint16_t(nds_firmware::freebios7[0]) | uint16_t(nds_firmware::freebios7[1]) << 8));
    assert(history[last9 + 2].words[0] == (uint16_t(nds_firmware::freebios9[0]) | uint16_t(nds_firmware::freebios9[1]) << 8));
    host.reset(); assert(!device.flags || !(device.flags & 3));
    assert(device.clock_seeds == 1);
    assert(host.firmware->profile().bytes[6] == 'Z');
    // OSD settings reset must never change native user data.
    host.menu = true; host.system_menu = true; host.cursor = 2; host.action(2);
    host.cursor = 0; host.action(2);
    assert(host.firmware->profile().bytes[6] == 'Z');
    // Failed BIOS transfer retains console hold and visible menu error.
    device.fail_upload = true; bootFromMenu(host);
    assert(host.firmware_error_dialog && host.menu && (device.flags & 1));
    assert(host.spi.history.back().select == Spi::IO); // neutral input after error
    bool stopped_failed_download = false;
    for (auto it = host.spi.history.rbegin(); it != host.spi.history.rend(); ++it)
      if (it->select == Spi::FIO) {
        stopped_failed_download = it->command == 0x53 && it->words == std::vector<uint16_t>({0});
        break;
      }
    assert(stopped_failed_download && !(device.flags & 4));
    device.fail_upload = false; host.action(3);
    bootFromMenu(host); assert(!host.menu && host.native_firmware);
    assert(device.clock_seeds == 1);
    // Exit still flushes after cancellation has set running=0.
    running = 0;
    host.run(0);
    assert(running == 0 && !(device.flags & 0x100));
    running = 1;
    // Disk failure must not send an operation5 ack or acknowledge cache clean.
    sector[4] ^= 1;
    device.requests.push_back({1, 2, 511, sector}); device.flags &= ~0x20;
    host.firmware->setFaultHook([](const char *) { throw std::runtime_error("injected disk full"); });
    assert(!host.sector());
    assert(host.firmware_failed && host.firmware_error_dialog && host.menu);
    assert(device.durable_acks == 1 && (device.flags & 0x100) && (device.flags & 1));
    assert(host.firmware_write_requests == 2 && host.firmware_writes_durable == 1);
    host.spi.history.clear(); framebuffer_metadata_requested = 1;
    host.serviceFramebufferMetadataRequest();
    assert(host.spi.history.size() == 2 && host.spi.history[1].command == 0x45);
    assert(metadataText().find("\"error\":6") != std::string::npos);
    assert(metadataText().find("\"writes_durable\":1") != std::string::npos);
    assert(device.durable_acks == 1 && (device.flags & 0x100));
    bool refused_direct = false;
    try { host.load(gamePath.string()); } catch (const std::exception &) { refused_direct = true; }
    assert(refused_direct && host.native_firmware && (device.flags & 1));
    // Trace stops after 32 unique LBAs, and repeated LBAs never consume its
    // allowance. Counters continue with no SPI activity or unbounded output.
    host.spi.history.clear();
    for (unsigned lba = 0; lba < 80; ++lba) host.recordFirmwareRequest(1, lba);
    const auto logged = host.firmware_unique_lbas_logged;
    for (unsigned i = 0; i < 100; ++i) host.recordFirmwareRequest(1, 0);
    assert(logged == 32 && host.firmware_unique_lbas_logged == 32 && host.spi.history.empty());
    assert(readBytes(host.firmwarePath()) == next);
    assert(readBytes(sd / "games/NDS/firmware.bin") == original);
    assert(readBytes(sd / "games/NDS/firmware/firmware.bin") == original);
    std::cout << "PASS native menu action, missing assets, no-cart asset protocol, durable sequence ack,\n"
                 "     shared profile/FreeBIOS restore, one-time RTC seed, reset, interrupted upload and visible disk failure,\n"
                 "     opt-in bounded diagnostics and owner-only status snapshots without SD protocol changes\n";
  }
  static void directIsolation(const fs::path &root) {
    const auto sd = root / "direct-sd", kit = root / "direct-kit", games = sd / "games/NDS";
    fs::create_directories(kit); fs::create_directories(games);
    const auto rom = games / "direct.nds";
    writeBytes(rom, nds_firmware::Bytes(512, 0x5a));
    // The retired nested save is neither a fallback nor an import source.
    const auto legacy = sd / "saves/NDS/firmware/firmware-working.bin";
    auto legacySaved = syntheticFirmware();
    put16(legacySaved, user + 6, 'L'); checksum(legacySaved, 0);
    fs::create_directories(legacy.parent_path()); writeBytes(legacy, legacySaved);
    Host host(kit.string(), games.string(), sd); FakeFirmware device(host);
    const auto verify = [&] {
      assert(!host.firmware && !host.native_firmware && !host.firmware_slot_mounted);
      assert(!host.firmware_error_dialog && !host.menu && !device.clock_seeds);
      for (const auto &t : host.spi.history) {
        assert(!(t.select == Spi::IO && t.command == 0x1c && t.words == std::vector<uint16_t>{2}));
        assert(!(t.select == Spi::FIO && t.command == 0x55 && t.words == std::vector<uint16_t>{6}));
      }
      assert(device.game_pages.size() == 512 && (device.flags & 0x200));
    };
    host.load(rom.string()); verify();
    assert(std::equal(device.game_pages.begin(), device.game_pages.end(), nds_firmware::builtin_user_pages.begin()));
    assert(!fs::exists(host.firmwarePath()) && readBytes(legacy) == legacySaved);
    // Supplied files existing (even invalid) are irrelevant to a normal game.
    writeBytes(games / "bios7.bin", nds_firmware::Bytes(1, 0));
    writeBytes(games / "bios9.bin", nds_firmware::Bytes(1, 0));
    writeBytes(games / "firmware.bin", nds_firmware::Bytes(1, 0));
    auto saved = syntheticFirmware();
    saved[user + 2] = 13; saved[user + 3] = 12; saved[user + 4] = 25;
    put16(saved, user + 6, 'Q'); saved[user + 0x64] = 0xfc; // only language4 survives
    put16(saved, user + 0x58, 0xffff); saved[user + 0x5d] = 255; // unusable GUI calibration
    checksum(saved, 0);
    fs::create_directories(host.firmwarePath().parent_path()); writeBytes(host.firmwarePath(), saved);
    host.spi.history.clear(); host.load(rom.string()); verify();
    assert(device.game_pages[6] == 'Q' && device.game_pages[2] == 13 &&
           device.game_pages[3] == 12 && device.game_pages[4] == 25);
    assert(device.game_pages[0x64] == ((nds_firmware::builtin_user_pages[0x64] & 0xf8) | 4));
    assert(std::equal(device.game_pages.begin() + 0x58, device.game_pages.begin() + 0x64,
                      nds_firmware::builtin_user_pages.begin() + 0x58));
    host.reset(); verify();
    assert(readBytes(host.firmwarePath()) == saved);
    // Invalid optional image falls back without importing originals or blocking.
    saved[user + 0x72] ^= 1; saved[user + 0x172] ^= 1;
    writeBytes(host.firmwarePath(), saved); host.load(rom.string()); verify();
    assert(std::equal(device.game_pages.begin(), device.game_pages.end(), nds_firmware::builtin_user_pages.begin()));
    assert(!host.personal_settings_notice.empty() && readBytes(host.firmwarePath()) == saved);
    host.togglemenu(); host.draw();
    assert(host.menu && !host.personal_settings_notice.empty());
    host.togglemenu();
    // A core which ignores new direct-profile readiness cannot release the ROM.
    device.suppress_direct_ready = true; host.spi.history.clear();
    bool refused = false;
    try { host.load(rom.string()); } catch (const std::exception &e) {
      refused = std::string(e.what()).find("built-in BIOS and personal settings") != std::string::npos;
    }
    assert(refused && (device.flags & 1));
    assert(readBytes(legacy) == legacySaved);
    for (const auto &t : host.spi.history)
      assert(!(t.select == Spi::IO && t.command == 0x45 && !t.words.empty() && t.words[0] == 3));
    std::cout << "PASS direct games use built-in BIOS/FIO7 without original files, native Media, calibration or RTC; old-core readiness rejected\n";
  }
  static void relocatedSources(const fs::path &root) {
    const auto sd = root / "relocated-sd", kit = root / "relocated-kit";
    const auto games = root / "configured-game-root";
    fs::create_directories(kit);
    sources(games);
    const auto original = readBytes(games / "firmware.bin");
    auto saved = original;
    put16(saved, user + 6, 'S'); checksum(saved, 0);
    const auto working = sd / "saves/NDS/firmware.bin";
    fs::create_directories(working.parent_path());
    writeBytes(working, saved);
    const auto legacy = sd / "saves/NDS/firmware/firmware-working.bin";
    fs::create_directories(legacy.parent_path()); writeBytes(legacy, original);
    // Existing settings remain authoritative after moving the read-only inputs;
    // the configured game root does not relocate or reseed the working copy.
    Host host(kit.string(), games.string(), sd);
    host.spi.history.clear();
    host.ensureFirmware();
    assert(host.firmware && host.firmware->image() == saved);
    assert(host.firmware->profile().bytes[6] == 'S');
    assert(host.firmwarePath() == working && readBytes(working) == saved);
    assert(readBytes(legacy) == original);
    assert(fs::exists(sd / "saves/NDS/firmware.bin.lock"));
    assert(readBytes(games / "firmware.bin") == original);
    assert(!fs::exists(sd / "games/NDS") && host.spi.history.empty());
    std::cout << "PASS canonical game-root assets, legacy subdirectory rejected, configured root honored, existing root-level saved profile retained; no nested-save fallback\n";
  }
  static void rememberedBoot(const fs::path &root) {
    const auto sd = root / "remembered-sd", kit = root / "remembered-kit";
    const auto usb = root / "usb0", moved = root / "usb1";
    const auto games = sd / "games/NDS";
    fs::create_directories(kit); fs::create_directories(games);
    sources(usb / "BIOS");
    const auto original = readBytes(usb / "BIOS/firmware.bin");
    nds_storage::test_volumes = {{sd,"sd","SD card"},{usb,"uuid:firmware-disk","USB 0"}};
    {
      Host host(kit.string(),games.string(),sd); FakeFirmware device(host);
      // First use browses. Selecting the source remembers it independently.
      host.cursor=1;host.action(2);finishStorage(host);
      assert(host.browser&&host.choosing_firmware&&!host.native_firmware);
      host.browseGames(usb/"BIOS");finishStorage(host);
      const auto it=std::find_if(host.roms.begin(),host.roms.end(),[](const auto&e){return e.name=="firmware.bin";});
      assert(it!=host.roms.end());host.cursor=int(it-host.roms.begin());
      host.action(2);finishStorage(host);
      assert(host.native_firmware&&!host.menu);
    }
    fs::rename(usb,moved);
    nds_storage::test_volumes.back().path=moved;
    {
      Host host(kit.string(),games.string(),sd); FakeFirmware device(host);
      // A fresh host follows the saved drive identity and boots in one action.
      bootFromMenu(host);
      assert(host.native_firmware&&!host.menu&&!host.browser);
      assert(host.firmware->image()==original);
      assert(readBytes(host.firmwarePath())==original);
      host.menu=true;
      fs::rename(moved/"BIOS/bios9.bin",moved/"BIOS/bios9.missing");
      host.spi.history.clear();host.cursor=1;host.action(2);finishStorage(host);
      assert(host.browser&&host.choosing_firmware&&!host.storage_devices);
      assert(host.currentdir==moved/"BIOS");
      for(const auto&t:host.spi.history)assert(t.select!=Spi::FIO&&t.command!=0x45);
      assert(readBytes(host.firmwarePath())==original);
      host.action(3);
      const auto preference=host.storage_preferences.encode();
      // Another disk at the old mount point must never be mistaken for it.
      fs::create_directories(usb);sources(usb/"BIOS");
      nds_storage::test_volumes.back()={usb,"uuid:other-disk","USB 0"};
      host.spi.history.clear();host.action(2);finishStorage(host);
      assert(host.browser&&host.storage_devices&&host.choosing_firmware);
      assert(host.storage_preferences.encode()==preference);
      for(const auto&t:host.spi.history)assert(t.select!=Spi::FIO&&t.command!=0x45);
      assert(readBytes(host.firmwarePath())==original);
      assert(readBytes(moved/"BIOS/firmware.bin")==original);
    }
    nds_storage::test_volumes.clear();
    std::cout << "PASS first-use browser, remembered one-action firmware boot after restart/USB renumbering, missing-file and missing-drive browser fallback without CPU hold or saved-data changes\n";
  }
};
int main() {
  char name[] = "/tmp/nds-host-firmware-XXXXXX";
  const auto root = mkdtemp(name); assert(root);
  try { HostTest::run(root); HostTest::relocatedSources(root); HostTest::directIsolation(root); HostTest::rememberedBoot(root); fs::remove_all(root); }
  catch (...) { fs::remove_all(root); throw; }
}
