// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#ifndef HOST_TEST_SOURCE
#define HOST_TEST_SOURCE "host.cpp"
#endif
#include HOST_TEST_SOURCE
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
  static void discover(Host &h, uint16_t flags = 0) {
    h.spi.response=[flags](uint32_t, uint16_t cmd, size_t index, uint16_t) {
      if(cmd!=0x46) return uint16_t(0);
      return uint16_t(index==0 ? 0x4456 : index==1 ? flags : 0x5350);
    };
    h.initializeVideoMetadata();
    assert(h.independent_outputs_supported);
    assert(h.spi.history.back().command == 0x1e);
    assert(h.spi.history.back().words[0] == h.liveStatus());
  }
  static std::string bytes(const fs::path &p) {
    std::ifstream f(p,std::ios::binary);
    return {std::istreambuf_iterator<char>(f),std::istreambuf_iterator<char>()};
  }
  static void run(const fs::path &root) {
    fs::create_directories(root / "kit");
    fs::create_directories(root / "sd");
    const auto cfg=root/"kit/NDS_v1.CFG";
    // Old default: Top/Bottom, CRT Off, split Off. Preserve all other words.
    std::array<uint16_t,8> words{uint16_t(REQUIRED_STATUS|(1u<<5)),1,2,3,4,5,6,7};
    std::ofstream(cfg,std::ios::binary).write((const char *)words.data(),sizeof(words));
    const auto original=bytes(cfg);
    Host h((root / "kit").string(), (root / "sd/games/NDS").string(), root / "sd");
    h.cursor=Host::SPLIT_CURSOR;
    const auto unsupported=h.status;
    h.action(2);
    assert(h.status==unsupported && h.message=="Core lacks split output support");
    discover(h);
    assert(h.status & INDEPENDENT_OUTPUTS); // Fails on the old CRT-Off startup.
    assert(((h.status>>5)&3)==1 && !(h.status & ANALOG_TOUCH));
    assert(h.full_status==words && bytes(cfg)==original); // No automatic disk rewrite.
    assert(!h.direct_video_metadata);

    // Upgrade every legacy layout/order/CRT combination without changing its
    // effective digital selection; analog retains the first/selected DS panel.
    for(unsigned crt=0;crt<2;++crt) for(unsigned layout=0;layout<4;++layout)
      for(unsigned order=0;order<2;++order) {
        auto old=cleanStatus(REQUIRED_STATUS|(crt<<13)|(layout<<5)|(order<<7)|
            (2u<<11)|(3u<<8)|(1u<<4));
        h.status=old;h.sendstatus();
        assert((h.status & ~(INDEPENDENT_OUTPUTS|ANALOG_TOUCH))==old);
        assert(bool(h.status & ANALOG_TOUCH)==((((old>>5)&3)==3)^bool(order)));
        assert(h.status & INDEPENDENT_OUTPUTS);
      }
    for(unsigned layout=0;layout<4;++layout) for(unsigned analog=0;analog<2;++analog) {
      h.status=REQUIRED_STATUS|CRT_TIMING|INDEPENDENT_OUTPUTS|(layout<<5)|(analog<<15);
      h.screen_peek=false;h.sendstatus();
      const auto saved=h.status;
      assert(((saved>>5)&3)==layout);
      h.screen_peek=true;
      const auto live=h.liveStatus();
      assert(((live>>15)&1)==(analog^1));
      assert(((live>>5)&3)==(layout>=2 ? layout^1 : layout));
      assert(h.status==saved);
      h.saveSettings();
      Host reloaded((root/"kit").string(),(root/"sd/games/NDS").string(),root/"sd");
      discover(reloaded);
      assert(reloaded.status==saved && !reloaded.screen_peek);
      for(unsigned i=1;i<8;++i)assert(reloaded.full_status[i]==words[i]);
      h.screen_peek=false;assert(h.liveStatus()==saved);
      h.cursor=2;h.draw();
      assert(h.osd_rows[3]==h.frame.renderRow(3,
          optionLabel(saved,{5,2,4,"Digital Layout",{"Side-by-side","Top/bottom","Main","Touch"}}),
          true,nds_osd::arrow_right));
      assert(h.osd_rows[10]==h.frame.renderRow(10," Analog Output:         240p",false,nds_osd::arrow_right));
      for(int cursor : {8,Host::SPLIT_CURSOR}) {
        h.cursor=cursor;h.action(2);assert(h.status==saved);
      }
    }
    const std::array<int,12> order{0,1,2,3,4,5,6,7,13,9,10,11};
    h.cursor=0;
    for(unsigned i=1;i<=order.size();++i){h.action(1);assert(h.cursor==order[i%order.size()]);}
    for(unsigned i=1;i<=order.size();++i){h.action(0);assert(h.cursor==order[(order.size()-i)%order.size()]);}
    // vga_scaler is an explicit computer-monitor mode, not native 240p.
    // Keep the digital layout and don't offer an ineffective Analog Screen row.
    discover(h,1u<<2);h.status=REQUIRED_STATUS|INDEPENDENT_OUTPUTS|(1u<<5);h.sendstatus();
    h.cursor=2;h.draw();
    assert(((h.status>>5)&3)==1);
    assert(h.mainMenuRow(Host::ANALOG_CURSOR)<0);
    assert(h.osd_rows[10]==h.frame.renderRow(10," Analog Output:  HDMI scaler",false,nds_osd::arrow_right));
    h.cursor=7;h.action(1);assert(h.cursor==Host::LID_CURSOR);
    const auto scaled=h.status;h.cursor=Host::ANALOG_CURSOR;h.action(2);assert(h.status==scaled);
    // Regression from the rig: a saved CRT-On bit must not override the
    // selected digital layout when the FPGA disables split for vga_scaler.
    for(unsigned crt=0;crt<2;++crt) for(unsigned layout=0;layout<4;++layout) {
      h.status=REQUIRED_STATUS|INDEPENDENT_OUTPUTS|ANALOG_TOUCH|(crt<<13)|(layout<<5);
      const auto saved=h.status;
      for(bool peek : {false,true}) {
        h.screen_peek=peek;h.sendstatus();
        const auto wire=h.spi.history.back().words[0];
        assert(!(wire & CRT_TIMING));
        // Model the FPGA's NDS_NATIVE_OUTPUT_ALLOWED=0 path: split is ignored.
        const auto effective=normalizeDisplayStatus(wire & ~INDEPENDENT_OUTPUTS);
        assert(((effective>>5)&3)==(peek && layout>=2 ? layout^1 : layout));
        assert(h.status==saved);
      }
      h.screen_peek=false;h.saveSettings();
      const auto cfg_status=uint16_t(uint8_t(bytes(cfg)[0])|(uint8_t(bytes(cfg)[1])<<8));
      assert(cfg_status==saved);
    }
    // Explicit Reset settings also returns to automatic independent output.
    h.reset_confirm=true;h.cursor=0;h.action(2);
    assert(h.status & INDEPENDENT_OUTPUTS);
    assert(uint16_t(uint8_t(bytes(cfg)[0])|(uint8_t(bytes(cfg)[1])<<8)) & INDEPENDENT_OUTPUTS);
    std::cout << "PASS: automatic independent startup, legacy migration, unchanged config until save, preserved digital layouts/settings, analog selection, Peek, menu navigation, scaled VGA and reset\n";
  }
};
int main() {
  char path[]="/tmp/nds-split-host-XXXXXX";
  assert(mkdtemp(path));
  HostTest::run(path);fs::remove_all(path);
}
