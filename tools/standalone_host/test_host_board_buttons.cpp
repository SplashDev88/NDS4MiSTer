// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>

struct HostTest {
  static std::string bytes(const fs::path &p) {
    std::ifstream f(p, std::ios::binary);
    return {std::istreambuf_iterator<char>(f), {}};
  }
  static void tap(Host &h, unsigned button) {
    h.boardButtons(button);
    h.boardButtons(button);
    h.boardButtons(0);
  }
  static void wizard(Host &h) {
    h.menu = h.system_menu = true;
    h.mapping_step = 0; h.mapping_pad.clear(); h.new_map.fill(0); h.cursor = 1;
  }
  static void run(const fs::path &root) {
    const auto kit = root / "kit", sd = root / "sd";
    fs::create_directories(kit / "inputs");
    fs::create_directories(sd / "config/inputs");
    fs::create_directories(sd / "saves/NDS");
    const auto private_map = kit / "inputs/NDS_input_controller-a_v3.map";
    const auto public_map = sd / "config/inputs/NDS_input_controller-a_v3.map";
    std::array<uint32_t,32> original{}; original.fill(0xbeef);
    for (const auto &p : {private_map,public_map})
      std::ofstream(p,std::ios::binary).write((const char*)original.data(),sizeof(original));
    const auto original_bytes = bytes(private_map);
    std::array<uint16_t,8> config{uint16_t(REQUIRED_STATUS | INDEPENDENT_OUTPUTS | CRT_TIMING | ANALOG_TOUCH),1,2,3,4,5,6,7};
    std::ofstream(kit/"NDS_v1.CFG",std::ios::binary).write((const char*)config.data(),sizeof(config));
    const auto config_bytes = bytes(kit/"NDS_v1.CFG");
    Host h(kit.string(), (sd/"games/NDS").string(), sd);
    h.menu = false;
    h.boardButtons(1); h.boardButtons(1); h.boardButtons(0);
    assert(!h.menu); // A button held across takeover does not become a click.
    h.boardButtons(1); assert(!h.menu);
    for(int i=0;i<1000;++i) h.boardButtons(1);
    assert(!h.menu); h.boardButtons(0); assert(h.menu);
    h.boardButtons(0); assert(h.menu);
    tap(h,1); assert(!h.menu);
    tap(h,1); assert(h.menu);
    h.spi.history.clear(); tap(h,2);
    assert(h.menu && h.spi.history.empty()); // USER is not another OSD button.

    wizard(h); h.spi.history.clear();
    h.boardButtons(2);
    for(int i=0;i<1000;++i) h.boardButtons(2);
    assert(h.mapping_step==0);
    h.boardButtons(0);
    assert(h.mapping_step==1 && h.new_map[0]==0 && h.mapping_pad.empty());
    h.boardButtons(0); assert(h.mapping_step==1);
    for(unsigned i=1;i<Host::button_names.size();++i) tap(h,2);
    assert(h.mapping_step==-1 && bytes(private_map)==original_bytes);
    assert(!fs::exists(kit/"inputs/NDS_input__v3.map"));
    assert(h.spi.history.empty()); // No reset, video flags, or game input.

    Pad a; a.id="controller-a"; a.map=original;
    Pad b; b.id="controller-b"; b.map=original;
    h.pads.push_back(a); h.pads.push_back(b);
    wizard(h); tap(h,2); // The first real input, not USER, selects a device.
    h.key(h.pads[0],BTN_SOUTH,true); h.key(h.pads[0],BTN_SOUTH,false);
    assert(h.mapping_pad==a.id && h.mapping_step==2 && h.new_map[1]==BTN_SOUTH);
    h.key(h.pads[1],BTN_EAST,true); h.key(h.pads[1],BTN_EAST,false);
    assert(h.mapping_step==2); // Other pads cannot steal a started mapping.
    h.key(h.pads[1],KEY_SPACE,true); h.key(h.pads[1],KEY_SPACE,false);
    assert(h.mapping_step==3 && h.new_map[2]==0);
    while(h.mapping_step<int(Host::button_names.size())-1) tap(h,2);
    h.new_map[Host::SCREEN_PEEK_BUTTON]=BTN_TR;
    tap(h,2); // Final USER skip commits exactly the selected controller.
    assert(h.mapping_step==-1 && h.pads[0].map[1]==BTN_SOUTH);
    assert(!h.pads[0].map[Host::SCREEN_PEEK_BUTTON] && !h.pads[0].map[Host::RESERVED_LID_SLOT]);
    assert(h.pads[1].map==original && bytes(public_map)==original_bytes);
    std::array<uint32_t,32> stored{};
    assert(Host::readmap(private_map,stored) && stored==h.pads[0].map);
    const auto committed = bytes(private_map);

    wizard(h); h.mapping_pad=a.id; h.new_map.fill(123);
    h.boardButtons(3); h.boardButtons(1);
    assert(h.mapping_step==0); h.boardButtons(0);
    assert(h.mapping_step==-1 && h.menu && h.system_menu && bytes(private_map)==committed);
    // Both release orders of the chord cancel once, never skip or close OSD.
    wizard(h); h.boardButtons(1); h.boardButtons(3); h.boardButtons(2); h.boardButtons(0);
    assert(h.mapping_step==-1 && h.menu && bytes(private_map)==committed);
    wizard(h); h.boardButtons(2); h.mapping_step=-1; h.boardButtons(0);
    assert(h.menu && bytes(private_map)==committed); // No cross-context release.
    h.menu=false; h.boardButtons(2); h.togglemenu(); h.boardButtons(0);
    assert(h.menu); // Keyboard opened OSD while USER was held; no reset.
    wizard(h); h.draw();
    assert(h.osd_rows[7]==h.frame.renderRow(7," Space/User: Skip",false,0));
    assert(h.osd_rows[8]==h.frame.renderRow(8," Esc/OSD: Cancel",false,0));
    tap(h,1); assert(h.mapping_step==-1 && h.menu);

    // Gameplay USER uses the real existing reset path, including matched-core
    // validation, built-in assets, reset pulse and neutralized held inputs.
    const auto save = sd/"saves/NDS/board-test.sav";
    std::ofstream(save,std::ios::binary) << "KEEP THIS SAVE";
    h.save=open(save.c_str(),O_RDWR); assert(h.save>=0);
    h.menu=false; h.lid_closed=true; h.pads[0].pressed[KEY_X]=true;
    h.spi.history.clear();
    h.boardButtons(2); assert(h.spi.history.empty());
    h.boardButtons(0);
    assert(!h.menu && !h.firmware_error_dialog && !h.lid_closed && !h.pads[0].pressed[KEY_X]);
    bool high=false,low=false,held=false,released=false;
    for(const auto &t : h.spi.history) {
      assert(t.command!=1); // Never rewrite Main's video/button configuration.
      if(t.command==0x1e) { if(t.words[0]&1) high=true; else if(high) low=true; }
      if(t.command==0x45 && t.words.size()>1) { held |= t.words[0]==1; released |= t.words[0]==3; }
    }
    assert(high && low && held && released && bytes(save)=="KEEP THIS SAVE");
    assert(bytes(kit/"NDS_v1.CFG")==config_bytes && bytes(public_map)==original_bytes);
    assert(bytes(private_map)==committed);
    std::cout << "PASS: OSD release/menu/cancel, USER single skip and gameplay reset, held/chord/context guards, map isolation, saved data and video flags preserved\n";
  }
};
int main() {
  char path[]="/tmp/nds-board-XXXXXX"; assert(mkdtemp(path));
  HostTest::run(path); fs::remove_all(path);
}
