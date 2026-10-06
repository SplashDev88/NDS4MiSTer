// SPDX-License-Identifier: GPL-3.0-only
// DV1 packet layout and ADV7513 update protocol follow MiSTer Main video.cpp.
// https://github.com/MiSTer-devel/Main_MiSTer (see THIRD_PARTY.md).
#pragma once
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <string>
#include <sys/ioctl.h>
#include <unistd.h>

namespace nds_video {
struct Geometry {
  uint32_t width = 0, height = 0, clocks = 0;
  uint32_t line_ticks = 0, frame_ticks = 0;
  uint16_t repeat = 0, left = 0, top = 0, flags = 0;
  bool valid() const {
    return width && width <= 1024 && height && height <= 1024 &&
           repeat && repeat <= 16 && left < 8192 && top < 256;
  }
  std::array<uint8_t, 31> packet(bool menu) const {
    std::array<uint8_t, 31> p{};
    p[0] = 0x83; p[1] = 1; p[2] = 25;
    p[4] = 'D'; p[5] = 'V'; p[6] = '1';
    p[7] = ((flags & 0x100) ? 1 : 0) | (menu ? 4 : 0) |
           ((flags & 0x200) ? 8 : 0);
    p[8] = uint8_t(repeat);
    const std::array<uint16_t, 4> fields{left, top, uint16_t(width), uint16_t(height)};
    for (size_t i = 0; i < fields.size(); ++i) {
      p[9 + 2*i] = uint8_t(fields[i]);
      p[10 + 2*i] = uint8_t(fields[i] >> 8);
    }
    p[17] = 'N'; p[18] = 'D'; p[19] = 'S';
    return p; // Main enables the transmitter's automatic SPD checksum.
  }
};

template<class SPI> Geometry readGeometry(SPI &spi) {
  Geometry g;
  spi.begin(SPI::IO, 0x23);
  try {
    g.flags = spi.word(0);
    auto u32 = [&]() {
      const uint32_t lo = spi.word(0), hi = spi.word(0);
      return lo | (hi << 16);
    };
    g.width = u32(); g.height = u32();
    g.line_ticks = u32(); g.frame_ticks = u32();
    for (int i = 0; i < 2; ++i) (void)u32(); // pixel/HDMI periods
    g.clocks = u32();
    g.repeat = spi.word(0); g.left = spi.word(0); g.top = spi.word(0);
    if (!g.repeat && g.width) g.repeat = uint16_t(g.clocks / g.width);
    spi.end();
  } catch (...) { spi.end(); throw; }
  return g;
}

// Require two matching samples so a layout change cannot publish a mixture
// of the previous raster's dimensions and the next raster's crop offsets.
class StablePacket {
  std::array<uint8_t, 31> candidate{}, written{};
  bool seen = false, sent = false;
public:
  bool ready(const Geometry &g, bool menu, std::array<uint8_t, 31> &out) {
    if (!g.valid()) { seen = false; return false; }
    auto p = g.packet(false);
    if (!seen || p != candidate) { candidate = p; seen = true; return false; }
    out = g.packet(menu);
    return !sent || written != out;
  }
  void acknowledge(const std::array<uint8_t, 31> &p) { written = p; sent = true; }
};

class Transmitter {
  int main_fd = -1, packet_fd = -1;
  static int readByte(int fd, uint8_t reg) {
    union i2c_smbus_data data{};
    struct i2c_smbus_ioctl_data args{I2C_SMBUS_READ, reg, I2C_SMBUS_BYTE_DATA, &data};
    return ioctl(fd, I2C_SMBUS, &args) < 0 ? -1 : data.byte;
  }
  static bool writeByte(int fd, uint8_t reg, uint8_t value) {
    union i2c_smbus_data data{}; data.byte = value;
    struct i2c_smbus_ioctl_data args{I2C_SMBUS_WRITE, reg, I2C_SMBUS_BYTE_DATA, &data};
    return ioctl(fd, I2C_SMBUS, &args) >= 0;
  }
  void closeDevices() {
    if (main_fd >= 0) close(main_fd);
    if (packet_fd >= 0) close(packet_fd);
    main_fd = packet_fd = -1;
  }
public:
  ~Transmitter() { closeDevices(); }
  bool openInheritedBus() {
    // The supervisor records the bus already owned by Main. Never scan
    // unrelated buses or change transmitter color/audio/mode settings.
    const char *bus = std::getenv("NDS_VIDEO_I2C_BUS");
    if (!bus || !*bus || std::strspn(bus, "0123456789") != std::strlen(bus) ||
        std::strlen(bus) > 2) return false;
    const std::string path = std::string("/dev/i2c-") + bus;
    main_fd = open(path.c_str(), O_RDWR | O_CLOEXEC);
    packet_fd = open(path.c_str(), O_RDWR | O_CLOEXEC);
    if (main_fd < 0 || packet_fd < 0 || ioctl(main_fd, I2C_SLAVE, 0x39) < 0 ||
        ioctl(packet_fd, I2C_SLAVE, 0x38) < 0 ||
        readByte(packet_fd, 4) != 'D' || readByte(packet_fd, 5) != 'V' ||
        readByte(packet_fd, 6) != '1') {
      closeDevices(); return false;
    }
    return true;
  }
  bool writePacket(const std::array<uint8_t, 31> &p) {
    if (main_fd < 0 || packet_fd < 0) return false;
    const int enable = readByte(main_fd, 0x40);
    if (enable < 0 || !writeByte(packet_fd, 0x1f, 0x80)) return false;
    bool ok = true;
    for (unsigned i = 0; i < p.size() && ok; ++i) ok = writeByte(packet_fd, uint8_t(i), p[i]);
    if (!ok) (void)writeByte(main_fd, 0x40, uint8_t(enable & ~0x40));
    // Release packet RAM even on an I2C failure. A later poll retries the
    // complete packet; failed writes are never acknowledged by StablePacket.
    const bool released = writeByte(packet_fd, 0x1f, 0);
    return ok && released && writeByte(main_fd, 0x40, uint8_t(enable | 0x40));
  }
};
}
