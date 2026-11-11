// SPDX-License-Identifier: GPL-3.0-only
// Independent scalar oracle, including malformed colors at every vector lane.
#include "packed_texels.h"
#include <random>
#include <stdexcept>
#include <iostream>
static bool oracle(const uint32_t* p,size_t n,std::vector<uint32_t>& out){
 if(!p || !n || (n&1))return false;
 std::vector<uint32_t> result(n/2);
 for(size_t i=0;i<n;i++){
  const unsigned r=p[i]&255,g=(p[i]>>8)&255,b=(p[i]>>16)&255,a=p[i]>>24;
  auto canonical=[](unsigned c){return c==0 || (c>=3 && c<=63 && (c&1));};
  if(!canonical(r)||!canonical(g)||!canonical(b)||(a!=0 && a!=31))return false;
  const uint32_t encoded=(r/2)|((g/2)<<5)|((b/2)<<10)|((a==31)<<15);
  result[i/2]|=encoded<<(16*(i%2));
 }
 out.swap(result);return true;
}
int main(){
 std::mt19937 random(718277);size_t cases=0;
 auto check=[&](const uint32_t* p,size_t n){
  std::vector<uint32_t> a{0x12345678,0x87654321},b=a;
  const bool x=oracle(p,n,a),y=fpga3d::packTexture16(p,n,b);
  if(x!=y||a!=b)throw std::runtime_error("packed scalar oracle mismatch");cases++;
 };
 std::vector<uint32_t> all(65536);for(unsigned i=0;i<65536;i++)all[i]=fpga3d::unpackTexture16(i);check(all.data(),all.size());
 std::vector<uint32_t> pixels(530);
 for(size_t offset=0;offset<4;offset++)for(size_t n=0;n<=518;n++){
  for(auto& p:pixels)p=fpga3d::unpackTexture16(uint16_t(random()));
  check(pixels.data()+offset,n);
  for(unsigned bit=0;bit<32 && n;bit++){
   const size_t lane=random()%n;const auto saved=pixels[offset+lane];pixels[offset+lane]^=1u<<bit;
   check(pixels.data()+offset,n);pixels[offset+lane]=saved;
  }
 }
 for(unsigned lane=0;lane<24;lane++)for(unsigned channel=0;channel<4;channel++)for(unsigned value=0;value<256;value++){
  std::fill(pixels.begin(),pixels.end(),0x1f3f3f3f);pixels[lane]=(pixels[lane]&~(255u<<(8*channel)))|(value<<(8*channel));check(pixels.data(),24);
 }
 check(nullptr,64);
 std::cout<<"PASS "<<cases<<" exact packed-texture scalar-oracle cases\n";
}
