// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
  static void run(const fs::path &root) {
    fs::create_directories(root / "kit");
    fs::create_directories(root / "sd");
    Host h((root / "kit").string(), (root / "sd/games/NDS").string(), root / "sd");
    h.status=REQUIRED_STATUS | CRT_TIMING | (2u<<5);
    h.cursor=Host::SPLIT_CURSOR;
    const auto before=h.status;
    h.action(2);
    assert(h.status==before && h.message=="Core lacks split output support");
    h.spi.response=[](uint32_t, uint16_t cmd, size_t index, uint16_t) {
      if(cmd!=0x46) return uint16_t(0);
      return uint16_t(index==0 ? 0x4456 : index==1 ? 0 : 0x5350);
    };
    // A saved split selection was initially masked before capability discovery.
    // Discovery must apply it without requiring a menu change or a DS reset,
    // including ordinary HDMI where the DV1 metadata flag is absent.
    h.status = before | INDEPENDENT_OUTPUTS | ANALOG_TOUCH;
    h.sendstatus();
    assert(!(h.spi.history.back().words[0] & INDEPENDENT_OUTPUTS));
    h.spi.history.clear();
    h.initializeVideoMetadata();
    assert(h.independent_outputs_supported);
    assert(h.spi.history.back().command == 0x1e);
    assert(h.spi.history.back().words[0] == h.status);
    assert(!h.direct_video_metadata);
    h.status = before;
    h.spi.response={};
    h.action(2);
    assert(h.status & INDEPENDENT_OUTPUTS);
    h.cursor=Host::ANALOG_CURSOR;h.action(2);
    assert(h.status & ANALOG_TOUCH);
    for(unsigned layout=0;layout<4;++layout) {
      for(unsigned analog=0;analog<2;++analog) {
        h.status=REQUIRED_STATUS|CRT_TIMING|INDEPENDENT_OUTPUTS|(layout<<5)|(analog<<15);
        h.screen_peek=false;h.sendstatus();
        const auto saved=h.status;
        assert(((saved>>5)&3)==layout); // CRT guard applies only to analog.
        h.screen_peek=true;
        const auto live=h.liveStatus();
        assert(((live>>15)&1)==(analog^1));
        assert(((live>>5)&3)==(layout>=2 ? layout^1 : layout));
        assert(h.status==saved);
        h.saveSettings();
        Host reloaded((root/"kit").string(),(root/"sd/games/NDS").string(),root/"sd");
        assert(reloaded.status==saved && !reloaded.screen_peek);
        h.screen_peek=false;assert(h.liveStatus()==saved);
        h.cursor=2;h.draw();
        assert(h.osd_rows[3]==h.frame.renderRow(3,
            optionLabel(saved,{5,2,4,"Digital Layout",{"Side-by-side","Top/bottom","Main","Touch"}}),
            true,nds_osd::arrow_right));
        h.cursor=8;const auto timing=h.status;h.action(2);
        assert(h.status==timing); // analog always stays 240p in this mode.
      }
    }
    // Normal single-screen CRT still rejects a stacked electrical raster.
    h.status=REQUIRED_STATUS|CRT_TIMING|(1u<<5);h.sendstatus();
    assert(((h.status>>5)&3)==2);
    std::cout << "PASS: split capability, all digital/analog choices, combined-layout preservation, temporary Peek, saved selection and fixed CRT timing\n";
  }
};
int main() {
  char path[]="/tmp/nds-split-host-XXXXXX";
  assert(mkdtemp(path));
  HostTest::run(path);fs::remove_all(path);
}
