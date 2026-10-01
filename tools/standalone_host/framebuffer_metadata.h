// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <array>
#include <cstdint>
#include <sstream>
#include <string>

// UIO_GET_FB_PAR: Main's video.cpp consumes words 0..4; sys_top.v also
// exposes the selected framebuffer's base and stride in words 5..7.
// These are live fields, not a latched frame descriptor. The change hint
// excludes base and stride and must not be used to prove bank stability.
struct FramebufferMetadata {
  uint16_t command_reply = 0;
  std::array<uint16_t, 8> words{};

  template <class Bus> static FramebufferMetadata read(Bus &spi) {
    FramebufferMetadata result;
    try {
      result.command_reply = spi.begin(Bus::IO, 0x40);
      for (auto &word : result.words) word = spi.word(0);
      spi.end();
    } catch (...) {
      spi.end();
      throw;
    }
    return result;
  }

  std::string json(uint64_t sequence, unsigned pid, uint64_t begin_us,
                   uint64_t end_us,
                   const std::array<uint16_t, 8> &status) const {
    std::ostringstream out;
    out << "{\n  \"schema_version\": 1,\n  \"request_sequence\": " << sequence
        << ",\n  \"host_pid\": " << pid
        << ",\n  \"started_monotonic_us\": " << begin_us
        << ",\n  \"completed_monotonic_us\": " << end_us
        << ",\n  \"command\": 64,\n  \"command_reply\": " << command_reply
        << ",\n  \"change_hint_crc8\": " << (command_reply & 255)
        << ",\n  \"atomic_hardware_snapshot\": false,\n  \"raw_words\": [";
    for (unsigned i = 0; i < words.size(); ++i)
      out << (i ? ", " : "") << words[i];
    out << "],\n  \"aspect_x\": " << (words[0] & 0xfff)
        << ",\n  \"aspect_y\": " << (words[1] & 0xfff)
        << ",\n  \"aspect_xy_flag\": " << ((words[0] & 0x1000) ? "true" : "false")
        << ",\n  \"flags_format\": " << words[2]
        << ",\n  \"local_framebuffer_enabled\": " << ((words[2] & 0x80) ? "true" : "false")
        << ",\n  \"framebuffer_enabled\": " << ((words[2] & 0x40) ? "true" : "false")
        << ",\n  \"format\": " << (words[2] & 0x3f)
        << ",\n  \"width\": " << words[3]
        << ",\n  \"height\": " << words[4]
        << ",\n  \"base_address\": " << (uint32_t(words[5]) | (uint32_t(words[6]) << 16))
        << ",\n  \"stride_bytes\": " << words[7]
        << ",\n  \"host_status_words\": [";
    for (unsigned i = 0; i < status.size(); ++i)
      out << (i ? ", " : "") << status[i];
    out << "]\n}\n";
    return out.str();
  }
};
