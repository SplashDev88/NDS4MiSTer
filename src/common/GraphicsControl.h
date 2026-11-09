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
    static constexpr std::uint32_t AAOn = 0x41410001, AAOff = 0x41410000,
                                   HalfRows = 0x41410002, RenderOff = 0x41410004;
    struct Settings { bool antiAlias; bool halfRows; bool renderOff; };
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
    Settings settings() const noexcept {
        // Unknown or corrupt values retain full quality.
        const auto value = word_ ? __atomic_load_n(word_, __ATOMIC_RELAXED) : AAOn;
        return {value != AAOff && value != HalfRows && value != RenderOff,
                value == HalfRows, value == RenderOff};
    }
    bool antiAlias() const noexcept { return settings().antiAlias; }
    void set(bool antiAlias, bool halfRows, bool renderOff = false) noexcept {
        if (word_ && writable_)
            __atomic_store_n(word_, antiAlias ? AAOn : renderOff ? RenderOff : halfRows ? HalfRows : AAOff,
                             __ATOMIC_RELAXED);
    }
    void setAntiAlias(bool enabled) noexcept {
        const auto current = settings();
        set(enabled, current.halfRows, current.renderOff);
    }
};
static_assert(__atomic_always_lock_free(4, nullptr), "Graphics control requires an atomic word");
}
