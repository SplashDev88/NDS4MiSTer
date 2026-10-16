#include "replay/Hybrid3DAbi.h"

#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <vector>

using namespace nds4mister::h3d;

namespace {
void require(bool ok, const char* message)
{
    if (!ok) { std::cerr << "FAIL: " << message << '\n'; std::exit(1); }
}

// Independent channel extraction; do not call either production packer.
std::uint32_t expected(std::uint32_t pixel, bool packed)
{
    const auto r = packed ? pixel & 63u : (pixel / 0x40000u) & 63u;
    const auto g = packed ? (pixel / 0x100u) & 63u : (pixel / 0x400u) & 63u;
    const auto b = packed ? (pixel / 0x10000u) & 63u : (pixel / 4u) & 63u;
    return r + 64u * g + 4096u * b;
}

Header ready()
{
    Header h {};
    h.magic = Magic;
    h.fpga_session = h.accepted_session = 7;
    h.quiesce_request = h.quiesce_ack = 7;
    return h;
}
}

int main()
{
    constexpr std::uint32_t Sentinel = 0xdeadc0de;
    constexpr auto Words = FullFrameBankCount * FullFrameBankStride / 4;
    std::vector<std::uint32_t> top(PlanePixels + 4), bottom(PlanePixels + 4);
    std::uint64_t comparisons = 0, digest = 1469598103934665603ull;
    std::uint32_t random = 0x12345678;
    for (const bool fused : {false, true}) {
        for (const bool packed : {false, true}) {
            auto header = ready();
            std::vector<std::uint32_t> storage(Words + 8, Sentinel);
            std::vector<std::uint32_t> reference = storage;
            auto* pixels = storage.data() + 4;
            FullFramePublisher publisher(header, pixels, fused);
            for (unsigned frame = 0; frame < 16; ++frame) {
                // Unaligned-to-16-byte sources; exhaustive 18-bit RGB plus
                // changing discarded/alpha bits, then full random words.
                for (unsigned screen = 0; screen < 2; ++screen) {
                    auto* source = (screen ? bottom : top).data() + 1;
                    for (std::size_t i = 0; i < PlanePixels; ++i) {
                        random ^= random << 13; random ^= random >> 17;
                        random ^= random << 5;
                        const auto color = (frame * PlanePixels * 2 +
                                            screen * PlanePixels + i) & 0x3ffffu;
                        const auto r = color & 63u, g = (color >> 6) & 63u;
                        const auto b = (color >> 12) & 63u;
                        source[i] = frame >= 8 ? random : packed ?
                            (r | (g << 8) | (b << 16) | (random & 0xffc0c0c0u)) :
                            ((r << 18) | (g << 10) | (b << 2) |
                             (random & 0xff030303u));
                    }
                }
                const auto source_top = top, source_bottom = bottom;
                require(publisher.publish(7, frame, top.data() + 1,
                                          bottom.data() + 1, packed), "publication");
                const auto bank = (frame + 1) & 3u;
                require(header.frame.bank == bank && header.frame.frame == frame &&
                        header.frame.session == 7 && header.frame.sequence == 2 * (frame + 1) &&
                        header.frame_publish_sequence == header.frame.sequence &&
                        header.frame.format == PixelFormatFullRgb666 &&
                        header.frame.width_height == (256u | (192u << 16)) &&
                        header.frame.stride == 1024, "descriptor and bank rotation");
                require(publisher.last_store_count() == PlanePixels * 2, "store count");
                for (unsigned screen = 0; screen < 2; ++screen) {
                    const auto* source = (screen ? bottom : top).data() + 1;
                    auto* out = reference.data() + 4 + bank * FullFrameBankStride / 4 +
                                screen * FullFrameScreenStride / 4;
                    for (std::size_t i = 0; i < PlanePixels; ++i) {
                        out[i] = expected(source[i], packed);
                        digest = (digest ^ out[i]) * 1099511628211ull;
                        ++comparisons;
                    }
                }
                require(storage == reference, "pixels, padding or other bank changed");
                require(top == source_top && bottom == source_bottom, "immutable source");
                const auto saved_header = header;
                require(!publisher.publish(7, frame + 1, top.data() + 1,
                                           bottom.data() + 1, packed), "unacked publication accepted");
                require(storage == reference &&
                        std::memcmp(&header, &saved_header, sizeof(header)) == 0 &&
                        publisher.last_store_count() == 0, "unacked publication wrote data");
                header.frame_ack_sequence = header.frame_publish_sequence;
            }
        }
        for (unsigned fault = 0; fault < 12; ++fault) {
            auto header = ready();
            switch (fault) {
            case 0: header.magic = QuiesceMagic; break;
            case 1: ++header.fpga_session; break;
            case 2: ++header.accepted_session; break;
            case 3: ++header.quiesce_request; break;
            case 4: header.quiesce_request_reserved = 1; break;
            case 5: header.quiesce_ack_reserved = 1; break;
            case 6: header.frame_publish_sequence_reserved = 1; break;
            case 7: header.frame_ack_sequence_reserved = 1; break;
            case 8: header.frame_publish_sequence = header.frame_ack_sequence = 1; break;
            case 9: header.frame_publish_sequence = header.frame_ack_sequence = 0xfffffffeu; break;
            default: break;
            }
            std::vector<std::uint32_t> storage(Words, Sentinel);
            const auto saved_header = header;
            FullFramePublisher publisher(header, fault == 10 ? nullptr : storage.data(), fused);
            require(!publisher.publish(7, 0, fault == 11 ? nullptr : top.data(),
                                       bottom.data()), "invalid publication accepted");
            require(std::all_of(storage.begin(), storage.end(),
                               [](auto v) { return v == Sentinel; }) &&
                    std::memcmp(&header, &saved_header, sizeof(header)) == 0,
                    "invalid publication wrote data");
        }
#if defined(NDS4MISTER_H3D_TEST_INSTRUMENTATION)
        for (unsigned fault = 0; fault < 2; ++fault) {
            auto header = ready();
            std::vector<std::uint32_t> storage(Words, Sentinel);
            FullFramePublisher publisher(header, storage.data(), fused);
            full_frame_before_commit_test_hook = fault == 0 ?
                +[](Header* h) { ++h->quiesce_request; } :
                +[](Header* h) { h->magic = QuiesceMagic; };
            require(!publisher.publish(7, 0, top.data(), bottom.data(), true),
                    "reset during pixel upload committed a descriptor");
            full_frame_before_commit_test_hook = nullptr;
            require(header.frame_publish_sequence == 0 && header.frame.sequence == 0,
                    "reset advanced publication");
            header = ready();
            require(publisher.publish(7, 1, top.data(), bottom.data(), true) &&
                    header.frame.bank == 1, "failed upload advanced bank ownership");
        }
#endif
    }
    std::cout << "PASS full-frame publication pixels=" << comparisons
              << " digest=" << digest << " paths=staged,fused formats=2 banks=4\n";
}
