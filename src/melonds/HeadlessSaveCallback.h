#pragma once

#include <cstdint>

namespace nds4mister {

// Per-cartridge callback context passed through melonDS's existing userdata
// seam.  Keeping the callback in the cart avoids a process-global save owner
// and lets independent emulator instances use independent save sessions.
struct HeadlessSaveCallback {
    using Write = void (*)(void* opaque, const std::uint8_t* data,
        std::uint32_t length, std::uint32_t offset,
        std::uint32_t writeLength) noexcept;

    Write write = nullptr;
    void* opaque = nullptr;
};

} // namespace nds4mister
