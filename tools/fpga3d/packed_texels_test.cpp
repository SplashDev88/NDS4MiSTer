// SPDX-License-Identifier: GPL-3.0-only
#include "transport.h"
#include <cstdio>
#include <stdexcept>
using namespace fpga3d;
static void check(bool b){if(!b)throw std::runtime_error("packed texture mismatch");}
int main(){
 std::vector<uint32_t> source(65536),packed;
 for(unsigned v=0;v<65536;v++)source[v]=unpackTexture16(v);
 check(packTexture16(source.data(),source.size(),packed));
 for(unsigned v=0;v<65536;v++)check(uint16_t(packed[v/2]>>(16*(v%2)))==v);
 const auto saved=packed;
 for(unsigned alpha=1;alpha<31;alpha++){
  source[100]=(source[100]&0xffffff)|(alpha<<24);
  check(!packTexture16(source.data(),source.size(),packed) && packed==saved);
 }
 source[100]=0x1f000002;check(!packTexture16(source.data(),source.size(),packed));
 check(!packTexture16(nullptr,64,packed) && !packTexture16(source.data(),63,packed));
 for(unsigned format=0;format<3;format++){
  Span s;s.flags|=Textured;s.texture=Textures|format;
  auto c=span(s),u=unpack(pack(c));check(u[13]==c[13] && u[14]==c[14]);
  for(unsigned target=0;target<3;target++){
   auto p=pack(c);const auto address=Textures+256;
   rebindTexture(p,address|target);auto expected=c;expected[13]=address;
   expected[14]=(expected[14]&~0x3000u)|(target<<12);check(p==pack(expected));
  }
 }
 Span bad;bad.flags|=Textured;bad.texture=Textures|3;check(pack(span(bad))[15]>>31);
 packedTexturesEnabled=true;
 // Start compact, then choose palette-free encodings under the same capacity.
 Frame f;std::vector<std::vector<uint32_t>> textures(16,std::vector<uint32_t>(16384));
 std::vector<Frame::TextureUse> uses;
 for(unsigned t=0;t<textures.size();t++){
  for(unsigned i=0;i<textures[t].size();i++)textures[t][i]=unpackTexture16(0x8000|((i+t)&255));
  uses.push_back({textures[t].data(),textures[t].size(),t+1});
  check(f.addTexture(textures[t].data(),textures[t].size()));
 }
 f.preferRawTextures(uses);check(f.textures.size()*4==16*16384*2);
 for(const auto& use:uses){
  const auto binding=f.textureOffsets.at(use.pixels);check((binding&3)==2);
  const auto base=((binding&~3u)-Textures)/4;
  for(unsigned i=0;i<use.count;i++)check(unpackTexture16(f.textures[base+i/2]>>(16*(i%2)))==use.pixels[i]);
 }
 f.preparedTextures.remember(uses,f.textures,f.textureOffsets);check(f.preparedTextures.matches(uses));
 textures[3][12]^=0x8000000;check(!f.preparedTextures.matches(uses));
 // Partial alpha remains lossless on the indexed/raw path.
 f.reset();std::fill(textures[0].begin(),textures[0].end(),0x11030303);
 check(f.addTexture(textures[0].data(),textures[0].size()));
 f.preferRawTextures({{textures[0].data(),textures[0].size(),100}});
 check(!(f.textureOffsets.at(textures[0].data())&2));
 // Capacity-limited frames retain indexed textures rather than failing.
 f.reset();for(const auto& use:uses)check(f.addTexture(use.pixels,use.count));
 const auto initial=f.textures.size()*4;f.preferRawTextures(uses,initial);check(f.textures.size()*4==initial && f.valid);
 puts("PASS 65536 exact texels, partial-alpha fallback, all binding format transitions, packed repacking and constrained arena");
}
