// SPDX-License-Identifier: GPL-3.0-only
#define STANDALONE_TEST
#define main standalone_unused_main
#include "host.cpp"
#undef main
#include <cassert>
#include <iostream>
struct HostTest {
  static void run() {
    const auto root=fs::temp_directory_path()/("nds-host-framed-"+std::to_string(getpid()));
    const auto kit=root/"kit",sd=root/"sd",rom=sd/"games/NDS/framed.nds";
    fs::create_directories(kit/"fmv");fs::create_directories(rom.parent_path());
    std::string bytes(1024,'x');bytes.replace(12,4,"BMTE");bytes[30]=0;
    std::ofstream(rom,std::ios::binary).write(bytes.data(),bytes.size());
    std::ofstream(kit/"fmv/stream.py")<<R"PY(import os,sys,struct
src,dst,parent=map(int,sys.argv[1:]);data=os.pread(src,1024,0)
def record(at,n,op):os.write(dst,struct.pack('<Qii',at,n,op))
record(1024,0,9);record(0,1024,10);os.write(dst,data);record(1024,0,7);record(0,0,11)
if os.environ['NDS_FRAMED_TEST_CASE']=='ok':record(1024,0,8)
)PY";
    setenv("NDS_FMV_AUTO","1",1);
    Host h(kit.string(),rom.parent_path().string(),sd);
    for(const char* mode:{"late","ok"}) {
      setenv("NDS_FRAMED_TEST_CASE",mode,1);h.spi.history.clear();running=1;
      bool complete=false;try{h.load(rom.string());complete=true;}catch(const std::runtime_error&){}
      const bool success=std::string(mode)=="ok";assert(complete==success);
      uint16_t index=0;bool released=false;
      for(const auto&t:h.spi.history) {
        if(t.select==Spi::FIO && t.command==0x55)index=t.words.at(0);
        if(t.select==Spi::FIO && t.command==0x53 && (index&255)==3 && t.words==std::vector<uint16_t>{0})released=true;
      }
      assert(released==success && RomMapping::test_live_mappings==0);
      if(success)assert(h.game==rom && h.loading_progress==167);
      else assert(h.game.empty() && h.loading_progress<167 && !fs::exists(sd/"saves/NDS/framed.sav"));
    }

    // Exercise writes crossing both physical aperture boundaries. The scaler,
    // Linux console framebuffer and TATE hole must retain their sentinels.
    const auto mapped=root/"mapped-memory";
    const int memory=open(mapped.c_str(),O_RDWR|O_CREAT|O_TRUNC,0600);assert(memory>=0);
    assert(ftruncate(memory,0x40000000)==0);
    const std::string sentinel(32,'S');
    for(off_t at:{off_t(0x20000000),off_t(0x22000000),off_t(0x24000000)})
      assert(pwrite(memory,sentinel.data(),sentinel.size(),at)==ssize_t(sentinel.size()));
    RomMapping::test_memory_fd=memory;RomMapping::test_iomem_path=(root/"iomem").string();
    std::ofstream(RomMapping::test_iomem_path)<<"00000000-1fefffff : System RAM\n";
    std::ofstream(kit/"fmv/stream.py")<<R"PY(import os,sys,struct
src,dst,parent=map(int,sys.argv[1:]);data=os.pread(src,1024,0)
def record(at,n,op):os.write(dst,struct.pack('<Qii',at,n,op))
record(512*1024*1024,0,9);record(0,1024,10);os.write(dst,data)
for at in [252*1024*1024-8,276*1024*1024-8]:
 record(at,32,10);os.write(dst,b'B'*32)
record(512*1024*1024,0,7);record(0,0,11);record(464*1024*1024,0,8)
)PY";
    h.spi.default_firmware_flags |= 0x4000;
    h.load(rom.string());assert(RomMapping::test_live_mappings==0 && h.loading_progress==167);
    char buffer[32];
    for(off_t at:{off_t(0x20000000),off_t(0x22000000),off_t(0x24000000)}) {
      assert(pread(memory,buffer,32,at)==32);assert(std::string(buffer,32)==sentinel);
    }
    for(off_t at:{off_t(0x3fbffff8),off_t(0x23fffff8)}) {
      assert(pread(memory,buffer,8,at)==8);assert(std::string(buffer,8)==std::string(8,'B'));
    }
    for(off_t at:{off_t(0x22800000),off_t(0x24400000)}) {
      assert(pread(memory,buffer,24,at)==24);assert(std::string(buffer,24)==std::string(24,'B'));
    }
    assert(pread(memory,buffer,32,0x2fffffe0)==32 && std::string(buffer,32)==std::string(32,char(0xff)));
    close(memory);RomMapping::test_memory_fd=-1;
    unsetenv("NDS_FMV_AUTO");unsetenv("NDS_FRAMED_TEST_CASE");fs::remove_all(root);
    std::cout<<"PASS actual framed Host::load holds CPU/save commit until completion and accepts clean retry\n";
  }
};
int main(){HostTest::run();}
