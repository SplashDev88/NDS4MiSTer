#include "replay/Hybrid3DAbi.h"

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <fcntl.h>
#include <iostream>
#include <stdexcept>
#include <sys/mman.h>
#include <thread>
#include <unistd.h>

namespace {

using nds4mister::h3d::FrameDescriptor;
using nds4mister::h3d::Header;

constexpr off_t PhysicalBase = 0x3fc00000;
constexpr std::size_t HeaderMappingBytes = 0x1000;
constexpr off_t PublicationPhysicalBase = 0x3fd00000;
constexpr std::size_t PublicationMappingBytes = 0x300000;
constexpr std::size_t Bank0Offset = 0;
constexpr std::size_t BankStride = 0x40000;
constexpr std::size_t FullFramebufferOffset = 0x100000;

void device_barrier()
{
#if defined(__arm__) || defined(__aarch64__)
    asm volatile("dmb sy" ::: "memory");
#else
    __sync_synchronize();
#endif
}

std::uint64_t hash_plane_grid(const std::uint32_t* pixels)
{
    // A stable 4x4 grid samples 3,072 pixels across the complete image.  Full
    // uncached reads take long enough to cross publication boundaries on the
    // A9 and perturb the workload being measured.  This grid is dense enough
    // to detect ordinary DS 3D animation while reading only 1/16 of the plane.
    std::uint64_t hash = 1469598103934665603ull;
    for (std::size_t y = 0; y < nds4mister::h3d::PlaneHeight; y += 4) {
        for (std::size_t x = 0; x < nds4mister::h3d::PlaneWidth; x += 4) {
            hash ^= pixels[y * nds4mister::h3d::PlaneWidth + x];
            hash *= 1099511628211ull;
        }
    }
    return hash;
}

} // namespace

int main(int argc, char** argv)
try {
    unsigned duration_seconds = 8;
    if (argc == 2) {
        char* end = nullptr;
        const auto parsed = std::strtoul(argv[1], &end, 10);
        if (!end || *end || parsed < 1 || parsed > 60)
            throw std::runtime_error("duration must be 1..60 seconds");
        duration_seconds = static_cast<unsigned>(parsed);
    } else if (argc != 1) {
        throw std::runtime_error("usage: h3d_distinct_frame_sampler [seconds]");
    }

    const int header_fd = open("/dev/mem", O_RDONLY | O_SYNC | O_CLOEXEC);
    if (header_fd < 0) throw std::runtime_error("could not open /dev/mem");
    void* const header_mapping = mmap(
        nullptr, HeaderMappingBytes, PROT_READ, MAP_SHARED,
        header_fd, PhysicalBase);
    close(header_fd);
    if (header_mapping == MAP_FAILED)
        throw std::runtime_error("could not map the H3D header");

    const int pixels_fd = open("/dev/mem", O_RDONLY | O_SYNC | O_CLOEXEC);
    if (pixels_fd < 0) {
        munmap(header_mapping, HeaderMappingBytes);
        throw std::runtime_error("could not open /dev/mem for publication pixels");
    }
    void* const pixels_mapping = mmap(
        nullptr, PublicationMappingBytes, PROT_READ, MAP_SHARED,
        pixels_fd, PublicationPhysicalBase);
    close(pixels_fd);
    if (pixels_mapping == MAP_FAILED) {
        munmap(header_mapping, HeaderMappingBytes);
        throw std::runtime_error("could not map the publication window");
    }

    const auto* const pixels_bytes =
        static_cast<const std::byte*>(pixels_mapping);
    const auto* const header =
        reinterpret_cast<const volatile Header*>(header_mapping);
    const auto started = std::chrono::steady_clock::now();
    const auto deadline = started + std::chrono::seconds(duration_seconds);

    std::uint32_t previous_sequence = 0;
    std::uint64_t previous_hash = 0;
    std::uint64_t observed = 0;
    std::uint64_t distinct = 0;
    std::uint64_t repeated = 0;
    std::uint64_t missed = 0;
    std::uint64_t torn = 0;
    std::uint32_t first_frame = 0;
    std::uint32_t last_frame = 0;

    while (std::chrono::steady_clock::now() < deadline) {
        const auto sequence = header->frame_publish_sequence;
        device_barrier();
        if ((sequence & 1u) != 0 || sequence == previous_sequence) {
            std::this_thread::sleep_for(std::chrono::microseconds(200));
            continue;
        }

        FrameDescriptor descriptor;
        descriptor.sequence = header->frame.sequence;
        descriptor.sequence_reserved = header->frame.sequence_reserved;
        descriptor.session = header->frame.session;
        descriptor.frame = header->frame.frame;
        descriptor.bank = header->frame.bank;
        descriptor.format = header->frame.format;
        descriptor.width_height = header->frame.width_height;
        descriptor.stride = header->frame.stride;
        device_barrier();
        if (header->frame_publish_sequence != sequence ||
            descriptor.sequence != sequence ||
            descriptor.sequence_reserved != 0 ||
            descriptor.width_height !=
                (nds4mister::h3d::PlaneWidth |
                 (nds4mister::h3d::PlaneHeight << 16)) ||
            descriptor.stride != nds4mister::h3d::PlaneStride) {
            ++torn;
            continue;
        }

        std::size_t offset = 0;
        if (descriptor.format == nds4mister::h3d::PixelFormatRgb666A5 &&
            descriptor.bank < 2) {
            offset = Bank0Offset + descriptor.bank * BankStride;
        } else if (
            descriptor.format == nds4mister::h3d::PixelFormatFullRgb666 &&
            descriptor.bank < nds4mister::h3d::FullFrameBankCount) {
            offset = FullFramebufferOffset +
                descriptor.bank * nds4mister::h3d::FullFrameBankStride;
        } else {
            munmap(pixels_mapping, PublicationMappingBytes);
            munmap(header_mapping, HeaderMappingBytes);
            throw std::runtime_error("unsupported published frame descriptor");
        }

        const auto hash = hash_plane_grid(reinterpret_cast<const std::uint32_t*>(
            pixels_bytes + offset));
        device_barrier();
        if (header->frame_publish_sequence != sequence) {
            ++torn;
            continue;
        }

        if (previous_sequence != 0 && sequence > previous_sequence + 2)
            missed += (sequence - previous_sequence) / 2 - 1;
        if (observed == 0) {
            first_frame = descriptor.frame;
        } else if (hash == previous_hash) {
            ++repeated;
        } else {
            ++distinct;
        }
        ++observed;
        previous_sequence = sequence;
        previous_hash = hash;
        last_frame = descriptor.frame;
    }

    const auto elapsed = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - started).count();
    munmap(pixels_mapping, PublicationMappingBytes);
    munmap(header_mapping, HeaderMappingBytes);
    const auto transitions = observed > 0 ? observed - 1 : 0;
    std::cout << "H3D_DISTINCT_FRAME_V2"
              << " elapsed_seconds=" << elapsed
              << " observed_publications=" << observed
              << " publication_fps=" << observed / elapsed
              << " distinct_transitions=" << distinct
              << " distinct_fps=" << distinct / elapsed
              << " repeated_transitions=" << repeated
              << " repeat_percent="
              << (transitions ? 100.0 * repeated / transitions : 0.0)
              << " missed_publications=" << missed
              << " torn_samples=" << torn
              << " sampled_pixels_per_frame="
              << (nds4mister::h3d::PlaneWidth / 4) *
                    (nds4mister::h3d::PlaneHeight / 4)
              << " first_frame=" << first_frame
              << " last_frame=" << last_frame << '\n';
    return 0;
} catch (const std::exception& error) {
    std::cerr << "h3d_distinct_frame_sampler: " << error.what() << '\n';
    return 1;
}
