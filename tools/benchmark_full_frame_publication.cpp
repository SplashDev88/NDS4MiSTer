#include "replay/Hybrid3DAbi.h"
#include <algorithm>
#include <chrono>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <unistd.h>

using namespace nds4mister::h3d;

// Explicit opt-in only, with the core stopped. The header is private process
// RAM: this probe never commits an FPGA descriptor or touches control pages.
int main(int argc, char** argv) try
{
    const bool physical = argc == 2 && std::string(argv[1]) == "--wc-menu";
    if (argc > 1 && !physical) throw std::runtime_error("usage: benchmark [--wc-menu]");
    constexpr auto Bytes = FullFrameBankCount * FullFrameBankStride;
    std::vector<std::uint32_t> cached(Bytes / 4, 0);
    auto* output = cached.data();
    int lock = -1;
    if (physical) {
        std::string core;
        std::ifstream("/tmp/CORENAME") >> core;
        if (core != "MENU" || access("/tmp/nds-standalone-guard-ready", F_OK) == 0)
            throw std::runtime_error("standalone must have exited to MENU");
        lock = open("/tmp/nds-hybrid-3d-service.lock", O_RDWR | O_CREAT | O_CLOEXEC, 0600);
        if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0)
            throw std::runtime_error("renderer lease busy");
        const int fd = open("/dev/nds_mem_wc", O_RDWR | O_SYNC | O_CLOEXEC);
        if (fd < 0) throw std::runtime_error("WC module unavailable");
        void* mapped = mmap(nullptr, Bytes, PROT_READ | PROT_WRITE,
                            MAP_SHARED, fd, 0x3fe00000);
        close(fd);
        if (mapped == MAP_FAILED) throw std::runtime_error("WC mmap failed");
        output = static_cast<std::uint32_t*>(mapped);
    }
    // Four source pairs prevent a tiny, permanently L1-hot source fixture.
    std::vector<std::uint32_t> source(PlanePixels * 2 * 4);
    std::uint32_t random = 0x98765432u;
    for (auto& word : source) {
        random ^= random << 13; random ^= random >> 17; random ^= random << 5;
        word = random;
    }
    std::cout << "mapping=" << (physical ? "WC" : "cached") << '\n';
    for (const bool packed : {true, false}) {
        std::uint64_t reference_digest = 0;
        for (const bool fused : {false, true, true, false}) {
            Header header {};
            header.magic = Magic;
            header.fpga_session = header.accepted_session = 7;
            header.quiesce_request = header.quiesce_ack = 7;
            FullFramePublisher publisher(header, output, fused);
            auto frame = [&](unsigned n) {
                const auto* top = source.data() + (n % 4) * PlanePixels * 2;
                if (!publisher.publish(7, n, top, top + PlanePixels, packed))
                    throw std::runtime_error("publish rejected");
                header.frame_ack_sequence = header.frame_publish_sequence;
            };
            for (unsigned n = 0; n < 64; ++n) frame(n);
            constexpr unsigned Frames = 512;
            for (unsigned sample = 0; sample < 3; ++sample) {
                const auto begin = std::chrono::steady_clock::now();
                for (unsigned n = 0; n < Frames; ++n) frame(n);
                const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                    std::chrono::steady_clock::now() - begin).count();
                std::uint64_t digest = 1469598103934665603ull;
                for (unsigned bank = 0; bank < 4; ++bank) {
                    const auto source_index = (bank + 3) % 4;
                    for (unsigned screen = 0; screen < 2; ++screen) {
                        const auto* in = source.data() +
                            (source_index * 2 + screen) * PlanePixels;
                        const auto* out = output + bank * FullFrameBankStride / 4 +
                            screen * FullFrameScreenStride / 4;
                        for (unsigned i = 0; i < PlanePixels; ++i) {
                            const auto wanted = packed ? pack_melonds_pixel(in[i]) & 0x3ffffu :
                                pack_melonds_framebuffer_pixel(in[i]);
                            if (out[i] != wanted) throw std::runtime_error("pixel mismatch");
                            digest = (digest ^ out[i]) * 1099511628211ull;
                        }
                    }
                }
                if (!reference_digest) reference_digest = digest;
                if (digest != reference_digest) throw std::runtime_error("digest mismatch");
                std::cout << "packed=" << packed << " fused=" << fused << " sample=" << sample
                          << " frames=" << Frames << " ns=" << ns
                          << " ns_per_frame=" << double(ns) / Frames
                          << " digest=" << digest << '\n' << std::flush;
            }
        }
    }
    if (physical) munmap(output, Bytes);
    if (lock >= 0) close(lock);
    return 0;
} catch (const std::exception& e) {
    std::cerr << "FAIL: " << e.what() << '\n';
    return 1;
}
