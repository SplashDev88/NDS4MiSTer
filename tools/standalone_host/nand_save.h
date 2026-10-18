// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <algorithm>
#include <array>
#include <cstdint>
#include <cerrno>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <stdexcept>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace nds_nand {
inline uint32_t bytes(uint8_t type) {
    return type == 8 ? 8u * 1024 * 1024 : type == 9 ? 16u * 1024 * 1024 : 0;
}
// Build erased NAND on the ARM side in bulk. Do not initialize tens of
// thousands of sectors through SPI or expose a half-written/zero-filled save.
// Existing nonempty sidecars are accepted only at their exact cartridge size.
inline void prepare(const std::filesystem::path &path, uint32_t size,
                    const std::function<void()> &service) {
    if (size != bytes(8) && size != bytes(9)) throw std::runtime_error("Invalid NAND save capacity");
    struct stat original{};
    const bool existed = lstat(path.c_str(), &original) == 0;
    if (!existed && errno != ENOENT) throw std::runtime_error("Cannot inspect NAND save");
    if (existed) {
        if (!S_ISREG(original.st_mode) || (original.st_size != 0 && original.st_size != size))
            throw std::runtime_error("NAND save has the wrong size or file type; existing file preserved");
        if (original.st_size == size) return;
    }
    const auto temp = path.string() + ".nand-new-" + std::to_string(getpid());
    int fd = open(temp.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (fd < 0) throw std::runtime_error("Cannot create temporary NAND save");
    try {
        std::array<unsigned char, 65536> erased;
        erased.fill(0xff);
        for (uint32_t position = 0; position < size;) {
            service();
            const auto n = write(fd, erased.data(), std::min<size_t>(erased.size(), size-position));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) throw std::runtime_error("NAND save initialization failed");
            position += uint32_t(n);
        }
        if (fsync(fd)) throw std::runtime_error("NAND save sync failed");
        service();
        struct stat current{};
        const bool exists_now = lstat(path.c_str(), &current) == 0;
        if (exists_now != existed || (exists_now &&
            (!S_ISREG(current.st_mode) || current.st_dev != original.st_dev ||
             current.st_ino != original.st_ino || current.st_size != 0)))
            throw std::runtime_error("NAND save changed during initialization; existing file preserved");
        if (!exists_now && errno != ENOENT) throw std::runtime_error("Cannot recheck NAND save");
        if (rename(temp.c_str(), path.c_str())) throw std::runtime_error("Cannot install initialized NAND save");
        close(fd); fd = -1;
        const int directory = open(path.parent_path().c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (directory < 0) throw std::runtime_error("Cannot open NAND save directory");
        const int result = fsync(directory); close(directory);
        if (result) throw std::runtime_error("Cannot sync NAND save directory");
    } catch (...) {
        if (fd >= 0) close(fd);
        unlink(temp.c_str());
        throw;
    }
}
}
