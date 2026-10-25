// SPDX-License-Identifier: GPL-3.0-only
#include "fmv_castlevania.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <vector>
static std::vector<uint8_t> read(const char* path) {
  std::ifstream file(path,std::ios::binary);
  if (!file) throw std::runtime_error("fixture not readable");
  return {std::istreambuf_iterator<char>(file),{}};
}
static void require(bool value) {if (!value) throw std::runtime_error("patch contract failed");}
int main(int argc,char**argv) {
  if (argc!=3) return 2;
  const auto original=read(argv[1]), expected=read(argv[2]);
  const nds_fmv::Profile* selected=nullptr;
  for (const auto& profile:nds_fmv::profiles)
    if (!std::memcmp(original.data()+12,profile.code,4) && original[30]==profile.revision) selected=&profile;
  require(selected!=nullptr); const auto& p=*selected;
  auto copy=original;
  require(nds_fmv::apply(copy.data(),copy.size(),copy.size()));
  require(copy==expected);
  // The alternate-stride mode shares these literals with the patched mode.
  require(std::memcmp(copy.data()+p.offsets[0]+0x40,original.data()+p.offsets[0]+0x40,16)==0);
  require(std::memcmp(copy.data()+p.color,original.data()+p.color,0x8c4)==0);
  require(!nds_fmv::apply(copy.data(),copy.size(),copy.size()));
  require(copy==expected);
  for (const size_t offset:{size_t(12),size_t(0x1e),size_t(0x100),p.color,p.color+0x10ef,p.audio,p.audio+0x880,p.table,p.table+193}) {
    copy=original;copy[offset]^=1;const auto before=copy;
    require(!nds_fmv::apply(copy.data(),copy.size(),copy.size()));require(copy==before);
  }
  for (size_t i=0;i<nds_fmv::patches.size();++i) {
    const auto& patch=nds_fmv::patches[i];
    copy=original;copy[p.offsets[i]+patch.size-1]^=1;const auto before=copy;
    require(!nds_fmv::apply(copy.data(),copy.size(),copy.size()));require(copy==before);
  }
  copy=original;
  require(!nds_fmv::apply(copy.data(),512,copy.size()));require(copy==original);
  require(!nds_fmv::apply(copy.data(),p.color+0x10f0,copy.size()));require(copy==original);
  require(!nds_fmv::apply(copy.data(),p.offsets[1]+nds_fmv::patches[1].size-1,copy.size()));require(copy==original);
  require(!nds_fmv::apply(copy.data(),copy.size(),copy.size()-1));require(copy==original);
  require(!nds_fmv::apply(nullptr,0,0));
  std::cout<<"PASS: exact staged patch; revision/header/code/bounds guards; atomic rejection; idempotence\n";
}
