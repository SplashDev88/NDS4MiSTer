#include "replay/LayerRecord.h"
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

namespace {
constexpr off_t kDdrPhysicalBase = 0x30000000;
constexpr std::size_t kCompactFrameBytes = 512u * 192u * 2u;
constexpr std::size_t kMapBytes = 3u * nds4mister::kLayerSlotBytes;
constexpr std::uint32_t kCompactAbi = 2;

std::vector<std::byte> readFrame(const char* path) {
    std::ifstream input(path, std::ios::binary | std::ios::ate);
    if (!input) throw std::runtime_error("open input frame");
    const auto size = input.tellg();
    if (size != static_cast<std::streamoff>(kCompactFrameBytes) &&
        size != static_cast<std::streamoff>(nds4mister::kLayerFrameBytes))
        throw std::runtime_error("input must be a 196608-byte RGB555 frame or 3932160-byte layer frame");
    input.seekg(0);
    std::vector<std::byte> source(static_cast<std::size_t>(size));
    if (!input.read(reinterpret_cast<char*>(source.data()), source.size()))
        throw std::runtime_error("read input frame");
    if (source.size() == kCompactFrameBytes) return source;
    std::vector<std::byte> frame(kCompactFrameBytes);
    const auto* records = reinterpret_cast<const nds4mister::LayerRecord*>(source.data());
    auto* pixels = reinterpret_cast<std::uint16_t*>(frame.data());
    for (std::size_t index = 0; index < nds4mister::kLayerFrameRecords; ++index) {
        const std::uint32_t color = records[index].pixels[0];
        pixels[index] = static_cast<std::uint16_t>(((color >> 1) & 0x1f) |
            ((color >> 4) & 0x3e0) | ((color >> 7) & 0x7c00));
    }
    return frame;
}
}

int main(int argc, char** argv) try {
    if (argc != 2) {
        std::cerr << "usage: nds_compact_upload frame.rgb555|frame.layers\n";
        return 2;
    }
    const auto frame = readFrame(argv[1]);
    const int fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (fd < 0) throw std::runtime_error(std::string("open /dev/mem: ") + std::strerror(errno));
    void* map = mmap(nullptr, kMapBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, kDdrPhysicalBase);
    if (map == MAP_FAILED) throw std::runtime_error(std::string("map DDR: ") + std::strerror(errno));

    auto* header = static_cast<nds4mister::LayerPublication*>(map);
    nds4mister::LayerPublication old{};
    std::memcpy(&old, header, sizeof(old));
    const std::uint64_t stable = ((old.generation & 1u) == 0 ? old.generation : 0) + 2;
    const std::uint32_t slot = old.activeSlot == 0 ? 1u : 0u;
    nds4mister::LayerPublication next{nds4mister::kLayerPublicationMagic,
        kCompactAbi, sizeof(nds4mister::LayerPublication), stable | 1u, slot,
        kCompactFrameBytes, 2, 512u * 192u, stable / 2u, stable | 1u, 0};
    std::memcpy(header, &next, sizeof(next));
    __sync_synchronize();
    auto* destination = static_cast<std::byte*>(map) + nds4mister::kLayerSlotBytes * (slot + 1u);
    std::memcpy(destination, frame.data(), frame.size());
    __sync_synchronize();
    next.generation = stable;
    next.generationCheck = stable;
    std::memcpy(header, &next, sizeof(next));
    __sync_synchronize();
    munmap(map, kMapBytes);
    close(fd);
    std::cout << "published compact RGB555 frame to slot " << slot << " generation " << stable << "\n";
} catch (const std::exception& error) {
    std::cerr << "nds_compact_upload: " << error.what() << "\n";
    return 1;
}
