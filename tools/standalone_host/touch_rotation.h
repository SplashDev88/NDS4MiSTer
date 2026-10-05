// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <cstdint>
#include <utility>

// Rotate input in screen coordinates (positive Y downward). This is separate
// from video/OSD rotation, which also serves physically rotated TATE monitors.
enum class TouchRotation : unsigned { Normal, Counterclockwise, Clockwise };
inline constexpr const char *TOUCH_ROTATION_NAMES[] = {"Normal", "90 CCW", "90 CW"};

inline std::pair<int, int> rotateTouch(int x, int y, TouchRotation rotation) {
  if (rotation == TouchRotation::Counterclockwise) return {y, -x};
  if (rotation == TouchRotation::Clockwise) return {-y, x};
  return {x, y};
}

inline uint16_t rotateTouchAnalog(uint16_t raw, TouchRotation rotation) {
  const auto signedByte = [](unsigned value) {
    return value < 128 ? int(value) : int(value) - 256;
  };
  const auto [x, y] = rotateTouch(signedByte(raw & 255), signedByte(raw >> 8), rotation);
  // Saturate -(-128), rather than wrapping across the screen. Zero stays zero.
  return uint8_t(std::clamp(x, -128, 127)) |
         (uint16_t(uint8_t(std::clamp(y, -128, 127))) << 8);
}
