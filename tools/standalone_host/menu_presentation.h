// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from MiSTer Main menu.cpp PrintDirectory/ProgressMessage and osd.cpp
// ScrollText. Copyright 2005-2007 Dennis van Weeren, 2008-2009 Jakub Bednarski,
// and MiSTer/NDS4MiSTer contributors. See THIRD_PARTY.md and COPYING.
#pragma once
#include "menu_model.h"
#include "osd_frame.h"
#include <optional>

struct BrowserEntry { std::string name; bool directory; };
struct BrowserView {
  std::array<std::string, 16> rows{};
  std::array<bool, 16> selected{};
  std::array<unsigned char, 16> markers{};
  int first = 0, selected_row = -1;
};
inline std::string browserName(const BrowserEntry &entry, bool cores) {
  auto name = entry.name;
  if (!entry.directory) {
    auto dot = name.find_last_of('.');
    if (dot != std::string::npos) name.resize(dot);
  } else if (cores && !name.empty() && name.front() == '_') name.erase(0, 1);
  return name;
}
inline BrowserView browserView(const std::vector<BrowserEntry> &entries,
                               int cursor, int first, bool expand, bool cores) {
  BrowserView view;
  if (entries.empty()) { view.rows[0] = "          No files!"; return view; }
  cursor = std::clamp(cursor, 0, int(entries.size()) - 1);
  first = std::clamp(first, std::max(0, cursor - 15), cursor);
  if (expand && cursor == first + 15 && cursor + 1 < int(entries.size()) &&
      !entries[cursor].directory && browserName(entries[cursor], cores).size() > 28) ++first;
  view.first = first;
  for (int row = 0, k = first; row < 16; ++row, ++k) {
    std::string text(32, ' ');
    if (k < int(entries.size())) {
      const auto &entry = entries[k];
      const auto name = browserName(entry, cores);
      const auto len = name.size() > 28 ? 27 : name.size();
      text.replace(1, len, name, 0, len);
      if (name.size() > 28) text[28] = 22;
      if (entry.directory) {
        const auto at = name == ".." ? 19 : 22;
        text.resize(at);
        text += name == ".." ? " <UP-DIR>" : " <DIR>";
      }
      view.selected[row] = k == cursor;
      if (k == cursor) view.selected_row = row;
      if (row == 0 && k) view.markers[row] = 17;
      if (row == 15 && k + 1 < int(entries.size())) view.markers[row] = 16;
      view.rows[row] = text;
      if (k == cursor && expand && !entry.directory && name.size() > 28 && row < 15) {
        // Main repeats the trailing portion on a second highlighted row.
        const auto tail = std::min<std::size_t>(name.size() - 27, 27);
        text.resize(1);
        text += name.substr(name.size() - tail);
        view.rows[++row] = text;
        view.selected[row] = true;
        if (row == 15 && k + 1 < int(entries.size())) view.markers[row] = 16;
      }
    } else view.rows[row] = text;
  }
  return view;
}
inline bool browserExpand(const std::string &ini) {
  std::istringstream input(ini);
  std::string line;
  bool active = true, result = true;
  while (std::getline(input, line)) {
    line = trim(line.substr(0, line.find(';')));
    std::transform(line.begin(), line.end(), line.begin(), ::tolower);
    if (!line.empty() && line.front() == '[') active = line == "[mister]" || line == "[nds]";
    const auto eq = line.find('=');
    if (active && eq != std::string::npos && trim(line.substr(0, eq)) == "browse_expand")
      result = trim(line.substr(eq + 1)) != "0";
  }
  return result;
}
inline int loadingProgress(uint64_t done, uint64_t total) {
  return total ? int(std::min(done, total) * 167 / total) : 0;
}
inline bool recentEnabled(const std::string &ini) {
  std::istringstream input(ini);
  std::string line;
  bool active = true, result = true;
  while (std::getline(input, line)) {
    line = trim(line.substr(0, line.find(';')));
    std::transform(line.begin(), line.end(), line.begin(), ::tolower);
    if (!line.empty() && line.front() == '[') active = line == "[mister]" || line == "[nds]";
    const auto eq = line.find('=');
    if (active && eq != std::string::npos && trim(line.substr(0, eq)) == "recents")
      result = trim(line.substr(eq + 1)) != "0";
  }
  return result;
}
inline std::string loadingBar(int progress) {
  static constexpr unsigned char partial[] = {0x8c, 0x8e, 0x8f, 0x90, 0x91, 0x7f};
  progress = std::clamp(progress, 0, 167);
  // InfoMessage's set_text keeps 28 characters per row, including the margin.
  return (" " + std::string(progress / 6, char(0x7f)) + char(partial[progress % 6])).substr(0, 28);
}
inline std::array<std::string, 8> loadingRows(const std::string &name, int progress) {
  std::array<std::string, 8> rows{};
  rows[3] = " " + name.substr(0, 27);
  rows[4] = loadingBar(progress);
  return rows;
}
// Main menu.cpp helpstate and osd.cpp ScrollReset/ScrollText: advance one
// animation step per poll, including after a delayed poll. Do not catch up
// by jumping pixels. Exit remains visible until the ten-second idle timeout.
class VersionFooter {
  unsigned phase_ = 0;
  uint64_t next_ = 0, offset_ = 0;
  nds_osd::Row row_{};
public:
  void reset(uint64_t now) {
    phase_ = 0;
    next_ = now + 10000;
    offset_ = 0;
  }
  std::optional<nds_osd::Row> advance(const nds_osd::Frame &frame,
      const nds_osd::Row &exit_row, const std::string &version, uint64_t now) {
    if (phase_ < 9) {
      if (now < next_) return std::nullopt;
      if (!phase_) row_ = exit_row;
      for (std::size_t x = nds_osd::title_width; x < row_.size(); ++x) row_[x] <<= 1;
      ++phase_;
      next_ = now + 32;
    } else if (phase_ == 9) {
      ++phase_;
      next_ = now + 1000;
      return std::nullopt;
    } else {
      if (now < next_) return std::nullopt;
      const auto text = std::string(32, ' ') + version;
      offset_ = (offset_ + 1) % ((text.size() + 10) * 8);
      row_ = frame.scrollRow(15, row_, text, offset_);
      next_ = now + 10;
    }
    return row_;
  }
};
