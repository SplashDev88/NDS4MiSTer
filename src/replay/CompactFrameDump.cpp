#include "replay/LayerRecord.h"
#include "replay/StandaloneBoot.h"

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

constexpr std::size_t kMapBytes = 3u * nds4mister::kLayerSlotBytes;
constexpr std::uint32_t kCompactAbi = 2;
constexpr std::uint32_t kWidth = 512;
constexpr std::uint32_t kHeight = 192;
constexpr std::uint32_t kPixels = kWidth * kHeight;
constexpr std::uint32_t kFrameBytes = kPixels * 2u;

std::uint64_t word64(const std::uint32_t* words, unsigned index) {
    return static_cast<std::uint64_t>(words[index]) |
        (static_cast<std::uint64_t>(words[index + 1]) << 32);
}

std::uint8_t expand5(std::uint16_t value) {
    value &= 31u;
    return static_cast<std::uint8_t>((value << 3) | (value >> 2));
}

} // namespace

int main(int argc, char** argv) try {
    if (argc != 2)
        throw std::runtime_error("usage: nds_compact_frame_dump output.ppm");

    const int fd = open("/dev/mem", O_RDONLY | O_SYNC | O_CLOEXEC);
    if (fd < 0)
        throw std::runtime_error(
            std::string("open /dev/mem: ") + std::strerror(errno));
    void* mapping = mmap(
        nullptr, kMapBytes, PROT_READ, MAP_SHARED, fd,
        static_cast<off_t>(nds4mister::kCompactPublicationPhysical));
    close(fd);
    if (mapping == MAP_FAILED)
        throw std::runtime_error(
            std::string("mmap publication: ") + std::strerror(errno));

    auto* bytes = static_cast<volatile const std::uint8_t*>(mapping);
    auto* deviceWords =
        reinterpret_cast<volatile const std::uint32_t*>(mapping);
    std::vector<std::uint16_t> pixels(kPixels);
    std::uint64_t generation = 0;
    std::uint64_t sequence = 0;
    std::uint32_t slot = 0;
    bool stable = false;

    for (unsigned attempt = 0; attempt < 10000 && !stable; ++attempt) {
        std::uint32_t header[16]{};
        const std::uint32_t generationLowBefore = deviceWords[4];
        const std::uint32_t generationHighBefore = deviceWords[5];
        __sync_synchronize();
        for (unsigned index = 0; index < 16; ++index)
            header[index] = deviceWords[index];
        __sync_synchronize();
        const std::uint32_t generationLowAfter = deviceWords[4];
        const std::uint32_t generationHighAfter = deviceWords[5];
        generation = word64(header, 4);
        const std::uint64_t generationCheck = word64(header, 12);
        slot = header[6];
        sequence = word64(header, 10);
        const bool headerStable =
            generationLowBefore == generationLowAfter &&
            generationHighBefore == generationHighAfter &&
            generation == generationCheck && (generation & 1u) == 0 &&
            word64(header, 0) == nds4mister::kLayerPublicationMagic &&
            header[2] == kCompactAbi && header[3] == sizeof(header) &&
            slot <= 1 && header[7] == kFrameBytes &&
            header[8] == 2 && header[9] == kPixels;
        if (!headerStable)
            continue;

        auto* source = reinterpret_cast<volatile const std::uint16_t*>(
            bytes + nds4mister::kLayerSlotBytes * (slot + 1u));
        for (std::size_t index = 0; index < pixels.size(); ++index)
            pixels[index] = source[index];
        __sync_synchronize();
        stable = generationLowBefore == deviceWords[4] &&
            generationHighBefore == deviceWords[5] &&
            slot == deviceWords[6];
    }
    if (!stable) {
        munmap(mapping, kMapBytes);
        throw std::runtime_error("no stable compact framebuffer snapshot");
    }

    std::ofstream output(argv[1], std::ios::binary | std::ios::trunc);
    if (!output)
        throw std::runtime_error("open output failed");
    output << "P6\n" << kWidth << ' ' << kHeight << "\n255\n";
    for (const std::uint16_t pixel : pixels) {
        const char rgb[3] = {
            static_cast<char>(expand5(pixel)),
            static_cast<char>(expand5(pixel >> 5)),
            static_cast<char>(expand5(pixel >> 10)),
        };
        output.write(rgb, sizeof(rgb));
    }
    output.close();
    if (!output)
        throw std::runtime_error("write output failed");

    munmap(mapping, kMapBytes);
    std::cout << "generation=" << generation
              << " sequence=" << sequence
              << " slot=" << slot
              << " output=" << argv[1] << "\n";
    return 0;
} catch (const std::exception& error) {
    std::cerr << "nds_compact_frame_dump: " << error.what() << "\n";
    return 1;
}
