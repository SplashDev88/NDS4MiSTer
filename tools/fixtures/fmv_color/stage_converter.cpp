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
}
