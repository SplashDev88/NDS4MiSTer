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
  const auto transfer=[&](const std::string&directory,bool success,unsigned timeout=1000,
                         const std::string&mode=std::string(),bool movies=true) {
    RomReader r(path.string(),directory,mode,movies);unsigned services=0;
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
  setenv("NDS_NSMB_PATCH","both",1);
  transfer(argv[1],true); // Wrong cartridge size/hash must preserve the original.
  const auto marker=root/"nsmb-worker-called";
  std::ofstream(fake/"nsmb_stream.py")<<
    "import os,sys,struct\nfrom pathlib import Path\n"
    "src,dst,parent=map(int,sys.argv[1:])\n"
    "Path('"<<marker.string()<<"').write_text(os.environ['NDS_NSMB_PATCH'])\n"
    "data=os.pread(src,1024,0)\n"
    "os.write(dst,struct.pack('<Qii',1024,0,0));os.write(dst,data)\n"
    "os.write(dst,struct.pack('<Qii',1024,0,8))\n";
  transfer(fake.string(),true);assert(fs::exists(marker));fs::remove(marker);
  transfer(fake.string(),true,1000,"off");assert(!fs::exists(marker));
  assert(std::string(getenv("NDS_NSMB_PATCH"))=="both");
  transfer(fake.string(),true,1000,"lookup",false);assert(fs::exists(marker));fs::remove(marker);
  for(const char* mode:{"bones","lookup+bones","skip+bones","both+bones"}){
    transfer(fake.string(),true,1000,mode,false);
    std::ifstream file(marker);std::string selected;file>>selected;assert(selected==mode);
    fs::remove(marker);
    transfer(argv[1],true,1000,mode,false); // Unknown identity must return original bytes.
  }
  original.replace(12,4,"BMTE");
  std::ofstream(path,std::ios::binary|std::ios::trunc).write(original.data(),original.size());
  transfer(fake.string(),true,1000,"both",false); // Speed options cannot enable movies.
  original.replace(12,4,"A2DE");
  std::ofstream(path,std::ios::binary|std::ios::trunc).write(original.data(),original.size());
  for(const char* mode:{"off","invalid"}){
    setenv("NDS_NSMB_PATCH",mode,1);transfer(fake.string(),true);assert(!fs::exists(marker));
  }
  setenv("NDS_NSMB_PATCH","both",1);original[30]=1;
  std::ofstream(path,std::ios::binary|std::ios::trunc).write(original.data(),original.size());
  transfer(fake.string(),true);assert(!fs::exists(marker));
  unsetenv("NDS_NSMB_PATCH");
  std::cout<<"PASS NSMB experiment requires explicit mode and revision zero; failed identity keeps original bytes\n";
  fs::remove_all(root);
}
