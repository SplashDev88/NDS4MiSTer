// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#include "rom_mapping.h"
#include "rom_reader.h"
#include "test_rom_fixture.h"
#include <cassert>
#include <filesystem>
#include <iostream>
#include <sstream>

static void reservation_tests() {
  const auto check = [](const char *text, bool expected) {
    std::istringstream input(text);
    bool passed = true;
    try { validateRomBank(input); }
    catch (const std::runtime_error &) { passed = false; }
    assert(passed == expected);
  };
  // Actual device System RAM and representative nested/device entries.
  check("00000000-1fefffff : System RAM\n  00008000-00dfffff : Kernel code\n"
        "ff706000-ff706fff : ff706000.fpgamgr fpgamgr@ff706000\n", true);
  check("00000000-27ffffff : System RAM\n2c000000-2fffffff : System RAM\n", true);
  check("00000000-28000000 : System RAM\n", false);
  check("2bffffff-2fffffff : System RAM\n", false);
  check("00000000-1fefffff : System RAM\n28001000-28001fff : System RAM\n", false);
  check("00000000-00000000 : System RAM\n", false);
  check("00000000-1fefffff : System RAM\n00000000-00000000 : System RAM\n", false);
  check("bad-range : System RAM\n", false);
  check("", false);
  check("ff706000-ff706fff : MMIO\n", false);
  std::istringstream unreadable;
  unreadable.setstate(std::ios::badbit);
  bool failed = false;
  try { validateRomBank(unreadable); }
  catch (const std::runtime_error &) { failed = true; }
  assert(failed);
  std::cout << "PASS reservation: actual map, inclusive overlap, extra RAM, redacted, empty and unreadable\n";
}

// Separate arithmetic from the production span table when reconstructing the
// transferred ROM. The upper bank rotates every 64 MiB and ends before2c000000.
static uint64_t physical(uint64_t logical) {
  return logical < 252ull * 1024 * 1024 ? 0x30000000 + logical
                                      : 0x28000000 + logical % (64ull * 1024 * 1024);
}
static void transfer_compare(const std::filesystem::path &rom,
                             const std::filesystem::path &backing, bool retain = false) {
  const auto size = std::filesystem::file_size(rom);
  const auto transferred = RomReader::transferSize(size);
  const auto stored = RomLayout::storageSize(size);
  const int memory = open(backing.c_str(), O_RDWR | O_CREAT, 0600);
  assert(memory >= 0 && ftruncate(memory, 0x40001000) == 0);
  std::array<unsigned char, 262144> expected, actual;
  expected.fill(0xa5);
  // Protect both sides of each bank and all four MiB of graphics/control.
  const std::array<std::pair<uint64_t, uint64_t>, 5> guards{{
    {0x27fff000, 4096}, {0x2c000000, 4096}, {0x2ffff000, 4096},
    {0x3fc00000, 4 * RomLayout::mib}, {0x40000000, 4096}}};
  for (const auto &guard : guards)
    for (uint64_t offset = 0; offset < guard.second;) {
      const auto n = std::min<uint64_t>(expected.size(), guard.second-offset);
      assert(pwrite(memory, expected.data(), n, guard.first+offset) == ssize_t(n));
      offset += n;
    }
  RomMapping::test_memory_fd = memory;
  RomMapping::test_mapped_spans.clear();
  uint64_t calls = 0;
  {
    RomReader reader(rom.string());
    const auto service = [&] { ++calls; };
    assert(reader.size(service) == size);
    RomMapping mapping(size);
    uint64_t offset = 0;
    while (offset < transferred) {
      const auto chunk = mapping.at(offset);
      offset += reader.read(chunk.data, std::min<size_t>(actual.size(),
                            std::min<uint64_t>(chunk.size, transferred-offset)), service);
    }
    const auto fill_start = calls;
    while (offset < stored) {
      service();
      const auto chunk = mapping.at(offset);
      const auto n = std::min<size_t>(actual.size(), chunk.size);
      memset(chunk.data, 0xff, n);
      offset += n;
    }
    assert(calls-fill_start == (stored-transferred+actual.size()-1)/actual.size());
    assert(offset == stored);
  }
  assert(RomMapping::test_live_mappings == 0);
  const size_t expected_maps = size > 256 * RomLayout::mib ? 3 : 1;
  assert(RomMapping::test_mapped_spans.size() == expected_maps);
  assert(RomMapping::test_mapped_spans[0].physical == 0x30000000);
  if (expected_maps == 3) {
    assert(RomMapping::test_mapped_spans[1].physical == 0x2bc00000);
    assert(RomMapping::test_mapped_spans[2].physical == 0x28000000);
  }
  const int source = open(rom.c_str(), O_RDONLY);
  assert(source >= 0);
  for (uint64_t logical = 0; logical < stored;) {
    const auto next_boundary = logical < 252 * RomLayout::mib ? 252 * RomLayout::mib :
                               logical < 256 * RomLayout::mib ? 256 * RomLayout::mib : stored;
    const auto n = std::min<uint64_t>(expected.size(), std::min(stored, next_boundary)-logical);
    expected.fill(0xff);
    if (logical < transferred) {
      const auto from_file = std::min<uint64_t>(n, transferred-logical);
      assert(pread(source, expected.data(), from_file, logical) == ssize_t(from_file));
    }
    assert(pread(memory, actual.data(), n, physical(logical)) == ssize_t(n));
    assert(memcmp(expected.data(), actual.data(), n) == 0);
    logical += n;
  }
  close(source);
  expected.fill(0xa5);
  for (const auto &guard : guards)
    for (uint64_t offset = 0; offset < guard.second;) {
      const auto n = std::min<uint64_t>(actual.size(), guard.second-offset);
      assert(pread(memory, actual.data(), n, guard.first+offset) == ssize_t(n));
      assert(memcmp(actual.data(), expected.data(), n) == 0);
      offset += n;
    }
  close(memory);
  RomMapping::test_memory_fd = -1;
  if (!retain) std::filesystem::remove(backing);
  std::cout << "PASS full physical reconstruction and bank/graphics guards: " << rom.filename()
            << " file_bytes=" << size << " stored_bytes=" << stored << " service_calls=" << calls << '\n';
}

int main(int argc, char **argv) {
  reservation_tests();
  char temp[] = "/tmp/nds-rom-mapping-XXXXXX";
  assert(mkdtemp(temp));
  const std::filesystem::path root(temp), rom = root / "synthetic.nds", backing = root / "memory";
  RomMapping::test_iomem_path = (root / "iomem").string();
  std::ofstream(RomMapping::test_iomem_path) << "00000000-1fefffff : System RAM\n";
  if (argc > 1) {
    for (int i = 1; i < argc; ++i) transfer_compare(argv[i], backing);
  } else {
    for (const auto size : {256 * RomLayout::mib, 512 * RomLayout::mib}) {
      largeRomFixture(rom.c_str(), size);
      if (size > 256 * RomLayout::mib) {
        unsigned char value = 1;
        for (const auto offset : {252 * RomLayout::mib-1, 252 * RomLayout::mib,
                                  256 * RomLayout::mib-1, 256 * RomLayout::mib,
                                  316 * RomLayout::mib-1})
          romFixtureByte(rom.c_str(), offset, value++);
      }
      transfer_compare(rom, backing, size == 512 * RomLayout::mib);
    }
    // Reuse the full512MiB image's physical backing. Its old non-FF body must
    // not survive past the new trimmed file's EOF anywhere through316MiB.
    largeRomFixture(rom.c_str(), 256 * RomLayout::mib + 1);
    transfer_compare(rom, backing);
    // The larger-bank guard is never consulted for LR1 or small mappings.
    RomMapping::test_iomem_path = "/does/not/exist";
    for (const auto size : {uint64_t{512}, 128 * RomLayout::mib, 256 * RomLayout::mib}) {
      RomMapping mapping(size);
    }
    assert(RomMapping::test_live_mappings == 0);
  }
  std::filesystem::remove_all(root);
}
