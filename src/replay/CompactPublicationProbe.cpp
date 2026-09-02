#include "replay/LayerRecord.h"
#include "replay/StandaloneBoot.h"

#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <stdexcept>
#include <string>
#include <sys/mman.h>
#include <unistd.h>

namespace {

constexpr std::size_t kMapBytes = 3u * nds4mister::kLayerSlotBytes;
constexpr std::uint32_t kCompactAbi = 2;
constexpr std::uint32_t kCompactFrameBytes = 512u * 192u * 2u;
constexpr std::uint32_t kCompactPixels = 512u * 192u;

std::uint32_t crc32(volatile const std::uint8_t* bytes, std::size_t size) {
    std::uint32_t crc = 0xffffffffu;
    for (std::size_t index = 0; index < size; ++index) {
        crc ^= bytes[index];
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^
                (0xedb88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

std::uint64_t word64(const std::uint32_t* words, unsigned index) {
    return static_cast<std::uint64_t>(words[index]) |
        (static_cast<std::uint64_t>(words[index + 1]) << 32);
}

} // namespace

int main() try {
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

    auto* deviceWords = static_cast<volatile const std::uint32_t*>(mapping);
    std::uint32_t header[16]{};
    bool stable = false;
    for (unsigned attempt = 0; attempt < 10000 && !stable; ++attempt) {
        const std::uint32_t generationLowBefore = deviceWords[4];
        const std::uint32_t generationHighBefore = deviceWords[5];
        __sync_synchronize();
        for (unsigned index = 0; index < 16; ++index)
            header[index] = deviceWords[index];
        __sync_synchronize();
        const std::uint32_t generationLowAfter = deviceWords[4];
        const std::uint32_t generationHighAfter = deviceWords[5];
        const std::uint64_t generation = word64(header, 4);
        const std::uint64_t check = word64(header, 12);
        stable = generationLowBefore == generationLowAfter &&
            generationHighBefore == generationHighAfter &&
            generation == check && (generation & 1u) == 0;
    }
    if (!stable) throw std::runtime_error("no stable publication header");

    const std::uint64_t magic = word64(header, 0);
    const std::uint32_t abi = header[2];
    const std::uint32_t headerBytes = header[3];
    const std::uint64_t generation = word64(header, 4);
    const std::uint32_t slot = header[6];
    const std::uint32_t frameBytes = header[7];
    const std::uint32_t recordBytes = header[8];
    const std::uint32_t recordCount = header[9];
    const std::uint64_t sequence = word64(header, 10);
    const std::uint64_t audioFrames = word64(header, 14);
    if (magic != nds4mister::kLayerPublicationMagic ||
        abi != kCompactAbi || headerBytes != sizeof(header) ||
        slot > 1 || frameBytes != kCompactFrameBytes ||
        recordBytes != 2 || recordCount != kCompactPixels ||
        audioFrames > 4096)
        throw std::runtime_error("invalid compact publication header");

    auto* bytes = static_cast<volatile const std::uint8_t*>(mapping);
    auto* pixels = reinterpret_cast<volatile const std::uint16_t*>(
        bytes + nds4mister::kLayerSlotBytes * (slot + 1u));
    std::size_t whitePixels = 0;
    std::size_t zeroPixels = 0;
    for (std::size_t index = 0; index < kCompactPixels; ++index) {
        const std::uint16_t pixel = pixels[index];
        whitePixels += pixel == 0x7fffu;
        zeroPixels += pixel == 0;
    }
    auto* audio = pixels + kCompactPixels;
    std::size_t nonzeroAudioSamples = 0;
    for (std::size_t index = 0; index < audioFrames * 2u; ++index)
        nonzeroAudioSamples += audio[index] != 0;

    const std::uint32_t frameCrc =
        crc32(reinterpret_cast<volatile const std::uint8_t*>(pixels),
              kCompactFrameBytes);
    const std::uint32_t inputWord = deviceWords[16];
    std::cout << "generation=" << generation
              << " sequence=" << sequence
              << " slot=" << slot
              << " frame_crc32=0x" << std::hex << frameCrc << std::dec
              << " white_pixels=" << whitePixels
              << " nonwhite_pixels=" << (kCompactPixels - whitePixels)
              << " zero_pixels=" << zeroPixels
              << " audio_frames=" << audioFrames
              << " nonzero_audio_samples=" << nonzeroAudioSamples
              << " input_word=0x" << std::hex << inputWord << std::dec
              << "\n";
    munmap(mapping, kMapBytes);
    return 0;
} catch (const std::exception& error) {
    std::cerr << "nds_compact_publication_probe: " << error.what() << "\n";
    return 1;
}
