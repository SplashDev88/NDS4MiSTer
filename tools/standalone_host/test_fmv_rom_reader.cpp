// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#include "rom_reader.h"
#include <cassert>
#include <filesystem>
#include <fstream>
#include <iostream>
namespace fs=std::filesystem;
int main(int argc,char**argv) {
  assert(argc==2);
  const auto root=fs::temp_directory_path()/"nds-fmv-reader-test";
  fs::remove_all(root);fs::create_directories(root);
  const auto path=root/"original name.nds";
  std::string original(1024,'x');original.replace(12,4,"BMTE");original[30]=0;
  std::ofstream(path,std::ios::binary).write(original.data(),original.size());
  const auto transfer=[&](const std::string&directory,bool success,unsigned timeout=1000) {
    RomReader r(path.string(),directory);unsigned services=0;
    const auto service=[&]{++services;};
    const auto n=r.size(service,timeout);assert(n==original.size());
    std::string got(n,'\0');size_t off=0;
    while(off<n)off+=r.read(got.data()+off,n-off,service,timeout);
    assert(got==original);
    bool done=false;try{r.finish(n,service,timeout);done=true;}catch(const std::exception&){}
    assert(done==success && services>0);
  };
  transfer(argv[1],true);
  std::cout<<"PASS paired Python reader falls back without changing unknown ROM\n";
  const auto fake=root/"fake";fs::create_directories(fake);
  std::ofstream(fake/"stream.py")<<R"PY(import os,sys,struct,time
src,dst,parent=map(int,sys.argv[1:]);data=os.pread(src,1024,0)
for i in range(12):
 os.write(dst,struct.pack('<Qii',i,0,7));time.sleep(.02)
os.write(dst,struct.pack('<Qii',1024,0,0));os.write(dst,data)
# Simulate late validation failure: all bytes arrived but no commit marker.
)PY";
  transfer(fake.string(),false,100);
  std::cout<<"PASS slow preparation services heartbeat; incomplete stream cannot commit\n";
  // Unrecognized games must not start even an invalid optional worker.
  original.replace(12,4,"A2DE");
  std::ofstream(path,std::ios::binary|std::ios::trunc).write(original.data(),original.size());
  transfer("/missing-worker",true);
  std::cout<<"PASS unrelated game retains native ROM reader\n";
  fs::remove_all(root);
}
