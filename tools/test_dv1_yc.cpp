// SPDX-License-Identifier: GPL-3.0-only
#include "Vdv1_yc_test.h"
#include "verilated.h"
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
struct Range {
  int lo=255, hi=0, count=0, rising=0, last=128;
  void add(int x) {lo=std::min(lo,x);hi=std::max(hi,x);count++;if(last<=128 && x>128)rising++;last=x;}
};
static void tick(Vdv1_yc_test &m) {m.clk_vid=0;m.eval();m.clk_vid=1;m.eval();}
struct Result {uint64_t digital=1469598103934665603ULL, analog=1469598103934665603ULL;};
static Result waveform(bool pal, bool change_analog, bool change_digital) {
  Vdv1_yc_test m;
  m.direct_video=1;m.nds_dv1_crt_target=1;m.nds_crt_active=1;m.nds_split_active=1;
  m.yc_en=1;m.cvbs=0;m.pal_en=pal;m.cfg=0;m.vga_fb=0;m.vga_scaler=0;
  m.nds_dv1_present=0;m.nds_dv1_ce=0;m.csync_en=1;
  const double carrier=pal?4433618.75:315000000.0/88.0;
  m.PhaseInc=std::llround(carrier/60000000.0*1099511627776.0);
  const int start=int(3.7*60000000.0/carrier), end=start+int(9.0*60000000.0/carrier);
  m.ColorBurst_Range=(start<<10)|end;
  Range burst, transmitted_burst, gray, color;Result r;int visible_burst=0, sync_checks=0;
  // Actual 3840-clock/262-line CRT raster. Three frames settle the transport's
  // measured vertical window. Analog has independent phase and pixel content.
  for(int f=0;f<4;f++)for(int line=0;line<262;line++)for(int t=0;t<3840;t++) {
    const int at=(t+1000)%3840;
    m.ce_pix=t%10==0;m.vga_hs_osd=t<280;m.vga_vs_osd=line>=250 && line<253;
    m.vga_cs_osd=m.vga_hs_osd^m.vga_vs_osd;
    m.vga_de_osd=line<240 && t>=560 && t<3760;
    const uint32_t digital=line<120?0x808080:(change_digital?0x40C040:0xC04040);
    m.vga_data_osd=m.vga_de_osd?digital:0;
    m.native_analog_hs=at<280;m.native_analog_vs=line>=245 && line<248;
    m.native_analog_cs=m.native_analog_hs^m.native_analog_vs;
    m.native_analog_de=line<240 && at>=560 && at<3760;
    m.native_analog_data=m.native_analog_de?(change_analog?0x4040C0:0x808080):0;
    tick(m);
    if(f==3) {
      r.digital=(r.digital^m.transport_data)*1099511628211ULL;
      r.analog=(r.analog^m.analog_data)*1099511628211ULL;
      if(line>10 && line<230 && t>=280+start+24 && t<280+end-24) {
        burst.add((m.routed_data>>16)&255);
        assert(m.transport_de && !m.transport_hs);
        transmitted_burst.add((m.transport_data>>16)&255);visible_burst++;
      }
      if(line>10 && line<230 && t>=620 && t<3700) {
        (line<120?gray:color).add((m.transport_data>>16)&255);
        assert(m.transport_de && !m.transport_hs && !(m.transport_data&255));
      }
      if(line<230 && t>=50 && t<250) {assert(m.transport_hs);sync_checks++;}
    }
  }
  assert(burst.hi-burst.lo>15 && transmitted_burst.hi-transmitted_burst.lo>15);
  assert(gray.hi-gray.lo<=2 && color.hi-color.lo>30);
  const double measured=color.rising*60000000.0/color.count;
  assert(std::abs(measured/carrier-1)<0.01);
  std::printf("PASS %s%s%s: transmitted burst %d..%d, color %d..%d, %.2f Hz, %d porch and %d sync samples\n",
      pal?"PAL-carrier":"NTSC",change_analog?" analog-changed":"",change_digital?" digital-changed":"",
      transmitted_burst.lo,transmitted_burst.hi,color.lo,color.hi,measured,visible_burst,sync_checks);
  return r;
}
static void gate() {
  Vdv1_yc_test m;m.PhaseInc=65593488409ULL;m.ColorBurst_Range=(62<<10)|213;
  m.vga_data_osd=0xAC4317;m.vga_hs_osd=0;m.vga_vs_osd=0;m.vga_cs_osd=1;m.vga_de_osd=1;
  m.native_analog_data=0x808080;m.native_analog_hs=0;m.native_analog_vs=0;m.native_analog_cs=0;m.native_analog_de=1;
  m.ce_pix=1;m.nds_dv1_present=0;m.csync_en=1;m.pal_en=0;
  for(unsigned b=0;b<1024;b++) {
    m.direct_video=b&1;m.nds_dv1_crt_target=(b>>1)&1;m.nds_crt_active=(b>>2)&1;
    m.nds_split_active=(b>>3)&1;m.yc_en=(b>>4)&1;m.cvbs=(b>>5)&1;
    m.vga_fb=(b>>6)&1;m.vga_scaler=(b>>7)&1;m.cfg=((b>>8)&1)<<7|((b>>9)&1)<<13;
    for(int i=0;i<32;i++)tick(m);
    const bool encoded=(b&31)==31 && !(b&992);
    if(encoded)assert(m.routed_data!=m.vga_data_osd && m.routed_data!=m.analog_data && !(m.routed_data&255));
    else if(!m.nds_split_active && m.yc_en)assert(m.routed_data==m.analog_data && !m.routed_cs);
    else assert(m.routed_data==m.vga_data_osd && m.routed_cs);
  }
  std::puts("PASS 1024 routing cases: CRT/Scaler, RGB/Y-C/CVBS, DV1/DVI/DV2, native/scaled, split/legacy");
}
int main(int argc,char **argv) {
  Verilated::commandArgs(argc,argv);gate();
  for(bool pal:{false,true}) {
    auto base=waveform(pal,false,false), a=waveform(pal,true,false), d=waveform(pal,false,true);
    assert(base.digital==a.digital && base.analog!=a.analog);
    assert(base.analog==d.analog && base.digital!=d.digital);
  }
  std::puts("PASS independent pictures: changing either source leaves the other encoded waveform byte-exact");
}
