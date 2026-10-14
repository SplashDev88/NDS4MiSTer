// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>

struct HostTest {
  static void discover(Host &h, uint16_t flags) {
    h.spi.response = [flags](uint32_t, uint16_t command, size_t index, uint16_t) {
      if (command != 0x46) return uint16_t(0);
      return uint16_t(index == 0 ? 0x4456 : index == 1 ? flags : 0x5350);
    };
    h.initializeVideoMetadata();
  }
  static std::string bytes(const fs::path &p) {
    std::ifstream f(p, std::ios::binary);
    return {std::istreambuf_iterator<char>(f), {}};
  }
  static void run(const fs::path &root) {
    auto kit = root / "kit", sd = root / "sd";
    fs::create_directories(kit); fs::create_directories(sd);
    std::array<uint16_t,8> original{uint16_t(REQUIRED_STATUS | INDEPENDENT_OUTPUTS | (1u<<5)),1,2,3,4,5,6,7};
    std::ofstream(kit/"NDS_v1.CFG",std::ios::binary).write((const char*)original.data(), sizeof(original));
    const auto saved = bytes(kit/"NDS_v1.CFG");
    Host h(kit.string(), (sd/"games/NDS").string(), sd);
    // First status write, before flags discovery, never emits the saved 31kHz layout.
    const auto first = std::find_if(h.spi.history.begin(), h.spi.history.end(), [](const auto &t) { return t.command == 0x1e; });
    assert(first != h.spi.history.end());
    assert((first->words[0] & (CRT_TIMING | (1u<<6))) == (CRT_TIMING | (1u<<6)));
    discover(h, 1u<<10);
    assert(h.direct_video_crt && h.mainMenuRow(Host::DV_TARGET_CURSOR)<0);
    assert(h.status==original[0] && bytes(kit/"NDS_v1.CFG")==saved);
    assert(!fs::exists(kit/"NDS_video.cfg"));
    for(unsigned layout=0; layout<4; ++layout) for(unsigned order=0; order<2; ++order)
      for(unsigned analog=0; analog<2; ++analog) {
        h.status=REQUIRED_STATUS|INDEPENDENT_OUTPUTS|(layout<<5)|(order<<7)|(analog<<15)|(2u<<11)|(3u<<8)|(1u<<4);
        const auto selected=h.status;
        h.sendstatus();
        auto wire=h.liveStatus();
        assert((wire & (CRT_TIMING|(1u<<6)))==(CRT_TIMING|(1u<<6)));
        assert(((wire>>5)&3)==(layout>=2 ? layout : 2));
        assert((wire & ~(CRT_TIMING|(3u<<5)))==(selected & ~(CRT_TIMING|(3u<<5))));
        assert(h.status==selected);
        h.screen_peek=true;
        assert(h.liveStatus()==(wire^(1u<<5)^ANALOG_TOUCH));
        h.screen_peek=false; assert(h.liveStatus()==wire);
        // Both menu and mapped Cycle Video Layout remain restricted to one panel.
        h.cursor=2;h.action(2);assert((h.liveStatus()&(3u<<5))==((wire^(1u<<5))&(3u<<5)));
        h.action(7);assert((h.liveStatus()&(3u<<5))==(wire&(3u<<5)));
        h.status=selected;
        h.display_menu=true;h.cursor=Host::DV_TARGET_CURSOR;h.action(2);
        assert(!h.direct_video_crt && h.status==selected);
        assert(((h.liveStatus()>>5)&3)==layout);
        h.action(2);assert(h.direct_video_crt && h.status==selected);h.display_menu=false;
      }
    // Main keeps quick selectors; Direct Video Target lives in Display options.
    h.cursor=1;h.action(1);assert(h.cursor==2);
    h.action(1);assert(h.cursor==Host::ANALOG_CURSOR);
    h.action(1);assert(h.cursor==Host::DISPLAY_CURSOR);
    h.action(2);assert(h.display_menu && h.cursor==3);
    for(int i=0;i<5;++i)h.action(1);
    assert(h.cursor==Host::DV_TARGET_CURSOR && h.mainMenuRow(h.cursor)==7);
    h.direct_video_crt=false;h.draw();
    assert(h.osd_rows[6]==h.frame.renderRow(6,"",false,nds_osd::arrow_left));
    assert(h.osd_rows[7]==h.frame.renderRow(7," Direct Video Target: Scaler",true,nds_osd::arrow_left));
    h.saveSettings();
    assert(bytes(kit/"NDS_video.cfg")=="NDS-DirectVideo-v1\nretrotink\n");
    Host reloaded(kit.string(),(sd/"games/NDS").string(),sd);
    discover(reloaded,1u<<10);assert(!reloaded.direct_video_crt);
    for(unsigned i=1;i<8;++i)assert(reloaded.full_status[i]==original[i]);
    // Scaled HDMI/native analog are unaffected; no target row in their menu.
    for(auto flags : {uint16_t(0), uint16_t(1u<<2)}) {
      discover(h, flags); h.direct_video_crt=true;
      assert(h.mainMenuRow(Host::DV_TARGET_CURSOR)<0);
      for(unsigned layout=0;layout<4;++layout) {
        h.status=REQUIRED_STATUS|INDEPENDENT_OUTPUTS|(layout<<5);
        h.sendstatus();assert(((h.liveStatus()>>5)&3)==layout);
      }
    }
    // Actual mapped trigger path: repeated presses alternate only Main/Touch.
    discover(h,1u<<10);h.status=REQUIRED_STATUS|INDEPENDENT_OUTPUTS|(1u<<5);
    Pad p;p.id="dv-target";p.fd=open("/dev/null",O_RDONLY);p.map[13]=BTN_TR;
    h.pads.push_back(p);h.menu=false;
    for(unsigned i=0;i<8;++i) {
      h.key(h.pads[0],BTN_TR,true);h.key(h.pads[0],BTN_TR,false);
      assert(((h.liveStatus()>>5)&3)==(i%2 ? 2 : 3));
    }
    std::cout << "PASS: CRT-safe first write, all DV1 layouts/order/analog combinations, Peek, target persistence, menu order and firmware separator, HDMI/scaled VGA and mapped layout trigger\n";
  }
};
int main() {
  char path[]="/tmp/nds-target-XXXXXX";assert(mkdtemp(path));
  HostTest::run(path);fs::remove_all(path);
}
