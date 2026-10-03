// SPDX-License-Identifier: GPL-3.0-only
#pragma once
// Synthetic test fixtures only: never contains a personal dump.
#include "firmware_media.h"
#include <cassert>
#include <fstream>
namespace firmware_fixture {
using namespace nds_firmware;
inline Bytes readBytes(const fs::path &path) {
  std::ifstream file(path, std::ios::binary);
  return Bytes(std::istreambuf_iterator<char>(file), {});
}
inline void writeBytes(const fs::path &path, const Bytes &bytes) {
  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  file.write(reinterpret_cast<const char *>(bytes.data()), bytes.size());
  assert(file.good());
}
inline void put16(Bytes &bytes, size_t offset, unsigned value) {
  bytes.at(offset) = uint8_t(value);
  bytes.at(offset + 1) = uint8_t(value >> 8);
}
// Entirely synthetic fixture: solve a 32-bit CRC suffix. Contains no BIOS code
// or personal dump data. It exercises the exact production CRC validation.
inline Bytes syntheticBios(size_t size, uint8_t fill, uint32_t target) {
  Bytes bytes(size, fill);
  std::fill(bytes.end() - 4, bytes.end(), 0);
  const uint32_t base = crc32(bytes);
  std::array<uint32_t, 32> basis{}, coefficients{};
  for (unsigned bit = 0; bit < 32; ++bit) {
    bytes[size - 4 + bit / 8] ^= uint8_t(1u << (bit % 8));
    uint32_t value = crc32(bytes) ^ base, mask = uint32_t(1) << bit;
    bytes[size - 4 + bit / 8] ^= uint8_t(1u << (bit % 8));
    for (int row = 31; row >= 0; --row) if (value & (uint32_t(1) << row)) {
      if (!basis[row]) { basis[row] = value; coefficients[row] = mask; break; }
      value ^= basis[row]; mask ^= coefficients[row];
    }
  }
  uint32_t value = target ^ base, suffix = 0;
  for (int row = 31; row >= 0; --row) if (value & (uint32_t(1) << row)) {
    assert(basis[row]); value ^= basis[row]; suffix ^= coefficients[row];
  }
  assert(!value);
  for (unsigned byte = 0; byte < 4; ++byte) bytes[size - 4 + byte] = uint8_t(suffix >> (byte * 8));
  assert(crc32(bytes) == target);
  return bytes;
}
inline constexpr size_t user = image_size - 512;
inline void checksum(Bytes &bytes, unsigned copy) {
  const auto offset = user + 256 * copy;
  put16(bytes, offset + 0x72, crc16(bytes.data() + offset, 0x70));
}
inline Bytes syntheticFirmware() {
  Bytes bytes(image_size, 0xff);
  bytes[8] = 'M'; bytes[9] = 'A'; bytes[10] = 'C'; bytes[11] = 'h';
  bytes[0x1d] = 0x20;
  put16(bytes, 0, 0x400); put16(bytes, 2, 0x500);
  put16(bytes, 0xc, 0x80); put16(bytes, 0x10, 0x100);
  put16(bytes, 0x14, 0x2000); put16(bytes, 0x16, 0x600);
  put16(bytes, 0x20, user / 8);
  put16(bytes, 0x2c, 0x138);
  put16(bytes, 0x2a, crc16(bytes.data() + 0x2c, 0x138, 0));
  for (unsigned copy = 0; copy < 2; ++copy) {
    const auto offset = user + copy * 256;
    std::fill_n(bytes.begin() + offset, 0x70, 0);
    put16(bytes, offset, 5);
    put16(bytes, offset + 6, copy ? 'B' : 'A');
    put16(bytes, offset + 0x1a, 1);
    put16(bytes, offset + 0x5e, 4080); put16(bytes, offset + 0x60, 3056);
    bytes[offset + 0x62] = 255; bytes[offset + 0x63] = 191;
    put16(bytes, offset + 0x70, copy ? 7 : 8);
    checksum(bytes, copy);
  }
  return bytes;
}
} // namespace firmware_fixture
