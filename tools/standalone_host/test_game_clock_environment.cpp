// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise production localNow against libc timezone conversion without changing
// the computer's system time or timezone. Only this test executable overrides time.
#include "game_clock.h"
#include <cassert>
#include <cstdlib>
#include <iostream>
static std::time_t fixture;
extern "C" std::time_t time(std::time_t *out) noexcept {if(out)*out=fixture;return fixture;}
static void at(std::time_t value, const char *zone, nds_clock::Date expected) {
  fixture=value;assert(setenv("TZ",zone,1)==0);tzset();
  assert(nds_clock::localNow()==expected);
}
static void bad(std::time_t value) {
  fixture=value;bool threw=false;
  try{nds_clock::localNow();}catch(const std::runtime_error&){threw=true;}
  assert(threw);
}
int main() {
  at(1792000800LL,"UTC0",{26,10,14,3,18,0,0});
  at(1792000800LL,"CST6CDT,M3.2.0/2,M11.1.0/2",{26,10,14,3,13,0,0});
  at(1772956799LL,"CST6CDT,M3.2.0/2,M11.1.0/2",{26,3,8,0,1,59,59});
  at(1772956800LL,"CST6CDT,M3.2.0/2,M11.1.0/2",{26,3,8,0,3,0,0});
  at(1793516399LL,"CST6CDT,M3.2.0/2,M11.1.0/2",{26,11,1,0,1,59,59});
  at(1793516400LL,"CST6CDT,M3.2.0/2,M11.1.0/2",{26,11,1,0,1,0,0});
  setenv("TZ","UTC0",1);tzset();bad(-1);bad(0);bad(946684799);bad(4102444800LL);
  std::cout<<"PASS production localNow: UTC/local timezone, both DST boundaries, missing/before-2000/after-2099 clock\n";
}
