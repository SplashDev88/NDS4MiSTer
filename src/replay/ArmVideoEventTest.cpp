#include "replay/ArmVideoEvent.h"

#include <iostream>

using nds4mister::arm_video::RecordKind;
using nds4mister::arm_video::make_record;
using nds4mister::arm_video::validate_record;

int main() {
    const auto bg2_scroll = make_record(
        RecordKind::Gpu2DRegister, 1, 0x3, 0x04000018, 0x00000123);
    const auto engine_b = make_record(
        RecordKind::Gpu2DRegister, 2, 0xf, 0x04001000, 0x00011f00);
    const auto palette = make_record(
        RecordKind::PaletteWrite, 1, 0xc, 0x05000402, 0xabcd0000);
    const auto oam = make_record(
        RecordKind::OamWrite, 2, 0xf, 0x07000040, 0x87654321);
    const auto hblank = make_record(
        RecordKind::HBlank, 0, 0, 262, 0x12345678u);
    if (!validate_record(bg2_scroll) || !validate_record(engine_b) ||
        !validate_record(palette) || !validate_record(oam) ||
        !validate_record(hblank))
        return 1;

    auto bad = bg2_scroll;
    bad.address_or_aux = 0x04000400;
    if (validate_record(bad)) return 2;
    bad = palette;
    bad.metadata &= ~(0x0fu << 16);
    if (validate_record(bad)) return 3;
    bad = hblank;
    bad.address_or_aux = 263;
    if (validate_record(bad)) return 4;
    bad = oam;
    bad.data |= std::uint64_t{1} << 40;
    if (validate_record(bad)) return 5;
    bad = bg2_scroll;
    bad.metadata |= 1u << 10;
    if (validate_record(bad)) return 6;
    bad = bg2_scroll;
    bad.address_or_aux = 0x0400001a;
    if (validate_record(bad)) return 7;
    bad = bg2_scroll;
    bad.address_or_aux = 0x04000060;
    if (validate_record(bad)) return 8;

    std::cout
        << "ARM video compact event ABI test\n"
        << "gpu2d_registers: passed\n"
        << "palette_oam_writes: passed\n"
        << "hblank_markers: passed\n"
        << "malformed_records: rejected\n";
    return 0;
}
