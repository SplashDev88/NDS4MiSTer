// SPDX-License-Identifier: GPL-3.0-only
// Exercise the standard encoder at the NDS 60 MHz shell clock and CRT raster.
#include "Vyc_out.h"
#include "verilated.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>

struct Range {
  int lo = 255, hi = 0, samples = 0, rising = 0, previous = 128;
  void add(int value) {
    lo = std::min(lo, value);
    hi = std::max(hi, value);
    ++samples;
    if (previous <= 128 && value > 128) ++rising;
    previous = value;
  }
};

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  for (int pal = 0; pal < 2; ++pal) {
    for (int cvbs = 0; cvbs < 2; ++cvbs) {
      Vyc_out encoder;
      encoder.PAL_EN = pal;
      encoder.CVBS = cvbs;
      const double carrier = pal ? 4433618.75 : 315000000.0 / 88.0;
      encoder.PHASE_INC = std::llround(carrier / 60000000.0 * 1099511627776.0);
      const int start = int(3.7 * 60000000.0 / carrier);
      const int end = start + int(9.0 * 60000000.0 / carrier);
      encoder.COLORBURST_RANGE = (start << 10) | end;
      Range burst, gray, color, luma_gray, luma_red;
      int checks = 0;
      for (int line = 0; line < 32; ++line) {
        for (int t = 0; t < 3840; ++t) {
          // 280 clocks sync, 280 back porch, 3200 active, 80 front porch.
          encoder.hsync = t < 280;
          encoder.vsync = 0;
          encoder.csync = encoder.hsync;
          encoder.de = t >= 560 && t < 3760;
          encoder.din = encoder.de ? (line < 16 ? 0x808080 : 0xC04040) : 0;
          encoder.clk = 0; encoder.eval();
          encoder.clk = 1; encoder.eval();
          const int chroma = (encoder.dout >> 16) & 255;
          const int luma = (encoder.dout >> 8) & 255;
          const int signal = cvbs ? luma : chroma;
          if (line > 0 && t >= 280 + start + 16 && t < 280 + end - 16)
            burst.add(signal);
          if (line > 1 && t >= 600 && t < 3700) {
            (line < 16 ? gray : color).add(signal);
            (line < 16 ? luma_gray : luma_red).add(luma);
            assert(encoder.de_o && !encoder.hsync_o);
            assert(!(encoder.dout & 255));
            if (cvbs) assert(chroma == 0);
            ++checks;
          }
          if (t >= 390 && t < 500)
            assert(!encoder.de_o && !encoder.hsync_o);
        }
      }
      assert(burst.hi - burst.lo > 15);
      assert(color.hi - color.lo > 30);
      assert(gray.hi - gray.lo <= 2);
      if (!cvbs) {
        assert(gray.lo >= 126 && gray.hi <= 130);
        assert(luma_gray.hi - luma_gray.lo <= 1);
        assert(luma_red.hi - luma_red.lo <= 1);
        // Count the actual waveform, allowing for discontinuities between lines.
        const double measured = color.rising * 60000000.0 / color.samples;
        assert(std::abs(measured / carrier - 1.0) < 0.01);
      }
      std::printf("PASS %s %s: burst=%d..%d gray=%d..%d color=%d..%d active_samples=%d phase=%llu\n",
                  pal ? "PAL" : "NTSC", cvbs ? "CVBS" : "SVIDEO",
                  burst.lo, burst.hi, gray.lo, gray.hi, color.lo, color.hi,
                  checks, (unsigned long long)encoder.PHASE_INC);
    }
  }
}
