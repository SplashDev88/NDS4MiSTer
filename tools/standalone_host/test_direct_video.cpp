// SPDX-License-Identifier: GPL-3.0-only
#include "direct_video.h"
#include "menu_model.h"
#include <cassert>
#include <iostream>
#include <vector>
struct Spi {
  static constexpr uint32_t IO=1;
  std::vector<uint16_t> words;
  size_t i=0;
  bool ended=false;
  void begin(uint32_t target,uint16_t cmd) { assert(target==IO && cmd==0x23); }
  uint16_t word(uint16_t value) { assert(!value); return words.at(i++); }
  void end() { ended=true; }
};
struct CapabilitySpi {
  static constexpr uint32_t IO=1;
  uint16_t signature=0x4456, split=0x5350, native=0x5350;
  unsigned i=0;
  bool ended=false;
  uint16_t begin(uint32_t target,uint16_t cmd) { assert(target==IO && cmd==0x46); return signature; }
  uint16_t word(uint16_t value) { assert(!value); return ++i==1 ? 0x400 : i==2 ? split : native; }
  void end() { ended=true; }
};
int main() {
  // Hardware video_calc words: flags; seven little-endian 32-bit values;
  // pixel repetition, DE offset in video clocks, DE offset in lines.
  Spi spi{{0,320,0,240,0,6400,0,0x1234,25,5333,0,0x2345,25,3200,0,10,280,15}};
  auto g=nds_video::readGeometry(spi);
  assert(spi.ended && spi.i==18 && g.valid());
  assert(g.width==320 && g.height==240 && g.repeat==10 && g.left==280 && g.top==15);
  auto p=g.packet(false);
  const std::array<uint8_t,31> expected{{0x83,1,25,0,'D','V','1',0,10,24,1,15,0,64,1,240,0,'N','D','S'}};
  assert(p==expected);
  nds_video::StablePacket tracker;
  assert(!tracker.ready(g,false,p));
  assert(tracker.ready(g,false,p)); tracker.acknowledge(p);
  assert(!tracker.ready(g,false,p));
  assert(tracker.ready(g,true,p) && p[7]==4); tracker.acknowledge(p);
  assert(!tracker.ready(g,true,p));
  for (uint16_t word : {0u,0x5350u,0x4e50u,0x4e51u,0xffffu}) {
    CapabilitySpi cap;cap.native=word;
    assert(nds_video::readNativeMenuPixels(cap)==(word==0x4e51));
    assert(cap.ended && cap.i==3);
  }
  for (unsigned fault : {0u,1u}) {
    CapabilitySpi cap;cap.native=0x4e51;
    if(fault==0) cap.signature=0; else cap.split=0;
    assert(!nds_video::readNativeMenuPixels(cap));
  }
  // A new raster preserves crop/repetition and removes the legacy OSD
  // decimation override. Mode changes need two matching observations.
  g.native_menu_pixels=true;
  assert(!tracker.ready(g,true,p));
  assert(tracker.ready(g,true,p) && p==expected);tracker.acknowledge(p);
  assert(!tracker.ready(g,false,p));
  assert(!tracker.ready(g,true,p));
  g.native_menu_pixels=false;
  assert(!tracker.ready(g,true,p));
  assert(tracker.ready(g,true,p) && p[7]==4);tracker.acknowledge(p);
  g.width=520; g.height=192; g.repeat=6; g.left=336;
  assert(!tracker.ready(g,false,p));
  assert(tracker.ready(g,false,p) && p[13]==8 && p[14]==2 && p[8]==6);
  // A failed write stays pending. Invalid/transient measurements break stability.
  assert(tracker.ready(g,false,p));
  auto invalid=g; invalid.repeat=0;
  assert(!tracker.ready(invalid,false,p));
  assert(!tracker.ready(g,false,p)); assert(tracker.ready(g,false,p));
  assert((cleanStatus(CRT_TIMING | (1u<<5)) & (3u<<5))==(2u<<5));
  assert((cleanStatus(CRT_TIMING | (3u<<5)) & (3u<<5))==(3u<<5));
  std::cout << "PASS: DV1 wire format, SPI measurement order, stable changes, OSD flags, retries and CRT layout normalization\n";
}
