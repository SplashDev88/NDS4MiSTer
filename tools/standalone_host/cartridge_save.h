// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstdint>
#include <functional>
#include <stdexcept>
#include <unistd.h>

namespace nds_cartridge_save {
inline uint32_t capacity(uint8_t type) {
    constexpr uint32_t sizes[] = {0, 512, 8192, 65536, 131072, 262144,
                                 524288, 1048576, 8388608, 16777216};
    return type < sizeof(sizes) / sizeof(sizes[0]) ? sizes[type] : 0;
}

// Some emulators pad a cartridge save to a larger capacity with erased bytes.
// Present only the real chip capacity to the FPGA, but keep the complete file:
// gameplay writes update its prefix and never truncate or overwrite the tail.
// Do not guess when the excess contains data or a file is unexpectedly short.
inline uint64_t mountedSize(int fd, uint64_t file_size, uint8_t type,
                            const std::function<void()> &service) {
    const uint32_t expected = capacity(type);
    if (!expected || file_size == 0 || file_size == expected) return file_size;
    // Existing 8 KiB -> 64 KiB migration is completed by the FPGA, filling the
    // missing sectors with FF. Preserve that protocol and its initial size.
    if (type == 3 && file_size == 8192) return file_size;
    if (type >= 8 || file_size < expected)
        throw std::runtime_error("Incompatible save size; original file preserved");
    std::array<uint8_t, 16384> buffer{};
    for (uint64_t position = expected; position < file_size;) {
        service();
        const auto count = std::min<uint64_t>(buffer.size(), file_size-position);
        const auto n = pread(fd, buffer.data(), count, off_t(position));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0)
            throw std::runtime_error("Cannot verify save padding; original file preserved");
        if (std::any_of(buffer.begin(), buffer.begin()+n,
                        [](uint8_t value) { return value != 0xff; }))
            throw std::runtime_error("Extra save data is not padding; original file preserved");
        position += uint64_t(n);
    }
    return expected;
}
}
