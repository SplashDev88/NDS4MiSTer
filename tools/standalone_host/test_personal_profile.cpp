// SPDX-License-Identifier: GPL-3.0-only
#include "personal_profile.h"
#include "test_firmware_fixture.h"
#include <cassert>
#include <iostream>
#include <set>
using namespace nds_firmware;
using namespace firmware_fixture;
static void crcPages(std::array<uint8_t, 512> &p, unsigned i) {
  const auto sum = crc16(p.data() + i * 256, 0x70);
  p[i * 256 + 0x72] = uint8_t(sum); p[i * 256 + 0x73] = uint8_t(sum >> 8);
}
int main() {
  auto input = syntheticFirmware();
  const auto offset = user;
  input[offset + 2] = 15; input[offset + 3] = 2; input[offset + 4] = 29;
  input[offset + 0x64] = 0xfe; input[offset + 0x65] = 0xff;
  const std::array<uint16_t, 3> name{{0x65e5, 0xd83d, 0xde00}};
  for (unsigned i = 0; i < name.size(); ++i) put16(input, offset + 6 + i * 2, name[i]);
  put16(input, offset + 0x1a, name.size());
  std::fill(input.begin() + offset + 12, input.begin() + offset + 26, 0xaa);
  // Deliberately unusable calibration/RTC/alarm/message: none is a game input.
  std::fill(input.begin() + offset + 0x1c, input.begin() + offset + 0x64, 0xa5);
  std::fill(input.begin() + offset + 0x66, input.begin() + offset + 0x70, 0xa5);
  checksum(input, 0);
  const auto before = input;
  const auto projected = projectPersonalImage(input);
  assert(projected.shared && projected.warning.empty() && input == before);
  std::set<unsigned> changed{2,3,4,0x1a,0x1b,0x64,0x72,0x73};
  for (unsigned i = 6; i < 26; ++i) changed.insert(i);
  for (unsigned c = 0; c < 2; ++c) {
    const auto *out = projected.pages.data() + 256 * c;
    assert(out[2] == 15 && out[3] == 2 && out[4] == 29 && le16(out + 0x1a) == 3);
    for (unsigned i = 0; i < name.size(); ++i) assert(le16(out + 6 + 2 * i) == name[i]);
    for (unsigned i = 12; i < 26; ++i) assert(out[i] == 0);
    assert(out[0x64] == ((builtin_user_pages[256*c + 0x64] & 0xf8) | 6));
    assert(crc16(out, 0x70) == le16(out + 0x72));
    for (unsigned i = 0; i < 256; ++i) if (!changed.count(i))
      assert(out[i] == builtin_user_pages[256*c + i]);
  }
  assert(std::equal(projected.pages.begin(), projected.pages.begin() + 112, projected.pages.begin() + 256));
  assert(le16(builtin_profile.data() + 0x1a) == 6);
  const char expected[] = "MiSTer";
  for (unsigned i = 0; i < 6; ++i) assert(le16(builtin_profile.data() + 6 + 2*i) == unsigned(expected[i]));
  std::array<uint8_t,512> p{}; std::copy_n(before.data() + user,512,p.begin());
  p[0x70]=127;p[0x71]=0;p[0x170]=0;p[0x171]=0;crcPages(p,0);crcPages(p,1);
  assert(projectPersonalPages(p).pages[6] == 'B'); //127->0 successor
  p[0x70]=9;p[0x170]=5;crcPages(p,0);crcPages(p,1);
  assert(projectPersonalPages(p).pages[6] == uint8_t(name[0])); //nonadjacent selects0
  p[0x72]^=1; assert(projectPersonalPages(p).pages[6] == 'B');
  p[0x172]^=1; assert(!projectPersonalPages(p).shared);
  for (auto field : {2u,3u,4u,0x64u,0x1au}) {
    auto bad=before;bad[user + field]=0xff;checksum(bad,0);bad[user + 0x172]^=1;
    const auto r=projectPersonalImage(bad);assert(!r.shared && r.pages==builtin_user_pages && !r.warning.empty());
  }
  char dir[]="/tmp/nds-personal-XXXXXX"; const auto root=mkdtemp(dir);assert(root);
  try {
    const auto file=fs::path(root)/"working.bin";
    auto missing=readGamePersonalProfile(file);assert(!missing.shared && missing.pages==builtin_user_pages);
    // Invalid firmware header/code/Wi-Fi is intentionally outside this parser.
    input[8]=0;input[0x1d]=0;input[0x2a]^=1;
    writeBytes(file,input);
    const auto fromFile=readGamePersonalProfile(file);assert(fromFile.shared && fromFile.pages==projected.pages);
    assert(readBytes(file)==input);
    const auto link=fs::path(root)/"link";fs::create_symlink(file,link);
    assert(!readGamePersonalProfile(link).shared);
    const auto fifo=fs::path(root)/"fifo";assert(mkfifo(fifo.c_str(),0600)==0);
    assert(!readGamePersonalProfile(fifo).shared);
    put16(input,0x20,0xffff);writeBytes(file,input);assert(!readGamePersonalProfile(file).shared);
    writeBytes(file,Bytes(7,0));assert(!readGamePersonalProfile(file).shared);
    assert(!readGamePersonalProfile(root).shared);
    fs::remove_all(root);
  } catch (...) {fs::remove_all(root);throw;}
  std::cout << "PASS four personal fields only, UTF16 length/tail, independent generated defaults/CRCs, slot CRC/rollover, read-only optional-file fallback without native media/calibration\n";
}
