// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>

static void checkGlyph(const nds_osd::Frame &frame, char letter,
                       const std::array<const char *, 8> &shape) {
  for (bool inverse : {false, true}) {
    auto row = frame.renderRow(1, std::string(1, letter), inverse);
    for (unsigned phase : {0u, 1u})
      for (unsigned y = 0; y < 8; ++y)
        for (unsigned x = 0; x < std::strlen(shape[y]); ++x) {
          const bool pixel = (row[nds_osd::title_width + 2*x + phase] >> y) & 1;
          assert(pixel == ((shape[y][x] == '#') != inverse));
        }
  }
}

struct HostTest {
  static void run(const fs::path &root) {
    fs::create_directories(root / "kit");
    Host host((root / "kit").string(), (root / "games/NDS").string(), root);
    nds_osd::Frame normal("", charfont), compact("", charfont);
    compact.setHalfWidthGlyphs(true);
    const std::string text = "firmware Main *.NDS oOa 100%";
    const auto ordinary = normal.renderRow(1, text);
    const auto corrected = compact.renderRow(1, text);
    assert(ordinary != corrected);
    checkGlyph(compact, 'M', {"#.#.","###.","###.","#.#.","#.#.","#.#.","#.#.","...."});
    checkGlyph(compact, 'm', {"....","....","#.#.","###.","###.","#.#.","#.#.","...."});
    checkGlyph(compact, 'N', {"#..#.","##.#.","##.#.","##.#.","#.##.","#.##.","#..#.","....."});
    checkGlyph(compact, 'w', {"....","....","#.#.","#.#.","###.","###.","#.#.","...."});
    checkGlyph(compact, 'S', {".##.","#...","#...",".#..","..#.","..#.","##..","...."});
    checkGlyph(compact, '*', {"....","#.#.",".#..","###.",".#..","#.#.","....","...."});
    checkGlyph(compact, 'o', {"....","....",".#..","#.#.","#.#.","#.#.",".#..","...."});
    checkGlyph(compact, 'O', {".#..","#.#.","#.#.","#.#.","#.#.","#.#.",".#..","...."});
    checkGlyph(compact, '%', {"#.#.","..#.","..#.",".#..","#...","#...","#.#.","...."});
    // Confirm that both horizontal sample phases distinguish o from a.
    const auto a = compact.renderRow(1, "a"), o = compact.renderRow(1, "o");
    for (unsigned phase : {0u, 1u}) {
      bool different = false;
      for (unsigned x = 0; x < 4; ++x)
        different |= a[22 + 2*x + phase] != o[22 + 2*x + phase];
      assert(different);
    }
    for (unsigned ch = 32; ch < 127; ++ch)
      if (ch != 'M' && ch != 'm' && ch != 'N' && ch != 'w' && ch != 'S' && ch != '*' && ch != 'o' && ch != 'O' && ch != '%')
        assert(compact.renderRow(1, std::string(1, char(ch))) ==
               normal.renderRow(1, std::string(1, char(ch))));

    // A custom-font oracle exercises titles, inversion, disabled text and
    // scrolling, rather than testing only a direct glyph lookup.
    nds_osd::Font expected_font;
    std::memcpy(expected_font, charfont, sizeof(expected_font));
    for (char ch : {'M', 'm', 'w', 'S', '*', 'o', 'O', '%'}) {
      const auto row = compact.renderRow(1, std::string(1, ch));
      std::copy_n(row.begin() + 22, 8, expected_font[unsigned(ch)]);
    }
    // Vertical N and S use stock Main columns: rotating the paired row
    // glyphs would preserve both copies and distort their stock proportions.
    // Other title glyphs retain the existing compact corrections.
    nds_osd::Font expected_title_font;
    std::memcpy(expected_title_font, expected_font, sizeof(expected_title_font));
    std::copy_n(charfont['S'], 8, expected_title_font['S']);
    // Trim exactly the two rightmost pixels in D's top and bottom ink rows.
    expected_title_font['D'][4] &= ~0x41;
    nds_osd::Frame title_expected("", expected_title_font);
    for (const auto *title : {"N", "D", "S", "NDS", "Oo%", "System", "Firmware", "Recent Files",
                              "Display options", "Loading", "Select"})
      for (unsigned rows : {8u, 16u}) {
        title_expected.setTitle(title, rows);
        compact.setTitle(title, rows);
        for (unsigned row = 0; row < rows; ++row)
          for (bool inverse : {false, true}) {
            const auto wanted = title_expected.renderRow(row, "NDS", inverse);
            const auto actual = compact.renderRow(row, "NDS", inverse);
            assert(std::equal(wanted.begin(), wanted.begin() + nds_osd::title_width,
                              actual.begin()));
          }
      }
    nds_osd::Frame expected("Oo%", expected_font);
    compact.setTitle("Oo%");
    const std::string fixed_width_text = "firmware Main *.DS oOa 100%";
    for (unsigned row = 0; row < 16; ++row)
      for (bool inverse : {false, true}) {
        const auto marked = std::string(1, char(0x0b)) + fixed_width_text;
        assert(compact.renderRow(row, marked, inverse) == expected.renderRow(row, marked, inverse));
        const auto base = compact.renderRow(row, fixed_width_text, inverse);
        for (unsigned offset = 0; offset < 88; ++offset)
          assert(compact.scrollRow(row, base, fixed_width_text, offset, 232, inverse) ==
                 expected.scrollRow(row, base, fixed_width_text, offset, 232, inverse));
      }

    // Independent pixel stream: four-column N plus its gap, D and S.
    // Exercise wrapping and every boundary where the wider cell meets the
    // ordinary cells, including windows wider than the physical OSD row.
    std::vector<unsigned char> pixels{0x7f,0x7f,0x0e,0x0e,0x30,0x30,0x7f,0x7f,0,0};
    pixels.insert(pixels.end(), charfont['D'], charfont['D'] + 8);
    pixels.insert(pixels.end(), expected_font['S'], expected_font['S'] + 8);
    assert(compact.textWidth("NDS") == 26 && normal.textWidth("NDS") == 24);
    pixels.resize(pixels.size() + 80, 0);
    assert(compact.scrollPeriod("NDS") == pixels.size());
    for (bool inverse : {false, true}) {
      const auto base = compact.renderRow(1, "NDS", inverse);
      for (unsigned x = 0; x < 26; ++x)
        assert(base[22 + x] == (pixels[x] ^ (inverse ? 0xff : 0)));
      for (unsigned width : {1u, 8u, 9u, 10u, 232u, 234u, 512u})
        for (unsigned offset = 0; offset < pixels.size() * 2; ++offset) {
          const auto row = compact.scrollRow(1, base, "NDS", offset, width, inverse);
          for (unsigned x = 0; x < std::min(width, 234u); ++x)
            assert(row[22 + x] == (pixels[(offset + x) % pixels.size()] ^ (inverse ? 0xff : 0)));
        }
    }
    compact.setTitle(std::string(128, 'N'), 8); // bounded title
    compact.setTitle("");

    unsigned cases = 0;
    for (unsigned flags = 0; flags < 32; ++flags)
      for (bool known : {false, true})
        for (bool supported : {false, true})
          for (unsigned layout = 0; layout < 4; ++layout)
            for (unsigned rotation = 0; rotation < 4; ++rotation) {
              host.video_flags = ((flags & 1) << 10) | (((flags >> 1) & 1) << 7) |
                  (((flags >> 2) & 1) << 13) | (((flags >> 3) & 1) << 12) |
                  (((flags >> 4) & 1) << 2);
              host.video_flags_known = known;
              host.independent_outputs_supported = supported;
              host.status = REQUIRED_STATUS | (layout << 5) | (rotation << 11);
              host.configureMenuGlyphs();
              host.frame.setTitle("");
              const bool affected = known && supported && (flags & 15) == 1 &&
                  layout == 1 && (rotation == 1 || rotation == 2);
              assert(host.frame.renderRow(1, text) == (affected ? corrected : ordinary));
              ++cases;
            }
    // Real draw/loading paths refresh the selection when the layout changes.
    host.video_flags = 1u << 10;
    host.video_flags_known = host.independent_outputs_supported = true;
    host.status = REQUIRED_STATUS | (1u << 5) | (2u << 11);
    host.draw();
    compact.setTitle("NDS");
    assert(host.osd_rows[0] == compact.renderRow(0, " Load *.NDS", true));
    host.beginLoading("Oo 100%.nds");
    expected.setTitle("Loading", 8);
    const auto loading = loadingRows("Oo 100%.nds", 0);
    for (unsigned row = 0; row < 8; ++row)
      assert(host.osd_rows[row] == expected.renderRow(row, loading[row]));
    host.status = REQUIRED_STATUS;
    host.draw();
    normal.setTitle("NDS");
    assert(host.osd_rows[0] == normal.renderRow(0, " Load *.NDS", true));
    std::cout << "PASS: M/m/N/w/S/*/o/O/% at both sample phases, other glyphs unchanged, rounded vertical D/stock N/S, titles, styles, scrolling, "
              << cases << " output/layout/rotation cases, loading and live mode changes\n";
  }
};

int main() {
  char directory[] = "/tmp/nds-menu-glyphs-XXXXXX";
  assert(mkdtemp(directory));
  HostTest::run(directory);
  fs::remove_all(directory);
}
