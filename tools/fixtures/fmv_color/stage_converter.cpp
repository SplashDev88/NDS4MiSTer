// SPDX-License-Identifier: GPL-3.0-only
#include "fmv_castlevania.h"
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <vector>

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    std::ifstream input(argv[1], std::ios::binary);
    if (!input) throw std::runtime_error("ROM fixture not readable");
    const std::vector<uint8_t> original {std::istreambuf_iterator<char>(input), {}};
    auto candidate = original;
    if (!nds_fmv::apply(candidate.data(), candidate.size(), candidate.size()))
        throw std::runtime_error("ROM fixture identity does not match");
    auto write = [](const char* path, const std::vector<uint8_t>& rom) {
        std::ofstream output(path, std::ios::binary);
        output.write(reinterpret_cast<const char*>(rom.data() + 0xc509c), 0x10f0);
        if (!output) throw std::runtime_error("Cannot stage converter fixture");
    };
    write("/tmp/original-converter.bin", original);
    write("/tmp/candidate-converter.bin", candidate);
    std::ofstream overlay("/tmp/embedded-overlay.bin", std::ios::binary);
    overlay.write(reinterpret_cast<const char*>(candidate.data() + 0xc5960), 0x82c);
    if (!overlay) throw std::runtime_error("Cannot stage overlay fixture");
    auto write_dct = [](const char* path, const std::vector<uint8_t>& rom) {
        std::ofstream output(path, std::ios::binary);
        output.write(reinterpret_cast<const char*>(rom.data() + 0xc9914), 0x47c);
        if (!output) throw std::runtime_error("Cannot stage transform fixture");
    };
    write_dct("/tmp/original-dct.bin", original);
    write_dct("/tmp/candidate-dct.bin", candidate);
    auto write_range = [](const char* path, const std::vector<uint8_t>& rom,
                          size_t offset, size_t size) {
        std::ofstream output(path, std::ios::binary);
        output.write(reinterpret_cast<const char*>(rom.data() + offset), size);
        if (!output) throw std::runtime_error("Cannot stage audio fixture");
    };
    write_range("/tmp/original-adpcm.bin", original, 0x5d960, 0x150);
    write_range("/tmp/candidate-adpcm.bin", candidate, 0x5d960, 0x150);
    write_range("/tmp/adpcm-tables.bin", original, 0x8a2d0, 194);
    write_range("/tmp/adpcm-original-literals.bin", original, 0x5dd20, 8);
}
