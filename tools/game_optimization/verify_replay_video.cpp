// SPDX-License-Identifier: GPL-3.0-or-later
#include <cstdint>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

int main(int argc,char** argv){
 if(argc!=3)return 2;
 std::ifstream pixels(argv[1],std::ios::binary),index(argv[2]);
 if(!pixels||!index)return 3;
 std::string line;std::getline(index,line);
 if(line!="frame,first_audio_sample,audio_samples,hash_top,hash_bottom")return 4;
 std::vector<uint32_t> buffer(256*192);unsigned frames=0;
 while(std::getline(index,line)){
  std::istringstream row(line);std::string field;std::vector<uint64_t> values;
  while(std::getline(row,field,','))values.push_back(std::stoull(field));
  if(values.size()!=5)return 5;
  for(unsigned screen=0;screen<2;++screen){
   pixels.read(reinterpret_cast<char*>(buffer.data()),buffer.size()*4);
   if(!pixels)return 6;
   uint64_t hash=14695981039346656037ull;
   for(auto word:buffer)hash=(hash^word)*1099511628211ull;
   if(hash!=values[3+screen]){std::cerr<<"Frame hash differs: "<<values[0]<<' '<<screen<<'\n';return 7;}
  }
  ++frames;
 }
 if(!frames||pixels.peek()!=std::char_traits<char>::eof())return 8;
 std::cout<<frames<<" full-resolution two-screen frames verified\n";
}
