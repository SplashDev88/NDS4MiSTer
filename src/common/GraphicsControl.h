// SPDX-License-Identifier: GPL-3.0-only
#pragma once
#include <cstdint>
#include <cstdlib>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace nds4mister {
// One session-owned, CPU-coherent word. This is not the FPGA shared ABI.
// Only the host writes; the renderer samples once before starting a frame.
class GraphicsControl {
    std::uint32_t* word_ = nullptr;
    bool writable_ = false;
public:
    static constexpr std::uint32_t AAOn = 0x41410001, AAOff = 0x41410000;
    explicit GraphicsControl(bool writable = false) noexcept : writable_(writable) {
        const char* path = std::getenv("NDS4MISTER_GRAPHICS_CONTROL");
        if (!path || !*path) return;
        const int fd = open(path, (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW);
        if (fd < 0) return;
        struct stat info {};
        if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size == 4) {
            void* mapping = mmap(nullptr, 4, PROT_READ | (writable ? PROT_WRITE : 0),
                                 MAP_SHARED, fd, 0);
            if (mapping != MAP_FAILED) word_ = static_cast<std::uint32_t*>(mapping);
        }
        close(fd);
    }
    ~GraphicsControl() { if (word_) munmap(word_, 4); }
    GraphicsControl(const GraphicsControl&) = delete;
    GraphicsControl& operator=(const GraphicsControl&) = delete;
    bool attached() const noexcept { return word_ != nullptr; }
    bool antiAlias() const noexcept {
        // Unknown or corrupt values retain full quality.
        return !word_ || __atomic_load_n(word_, __ATOMIC_RELAXED) != AAOff;
    }
    void setAntiAlias(bool enabled) noexcept {
        if (word_ && writable_)
            __atomic_store_n(word_, enabled ? AAOn : AAOff, __ATOMIC_RELAXED);
    }
};
static_assert(__atomic_always_lock_free(4, nullptr), "Graphics control requires an atomic word");
}
