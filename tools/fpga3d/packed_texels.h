// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>
#include <cstddef>
#include <vector>
#if defined(__ARM_NEON) && __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__ && !defined(NDS4MISTER_PACKED_TEXTURES_SCALAR)
#include <arm_neon.h>
#define NDS4MISTER_PACKED_TEXTURES_NEON 1
#endif
namespace fpga3d {
constexpr uint32_t expandTexture5(uint32_t v) { return (v << 1) + (v != 0); }
constexpr uint32_t unpackTexture16(uint16_t v) {
 return expandTexture5(v & 31) | (expandTexture5((v >> 5) & 31) << 8) |
     (expandTexture5((v >> 10) & 31) << 16) | ((v & 0x8000) ? 0x1f000000u : 0);
}
inline bool packTexture16(const uint32_t* pixels,size_t count,std::vector<uint32_t>& output) {
 if(!pixels || !count || (count&1))return false;
 std::vector<uint32_t> packed(count/2);
 size_t i=0;
#ifdef NDS4MISTER_PACKED_TEXTURES_NEON
 // Validate the complete RGBA value after expansion, just as the scalar
 // path does. No noncanonical channel or partial alpha is quantized away.
 const auto packFour=[](uint32x4_t p,uint32x4_t& valid) {
  auto encoded=vorrq_u32(vandq_u32(vshrq_n_u32(p,1),vdupq_n_u32(31)),
      vandq_u32(vshrq_n_u32(p,4),vdupq_n_u32(0x3e0)));
  encoded=vorrq_u32(encoded,vandq_u32(vshrq_n_u32(p,7),vdupq_n_u32(0x7c00)));
  encoded=vorrq_u32(encoded,vandq_u32(vshrq_n_u32(p,13),vdupq_n_u32(0x8000)));
  const auto expand=[](uint32x4_t c) {
   return vsubq_u32(vshlq_n_u32(c,1),vmvnq_u32(vceqq_u32(c,vdupq_n_u32(0))));
  };
  auto decoded=expand(vandq_u32(encoded,vdupq_n_u32(31)));
  decoded=vorrq_u32(decoded,vshlq_n_u32(expand(vandq_u32(vshrq_n_u32(encoded,5),vdupq_n_u32(31))),8));
  decoded=vorrq_u32(decoded,vshlq_n_u32(expand(vandq_u32(vshrq_n_u32(encoded,10),vdupq_n_u32(31))),16));
  decoded=vorrq_u32(decoded,vandq_u32(vmvnq_u32(vceqq_u32(vandq_u32(encoded,vdupq_n_u32(0x8000)),vdupq_n_u32(0))),vdupq_n_u32(0x1f000000)));
  valid=vceqq_u32(decoded,p);
  return vmovn_u32(encoded);
 };
 for(;i+8<=count;i+=8) {
  uint32x4_t validA,validB;
  const auto a=packFour(vld1q_u32(pixels+i),validA);
  const auto b=packFour(vld1q_u32(pixels+i+4),validB);
  const auto valid=vandq_u32(validA,validB);
  const auto halves=vand_u32(vget_low_u32(valid),vget_high_u32(valid));
  if(vget_lane_u32(vpmin_u32(halves,halves),0)!=0xffffffffu)return false;
  vst1q_u32(packed.data()+i/2,vreinterpretq_u32_u16(vcombine_u16(a,b)));
 }
#endif
 for(;i<count;i++) {
  const uint32_t p=pixels[i];
  const uint16_t v=uint16_t(((p>>1)&31)|(((p>>9)&31)<<5)|(((p>>17)&31)<<10)|((p>>24)?0x8000:0));
  // No quantization: partial alpha and noncanonical RGB6 stay on the old path.
  if(unpackTexture16(v)!=p)return false;
  packed[i/2]|=uint32_t(v)<<(16*(i&1));
 }
 output.swap(packed);return true;
}
}
