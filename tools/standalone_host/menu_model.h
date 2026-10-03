// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include "core_menu.h"
#include <algorithm>
#include <array>
#include <cctype>
#include <cstdint>
#include <sstream>
#include <string>
#include <vector>
inline unsigned optionValue(uint16_t status, const CoreOption &o) {
  auto value = (status >> o.shift) & ((1u << o.width) - 1);
  return value < o.count ? value : 0;
}
inline uint16_t changeOption(uint16_t status, const CoreOption &o,
                             int direction) {
  unsigned value = (optionValue(status, o) + o.count + direction) % o.count;
  return (status & ~(((1u << o.width) - 1) << o.shift)) | (value << o.shift);
}
// Bit10 is retained on the wire for older cores/configs; both engines are mandatory.
inline constexpr uint16_t REQUIRED_STATUS = 1u << 10;
inline uint16_t cleanStatus(uint16_t value) {
  value &= CORE_OPTION_MASK;
  for (const auto &o : CORE_OPTIONS)
    if (((value >> o.shift) & ((1u << o.width) - 1)) >= o.count)
      value &= ~(((1u << o.width) - 1) << o.shift);
  return value | REQUIRED_STATUS;
}
inline std::string optionLabel(uint16_t status, const CoreOption &o) {
  std::string label = " " + std::string(o.label);
  std::string value = o.values[optionValue(status, o)];
  // Main's generic option row: a colon after the label, value ending at
  // column 28, shortening the label only when needed to fit the value.
  label.resize(std::min(label.size(), 27 - value.size()));
  label += ':';
  return label + std::string(28 - value.size() - label.size(), ' ') + value;
}
inline bool mappedButton(uint32_t mapping, unsigned code) {
  return code != 0 && (code == (mapping & 65535u) || code == (mapping >> 16));
}
inline std::string trim(std::string s) {
  auto begin = s.find_first_not_of(" \t\r\n");
  if (begin == std::string::npos)
    return "";
  return s.substr(begin, s.find_last_not_of(" \t\r\n") - begin + 1);
}
inline int osdRotation(const std::string &contents) {
  std::istringstream input(contents);
  std::string line;
  bool global = true, nds = false;
  int result = 0;
  while (std::getline(input, line)) {
    line = trim(line.substr(0, line.find(';')));
    if (line.empty() || line[0] == '#')
      continue;
    if (line.front() == '[' && line.back() == ']') {
      auto section = line.substr(1, line.size() - 2);
      std::transform(section.begin(), section.end(), section.begin(),
                     ::tolower);
      global = section == "mister";
      nds = section == "nds";
    } else if (global || nds) {
      auto equal = line.find('=');
      if (equal != std::string::npos &&
          trim(line.substr(0, equal)) == "osd_rotate") {
        auto value = trim(line.substr(equal + 1));
        if (value == "1" || value == "2")
          result = value[0] - '0';
        else
          result = 0;
      }
    }
  }
  return result;
}
