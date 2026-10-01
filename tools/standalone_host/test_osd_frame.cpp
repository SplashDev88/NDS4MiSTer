// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer reference routines below retain their original attribution:
// Copyright 2005, 2006, 2007 Dennis van Weeren
// Copyright 2008, 2009 Jakub Bednarski
// Distributed under GPL version 3 or, at your option, any later version.
// Without any warranty; see osd_frame.h and THIRD_PARTY.md.
#include "font.h"
#include "osd_frame.h"
#include "system_menu.h"
#include <algorithm>
#include <cassert>
#include <cstring>
#include <fstream>
#include <iostream>
#include <random>
#include <string>

// Independent oracle extracted from Main_MiSTer/osd.cpp at
// 5fb9bd102024ac16a92291f291318d5846dcaae2: rotatechar, OsdSetTitle,
// draw_title, and the default OsdWriteOffset path. Hardware writes are
// captured in osdbuf. Removed paths: scrolling, background images,
// partial inversion and multi-line writes, which this row API does not expose.
// Keep the original pointer/cursor algorithm here, separate from Frame.
namespace reference {
static unsigned OSDHEIGHT = 128;
static constexpr int OSDLINELEN = 256;
static int osd_size = 16;
static unsigned char titlebuffer[256], osdbuf[256 * 16];
static unsigned osdbufpos;

static void rotatechar(unsigned char *in, unsigned char *out) {
  int a, b, c;
  for (b = 0; b < 8; ++b) {
    a = 0;
    for (c = 0; c < 8; ++c) {
      a <<= 1;
      a |= (in[c] >> b) & 1;
    }
    out[b] = a;
  }
}

static void OsdSetTitle(const char *s, int rows = 16) {
  osd_size = rows;
  OSDHEIGHT = rows * 8;
  int zeros = 0;
  unsigned i = 0, j = 0, outp = 0;
  while (1) {
    int c = s[i++];
    if (c && (outp < OSDHEIGHT - 8)) {
      unsigned char *p = &charfont[c][0];
      for (j = 0; j < 8; ++j) {
        unsigned char nc = *p++;
        if (nc) {
          zeros = 0;
          titlebuffer[outp++] = nc;
        } else if (zeros == 0 || (c == ' ' && zeros < 5)) {
          titlebuffer[outp++] = 0;
          zeros++;
        }
        if (outp > sizeof(titlebuffer)) break;
      }
    } else break;
  }
  for (i = outp; i < OSDHEIGHT; i++) titlebuffer[i] = 0;
  unsigned c = (OSDHEIGHT - 1 - outp) / 2;
  memmove(titlebuffer + c, titlebuffer, outp);
  for (i = 0; i < c; ++i) titlebuffer[i] = 0;
  for (i = 0; i < OSDHEIGHT; i += 8) {
    unsigned char tmp[8];
    rotatechar(&titlebuffer[i], tmp);
    for (c = 0; c < 8; ++c) titlebuffer[i + c] = tmp[c];
  }
}

static void draw_title(const unsigned char *p) {
  osdbuf[osdbufpos++] = 0xff;
  osdbuf[osdbufpos++] = 0xff;
  osdbuf[osdbufpos++] = 0xff;
  for (int i = 0; i < 8; i++) {
    osdbuf[osdbufpos++] = 255 ^ *p;
    osdbuf[osdbufpos++] = 255 ^ *p++;
  }
  osdbuf[osdbufpos++] = 0xff;
  osdbuf[osdbufpos++] = 0;
  osdbuf[osdbufpos++] = 0;
}

static nds_osd::Row OsdWrite(unsigned char n, const char *s,
                             unsigned char invert, unsigned arrows, unsigned char leftchar = 0) {
  unsigned short i = 0;
  unsigned char b, stipplemask = 0xff, stipple = 0, xorchar = 0;
  unsigned char xormask = invert ? 255 : 0;
  const unsigned char *p;
  int linelimit = OSDLINELEN;
  unsigned arrowmask = n == osd_size - 1 ? arrows : 0;
  if (n && n < osd_size - 1) leftchar = 0;
  if (arrowmask & 2) linelimit -= 22;
  osdbufpos = n * 256;
  while (1) {
    if (i == 0 && n < osd_size) {
      unsigned char tmp[8];
      if (leftchar) {
        unsigned char tmp2[8];
        std::memcpy(tmp2, charfont[leftchar], 8);
        rotatechar(tmp2, tmp);
        p = tmp;
      } else p = &titlebuffer[(osd_size - 1 - n) * 8];
      draw_title(p);
      i += 22;
    } else if (arrowmask & 1) {
      for (int j = 0; j < 3; ++j) osdbuf[osdbufpos++] = xormask;
      p = &charfont[0x10][0];
      for (b = 0; b < 8; ++b) osdbuf[osdbufpos++] = *p++ ^ xormask;
      p = &charfont[0x14][0];
      for (b = 0; b < 8; ++b) osdbuf[osdbufpos++] = *p++ ^ xormask;
      for (int j = 0; j < 5; ++j) osdbuf[osdbufpos++] = xormask;
      i += 24;
      arrowmask &= ~1u;
      if (*s++ == 0) break;
      if (*s++ == 0) break;
      if (*s++ == 0) break;
    } else {
      b = *s++;
      if (!b) break;
      if (b == 0xb) {
        stipplemask ^= 0xaa;
        stipple ^= 0xff;
      } else if (b == 0xc) {
        xorchar ^= 0xff;
      } else if (i < linelimit - 8) {
        p = &charfont[b][0];
        for (unsigned char c = 0; c < 8; c++) {
          osdbuf[osdbufpos++] = (*p++ & stipplemask) ^ xormask ^ xorchar;
          stipplemask ^= stipple;
        }
        i += 8;
      }
    }
  }
  for (; i < linelimit; i++) osdbuf[osdbufpos++] = xormask;
  if (arrowmask & 2) {
    for (int j = 0; j < 3; ++j) osdbuf[osdbufpos++] = xormask;
    p = &charfont[0x15][0];
    for (b = 0; b < 8; ++b) osdbuf[osdbufpos++] = *p++ ^ xormask;
    p = &charfont[0x11][0];
    for (b = 0; b < 8; ++b) osdbuf[osdbufpos++] = *p++ ^ xormask;
    for (int j = 0; j < 3; ++j) osdbuf[osdbufpos++] = xormask;
  }
  nds_osd::Row result;
  std::copy_n(osdbuf + n * 256, 256, result.begin());
  return result;
}
} // namespace reference

static unsigned comparisons;
static void compare(const nds_osd::Frame &frame, unsigned row,
                    const std::string &text, bool inverse, unsigned arrows = 0,
                    unsigned char leftchar = 0) {
  auto actual = frame.renderRow(row, text, inverse, arrows, leftchar);
  auto expected = reference::OsdWrite(row, text.c_str(), inverse, arrows, leftchar);
  if (actual != expected) {
    auto mismatch = std::mismatch(actual.begin(), actual.end(), expected.begin());
    std::cerr << "OSD mismatch: row " << row << ", column "
              << mismatch.first - actual.begin() << ", inverse " << inverse
              << ", arrows " << arrows
              << '\n';
    std::abort();
  }
  ++comparisons;
}

// Optional portable preview: one logical OSD pixel becomes a 4x4 RGB block.
static void preview(const char *path) {
  const nds_osd::Frame frame("NDS", charfont);
  const std::array<std::string, 16> rows{
      " Load NDS (max 128 MiB)", "", " Video Layout:    Left/Right",
      " Screen Order:    Main First", " Screen Gap:        8 Pixels",
      " 3D FPS Counter:          On", " Engine B (next Reset):   On",
      " Video Rotation:         Off", " Reset", "", "", "", "", "",
      "", "            exit"};
  std::ofstream output(path, std::ios::binary);
  output << "P6\n1024 512\n255\n";
  for (unsigned y = 0; y < 512; ++y) {
    auto row = frame.renderRow(y / 32, rows[y / 32], y / 32 == 5, nds_osd::arrow_right);
    for (unsigned x = 0; x < 1024; ++x) {
      const bool lit = row[x / 4] & (1u << ((y / 4) % 8));
      const char rgb[3] = {char(lit ? 255 : 0), char(lit ? 255 : 0),
                           char(lit ? 255 : 96)};
      output.write(rgb, sizeof(rgb));
    }
  }
  assert(output.good());
}

// Explicit MENU_COMMON1 reference rows for NDS: UART absent, audio filter
// supported. Stipple comes from Main's disabled-UI flag (equivalent to 0x0b).
static void system_menu_test(const char *preview_dir) {
  const std::array<std::string, 16> main_rows{
    " Core                      \x16", "", " Define NDS buttons        \x16",
    " Button/Key remap          \x16", " Reset player assignment", "",
    " Video processing          \x16", "", " Audio filter - Internal",
    " < none >                  \x16 ", "", " Reset settings", " Save settings",
    "", " Reboot", "            exit"}; // User exceptions: no Help/About/hold hint.
  const int selected_rows[] = {0, 2, 11, 12, 14, 15};
  const int first_rows[] = {0, 0, 0, 0, 0, 0};
  const auto rows = systemMenuRows({});
  assert(rows.size() == main_rows.size());
  for (int i = 0; i < 16; ++i) {
    auto plain = rows[i].text;
    plain.erase(std::remove(plain.begin(), plain.end(), char(0x0b)), plain.end());
    assert(plain == main_rows[i]);
    const bool disabled = i == 3 || i == 4 || i == 6 || i == 8 || i == 9;
    assert(rows[i].disabled == disabled);
  }
  nds_osd::Frame frame("System", charfont);
  reference::OsdSetTitle("System");
  int first = 0;
  for (int cursor = 0; cursor < 6; ++cursor) {
    auto view = systemMenuView(rows, cursor, first);
    first = view.first;
    assert(first == first_rows[cursor]);
    assert(view.selected == selected_rows[cursor] - first);
    for (int y = 0; y < 16; ++y) {
      const int row = first + y;
      auto expected_text = main_rows[row];
      if (rows[row].disabled) expected_text.insert(expected_text.begin(), char(0x0b));
      const auto text = view.rows[y].disabled ? std::string(1, char(0x0b)) + view.rows[y].text : view.rows[y].text;
      const unsigned arrows = row == 15 ? nds_osd::arrow_left : 0;
      const unsigned char marker = y == 0 && first ? 17 : y == 15 && !arrows ? 16 : 0;
      const auto expected = reference::OsdWrite(y, expected_text.c_str(), y == view.selected, arrows, marker);
      assert(frame.renderRow(y, text, y == view.selected, view.rows[y].arrows, view.markers[y]) == expected);
    }
    if (preview_dir && (cursor == 0 || cursor == 5)) {
      std::ofstream out(std::string(preview_dir) + (cursor ? "/system-bottom.bin" : "/system-top.bin"), std::ios::binary);
      for (int y = 0; y < 16; ++y) {
        const auto &row = view.rows[y];
        auto bytes = frame.renderRow(y, row.disabled ? std::string(1, char(0x0b)) + row.text : row.text,
                                    y == view.selected, row.arrows, view.markers[y]);
        out.write((const char *)bytes.data(), bytes.size());
      }
      assert(out.good());
    }
  }
  const auto locked = systemMenuRows({true, true, "LPF2000_3tap.txt"});
  assert(locked.size() == 18 && locked[2].text == " Lock OSD" && locked[2].disabled);
  assert(locked[10].text == " Audio filter - Custom");
  assert(systemMenuView(locked, 5, 0).first == 2);
  assert(systemMenuView(locked, 0, 2).first == 0);
  assert(systemMenuView(rows, -1, 0).selected == -1);
  auto ini = systemMenuOptions("osd_lock=ABCD\nosd_lock_time=0\nafilter_default=folder/LPF.txt\n[Other]\nafilter_default=ignore.txt", "/nonexistent-nds-config");
  assert(ini.lock_osd && ini.custom_filter && ini.filter_name == "LPF.txt");
  assert(!systemMenuOptions("osd_lock=ABCD\nosd_lock_time=10", "/nonexistent-nds-config").lock_osd);
  std::cout << "PASS: NDS System rows/disabled pixels/scrolling against Main; optional lock/filter labels\n";
}

int main(int argc, char **argv) {
  system_menu_test(argc == 3 ? argv[2] : nullptr);
  static_assert(nds_osd::text_columns == 29, "Main fits 29 complete glyphs");
  const std::array<std::string, 8> titles{
      "NDS", "System", "Select", "Load NDS", "", "   N D S   ",
      std::string(1000, 'W'), std::string(1000, ' ')};
  const std::array<std::string, 9> texts{
      "", " Load NDS", " 3D FPS Counter            On",
      " Engine B (next Reset)     On", std::string(28, 'A'),
      std::string(29, 'B'), std::string(30, 'C'), std::string(1000, 'D'),
      "Plain\vStipple\vPlain\fReverse\f"};
  nds_osd::Frame frame("", charfont);
  for (const auto &title : titles) {
    frame.setTitle(title);
    reference::OsdSetTitle(title.c_str());
    for (unsigned row = 0; row < 16; ++row)
      for (const auto &text : texts)
        for (bool inverse : {false, true})
          for (unsigned arrows = 0; arrows < 4; ++arrows)
            compare(frame, row, text, inverse, arrows);
  }
  for (const auto *title : {"Loading", "Select"}) {
    frame.setTitle(title, 8);
    reference::OsdSetTitle(title, 8);
    for (unsigned row = 0; row < 8; ++row)
      for (const auto &text : texts)
        for (bool inverse : {false, true}) compare(frame, row, text, inverse);
    assert(frame.renderRow(8, "stale file row") == nds_osd::Row{});
  }
  frame.setTitle("Select"); reference::OsdSetTitle("Select");
  for (unsigned row = 0; row < 16; ++row)
    for (unsigned char marker : {16, 17})
      for (bool inverse : {false, true}) compare(frame, row, " A file", inverse, 0, marker);

  // Check the final full glyph and 2 trailing pixels explicitly; title and
  // blue gap must remain identical while selection inverts the text region.
  frame.setTitle("NDS");
  auto normal = frame.renderRow(15, std::string(30, 'X'));
  auto selected = frame.renderRow(15, std::string(30, 'X'), true);
  for (unsigned x = 0; x < 256; ++x)
    assert((normal[x] ^ selected[x]) == (x < 22 ? 0 : 255));
  for (unsigned x = 0; x < 8; ++x) assert(normal[246 + x] == charfont['X'][x]);
  assert(normal[254] == 0 && normal[255] == 0);
  assert(normal[0] == 255 && normal[19] == 255 && normal[20] == 0 && normal[21] == 0);

  // Deterministic differential cases cover glyph bytes, NUL termination,
  // controls, long clipping, every line and repeated title replacement.
  std::mt19937 random(0x4e4453);
  for (unsigned trial = 0; trial < 3000; ++trial) {
    std::string title(random() % 256, ' '), text(random() % 512, ' ');
    for (char &ch : title) ch = char(32 + random() % 95);
    for (char &ch : text) {
      ch = char(random() % 256);
      if (ch == '\r' || ch == '\n') ch = ' ';
    }
    frame.setTitle(title);
    reference::OsdSetTitle(title.c_str());
    compare(frame, random() % 16, text, random() % 2, random() % 4);
  }

  // Malformed/untrusted inputs are intentionally bounded to one row.
  const nds_osd::Row blank{};
  for (unsigned trial = 0; trial < 1000; ++trial) {
    std::string arbitrary(random() % 1024, ' ');
    for (char &ch : arbitrary) ch = char(random() % 256);
    frame.setTitle(arbitrary);
    (void)frame.renderRow(random() % 16, arbitrary, random() % 2, random() % 4);
    assert(frame.renderRow(16 + random(), arbitrary, true) == blank);
  }
  assert(frame.renderRow(0, "x\ny") == frame.renderRow(0, "x"));
  assert(frame.renderRow(0, "x\ry") == frame.renderRow(0, "x"));
  if (argc == 2) preview(argv[1]);
  std::cout << "PASS: " << comparisons
            << " Main byte comparisons; title, selection, page arrows, clipping,"
               " controls and malformed-input bounds\n";
}
