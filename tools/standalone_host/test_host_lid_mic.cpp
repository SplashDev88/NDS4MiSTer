// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
  static void run(const fs::path &root) {
    const auto kit=root/"kit",sd=root/"sd";
    fs::create_directories(kit/"inputs"); fs::create_directories(sd/"config/inputs");
    Host h(kit.string(),(sd/"games/NDS").string(),sd);
    Pad p; p.id="lidmic"; p.fd=open("/dev/null",O_RDONLY);
    p.map[4]=BTN_SOUTH; p.map[14]=BTN_THUMBL|(uint32_t(BTN_THUMBR)<<16); p.map[15]=BTN_TL2;
    h.pads.push_back(p); auto &pad=h.pads[0];
    assert(!h.lid_closed && h.lastjoy==0 && h.menu);
    const auto saved=h.status;
    h.menu=false;
    h.key(pad,BTN_THUMBL,true); assert(h.lid_closed && h.lastjoy==Host::LID_MASK);
    h.key(pad,BTN_THUMBL,true); h.key(pad,BTN_THUMBR,true);
    h.key(pad,BTN_THUMBL,false); assert(h.lid_closed);
    h.key(pad,BTN_THUMBR,false); assert(h.lid_closed);
    h.key(pad,BTN_SOUTH,true); h.key(pad,BTN_TL2,true); h.inputs();
    assert(h.lastjoy==(Host::LID_MASK|Host::MIC_MASK|16));
    h.togglemenu(); assert(h.menu && h.lastjoy==Host::LID_MASK);
    h.inputs(); assert(h.lastjoy==Host::LID_MASK); // Menus silence mic, retain closed lid.
    h.key(pad,BTN_THUMBL,true); assert(h.lid_closed); // Menu ignores mapped toggle.
    h.key(pad,BTN_THUMBL,false);
    h.cursor=7; h.action(2); assert(!h.lid_closed && h.menu && !h.lastjoy);
    h.action(2); assert(h.lid_closed && h.lastjoy==Host::LID_MASK);
    h.draw(); assert(h.status==saved); // Lid isn't a saved display/status option.
    h.togglemenu(); h.inputs(); assert(h.lastjoy==(Host::LID_MASK|Host::MIC_MASK|16));
    h.key(pad,BTN_TL2,false); h.inputs(); assert(h.lastjoy==(Host::LID_MASK|16));
    h.key(pad,KEY_F10,true); assert(!h.lid_closed);
    h.key(pad,KEY_F10,false); h.key(pad,KEY_F11,true); h.inputs();
    assert(h.lastjoy==(Host::MIC_MASK|16));
    h.key(pad,KEY_F11,false); h.inputs(); assert(h.lastjoy==16);
    h.key(pad,KEY_F10,true); h.key(pad,KEY_F11,true); h.inputs();
    assert(h.lid_closed && (h.lastjoy&Host::MIC_MASK));
    h.clearConsoleInputs(); h.inputs();
    assert(!h.lid_closed && !h.lastjoy && !pad.joy);
    for (bool pressed : pad.pressed) assert(!pressed);
    // Actual reset and load paths clear state; a later launch also starts open.
    h.key(pad,KEY_F10,true); h.key(pad,KEY_F11,true); h.inputs();
    h.reset(); h.inputs(); assert(!h.lid_closed && !h.lastjoy);
    RomMapping::test_iomem_path=(root/"iomem").string();
    std::ofstream(RomMapping::test_iomem_path)<<"00000000-1fefffff : System RAM\n";
    const auto rom=root/"test.nds"; std::ofstream(rom)<<std::string(512,'x');
    h.key(pad,KEY_F10,true); h.key(pad,KEY_F11,true); h.inputs();
    h.load(rom.string()); h.inputs(); assert(!h.lid_closed && !h.lastjoy);
    // Dropped evdev events cannot leave a held mic behind.
    close(pad.fd); int fds[2]; assert(pipe(fds)==0); pad.fd=fds[0];
    fcntl(pad.fd,F_SETFL,O_NONBLOCK); h.key(pad,KEY_F11,true); h.inputs();
    assert(h.lastjoy==Host::MIC_MASK);
    input_event e{}; e.type=EV_SYN; e.code=SYN_DROPPED;
    assert(write(fds[1],&e,sizeof(e))==sizeof(e)); h.inputs();
    assert(!h.lastjoy && !pad.joy); close(fds[1]);
    auto map=pad.map; map[13]=BTN_TR2; map[14]=BTN_THUMBL; map[15]=BTN_TL2;
    const auto name="NDS_input_lidmic_v3.map";
    h.atomicFile(sd/"config/inputs"/name,map.data(),sizeof(map));
    h.readCoreMap(pad,sd/"config/inputs");
    assert(pad.map[4]==BTN_SOUTH && !pad.map[13] && !pad.map[14] && !pad.map[15]);
    // Private maps preserve the layout shortcut and old empty optional slots.
    map[14]=map[15]=0; h.atomicFile(kit/"inputs"/name,map.data(),sizeof(map));
    h.readCoreMap(pad,sd/"config/inputs"); assert(pad.map==map);
    h.menu=true; h.mapping_step=14; h.mapping_pad=pad.id; h.new_map=map;
    h.key(pad,BTN_THUMBL,true); h.key(pad,BTN_THUMBL,false);
    h.key(pad,BTN_TL2,true); h.key(pad,BTN_TL2,false);
    assert(h.mapping_step==-1 && pad.map[13]==BTN_TR2 && pad.map[14]==BTN_THUMBL && pad.map[15]==BTN_TL2);
    std::array<uint32_t,32> persisted{};
    assert(Host::readmap(kit/"inputs"/name,persisted) && persisted==pad.map);
    h.key(pad,KEY_F10,true); assert(!h.lid_closed); // Menu hotkey can't change lid.
    Host fresh(kit.string(),(sd/"games/NDS").string(),sd);
    assert(!fresh.lid_closed && !fresh.lastjoy && fresh.menu);
    std::cout<<"PASS lid mapping/menu/edge, mic hold/release, neutral input, reset/load/fresh launch, map compatibility\n";
  }
};
int main() {
  char dir[]="/tmp/nds-lid-mic-host-XXXXXX"; assert(mkdtemp(dir));
  HostTest::run(dir); fs::remove_all(dir);
}
