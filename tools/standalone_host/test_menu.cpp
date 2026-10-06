// SPDX-License-Identifier: GPL-3.0-only
#include "menu_model.h"
#include <cassert>
#include <iostream>
int main() {
  assert(CORE_OPTIONS.size() == 6 && CORE_OPTION_MASK == 0x3bf0);
  for (unsigned original = 0; original < 65536; original++) {
    auto valid = cleanStatus(original);
    assert((valid & ~(CORE_OPTION_MASK | REQUIRED_STATUS)) == 0);
    assert((valid & REQUIRED_STATUS) == REQUIRED_STATUS);
    assert(cleanStatus(original & ~REQUIRED_STATUS) == valid);
    for (const auto &o : CORE_OPTIONS) {
      auto value = valid;
      for (unsigned n = 0; n < o.count; n++)
        value = changeOption(value, o, 1);
      assert(value == valid);
      assert(changeOption(changeOption(valid, o, 1), o, -1) == valid);
      assert(((changeOption(valid, o, 1) ^ valid) &
              ~(((1 << o.width) - 1) << o.shift)) == 0);
    }
  }
  assert(CORE_OPTIONS[4].shift == 4 &&
         std::string(CORE_OPTIONS[4].label) == "3D FPS Counter");
  assert(CORE_OPTIONS[1].shift == 11 &&
         std::string(CORE_OPTIONS[1].label) == "Video Rotation");
  assert((changeOption(0, CORE_OPTIONS[1], 1) & 1) == 0);
  assert(optionLabel(0, CORE_OPTIONS[0]) == " Video Layout:    Left/Right");
  assert(optionLabel(0, CORE_OPTIONS[1]) == " Video Rotation:         Off");
  for (const auto &o : CORE_OPTIONS)
    for (unsigned value = 0; value < o.count; ++value) {
      const auto label = optionLabel(value << o.shift, o);
      assert(label.size() == 28 && label.find(':') != std::string::npos);
    }
  assert(osdRotation(
             "osd_rotate=2\n[NDS]\nosd_rotate = 1\n[SNES]\nosd_rotate=0") == 1);
  assert(osdRotation("[MiSTer]\nosd_rotate=2\n[NDS]\nfoo=1") == 2);
  assert(osdRotation("[NDS]\nosd_rotate=0") == 0);
  assert(mappedButton((0x320u << 16) | 304u, 304));
  assert(mappedButton((0x320u << 16) | 304u, 0x320));
  assert(!mappedButton(0, 0));
  assert(!mappedButton((0x320u << 16) | 304u, 0x300));
  std::cout << "PASS: all65536statusvalues, options/masks/resetsemantics, INI "
               "rotation, packedcontrollercodes\n";
}
