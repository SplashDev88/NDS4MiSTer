// SPDX-License-Identifier: GPL-3.0-only
#include "transport.h"
#include "../../src/replay/Hybrid3DMemoryMapping.h"
#include <fstream>
#include <iostream>
#include <iterator>
#include <filesystem>
using namespace fpga3d;
static void require(bool b,const char* m){if(!b)throw std::runtime_error(m);}
template<class T>std::vector<T> load(const std::string& p){
 std::ifstream f(p,std::ios::binary|std::ios::ate);require(bool(f),"missing fixture");auto n=f.tellg();
 require(n>=0 && n<10000000 && size_t(n)%sizeof(T)==0,"bad fixture");std::vector<T> result(size_t(n)/sizeof(T));f.seekg(0);f.read(reinterpret_cast<char*>(result.data()),n);return result;
}
int main(int argc,char** argv)try{
 require(argc==3,"usage: hardware_test fixture-directory count (renderer FPGA3D must be off)");
 std::ifstream pidfile("/tmp/nds-hybrid-3d-service.pid");int pid=0;pidfile>>pid;require(pid>1,"no renderer owner");
 std::ifstream ef("/proc/"+std::to_string(pid)+"/environ",std::ios::binary);
 require(bool(ef),"renderer environment inaccessible");std::string env((std::istreambuf_iterator<char>(ef)),{});
 require(env.find(std::string("NDS4MISTER_FPGA3D=0")+char(0))!=std::string::npos,"renderer must explicitly disable FPGA3D before diagnostic");
 nds4mister::h3d::memory::Mapping mapping("/dev/mem");bind(mapping.data(),mapping.publication_data(),true);
 require(available(),"accelerator unavailable/session mismatch");
 Frame frame;frame.deadlineMs=5000;std::vector<uint32_t> result(256*192);
 int count=std::stoi(argv[2]);require(count>=1&&count<=100,"fixture count");
 for(int j=0;j<count;j++){
  auto prefix=std::string(argv[1])+"/"+std::to_string(j);
  frame.commands=load<Command>(prefix+".commands");frame.textures=load<uint32_t>(prefix+".textures");auto expected=load<uint32_t>(prefix+".expected");
  require(frame.commands.size()<=MaxCommands && frame.textures.size()*4<=TextureBytes && expected.size()==result.size(),"fixture bounds");
  auto start=std::chrono::steady_clock::now();require(frame.submit(result.data(),256),"hardware submission failed");
  auto us=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count();
  for(size_t i=0;i<result.size();i++)if(result[i]!=expected[i]){
   std::cerr<<"MISMATCH fixture="<<j<<" pixel="<<i<<" expected="<<std::hex<<expected[i]<<" actual="<<result[i]<<"\n";
   return 2;
  }
  std::cout<<"HARDWARE_PASS fixture="<<j<<" pixels="<<result.size()<<" total_us="<<us<<" fps="<<1000000.0/us<<std::endl;
 }
 return 0;
}catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<std::endl;return 1;}
