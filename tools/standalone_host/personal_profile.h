// SPDX-License-Identifier: GPL-3.0-only
#pragma once
// The optional GUI image is a settings source, never game boot/SPI media.
#include "builtin_firmware_profile.h"
#include "firmware_media.h"
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace nds_firmware {
struct GamePersonalProfile {
  std::array<uint8_t, 512> pages = builtin_user_pages;
  bool shared = false;
  // Fixed messages only; never includes private field values.
  std::string warning;
};
inline GamePersonalProfile defaultPersonalProfile(const char *warning) {
  GamePersonalProfile result;
  result.warning = warning;
  return result;
}
inline GamePersonalProfile projectPersonalPages(const std::array<uint8_t, 512> &pages) {
  std::array<bool, 2> valid{};
  std::array<uint16_t, 2> count{};
  for (unsigned copy = 0; copy < 2; ++copy) {
    const auto *p = pages.data() + copy * 256;
    count[copy] = le16(p + 0x70);
    valid[copy] = le16(p) == 5 && le16(p + 0x1a) <= 10 && count[copy] <= 127 &&
                  crc16(p, 0x70) == le16(p + 0x72);
  }
  if (!valid[0] && !valid[1])
    return defaultPersonalProfile("Saved GUI settings have no valid user copy; using built-in personal settings.");
  const unsigned selected = valid[1] && (!valid[0] || ((count[0] + 1) & 127) == count[1]);
  const auto *p = pages.data() + selected * 256;
  const auto length = le16(p + 0x1a);
  // Zero birthday fields mean unset. Language7 is reserved; DS languages0..6
  // include Chinese. Unrelated settings bits and calibration are not examined.
  if (p[2] > 15 || p[3] > 12 || p[4] > 31 || (p[0x64] & 7) > 6)
    return defaultPersonalProfile("Saved GUI personal fields are invalid; using built-in personal settings.");
  GamePersonalProfile result;
  for (unsigned copy = 0; copy < 2; ++copy) {
    auto *out = result.pages.data() + copy * 256;
    std::copy_n(p + 2, 3, out + 2); // color, birthday month/day
    std::fill_n(out + 6, 20, 0);
    std::copy_n(p + 6, 2 * length, out + 6);
    out[0x1a] = uint8_t(length); out[0x1b] = 0;
    out[0x64] = uint8_t((out[0x64] & 0xf8) | (p[0x64] & 7));
    const auto crc = crc16(out, 0x70);
    out[0x72] = uint8_t(crc); out[0x73] = uint8_t(crc >> 8);
  }
  result.shared = true;
  return result;
}
inline bool personalUserOffset(uint16_t pointer, uint32_t &offset) {
  offset = uint32_t(pointer) * 8;
  return offset >= 0x200 && !(offset & 255) && offset <= image_size - 512;
}
inline GamePersonalProfile projectPersonalImage(const Bytes &image) {
  uint32_t offset = 0;
  if (image.size() != image_size || !personalUserOffset(le16(image.data() + 0x20), offset))
    return defaultPersonalProfile("Saved GUI settings pointer is invalid; using built-in personal settings.");
  std::array<uint8_t, 512> pages{};
  std::copy_n(image.data() + offset, pages.size(), pages.begin());
  return projectPersonalPages(pages);
}
inline GamePersonalProfile readGamePersonalProfile(const fs::path &working) {
  // O_NONBLOCK prevents an unexpected FIFO from blocking; descriptor-only reads
  // avoid path replacement races. Media uses atomic replacement, so an opened
  // regular-file inode is a consistent old/new snapshot, without another owner.
  const int fd = ::open(working.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (fd < 0) return defaultPersonalProfile(errno == ENOENT
      ? "No saved GUI settings; using built-in personal settings."
      : "Cannot read optional GUI settings; using built-in personal settings.");
  struct Close { int fd; ~Close() { ::close(fd); } } close{fd};
  struct stat st{};
  if (::fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size != image_size)
    return defaultPersonalProfile("Optional GUI settings file is invalid; using built-in personal settings.");
  const auto read = [&](void *target, size_t size, off_t offset) {
    auto *p = static_cast<uint8_t *>(target);
    while (size) {
      const auto n = ::pread(fd, p, size, offset);
      if (n < 0 && errno == EINTR) continue;
      if (n <= 0) return false;
      p += n; size -= size_t(n); offset += n;
    }
    return true;
  };
  std::array<uint8_t, 2> pointer{};
  std::array<uint8_t, 512> pages{};
  uint32_t offset = 0;
  if (!read(pointer.data(), pointer.size(), 0x20) ||
      !personalUserOffset(le16(pointer.data()), offset) || !read(pages.data(), pages.size(), offset))
    return defaultPersonalProfile("Cannot read optional GUI user copies; using built-in personal settings.");
  return projectPersonalPages(pages);
}
} // namespace nds_firmware
