// SPDX-License-Identifier: GPL-3.0-or-later
// NDS System layout follows MiSTer Main menu.cpp MENU_COMMON1/MenuWrite at
// 5fb9bd102024ac16a92291f291318d5846dcaae2. See THIRD_PARTY.md and COPYING.
#pragma once
#include "menu_model.h"
#include "osd_frame.h"
#include <filesystem>
#include <fstream>

struct SystemMenuOptions {
  bool lock_osd = false, custom_filter = false;
  std::string filter_name;
};
inline SystemMenuOptions systemMenuOptions(const std::string &ini,
                                          const std::filesystem::path &filter_config) {
  SystemMenuOptions result;
  std::istringstream stream(ini);
  std::string line, default_filter, lock;
  bool active = true;
  int lock_time = 0;
  while (std::getline(stream, line)) {
    line = trim(line.substr(0, line.find(';')));
    auto lower = line;
    std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
    if (!lower.empty() && lower.front() == '[')
      active = lower == "[mister]" || lower == "[nds]";
    const auto eq = line.find('=');
    if (!active || eq == std::string::npos) continue;
    const auto key = trim(lower.substr(0, eq)), value = trim(line.substr(eq + 1));
    if (key == "afilter_default") default_filter = value;
    if (key == "osd_lock") lock = value;
    if (key == "osd_lock_time") {
      std::istringstream number(value);
      number >> lock_time;
    }
  }
  result.lock_osd = !lock.empty() && lock_time <= 0;
  result.custom_filter = !default_filter.empty();
  result.filter_name = default_filter;
  // Read the state Main applied at startup; no filter commands or polling.
  std::ifstream file(filter_config, std::ios::binary);
  std::array<char, 1024> data{};
  file.read(data.data(), data.size() - 1);
  if (file.gcount() > 0 && static_cast<unsigned char>(data[0]) <= 1) {
    result.custom_filter = data[0] != 0;
    result.filter_name = data.data() + 1;
  }
  result.filter_name = std::filesystem::path(result.filter_name).filename().string();
  return result;
}

struct SystemMenuRow {
  std::string text;
  int action = -1; // Only implemented actions have a cursor stop.
  bool disabled = false;
  unsigned arrows = 0;
};
inline std::vector<SystemMenuRow> systemMenuRows(const SystemMenuOptions &options) {
  std::vector<SystemMenuRow> rows;
  auto add = [&](std::string text = "", int action = -1, bool disabled = false,
                 unsigned arrows = 0) { rows.push_back({text, action, disabled, arrows}); };
  add(" Core                      \x16", 0);
  add();
  if (options.lock_osd) {
    add(" Lock OSD", -1, true);
    add();
  }
  auto define = std::string(" Define NDS buttons");
  define.resize(27, ' ');
  add(define + char(22), 1);
  add(" Button/Key remap          \x16", -1, true);
  add(" Reset player assignment", -1, true);
  // This NDS FPGA exposes no UART flags/speeds, so Main has no UART row.
  add();
  add(" Video processing          \x16", -1, true);
  // sys_top advertises UIO_SET_AFILTER support on the accepted NDS FPGA.
  add();
  add(std::string(" Audio filter - ") + (options.custom_filter ? "Custom" : "Internal"), -1, true);
  auto filter = options.filter_name.empty() ? std::string(" < none >")
                                           : " " + options.filter_name.substr(0, 25);
  filter.resize(26, ' ');
  add(filter + " \x16 ", -1, true);
  add();
  add(" Reset settings", 2);
  add(" Save settings", 3);
  add();
  // User preference: omit Help and About, including their trailing spacer.
  // User preference: omit Main's cold-reboot hint until that action exists.
  add(" Storage                   \x16", 4);
  add();
  add(" Reboot", 5);
  while (rows.size() < 15) add();
  add("            exit", 6, false, nds_osd::arrow_left);
  return rows;
}

struct SystemMenuView {
  std::array<SystemMenuRow, 16> rows{};
  std::array<unsigned char, 16> markers{};
  int first = 0, selected = -1;
};
inline SystemMenuView systemMenuView(const std::vector<SystemMenuRow> &rows,
                                    int cursor, int first) {
  SystemMenuView view;
  int selected = -1;
  for (size_t i = 0; i < rows.size(); ++i)
    if (rows[i].action >= 0 && rows[i].action == cursor && !rows[i].disabled) selected = int(i);
  // Same adjustment as Main MenuWrite/adjvisible; return to top at Core.
  if (cursor == 0) first = 0;
  first = std::clamp(first, 0, std::max(0, int(rows.size()) - 16));
  if (selected >= 0) {
    if (selected < first) first = selected;
    if (selected >= first + 16) first = selected - 15;
    view.selected = selected - first;
  }
  view.first = first;
  for (int y = 0; y < 16; ++y) {
    const int i = first + y;
    if (i < int(rows.size())) view.rows[y] = rows[i];
    if (y == 0 && first) view.markers[y] = 17;
    if (y == 15 && !view.rows[y].arrows) view.markers[y] = 16;
  }
  return view;
}
