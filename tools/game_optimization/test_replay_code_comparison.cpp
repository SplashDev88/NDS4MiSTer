// SPDX-License-Identifier: GPL-3.0-or-later
#include "replay_code_comparison.h"
#include <filesystem>
#include <iostream>
#include <numeric>

int main(int argc,char** argv) {
 if(argc!=2)return 2;
 unsigned checks=0;
 auto check=[&](bool value){if(!value)throw std::runtime_error("comparison test failed");++checks;};
 auto rejects=[&](const auto& action){try{action();}catch(const std::exception&){++checks;return;}throw std::runtime_error("expected comparison rejection");};
 const auto path=std::filesystem::path(argv[1])/"synthetic overlay context.bin";
 std::vector<uint8_t> context(64);std::iota(context.begin(),context.end(),0);
 {std::ofstream out(path,std::ios::binary);out.write(reinterpret_cast<const char*>(context.data()),context.size());}
 const std::string first="02100010 1011121314151617 aaaaaaaaaaaaaaaa";
 const std::string second="02100028 28292a2b2c2d2e2f bbbbbbbbbbbbbbbb";
 auto overlay=[&](std::string patch,unsigned id=5,std::string base="02100000"){
  std::ostringstream row;row<<patch<<" overlay "<<id<<' '<<base<<' '<<std::quoted(path.string());return row.str();
 };
 auto load=[](const std::string& spec){ReplayCodeComparison c;std::istringstream input(spec);c.Load(input);return c;};
 auto c=load(overlay(first)+"\n"+overlay(second));
 std::vector<uint8_t> ram(0x400000,0x55);
 std::copy(context.begin(),context.end(),ram.begin()+0x100000);
 const auto original=ram;
 auto counts=c.Normalize(ram);check(counts.original==2&&counts.replacement==0&&counts.unmatchedOverlay==0);check(ram==original);
 std::fill_n(ram.begin()+0x100010,8,0xaa);std::fill_n(ram.begin()+0x100028,8,0xbb);
 counts=c.Normalize(ram);check(counts.replacement==2&&counts.original==0);check(ram==original);
 // Mutation outside declared code must prevent every normalization, even
 // when both replacement snippets still match at their reused addresses.
 ram[0x100001]^=1;std::fill_n(ram.begin()+0x100010,8,0xaa);std::fill_n(ram.begin()+0x100028,8,0xbb);
 auto unknown=ram;counts=c.Normalize(ram);check(counts.unmatchedOverlay==2&&counts.replacement==0);check(ram==unknown);
 ram.assign(0x400000,0);unknown=ram;counts=c.Normalize(ram);check(counts.unmatchedOverlay==2);check(ram==unknown);
 // Partial patch delivery is also unmatched and left visible.
 ram=original;std::fill_n(ram.begin()+0x100010,8,0xaa);unknown=ram;counts=c.Normalize(ram);check(counts.unmatchedOverlay==2);check(ram==unknown);
 auto main=load(first);ram=original;counts=main.Normalize(ram);check(counts.original==1);
 std::fill_n(ram.begin()+0x100010,8,0xaa);counts=main.Normalize(ram);check(counts.replacement==1);check(ram==original);
 ram[0x100010]=0;rejects([&]{main.Normalize(ram);});
 for(const auto& spec:std::vector<std::string>{"", "02000000 00 00", first+" extra", first+"\n"+first,
      overlay(first)+"\n"+overlay(second,6), overlay(first)+"\n"+second,
      overlay(first)+"\n"+overlay(second,5,"02100004"),
      overlay("02100040 1011121314151617 aaaaaaaaaaaaaaaa"),
      overlay("02100010 0000000000000000 aaaaaaaaaaaaaaaa"),
      overlay(first,5,"023ffff0"),
      first+" overlay 5 02100000 \"/missing/comparison-context\""})
  rejects([&]{load(spec);});
 std::vector<uint8_t> shortRam(16);rejects([&]{c.Normalize(shortRam);});
 std::istringstream again(first);rejects([&]{c.Load(again);});
 std::filesystem::remove(path);
 std::cout<<"PASS "<<checks<<" comparison checks\n";
}
