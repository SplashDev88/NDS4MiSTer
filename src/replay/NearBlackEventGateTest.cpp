// SPDX-License-Identifier: GPL-3.0-or-later
#include "replay/NearBlackEventGate.h"
#include <array>
#include <stdexcept>
#include <iostream>
int main() {
 using Gate = nds4mister::replay::NearBlackEventGate;
 using Event = Gate::Event;
 const auto require=[](bool value){if(!value)throw std::runtime_error("near-black trace gate failed");};
 std::array<std::uint32_t,256> row;row.fill(0xff000000u);
 require(nds4mister::replay::count_rgb_nonblack(row.data(),row.size())==0);
 row[4]=1;row[8]=0xff001000u;row[12]=0xff200000u;
 require(nds4mister::replay::count_rgb_nonblack(row.data(),row.size())==3);
 Gate gate;require(gate.observe(256,3)==Event::None);
 gate.arm(7,false);require(gate.observe(256,3)==Event::None);
 gate.arm(0,true);require(gate.observe(256,3)==Event::None);
 gate.arm(7,true);
 require(gate.observe(0,0)==Event::None); // ordinary both-screen fade
 require(gate.observe(256,33)==Event::None);
 for(unsigned i=1;i<=Gate::Limit;++i){
  require(gate.observe(190,3)==Event::Dark);
  require(gate.event_number()==i);
  gate.arm(7,true); // an unchanged cookie must not restart the event budget
  require(gate.observe(190,0)==Event::None);
  require(gate.observe(190,192)==Event::Recovery);
  require(gate.observe(190,192)==Event::None);
 }
 require(gate.observe(190,0)==Event::None);require(gate.observe(190,192)==Event::None);
 gate.arm(8,false);require(gate.observe(190,3)==Event::None);
 gate.arm(8,true);require(gate.observe(190,3)==Event::Dark);
 gate.arm(8,false);require(gate.observe(190,192)==Event::None);
 std::cout << "PASS: retained HUD detection, alpha masking, session arming, transitions and eight-event cap\n";
}
