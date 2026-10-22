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
  auto copy=original;
  require(nds_fmv::apply(copy.data(),copy.size(),copy.size()));
  require(copy==expected);
  // The alternate-stride mode shares these literals with the patched mode.
  require(std::memcmp(copy.data()+0xc59a0,original.data()+0xc59a0,16)==0);
  require(std::memcmp(copy.data()+0xc509c,original.data()+0xc509c,0x8c4)==0);
  require(!nds_fmv::apply(copy.data(),copy.size(),copy.size()));
  require(copy==expected);
  for (const size_t offset:{size_t(12),size_t(0x1e),size_t(0x100),size_t(0xc509c),size_t(0xc618b),size_t(0x5d4a0),size_t(0x5dd20),size_t(0x8a2d0),size_t(0x8a391)}) {
    copy=original;copy[offset]^=1;const auto before=copy;
    require(!nds_fmv::apply(copy.data(),copy.size(),copy.size()));require(copy==before);
  }
  for (const auto& patch:nds_fmv::patches) {
    copy=original;copy[patch.offset+patch.size-1]^=1;const auto before=copy;
    require(!nds_fmv::apply(copy.data(),copy.size(),copy.size()));require(copy==before);
  }
  copy=original;
  require(!nds_fmv::apply(copy.data(),512,copy.size()));require(copy==original);
  require(!nds_fmv::apply(copy.data(),0xc618c,copy.size()));require(copy==original);
  require(!nds_fmv::apply(copy.data(),0xc9d8f,copy.size()));require(copy==original);
  require(!nds_fmv::apply(copy.data(),copy.size(),copy.size()-1));require(copy==original);
  require(!nds_fmv::apply(nullptr,0,0));
  std::cout<<"PASS: exact staged patch; revision/header/code/bounds guards; atomic rejection; idempotence\n";
}
