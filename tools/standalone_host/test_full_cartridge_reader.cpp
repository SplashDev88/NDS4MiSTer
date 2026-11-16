// SPDX-License-Identifier: GPL-3.0-only
// Supply a local >464 MiB cartridge with meaningful bytes in its tail.
// No cartridge data is embedded in or emitted by this test.
#include "rom_reader.h"
#include <cassert>
#include <iostream>
int main(int argc,char**argv){
  assert(argc==3);
  bool rejected=false;
  {RomReader old(argv[1]);try{old.size([]{});}catch(const std::exception&e){rejected=std::string(e.what()).find("FF padding")!=std::string::npos;}}
  assert(rejected);
  for(bool python:{false,true}){
    if(python)setenv("NDS_GUEST_PATCH_MANIFEST","/unqualified-manifest",1);
    RomReader reader(argv[1],python?argv[2]:"","off",true,true);
    const auto size=reader.size([]{});
    assert(reader.fullCartridge() && !reader.framed() && reader.transferBytes(size)==size);
    const int original=open(argv[1],O_RDONLY);assert(original>=0);
    std::array<unsigned char,262144> got,expected;
    uint64_t offset=0;
    while(offset<size){
      const auto n=reader.read(got.data(),std::min<uint64_t>(got.size(),size-offset),[]{});
      size_t off=0;
      while(off<n){auto part=pread(original,expected.data()+off,n-off,offset+off);assert(part>0);off+=part;}
      assert(std::memcmp(got.data(),expected.data(),n)==0);offset+=n;
    }
    reader.finish(size,[]{});close(original);
    if(python)unsetenv("NDS_GUEST_PATCH_MANIFEST");
    assert(!getenv("NDS_CART_SDRAM"));
    std::cout<<"PASS "<<(python?"Python fallback":"native")<<": original cartridge byte comparison "<<offset<<" bytes\n";
  }
}
