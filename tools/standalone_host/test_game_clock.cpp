// SPDX-License-Identifier: GPL-3.0-or-later
#include "game_clock.h"
#include <cassert>
#include <iostream>
using namespace nds_clock;
template<class F> void rejects(F f) {bool bad=false;try{f();}catch(const std::exception&){bad=true;}assert(bad);}
int main() {
  // Every midnight in the DS's century, independently advanced by civil fields.
  Date expected{0,1,1,6,0,0,0};
  for(int64_t t=0;t<century_seconds;t+=86400) {
    assert(date(t)==expected);assert(seconds(expected)==t);
    assert(unpack(pack(expected))==expected);
    expected[3]=(expected[3]+1)%7;
    if(++expected[2]>monthDays(expected[0],expected[1])) {
      expected[2]=1;if(++expected[1]>12){expected[1]=1;++expected[0];}
    }
  }
  assert((date(-1)==Date{99,12,31,5,23,59,59}));
  assert((date(century_seconds)==Date{0,1,1,5,0,0,0}));
  assert((date(60)==Date{0,1,1,6,0,1,0}));
  assert((date(12*3600+34*60+56)==Date{0,1,1,6,12,34,56}));
  const Date now{26,10,14,3,13,15,42}, edited{45,2,28,1,23,59,59};
  const auto saved=Offset::between(edited,now);
  assert(saved.apply(now)==edited);
  assert(Offset::parse(saved.serialize()).apply(date(seconds(now)+2))==(Date{45,3,1,2,0,0,1}));
  assert(Offset{}.apply(now)==now);
  rejects([]{unpack({0x26,0x02,0x29,0,0,0,0,0});});
  rejects([]{unpack({0x26,0x10,0x1a,0,0,0,0,0});});
  rejects([]{unpack({0x26,0x10,0x14,7,0,0,0,0});});
  rejects([]{unpack({0x26,0x10,0x14,3,0x24,0,0,0});});
  for(const auto &bad:{"","NDS-RTC-v1\n0","NDS-RTC-v1\n0\n7\n","NDS-RTC-v1\n0\n-1\n",
      "NDS-RTC-v1\n3155760000\n0\n","NDS-RTC-v1\n-3155760000\n0\n","NDS-RTC-v1\n0\n0\nextra"})
    rejects([&]{Offset::parse(bad);});
  std::cout<<"PASS 36525 civil days, BCD validation, 2099 wrap, offline elapsed time and persistent offsets beyond 2038\n";
}
