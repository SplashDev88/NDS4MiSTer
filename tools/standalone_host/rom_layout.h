// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <array>
#include <cstdint>

namespace RomLayout {
inline constexpr uint64_t mib = 1024ull * 1024;
inline constexpr uint64_t lr1_file_size = 256 * mib;
inline constexpr uint64_t lr1_transfer_size = 252 * mib;
inline constexpr uint64_t max_file_size = 512 * mib;
inline constexpr uint64_t max_transfer_size = 464 * mib;
inline constexpr uint64_t bank_start = 0x22800000;
inline constexpr uint64_t bank_end = 0x30000000;
inline constexpr bool extended(uint64_t size) { return size > lr1_file_size; }
inline constexpr uint64_t transferLimit(uint64_t size) {
  return extended(size) ? max_transfer_size : lr1_transfer_size;
}
inline constexpr uint64_t transferSize(uint64_t size) {
  return std::min(size, transferLimit(size));
}
inline constexpr uint64_t storageSize(uint64_t size) {
  return extended(size) ? max_transfer_size : transferSize(size);
}
inline constexpr uint16_t index(uint64_t size) {
  return extended(size) ? 0xb03 : size > 128 * mib ? 0x103 : 3;
}
struct Span { uint64_t logical, physical, size; };
inline constexpr std::array<Span, 3> spans(uint64_t size) {
  const auto stored = storageSize(size);
  return {{{0, 0x30000000, std::min(stored, lr1_transfer_size)},
           // Preserve scaler0x200..0x220 and Linux framebuffer0x220..0x228.
           {lr1_transfer_size, bank_start,
            stored > lr1_transfer_size ? std::min(stored, 276 * mib) - lr1_transfer_size : 0},
           // Leave 0x24000000..0x24400000 for TATE (four reserved 1 MiB slots).
           {276 * mib, 0x24400000,
            stored > 276 * mib ? stored - 276 * mib : 0}}};
}
}
