#pragma once

#include <array>
#include <cstdint>

namespace melonDS {

// A cache for one immutable, flattened VRAM snapshot only. Construct a new
// instance for each Texcache::Update, after its coherence copies complete.
// Entries compare the full range identity; hash-table collisions only cost time.
class NDS4MiSTerTextureRangeHashes {
public:
    template <typename Calculate>
    uint64_t Get(const void* region, uint32_t regionSize,
                 uint32_t start, uint32_t size, Calculate&& calculate) {
        uint32_t key = (start * 2654435761u) ^ (size * 2246822519u) ^ regionSize;
        key ^= key >> 16; key *= 0x7feb352du; key ^= key >> 15;
        unsigned slot = key & 127;
        for (unsigned probe = 0; probe < 8; ++probe, slot = (slot + 1) & 127) {
            const uint64_t bit = uint64_t(1) << (slot & 63);
            if (!(Occupied[slot >> 6] & bit)) {
                const auto value = calculate();
                Entries[slot] = {region, regionSize, start, size, value};
                Occupied[slot >> 6] |= bit;
                return value;
            }
            const auto& entry = Entries[slot];
            if (entry.Region == region && entry.RegionSize == regionSize &&
                entry.Start == start && entry.Size == size)
                return entry.Hash;
        }
        return calculate();
    }
private:
    struct Entry {
        const void* Region;
        uint32_t RegionSize, Start, Size;
        uint64_t Hash;
    };
    // Entries are read only after their occupied bit is set. Avoid clearing
    // several KiB on every frame just to mark this short-lived cache empty.
    std::array<Entry, 128> Entries;
    std::array<uint64_t, 2> Occupied {};
};

}
