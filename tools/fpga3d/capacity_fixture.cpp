// SPDX-License-Identifier: GPL-3.0-only
#include "abi.h"
#include <fstream>
#include <string>
#include <cstdio>
using namespace fpga3d;
int main(int argc,char** argv){
 if(argc!=2)return 2;
 std::vector<Command> commands;
 for(unsigned y=0;y<192;y++){
  commands.push_back(clear(y,0x1f102030,0xffffff));
  for(unsigned k=0;k<40+(y<64);k++){
   Span s;s.first=0;s.end=1;s.width=1;s.alphaRef=31;s.flags=Linear|(y&1?WBuffer:0);
   s.z0=0xffffff;s.z1=0;s.left.fill(-32768);s.right.fill(32767);
   commands.push_back(span(s));
  }
  commands.push_back(flush(y));
 }
 if(commands.size()!=MaxCommands || MaxCommands!=8128)return 3;
 std::vector<uint32_t> expected(49152,0x1f102030);
 auto save=[&](const char* suffix,const void* data,size_t length){std::ofstream f(std::string(argv[1])+suffix,std::ios::binary);if(length)f.write(static_cast<const char*>(data),length);if(!f)throw std::runtime_error("fixture write");};
 save(".commands",commands.data(),commands.size()*sizeof(Command));save(".textures",nullptr,0);save(".expected",expected.data(),expected.size()*4);
 std::puts("PASS full 8128-descriptor arena fixture; alpha reference rejects all geometry, preserving every clear pixel");
}
