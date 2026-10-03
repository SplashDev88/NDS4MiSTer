// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "rom_reader.h"
#include <cassert>

// Sparse stored data and real FF omitted padding. Distinct endpoint bytes
// catch truncation and accidental inclusion of synthetic data.
inline void largeRomFixture(const char *path, uint64_t size) {
  const int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
  assert(fd >= 0 && ftruncate(fd, size) == 0);
  std::array<unsigned char, 65536> padding;
  padding.fill(0xff);
  for (uint64_t off = RomLayout::transferLimit(size); off < size;) {
    const auto n = std::min<uint64_t>(padding.size(), size - off);
    assert(pwrite(fd, padding.data(), n, off) == ssize_t(n));
    off += n;
  }
  const unsigned char first = 0x12, last = 0x37;
  assert(pwrite(fd, &first, 1, 0) == 1);
  assert(pwrite(fd, &last, 1, RomReader::transferSize(size) - 1) == 1);
  assert(close(fd) == 0);
}

inline void romFixtureByte(const char *path, uint64_t offset, unsigned char value) {
  const int fd = open(path, O_RDWR);
  assert(fd >= 0 && pwrite(fd, &value, 1, offset) == 1);
  assert(close(fd) == 0);
}
