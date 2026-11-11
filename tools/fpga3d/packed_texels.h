// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>
#include <cstddef>
#include <vector>
namespace fpga3d {
constexpr uint32_t expandTexture5(uint32_t v) { return (v << 1) + (v != 0); }
constexpr uint32_t unpackTexture16(uint16_t v) {
 return expandTexture5(v & 31) | (expandTexture5((v >> 5) & 31) << 8) |
     (expandTexture5((v >> 10) & 31) << 16) | ((v & 0x8000) ? 0x1f000000u : 0);
}
inline bool packTexture16(const uint32_t* pixels,size_t count,std::vector<uint32_t>& output) {
 if(!pixels || !count || (count&1))return false;
 std::vector<uint32_t> packed(count/2);
 for(size_t i=0;i<count;i++) {
  const uint32_t p=pixels[i];
  const uint16_t v=uint16_t(((p>>1)&31)|(((p>>9)&31)<<5)|(((p>>17)&31)<<10)|((p>>24)?0x8000:0));
  // No quantization: partial alpha and noncanonical RGB6 stay on the old path.
  if(unpackTexture16(v)!=p)return false;
  packed[i/2]|=uint32_t(v)<<(16*(i&1));
 }
 output.swap(packed);return true;
}
}
