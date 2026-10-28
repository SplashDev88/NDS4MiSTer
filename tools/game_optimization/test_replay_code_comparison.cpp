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
 const std::string snippet="1011121314151617",changed="101112131415aa17";
 const std::string stage="02300010 "+snippet+' '+changed+" autoload mainram";
 const std::string loaded="037f8010 "+snippet+' '+changed+" autoload sharedwram";
 const std::string privateCode="03800010 "+snippet+' '+changed+" autoload arm7wram";
 auto autoload=load(stage+'\n'+loaded+'\n'+privateCode);check(autoload.HasAutoload());check(!c.HasAutoload());
 std::vector<uint8_t> shared(0x8000),privateRam(0x10000);ram.assign(0x400000,0);
 auto place=[&](std::vector<uint8_t>& memory,size_t at,const std::string& bytes){auto v=ReplayCodeComparison::Hex(bytes);std::copy(v.begin(),v.end(),memory.begin()+at);};
 place(ram,0x300010,snippet);place(shared,0x10,snippet);place(privateRam,0x10,snippet);
 auto originalMain=ram,originalShared=shared,originalPrivate=privateRam;
 counts=autoload.Normalize(ram,&shared,&privateRam);check(counts.original==3&&counts.unmatchedAutoload==0);
 check(ram==originalMain&&shared==originalShared&&privateRam==originalPrivate);
 place(ram,0x300010,changed);place(shared,0x10,changed);place(privateRam,0x10,changed);
 counts=autoload.Normalize(ram,&shared,&privateRam);check(counts.replacement==3);
 check(ram==originalMain&&shared==originalShared&&privateRam==originalPrivate);
 // Reused staging and a partial WRAM load must remain byte-for-byte raw.
 ram[0x300010]=0x99;shared[0x10]=0;place(privateRam,0x10,changed);
 auto reused=ram,partial=shared;counts=autoload.Normalize(ram,&shared,&privateRam);
 check(counts.unmatchedAutoload==2&&counts.replacement==1&&counts.unmatchedOverlay==0);
 check(ram==reused&&shared==partial&&privateRam==originalPrivate);
 // A changed byte outside the allowed change, within its context, prevents masking.
 place(shared,0x10,changed);shared[0x11]^=1;partial=shared;
 counts=autoload.Normalize(ram,&shared,&privateRam);check(counts.unmatchedAutoload==2);check(shared==partial);
 rejects([&]{autoload.Normalize(ram);});rejects([&]{autoload.Normalize(ram,&shared);});
 std::vector<uint8_t> badShared(0x7fff),badPrivate(0x10001);
 rejects([&]{autoload.Normalize(ram,&badShared,&privateRam);});
 rejects([&]{autoload.Normalize(ram,&shared,&badPrivate);});
 for(const auto& spec:std::vector<std::string>{stage+" extra",loaded+"\n"+loaded,
      "037f8010 "+snippet+' '+changed+" autoload mainram",
      "02300010 "+snippet+' '+changed+" autoload sharedwram",
      "037ffffc "+snippet+' '+changed+" autoload sharedwram",
      "0380fffc "+snippet+' '+changed+" autoload arm7wram",
      "03000010 "+snippet+' '+changed+" autoload sharedwram",
      "03800010 "+snippet+' '+changed+" autoload unknown",
      stage+'\n'+"02300014 "+snippet+' '+changed+" autoload mainram",
      loaded+'\n'+"037f8010 "+snippet+' '+changed})rejects([&]{load(spec);});
 std::filesystem::remove(path);
 std::cout<<"PASS "<<checks<<" comparison checks\n";
}
