// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Title and row rendering adapted from MiSTer Main osd.cpp at
 * 5fb9bd102024ac16a92291f291318d5846dcaae2. See THIRD_PARTY.md.
 * Copyright 2005, 2006, 2007 Dennis van Weeren
 * Copyright 2008, 2009 Jakub Bednarski
 * Copyright 2026 NDS4MiSTer contributors
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * General Public License for more details: <https://www.gnu.org/licenses/>.
 */
#pragma once
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace nds_osd {
inline constexpr std::size_t row_count = 16;
inline constexpr std::size_t row_bytes = 256;
inline constexpr std::size_t title_width = 22;
inline constexpr std::size_t text_columns = (row_bytes - title_width) / 8;
using Font = unsigned char[256][8];
using Row = std::array<uint8_t, row_bytes>;
inline constexpr unsigned arrow_left = 1, arrow_right = 2;

// Pure menu rendering; the caller owns the font and sends rows over OSD SPI.
// Matches Main's unscrolled OsdWrite, including its footer page arrows.
class Frame {
  const Font &font_;
  std::array<uint8_t, row_count * 8> title_{};
  std::size_t rows_ = row_count;
  bool half_width_glyphs_ = false;

  const unsigned char *glyph(unsigned char ch) const {
    // Rotated Top/Bottom DV1 can retain only one column of each pair.
    // Keep the letter curves, symbol strokes and trailing gap in either
    // sample phase.
    static constexpr unsigned char upper_m[8] = {0x7f,0x7f,0x06,0x06,0x7f,0x7f,0,0};
    static constexpr unsigned char lower_m[8] = {0x7c,0x7c,0x18,0x18,0x7c,0x7c,0,0};
    // Open the opposite stem pixels beside N's diagonal so it reads as N
    // rather than H when only three ink columns survive the downsampling.
    static constexpr unsigned char upper_n[8] = {0x6f,0x6f,0x1c,0x1c,0x7b,0x7b,0,0};
    static constexpr unsigned char lower_w[8] = {0x7c,0x7c,0x30,0x30,0x7c,0x7c,0,0};
    static constexpr unsigned char upper_s[8] = {0x46,0x46,0x49,0x49,0x31,0x31,0,0};
    static constexpr unsigned char asterisk[8] = {0x2a,0x2a,0x1c,0x1c,0x2a,0x2a,0,0};
    static constexpr unsigned char lower_o[8] = {0x38,0x38,0x44,0x44,0x38,0x38,0,0};
    static constexpr unsigned char upper_o[8] = {0x3e,0x3e,0x41,0x41,0x3e,0x3e,0,0};
    static constexpr unsigned char percent[8] = {0x71,0x71,0x08,0x08,0x47,0x47,0,0};
    if (half_width_glyphs_) {
      if (ch == 'M') return upper_m;
      if (ch == 'm') return lower_m;
      if (ch == 'N') return upper_n;
      if (ch == 'w') return lower_w;
      if (ch == 'S') return upper_s;
      if (ch == '*') return asterisk;
      if (ch == 'o') return lower_o;
      if (ch == 'O') return upper_o;
      if (ch == '%') return percent;
    }
    return font_[ch];
  }

public:
  Frame(std::string_view title, const Font &font) : font_(font) {
    setTitle(title);
  }

  // Select before setTitle so the vertical title uses the same glyphs.
  void setHalfWidthGlyphs(bool enabled) { half_width_glyphs_ = enabled; }

  void setTitle(std::string_view title, std::size_t rows = row_count) {
    rows_ = rows == 8 ? 8 : row_count;
    const auto height = rows_ * 8;
    std::array<uint8_t, row_count * 8> condensed{}, centered{};
    std::size_t used = 0;
    unsigned zeros = 0;
    for (unsigned char ch : title) {
      if (!ch || used >= height - 8) break;
      for (unsigned x = 0; x < 8; ++x) {
        const auto column = glyph(ch)[x];
        if (column) {
          zeros = 0;
          condensed[used++] = column;
        } else if (!zeros || (ch == ' ' && zeros < 5)) {
          condensed[used++] = 0;
          ++zeros;
        }
      }
    }
    const auto start = (height - 1 - used) / 2;
    for (std::size_t i = 0; i < used; ++i)
      centered[start + i] = condensed[i];

    // Rotate each 8x8 tile. Row order is reversed when drawing the stripe.
    title_.fill(0);
    for (std::size_t i = 0; i < height; ++i)
      for (unsigned bit = 0; bit < 8; ++bit)
        title_[(i / 8) * 8 + bit] |=
            ((centered[i] >> bit) & 1u) << (7 - i % 8);
  }

  Row renderRow(std::size_t row, std::string_view text = {},
                bool inverse = false, unsigned arrows = 0,
                unsigned char leftchar = 0) const {
    Row result{};
    if (row >= rows_) return result;
    const uint8_t invert = inverse ? 0xff : 0;
    result.fill(invert);

    // Main's stripe: 3 white columns, 8 doubled title columns, 1 white
    // column, and a 2-column gap. Selection never inverts the title.
    for (std::size_t x = 0; x < 20; ++x) result[x] = 0xff;
    const auto title_start = (rows_ - 1 - row) * 8;
    std::array<uint8_t, 8> marker{};
    if (leftchar && (row == 0 || row == rows_ - 1)) {
      for (unsigned bit = 0; bit < 8; ++bit)
        for (unsigned x = 0; x < 8; ++x)
          marker[bit] |= ((font_[leftchar][x] >> bit) & 1u) << (7 - x);
    } else leftchar = 0;
    for (std::size_t x = 0; x < 16; ++x)
      result[3 + x] = 0xff ^ (leftchar ? marker[x / 2] : title_[title_start + x / 2]);
    result[20] = result[21] = 0;

    std::size_t column = title_width;
    if (row != rows_ - 1) arrows = 0;
    const auto limit = row_bytes - ((arrows & arrow_right) ? 22 : 0);
    if (arrows & arrow_left) {
      column += 3;
      for (unsigned ch : {0x10u, 0x14u})
        for (auto bits : font_[ch]) result[column++] = bits ^ invert;
      column += 5;
      // Main skips the first three footer characters to preserve alignment.
      if (text.find('\0') < 3) text = {};
      else text.remove_prefix(std::min<std::size_t>(3, text.size()));
    }
    uint8_t stipple_mask = 0xff, stipple = 0, glyph_invert = 0;
    for (unsigned char ch : text) {
      // A row cannot write into its neighbors, even for malformed filenames.
      if (!ch || ch == '\r' || ch == '\n') break;
      if (ch == 0x0b) {
        stipple_mask ^= 0xaa;
        stipple ^= 0xff;
      } else if (ch == 0x0c) {
        glyph_invert ^= 0xff;
      } else {
        if (column >= limit - 8) break;
        for (unsigned x = 0; x < 8; ++x) {
          const auto bits = glyph(ch)[x];
          result[column++] = (bits & stipple_mask) ^ invert ^ glyph_invert;
          stipple_mask ^= stipple;
        }
      }
    }
    if (arrows & arrow_right) {
      column = limit + 3;
      for (unsigned ch : {0x15u, 0x11u})
        for (auto bits : font_[ch]) result[column++] = bits ^ invert;
    }
    return result;
  }
  // Main's print_line scrolls one pixel per tick and leaves columns outside
  // the scrolling window intact (directory suffixes and trailing pixels).
  Row scrollRow(std::size_t row, const Row &base, std::string_view text,
                uint64_t offset, unsigned width = 232, bool inverse = false) const {
    Row result = base;
    if (row >= rows_) return {};
    const auto stripe = renderRow(row);
    std::copy_n(stripe.begin(), title_width, result.begin());
    width = std::min<unsigned>(width, row_bytes - title_width);
    const auto period = (text.size() + 10) * 8;
    for (unsigned x = 0; x < width; ++x) {
      const auto pixel = (offset + x) % period;
      const unsigned char ch = pixel / 8 < text.size() ? text[pixel / 8] : ' ';
      result[title_width + x] = glyph(ch)[pixel % 8] ^ (inverse ? 0xff : 0);
    }
    return result;
  }
};
} // namespace nds_osd
