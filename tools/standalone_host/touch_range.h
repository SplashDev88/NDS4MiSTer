// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <array>
#include <cstdint>

inline constexpr std::array<unsigned, 5> TOUCH_RANGE_PERCENT{100, 125, 150, 175, 200};

// Expand the signed touch coordinates after the existing input dead zone.
// Clamping lets circular/octagonal sticks reach rectangular screen corners.
// Keep the raw coordinates in Pad so closing the menu never compounds gain.
inline uint16_t expandTouchAnalog(uint16_t raw, unsigned range_index) {
  if (!range_index || range_index >= TOUCH_RANGE_PERCENT.size()) return raw;
  const auto axis = [range_index](unsigned byte) {
    const int value = byte < 128 ? int(byte) : int(byte) - 256;
    return uint8_t(std::clamp(value * int(TOUCH_RANGE_PERCENT[range_index]) / 100,
                              -128, 127));
  };
  return axis(raw & 255) | (uint16_t(axis(raw >> 8)) << 8);
}
