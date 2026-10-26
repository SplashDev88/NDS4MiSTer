// SPDX-License-Identifier: GPL-3.0-or-later
// Reference layout/progress algorithms adapted from MiSTer Main menu.cpp.
// Original attribution and license: see THIRD_PARTY.md and COPYING.
#include "font.h"
#include "menu_presentation.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>

static std::array<std::string, 8> referenceProgress(const char *name, int current, int max) {
  static const char pchar[] = {char(0x8c), char(0x8e), char(0x8f), char(0x90), char(0x91), char(0x7f)};
  int progress = uint64_t(current) * 167 / max;
  if (progress > 167) progress = 167;
  char buffer[128]{};
  std::snprintf(buffer, sizeof(buffer), "\n\n %.27s\n ", name);
  char *bar = buffer + std::strlen(buffer);
  for (int i = 0; i <= progress / 6; ++i) bar[i] = i < progress / 6 ? char(0x7f) : pchar[progress % 6];
  bar[28] = 0;
  std::array<std::string, 8> rows{};
  char line[40]; int i = 0, l = 1;
  const char *message = buffer;
  do {
    line[i++] = *message;
    if (i == 29 || *message == '\n' || !*message) {
      line[--i] = 0;
      rows[l++] = line;
      i = 0;
    }
  } while (*message++);
  return rows;
}

static BrowserView referenceDirectory(const std::vector<BrowserEntry> &entries, int cursor, int first, bool expand) {
  BrowserView result; result.first = first;
  int i = 0, k = first;
  while (i < 16) {
    char s[40]; std::memset(s, ' ', 32); s[32] = 0;
    int len2 = 0;
    if (k < int(entries.size())) {
      const auto name = browserName(entries[k], false);
      int len = name.size();
      if (len > 28) { len2 = std::min(len - 27, 27); if (!expand) len2 = 0; len = 27; s[28] = 22; }
      std::strncpy(s + 1, name.c_str(), len);
      if (entries[k].directory) {
        if (name == "..") std::strcpy(s + 19, " <UP-DIR>");
        else std::strcpy(s + 22, " <DIR>");
        len2 = 0;
      }
      if (!i && k) result.markers[i] = 17;
      if (i == 15 && k + 1 < int(entries.size())) result.markers[i] = 16;
      const bool sel = k == cursor;
      result.rows[i] = s; result.selected[i] = sel;
      if (sel) result.selected_row = i;
      ++i;
      if (sel && len2 && i < 16) {
        std::strcpy(s + 1, name.c_str() + name.size() - len2);
        result.rows[i] = s; result.selected[i] = true;
        if (i == 15 && k + 1 < int(entries.size())) result.markers[i] = 16;
        ++i;
      }
    } else { result.rows[i++] = s; }
    ++k;
  }
  return result;
}

static void preview(const std::string &path, const std::vector<nds_osd::Row> &rows) {
  std::ofstream out(path, std::ios::binary);
  out << "P6\n1024 " << rows.size() * 32 << "\n255\n";
  for (unsigned y = 0; y < rows.size() * 32; ++y)
    for (unsigned x = 0; x < 1024; ++x) {
      bool lit = rows[y / 32][x / 4] & (1 << ((y / 4) % 8));
      const char rgb[] = {char(lit ? 255 : 0), char(lit ? 255 : 0), char(lit ? 255 : 96)};
      out.write(rgb, 3);
    }
  assert(out.good());
}

int main(int argc, char **argv) {
  std::vector<BrowserEntry> files{{"..", true}, {"Favorites", true}};
  for (int i = 0; i < 24; ++i) files.push_back({"Game " + std::to_string(i) + ".nds", false});
  files[3].name = "Final Fantasy Tactics A2 - Grimoire of the Rift (USA).nds";
  files[4].name = std::string(100, 'L') + ".nds";
  files[16].name = files[3].name;
  for (bool expand : {false, true})
    for (int cursor = 0; cursor < int(files.size()); ++cursor) {
      const auto actual = browserView(files, cursor, 0, expand, false);
      const auto oracle = referenceDirectory(files, cursor, actual.first, expand);
      assert(actual.rows == oracle.rows && actual.selected == oracle.selected && actual.markers == oracle.markers);
      assert(actual.rows[15] != "" && actual.selected_row >= 0);
    }
  assert(browserName({"Game.NDS", false}, false) == "Game");
  assert(browserName({"_Console", true}, true) == "Console");
  assert(browserView({}, 0, 0, true, false).rows[0] == "          No files!");
  assert(browserExpand("") && !browserExpand("browse_expand=0"));
  assert(browserExpand("browse_expand=0\n[NDS]\nbrowse_expand=1\n[Other]\nbrowse_expand=0"));
  for (int current = 0; current <= 1000; ++current) {
    auto rows = loadingRows("Final Fantasy Tactics A2.nds", loadingProgress(current, 1000));
    assert(rows == referenceProgress("Final Fantasy Tactics A2.nds", current, 1000));
  }
  nds_osd::Frame frame("NDS", charfont);
  const auto exit = frame.renderRow(15, "            exit", false, nds_osd::arrow_right);
  // Reference Main helpstate/ScrollText state machine, including delayed polls.
  unsigned footer_checks = 0;
  for (bool selected : {false, true}) for (bool delayed : {false, true}) {
    VersionFooter actual;
    actual.reset(0);
    auto base = frame.renderRow(15, "            exit", selected, nds_osd::arrow_right);
    auto oracle = base;
    unsigned helpstate = 0, scroll_offset = 0;
    uint64_t helptext_timer = 10000, scroll_timer = 0;
    const std::string text = std::string(32, ' ') + CORE_VERSION;
    for (uint64_t now = 0; now < 27000; now += delayed ? 17 + now % 113 : 1) {
      bool changed = false;
      if (helpstate < 9) {
        if (now >= helptext_timer) {
          helptext_timer = now + 32;
          for (int i = 22; i < 256; ++i) oracle[i] <<= 1;
          ++helpstate;
          changed = true;
        }
      } else if (helpstate == 9) {
        scroll_timer = now + 1000;
        scroll_offset = 0;
        ++helpstate;
      } else if (now >= scroll_timer) {
        scroll_timer = now + 10;
        if (++scroll_offset >= (text.size() + 10) * 8) scroll_offset = 0;
        // Main print_line writes 232 columns, normal (non-inverted) text.
        for (unsigned x = 0; x < 232; ++x) {
          unsigned pixel = (scroll_offset + x) % ((text.size() + 10) * 8);
          unsigned char c = pixel / 8 < text.size() ? text[pixel / 8] : ' ';
          oracle[22 + x] = charfont[c][pixel % 8];
        }
        changed = true;
      }
      auto row = actual.advance(frame, base, CORE_VERSION, now);
      assert(bool(row) == changed);
      if (row) assert(*row == oracle);
      ++footer_checks;
    }
    // A new menu action restarts the idle delay, including after scrolling.
    actual.reset(50000);
    assert(!actual.advance(frame, base, CORE_VERSION, 59999));
    auto first = actual.advance(frame, base, CORE_VERSION, 60000);
    assert(first && (*first)[230] == uint8_t(base[230] << 1));
  }
  // Independent pixel oracle for Main's one-pixel scroll, including wrap gap.
  const std::string scroll = "                                " + std::string(CORE_VERSION);
  for (unsigned offset = 0; offset < (scroll.size() + 10) * 8; ++offset) {
    auto actual = frame.scrollRow(15, exit, scroll, offset);
    for (unsigned x = 0; x < 232; ++x) {
      unsigned p = (offset + x) % ((scroll.size() + 10) * 8);
      unsigned char c = p / 8 < scroll.size() ? scroll[p / 8] : ' ';
      assert(actual[22 + x] == charfont[c][p % 8]);
    }
  }
  if (argc == 2) {
    std::vector<nds_osd::Row> rows;
    frame.setTitle("Select");
    auto view = browserView(files, 3, 0, true, false);
    for (int r = 0; r < 16; ++r) rows.push_back(frame.renderRow(r, view.rows[r], view.selected[r], 0, view.markers[r]));
    preview(std::string(argv[1]) + "-picker.ppm", rows);
    rows.clear(); frame.setTitle("Loading", 8);
    auto loading = loadingRows("Final Fantasy Tactics A2.nds", 84);
    for (int r = 0; r < 8; ++r) rows.push_back(frame.renderRow(r, loading[r]));
    preview(std::string(argv[1]) + "-loading.ppm", rows);
    rows.clear(); frame.setTitle("NDS");
    for (int r = 0; r < 16; ++r) rows.push_back(frame.renderRow(r));
    rows[0] = frame.renderRow(0, " " + std::string(LOAD_LABEL));
    for (int r = 2; r <= 7; ++r) rows[r] = frame.renderRow(r, optionLabel(0, CORE_OPTIONS[r-2]));
    rows[8] = frame.renderRow(8, " Reset");
    VersionFooter footer;
    footer.reset(0);
    for (uint64_t t = 0; t <= 13838; ++t)
      if (auto row = footer.advance(frame, exit, CORE_VERSION, t)) rows[15] = *row;
    preview(std::string(argv[1]) + "-footer.ppm", rows);
  }
  std::cout << "PASS: MiSTer directory layout, 1001 progress snapshots, idle version marquee and pixel scroll; " << footer_checks << " footer oracle polls\n";
}
