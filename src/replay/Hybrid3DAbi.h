#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <atomic>
#include <limits>
#include <memory>
#include <type_traits>

#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif

namespace nds4mister::h3d {

constexpr std::uint32_t Magic = 0x31443348u; // H3D1
constexpr std::uint32_t QuiesceMagic = 0x51443348u; // H3DQ
constexpr std::uint16_t Version = 1;
constexpr std::uint16_t HeaderSize = 128;
constexpr std::uint32_t EventSize = 32;
constexpr std::uint32_t DefaultEntryCount = 16384;
constexpr std::uint32_t PixelFormatRgb666A5 = 1;
constexpr std::uint32_t PixelFormatFullRgb666 = 2;
constexpr std::uint32_t PixelFormatRgb666A5EngineB = 3;
constexpr std::uint32_t PlaneWidth = 256;
constexpr std::uint32_t PlaneHeight = 192;
constexpr std::uint32_t PlaneStride = PlaneWidth * sizeof(std::uint32_t);
constexpr std::size_t PlanePixels =
    std::size_t(PlaneWidth) * PlaneHeight;
constexpr std::size_t PlaneBytes = PlanePixels * sizeof(std::uint32_t);
constexpr std::size_t EngineBBankCount = 2;
constexpr std::size_t EngineBBankStride = 0x40000;
constexpr std::size_t FullFrameBankCount = 4;
constexpr std::size_t FullFrameScreenStride = 0x40000;
constexpr std::size_t FullFrameBankStride = 0x80000;

#if defined(__GNUC__) || defined(__clang__)
__attribute__((noinline, hot))
#endif
inline bool equal_pixel_block_16(
    const std::uint32_t* first, const std::uint32_t* second) noexcept
{
#if defined(__ARM_NEON)
    auto difference = veorq_u32(
        vld1q_u32(first), vld1q_u32(second));
    difference = vorrq_u32(
        difference,
        veorq_u32(vld1q_u32(first + 4), vld1q_u32(second + 4)));
    difference = vorrq_u32(
        difference,
        veorq_u32(vld1q_u32(first + 8), vld1q_u32(second + 8)));
    difference = vorrq_u32(
        difference,
        veorq_u32(vld1q_u32(first + 12), vld1q_u32(second + 12)));
    const auto folded = vorr_u32(
        vget_low_u32(difference), vget_high_u32(difference));
    return (vget_lane_u32(folded, 0) |
            vget_lane_u32(folded, 1)) == 0;
#else
    return std::memcmp(
        first, second, 16 * sizeof(std::uint32_t)) == 0;
#endif
}

inline void pack_melonds_pixel_block_16(
    std::uint32_t* destination, const std::uint32_t* source) noexcept
{
#if defined(__ARM_NEON)
    const auto red_mask = vdupq_n_u32(0x0000003fu);
    const auto green_mask = vdupq_n_u32(0x00000fc0u);
    const auto blue_mask = vdupq_n_u32(0x0003f000u);
    const auto alpha_mask = vdupq_n_u32(0x007c0000u);
    for (std::size_t offset = 0; offset < 16; offset += 4) {
        const auto pixels = vld1q_u32(source + offset);
        auto packed = vandq_u32(pixels, red_mask);
        packed = vorrq_u32(
            packed, vandq_u32(vshrq_n_u32(pixels, 2), green_mask));
        packed = vorrq_u32(
            packed, vandq_u32(vshrq_n_u32(pixels, 4), blue_mask));
        packed = vorrq_u32(
            packed, vandq_u32(vshrq_n_u32(pixels, 6), alpha_mask));
        vst1q_u32(destination + offset, packed);
    }
#else
    for (std::size_t offset = 0; offset < 16; ++offset) {
        const auto pixel = source[offset];
        destination[offset] = (pixel & 0x0000003fu) |
            ((pixel >> 2) & 0x00000fc0u) |
            ((pixel >> 4) & 0x0003f000u) |
            ((pixel >> 6) & 0x007c0000u);
    }
#endif
}

// WC publication needs both a private copy for future dirty detection and a
// packed shared copy for the FPGA. Load each source cache line once and emit
// both destinations in the same NEON pass; this avoids a separate memcpy and
// a second source read for every changed block.
inline void pack_and_cache_melonds_pixel_block_16(
    std::uint32_t* packed_destination,
    std::uint32_t* source_cache,
    const std::uint32_t* source) noexcept
{
#if defined(__ARM_NEON)
    const auto red_mask = vdupq_n_u32(0x0000003fu);
    const auto green_mask = vdupq_n_u32(0x00000fc0u);
    const auto blue_mask = vdupq_n_u32(0x0003f000u);
    const auto alpha_mask = vdupq_n_u32(0x007c0000u);
    for (std::size_t offset = 0; offset < 16; offset += 4) {
        const auto pixels = vld1q_u32(source + offset);
        vst1q_u32(source_cache + offset, pixels);
        auto packed = vandq_u32(pixels, red_mask);
        packed = vorrq_u32(
            packed, vandq_u32(vshrq_n_u32(pixels, 2), green_mask));
        packed = vorrq_u32(
            packed, vandq_u32(vshrq_n_u32(pixels, 4), blue_mask));
        packed = vorrq_u32(
            packed, vandq_u32(vshrq_n_u32(pixels, 6), alpha_mask));
        vst1q_u32(packed_destination + offset, packed);
    }
#else
    for (std::size_t offset = 0; offset < 16; ++offset) {
        const auto pixel = source[offset];
        source_cache[offset] = pixel;
        packed_destination[offset] = (pixel & 0x0000003fu) |
            ((pixel >> 2) & 0x00000fc0u) |
            ((pixel >> 4) & 0x0003f000u) |
            ((pixel >> 6) & 0x007c0000u);
    }
#endif
}

enum class ServiceState : std::uint32_t {
    Offline = 0,
    Initializing = 1,
    Ready = 2,
    Fault = 3,
    RestartRequested = 4,
};

enum class EventType : std::uint8_t {
    Arm9GpuIoWrite = 1,
    Arm9VramWrite = 2,
    Arm7VramWrite = 3,
    FrameBoundary = 4,
    SessionReset = 5,
};

enum class AccessWidth : std::uint8_t {
    Byte = 0,
    Half = 1,
    Word = 2,
};

enum Fault : std::uint32_t {
    FaultNone = 0,
    FaultBadHeader = 1ull << 0,
    FaultBadSession = 1ull << 1,
    FaultSequenceGap = 1ull << 2,
    FaultTornEvent = 1ull << 3,
    FaultBadEvent = 1ull << 4,
    FaultRingOverrun = 1ull << 5,
    FaultBadFrame = 1ull << 6,
    FaultArmCrash = 1ull << 7,
};

struct Event {
    std::uint32_t address;
    std::uint32_t data;
    std::uint32_t frame;
    std::uint32_t metadata;
    std::uint32_t timestamp_low;
    std::uint32_t timestamp_high;
    std::uint32_t sequence;
    std::uint32_t sequence_reserved;
};

struct FrameDescriptor {
    std::uint32_t sequence;
    std::uint32_t sequence_reserved;
    std::uint32_t session;
    std::uint32_t frame;
    std::uint32_t bank;
    std::uint32_t format;
    std::uint32_t width_height;
    std::uint32_t stride;
};

struct Header {
    std::uint32_t magic;
    std::uint16_t version;
    std::uint16_t header_size;
    std::uint32_t fpga_session;
    std::uint32_t entry_count;
    std::uint32_t producer_sequence;
    std::uint32_t producer_sequence_reserved;
    std::uint32_t consumer_sequence;
    std::uint32_t consumer_sequence_reserved;
    std::uint32_t fpga_fault_bits;
    std::uint32_t hps_fault_bits;
    std::uint32_t service_state;
    std::uint32_t accepted_session;
    std::uint32_t frame_publish_sequence;
    std::uint32_t frame_publish_sequence_reserved;
    std::uint32_t frame_ack_sequence;
    std::uint32_t frame_ack_sequence_reserved;
    FrameDescriptor frame;
    std::uint32_t fpga_heartbeat;
    // Tagged public crash telemetry. The historical field name is retained
    // so the fixed 128-byte H3D1 layout and existing binaries remain ABI-safe.
    std::uint32_t fpga_heartbeat_reserved;
    std::uint32_t hps_heartbeat;
    // Nonzero only while HPS requests a bounded manual FPGA/CPU snapshot.
    std::uint32_t hps_heartbeat_reserved;
    std::uint32_t quiesce_request;
    std::uint32_t quiesce_request_reserved;
    std::uint32_t quiesce_ack;
    std::uint32_t quiesce_ack_reserved;
};

static_assert(sizeof(Event) == EventSize);
static_assert(sizeof(FrameDescriptor) == 32);
static_assert(sizeof(Header) == HeaderSize);
static_assert(std::is_standard_layout_v<Event>);
static_assert(std::is_standard_layout_v<Header>);
static_assert(offsetof(Header, producer_sequence) == 0x10);
static_assert(offsetof(Header, consumer_sequence) == 0x18);
static_assert(offsetof(Header, fpga_fault_bits) == 0x20);
static_assert(offsetof(Header, hps_fault_bits) == 0x24);
static_assert(offsetof(Header, service_state) == 0x28);
static_assert(offsetof(Header, frame_publish_sequence) == 0x30);
static_assert(offsetof(Header, frame_ack_sequence) == 0x38);
static_assert(offsetof(Header, frame) == 0x40);
static_assert(offsetof(Header, quiesce_request) == 0x70);
static_assert(offsetof(Header, quiesce_ack) == 0x78);

constexpr std::uint32_t make_metadata(
    EventType type, bool arm7, AccessWidth width, std::uint8_t byte_enable,
    std::uint32_t flags = 0)
{
    return static_cast<std::uint32_t>(type) |
        (static_cast<std::uint32_t>(arm7) << 8) |
        (static_cast<std::uint32_t>(width) << 9) |
        ((static_cast<std::uint32_t>(byte_enable) & 0x0fu) << 11) |
        ((flags & 0x1ffffu) << 15);
}

constexpr EventType event_type(const Event& event)
{
    return static_cast<EventType>(event.metadata & 0xffu);
}

constexpr bool event_is_arm7(const Event& event)
{
    return ((event.metadata >> 8) & 1u) != 0;
}

constexpr AccessWidth event_width(const Event& event)
{
    return static_cast<AccessWidth>((event.metadata >> 9) & 3u);
}

constexpr std::uint8_t event_byte_enable(const Event& event)
{
    return static_cast<std::uint8_t>((event.metadata >> 11) & 0x0fu);
}

constexpr std::uint64_t event_timestamp(const Event& event)
{
    return std::uint64_t(event.timestamp_low) |
        (std::uint64_t(event.timestamp_high) << 32);
}

// The HPS mapping is shared with an external FPGA master. ARMv7 64-bit
// atomics use LDREXD/STREXD and are not a valid portable operation on Device
// memory. Every shared fence therefore uses one naturally aligned 32-bit low
// word and a high word that must remain zero. The explicit system barrier is
// also stronger than a normal C++ inter-thread fence on ARM.
#if defined(NDS4MISTER_H3D_TEST_INSTRUMENTATION)
inline std::uint64_t device_barrier_test_count = 0;
using EventPayloadSnapshotTestHook = void (*)(Event*);
inline EventPayloadSnapshotTestHook event_payload_snapshot_test_hook = nullptr;
using SessionSnapshotTestHook = void (*)(Header*);
inline SessionSnapshotTestHook session_snapshot_test_hook = nullptr;

inline void reset_device_barrier_test_count()
{
    device_barrier_test_count = 0;
}
#endif

inline void device_barrier()
{
#if defined(NDS4MISTER_H3D_TEST_INSTRUMENTATION)
    ++device_barrier_test_count;
#endif
#if defined(__arm__) || defined(__aarch64__)
    __asm__ __volatile__("dmb sy" ::: "memory");
#else
    std::atomic_thread_fence(std::memory_order_seq_cst);
#endif
}

// Normal non-cacheable/write-combined framebuffer stores may remain posted
// after a DMB. Complete those writes before publishing the descriptor that
// lets the FPGA consume them. Control/register ordering continues to use the
// cheaper device_barrier(); only bulk pixel publication needs this DSB.
inline void publication_barrier()
{
#if defined(NDS4MISTER_H3D_TEST_INSTRUMENTATION)
    ++device_barrier_test_count;
#endif
#if defined(__arm__) || defined(__aarch64__)
    __asm__ __volatile__("dsb sy" ::: "memory");
#else
    std::atomic_thread_fence(std::memory_order_seq_cst);
#endif
}

inline std::uint32_t load_volatile(const std::uint32_t* address)
{
    const auto* shared = reinterpret_cast<volatile const std::uint32_t*>(
        address);
    return *shared;
}

inline std::uint16_t load_volatile(const std::uint16_t* address)
{
    const auto* shared = reinterpret_cast<volatile const std::uint16_t*>(
        address);
    return *shared;
}

inline std::uint32_t load_acquire(const std::uint32_t* address)
{
    const auto value = load_volatile(address);
    device_barrier();
    return value;
}

inline std::uint16_t load_acquire(const std::uint16_t* address)
{
    const auto value = load_volatile(address);
    device_barrier();
    return value;
}

inline bool load_counter(
    const std::uint32_t* low, const std::uint32_t* reserved,
    std::uint32_t& value)
{
    // These three naturally aligned Device-memory reads are one snapshot.
    // Volatile preserves their compiler order; Device memory preserves their
    // bus order; the single trailing DMB completes the snapshot before any
    // caller can act on it.  Re-reading the reserved high word still detects a
    // malformed/torn writer without paying one system barrier per field.
    const auto high_before = load_volatile(reserved);
    const auto low_value = load_volatile(low);
    const auto high_after = load_volatile(reserved);
    device_barrier();
    if (high_before != 0 || high_after != 0) return false;
    value = low_value;
    return true;
}

inline bool active_session_current(
    const Header& header, std::uint32_t session,
    std::uint32_t quiesce_generation, bool require_accepted)
{
    // The FPGA publishes the next quiesce request and then H3DQ before it can
    // reuse any session/HPS-owned field; a fresh H3D1 magic is published last.
    // Take the complete ownership snapshot as ordered volatile Device-memory
    // reads, bracket it with magic, then use one trailing system barrier before
    // the caller acts. A request/ack mismatch catches the short pre-H3DQ window.
    // H3DQ cannot return to H3D1 without this generation's HPS acknowledgement,
    // so equal H3D1 fences cannot hide an intervening lifecycle transition.
    const auto magic_before = load_volatile(&header.magic);
    const auto fpga_session = load_volatile(&header.fpga_session);
    const auto accepted_session = load_volatile(&header.accepted_session);
    const auto request_high_before =
        load_volatile(&header.quiesce_request_reserved);
    const auto request = load_volatile(&header.quiesce_request);
    const auto request_high_after =
        load_volatile(&header.quiesce_request_reserved);
    const auto ack_high_before =
        load_volatile(&header.quiesce_ack_reserved);
    const auto acknowledged = load_volatile(&header.quiesce_ack);
    const auto ack_high_after =
        load_volatile(&header.quiesce_ack_reserved);
#if defined(NDS4MISTER_H3D_TEST_INSTRUMENTATION)
    if (session_snapshot_test_hook)
        session_snapshot_test_hook(const_cast<Header*>(&header));
#endif
    const auto magic_after = load_volatile(&header.magic);
    device_barrier();

    const bool generation_current = quiesce_generation != 0
        ? request == quiesce_generation &&
            acknowledged == quiesce_generation
        : request != 0 && acknowledged == request;
    return session != 0 &&
        magic_before == Magic && magic_after == Magic &&
        fpga_session == session &&
        (!require_accepted || accepted_session == session) &&
        request_high_before == 0 && request_high_after == 0 &&
        ack_high_before == 0 && ack_high_after == 0 &&
        generation_current;
}

inline void store_release(std::uint32_t* address, std::uint32_t value)
{
    device_barrier();
    auto* shared = reinterpret_cast<volatile std::uint32_t*>(address);
    *shared = value;
    device_barrier();
}

inline void store_counter(
    std::uint32_t* low, std::uint32_t* reserved, std::uint32_t value)
{
    store_release(reserved, 0);
    store_release(low, value);
}

constexpr std::uint32_t pack_melonds_pixel(std::uint32_t pixel)
{
    return (pixel & 0x0000003fu) |
        ((pixel >> 2) & 0x00000fc0u) |
        ((pixel >> 4) & 0x0003f000u) |
        ((pixel >> 6) & 0x007c0000u);
}

// melonDS's complete 2D framebuffer is AARRGGBB. MiSTer's established DS
// framebuffer stores {14'b0,BGR666}, one 32-bit word per pixel.
constexpr std::uint32_t pack_melonds_framebuffer_pixel(std::uint32_t pixel)
{
    return ((pixel >> 18) & 0x0000003fu) |
        ((pixel >> 4) & 0x00000fc0u) |
        ((pixel << 10) & 0x0003f000u);
}

class FullFramePublisher {
public:
    FullFramePublisher(Header& header, std::uint32_t* framebuffer)
        : header_(header), framebuffer_(framebuffer)
    {
    }

    bool publish(
        std::uint32_t session, std::uint32_t frame,
        const std::uint32_t* top, const std::uint32_t* bottom,
        bool packed_input = false)
    {
        last_store_count_ = 0;
        if (!framebuffer_ || !top || !bottom) return false;
        const auto quiesce = load_acquire(&header_.quiesce_request);
        if (load_acquire(&header_.magic) != Magic ||
            load_acquire(&header_.fpga_session) != session ||
            load_acquire(&header_.accepted_session) != session ||
            load_acquire(&header_.quiesce_request_reserved) != 0 ||
            load_acquire(&header_.quiesce_ack_reserved) != 0 ||
            load_acquire(&header_.quiesce_ack) != quiesce)
            return false;

        std::uint32_t published = 0;
        std::uint32_t acknowledged = 0;
        if (!load_counter(
                &header_.frame_publish_sequence,
                &header_.frame_publish_sequence_reserved, published) ||
            !load_counter(
                &header_.frame_ack_sequence,
                &header_.frame_ack_sequence_reserved, acknowledged) ||
            (published & 1u) != 0 || acknowledged != published ||
            published > std::numeric_limits<std::uint32_t>::max() - 2)
            return false;

        // Build the complete packed frame in private cached RAM first. The
        // old per-pixel volatile loop mixed color conversion with uncached
        // DDR stores, preventing the compiler from vectorizing either part.
        // Two bulk copies then push the already-complete screens to the
        // inactive shared bank; the descriptor is still committed only after
        // both copies and the device barrier, so partial output is invisible.
        const auto bank = next_bank_;
        auto* shared_bank =
            framebuffer_ + bank * (FullFrameBankStride / 4);
        const std::uint32_t* screens[2] {top, bottom};
        for (std::size_t screen = 0; screen < 2; ++screen) {
            auto* packed = packed_frame_.get() + screen * PlanePixels;
            for (std::size_t index = 0; index < PlanePixels; ++index) {
                packed[index] = packed_input ?
                    pack_melonds_pixel(screens[screen][index]) &
                        0x0003ffffu :
                    pack_melonds_framebuffer_pixel(screens[screen][index]);
            }
            auto* destination = shared_bank +
                screen * (FullFrameScreenStride / 4);
            std::memcpy(destination, packed, PlaneBytes);
            last_store_count_ += PlanePixels;
        }
        publication_barrier();

        if (load_acquire(&header_.magic) != Magic ||
            load_acquire(&header_.fpga_session) != session ||
            load_acquire(&header_.accepted_session) != session ||
            load_acquire(&header_.quiesce_request) != quiesce ||
            load_acquire(&header_.quiesce_request_reserved) != 0 ||
            load_acquire(&header_.quiesce_ack) != quiesce ||
            load_acquire(&header_.quiesce_ack_reserved) != 0)
            return false;

        const auto odd = published + 1;
        const auto even = published + 2;
        store_counter(
            &header_.frame_publish_sequence,
            &header_.frame_publish_sequence_reserved, odd);
        FrameDescriptor descriptor{};
        descriptor.sequence = even;
        descriptor.session = session;
        descriptor.frame = frame;
        descriptor.bank = bank;
        descriptor.format = PixelFormatFullRgb666;
        descriptor.width_height = PlaneWidth | (PlaneHeight << 16);
        descriptor.stride = PlaneStride;
        store_release(&header_.frame.sequence, descriptor.sequence);
        store_release(
            &header_.frame.sequence_reserved,
            descriptor.sequence_reserved);
        store_release(&header_.frame.session, descriptor.session);
        store_release(&header_.frame.frame, descriptor.frame);
        store_release(&header_.frame.bank, descriptor.bank);
        store_release(&header_.frame.format, descriptor.format);
        store_release(
            &header_.frame.width_height, descriptor.width_height);
        store_release(&header_.frame.stride, descriptor.stride);
        device_barrier();
        store_counter(
            &header_.frame_publish_sequence,
            &header_.frame_publish_sequence_reserved, even);
        next_bank_ = (next_bank_ + 1u) & 3u;
        return true;
    }

    std::size_t last_store_count() const noexcept {
        return last_store_count_;
    }

private:
    Header& header_;
    std::uint32_t* framebuffer_ = nullptr;
    // Bank zero is the FPGA scanout reset bank. The first ARM publication
    // starts in bank one and never reuses any bank before descriptor ACK.
    std::uint32_t next_bank_ = 1;
    std::size_t last_store_count_ = 0;
    std::unique_ptr<std::uint32_t[]> packed_frame_ {
        new std::uint32_t[PlanePixels * 2] {}};
};

class PlanePublisher {
public:
    PlanePublisher(
        Header& header, std::uint32_t* bank0, std::uint32_t* bank1,
        bool write_combined = false,
        std::uint32_t* framebuffer = nullptr)
        : header_(header), banks_{bank0, bank1},
          write_combined_(write_combined), framebuffer_(framebuffer)
    {
    }

    bool publish(
        std::uint32_t session, std::uint32_t frame,
        const std::uint32_t* melon_pixels,
        std::atomic<bool>* publication_fence_active = nullptr,
        const std::uint32_t* engine_b_pixels = nullptr,
        bool engine_b_screen = false)
    {
        if (!melon_pixels) return false;
        return publish_lines_impl(
            session, frame,
            [melon_pixels](std::size_t line) {
                return melon_pixels + line * PlaneWidth;
            },
            publication_fence_active, engine_b_pixels, engine_b_screen);
    }

    bool publish_scanlines(
        std::uint32_t session, std::uint32_t frame,
        const std::array<const std::uint32_t*, PlaneHeight>& scanlines,
        std::atomic<bool>* publication_fence_active = nullptr,
        const std::uint32_t* engine_b_pixels = nullptr,
        bool engine_b_screen = false)
    {
        for (const auto* line : scanlines) {
            if (!line) return false;
        }
        return publish_lines_impl(
            session, frame,
            [&scanlines](std::size_t line) { return scanlines[line]; },
            publication_fence_active, engine_b_pixels, engine_b_screen);
    }

    // A direct scanline caller may use this while serializing all calls into
    // this publisher. Busy is not a fault: it only means the currently
    // displayed shared bank must remain immutable until FPGA acknowledgement.
    bool ready(std::uint32_t session) const
    {
        if (!banks_[0] || !banks_[1]) return false;
        const auto quiesce = load_acquire(&header_.quiesce_request);
        if (load_acquire(&header_.magic) != Magic ||
            load_acquire(&header_.fpga_session) != session ||
            load_acquire(&header_.accepted_session) != session ||
            load_acquire(&header_.quiesce_request_reserved) != 0 ||
            load_acquire(&header_.quiesce_ack_reserved) != 0 ||
            load_acquire(&header_.quiesce_ack) != quiesce)
            return false;

        std::uint32_t published = 0;
        std::uint32_t acknowledged = 0;
        if (!load_counter(
                &header_.frame_publish_sequence,
                &header_.frame_publish_sequence_reserved, published) ||
            !load_counter(
                &header_.frame_ack_sequence,
                &header_.frame_ack_sequence_reserved, acknowledged))
            return false;
        return (published & 1u) == 0 && acknowledged == published &&
            published <= std::numeric_limits<std::uint32_t>::max() - 2;
    }

private:
    template<typename LineSource>
    bool publish_lines_impl(
        std::uint32_t session, std::uint32_t frame,
        LineSource source_line,
        std::atomic<bool>* publication_fence_active,
        const std::uint32_t* engine_b_pixels,
        bool engine_b_screen)
    {
        last_store_count_ = 0;
        if (!banks_[0] || !banks_[1]) return false;
        const auto quiesce = load_acquire(&header_.quiesce_request);
        if (load_acquire(&header_.magic) != Magic ||
            load_acquire(&header_.fpga_session) != session ||
            load_acquire(&header_.accepted_session) != session ||
            load_acquire(&header_.quiesce_request_reserved) != 0 ||
            load_acquire(&header_.quiesce_ack_reserved) != 0 ||
            load_acquire(&header_.quiesce_ack) != quiesce)
            return false;

        std::uint32_t published = 0;
        std::uint32_t acknowledged = 0;
        if (!load_counter(
                &header_.frame_publish_sequence,
                &header_.frame_publish_sequence_reserved, published) ||
            !load_counter(
                &header_.frame_ack_sequence,
                &header_.frame_ack_sequence_reserved, acknowledged))
            return false;
        if ((published & 1u) != 0 || acknowledged != published)
            return false;
        if (published > std::numeric_limits<std::uint32_t>::max() - 2)
            return false;

        const auto bank = next_bank_;
        auto* shared_bank = banks_[bank];
        auto& packed_bank = packed_banks_[bank];
        auto& source_bank = source_banks_[bank];
        const bool initialize_bank = !bank_initialized_[bank];
        constexpr std::size_t BlockPixels = 16;
        static_assert((PlanePixels % BlockPixels) == 0);
        if (write_combined_) {
            // A WC mapping makes contiguous bursts cheap. Convert each
            // changed cache line in normal cached RAM, then issue one bulk
            // write instead of up to sixteen individually ordered stores.
            for (std::size_t y = 0; y < PlaneHeight; ++y) {
                const auto* line = source_line(y);
                if (!line) return false;
                const auto base = y * PlaneWidth;
                for (std::size_t x = 0; x < PlaneWidth;
                     x += BlockPixels) {
                    const auto index = base + x;
                    if (!initialize_bank && equal_pixel_block_16(
                            line + x, source_bank.data() + index))
                        continue;
                    // Source pixels use only RGB666A5 payload bits. A changed
                    // raw block therefore implies a changed packed block in
                    // normal renderer output. Write it directly to WC memory
                    // while the same loads refresh the private dirty cache.
                    pack_and_cache_melonds_pixel_block_16(
                        shared_bank + index, source_bank.data() + index,
                        line + x);
                    last_store_count_ += BlockPixels;
                }
            }
        } else {
            auto* volatile_bank =
                reinterpret_cast<volatile std::uint32_t*>(shared_bank);
            for (std::size_t y = 0; y < PlaneHeight; ++y) {
                const auto* line = source_line(y);
                if (!line) return false;
                const auto base = y * PlaneWidth;
                for (std::size_t x = 0; x < PlaneWidth;
                     x += BlockPixels) {
                    const auto index = base + x;
                    if (!initialize_bank && equal_pixel_block_16(
                            line + x, source_bank.data() + index))
                        continue;
                    for (std::size_t lane = 0; lane < BlockPixels; ++lane) {
                        const auto pixel_index = index + lane;
                        const auto source = line[x + lane];
                        source_bank[pixel_index] = source;
                        const auto packed = pack_melonds_pixel(source);
                        if (initialize_bank ||
                            packed_bank[pixel_index] != packed) {
                            volatile_bank[pixel_index] = packed;
                            packed_bank[pixel_index] = packed;
                            ++last_store_count_;
                        }
                    }
                }
            }
        }
        std::uint32_t engine_b_bank = 0;
        if (engine_b_pixels) {
            if (!framebuffer_) return false;
            engine_b_bank = next_engine_b_bank_;
            auto* shared_screen = framebuffer_ +
                engine_b_bank * (EngineBBankStride / 4);
            auto& source_screen = engine_b_source_banks_[engine_b_bank];
            const bool initialize_engine_b =
                !engine_b_bank_initialized_[engine_b_bank];
            auto* volatile_screen =
                reinterpret_cast<volatile std::uint32_t*>(shared_screen);
            for (std::size_t index = 0; index < PlanePixels;
                 index += BlockPixels) {
                if (!initialize_engine_b && equal_pixel_block_16(
                        engine_b_pixels + index,
                        source_screen.data() + index))
                    continue;
                if (write_combined_) {
                    // Engine-B-only rendering keeps PackedOutput enabled.
                    pack_and_cache_melonds_pixel_block_16(
                        shared_screen + index, source_screen.data() + index,
                        engine_b_pixels + index);
                    last_store_count_ += BlockPixels;
                } else {
                    for (std::size_t lane = 0; lane < BlockPixels; ++lane) {
                        const auto pixel_index = index + lane;
                        const auto source = engine_b_pixels[pixel_index];
                        source_screen[pixel_index] = source;
                        volatile_screen[pixel_index] =
                            pack_melonds_pixel(source) & 0x0003ffffu;
                        ++last_store_count_;
                    }
                }
            }
        }
        publication_barrier();

        // The full-plane copy is deliberately interruptible only at its
        // publication boundary.  If FPGA requested quiescence while the HPS
        // was copying, leave the descriptor untouched.  The console is held
        // in reset before that request is published, so these uncommitted
        // bank bytes can never become visible.
        if (load_acquire(&header_.magic) != Magic ||
            load_acquire(&header_.fpga_session) != session ||
            load_acquire(&header_.accepted_session) != session ||
            load_acquire(&header_.quiesce_request) != quiesce ||
            load_acquire(&header_.quiesce_request_reserved) != 0 ||
            load_acquire(&header_.quiesce_ack) != quiesce ||
            load_acquire(&header_.quiesce_ack_reserved) != 0) {
            bank_initialized_[bank] = false;
            return false;
        }

        // The odd sequence is a deliberate in-progress marker. Production's
        // input and publication workers share this publisher, so expose only
        // that tiny control-fence interval to the owner. A concurrent reader
        // can then drop optional derived work instead of misclassifying the
        // transient odd value as shared-memory corruption.
        if (publication_fence_active)
            publication_fence_active->store(true, std::memory_order_release);
        const auto odd = published + 1;
        const auto even = published + 2;
        store_counter(
            &header_.frame_publish_sequence,
            &header_.frame_publish_sequence_reserved, odd);
        FrameDescriptor descriptor{};
        descriptor.sequence = even;
        descriptor.session = session;
        descriptor.frame = frame;
        descriptor.bank = engine_b_pixels ?
            bank | (engine_b_bank << 1) |
                (static_cast<std::uint32_t>(engine_b_screen) << 2) :
            bank;
        descriptor.format = engine_b_pixels ?
            PixelFormatRgb666A5EngineB : PixelFormatRgb666A5;
        descriptor.width_height = PlaneWidth | (PlaneHeight << 16);
        descriptor.stride = PlaneStride;
        store_release(&header_.frame.sequence, descriptor.sequence);
        store_release(
            &header_.frame.sequence_reserved,
            descriptor.sequence_reserved);
        store_release(&header_.frame.session, descriptor.session);
        store_release(&header_.frame.frame, descriptor.frame);
        store_release(&header_.frame.bank, descriptor.bank);
        store_release(&header_.frame.format, descriptor.format);
        store_release(
            &header_.frame.width_height, descriptor.width_height);
        store_release(&header_.frame.stride, descriptor.stride);
        device_barrier();
        store_counter(
            &header_.frame_publish_sequence,
            &header_.frame_publish_sequence_reserved, even);
        if (publication_fence_active)
            publication_fence_active->store(false, std::memory_order_release);
        bank_initialized_[bank] = true;
        if (engine_b_pixels) {
            engine_b_bank_initialized_[engine_b_bank] = true;
            next_engine_b_bank_ ^= 1u;
        }
        last_published_bank_ = bank;
        last_published_bank_valid_ = true;
        next_bank_ ^= 1u;
        return true;
    }

public:
    // Publish a new architectural frame descriptor without rescanning or
    // rewriting pixels when the renderer proved its completed plane is
    // identical to the last plane already accepted by the FPGA. Reusing the
    // same immutable bank is safe only after the preceding descriptor ACK;
    // the normal changed-plane path keeps targeting the other bank.
    bool republish_last(
        std::uint32_t session, std::uint32_t frame,
        std::atomic<bool>* publication_fence_active = nullptr)
    {
        last_store_count_ = 0;
        if (!last_published_bank_valid_ ||
            !bank_initialized_[last_published_bank_])
            return false;
        const auto quiesce = load_acquire(&header_.quiesce_request);
        if (load_acquire(&header_.magic) != Magic ||
            load_acquire(&header_.fpga_session) != session ||
            load_acquire(&header_.accepted_session) != session ||
            load_acquire(&header_.quiesce_request_reserved) != 0 ||
            load_acquire(&header_.quiesce_ack_reserved) != 0 ||
            load_acquire(&header_.quiesce_ack) != quiesce)
            return false;

        std::uint32_t published = 0;
        std::uint32_t acknowledged = 0;
        if (!load_counter(
                &header_.frame_publish_sequence,
                &header_.frame_publish_sequence_reserved, published) ||
            !load_counter(
                &header_.frame_ack_sequence,
                &header_.frame_ack_sequence_reserved, acknowledged) ||
            (published & 1u) != 0 || acknowledged != published ||
            published > std::numeric_limits<std::uint32_t>::max() - 2)
            return false;

        // No framebuffer write occurs here, but retain the same second
        // lifecycle snapshot as a normal publication so reset/quiesce cannot
        // acquire a descriptor for an old session.
        if (load_acquire(&header_.magic) != Magic ||
            load_acquire(&header_.fpga_session) != session ||
            load_acquire(&header_.accepted_session) != session ||
            load_acquire(&header_.quiesce_request) != quiesce ||
            load_acquire(&header_.quiesce_request_reserved) != 0 ||
            load_acquire(&header_.quiesce_ack) != quiesce ||
            load_acquire(&header_.quiesce_ack_reserved) != 0)
            return false;

        if (publication_fence_active)
            publication_fence_active->store(true, std::memory_order_release);
        const auto odd = published + 1;
        const auto even = published + 2;
        store_counter(
            &header_.frame_publish_sequence,
            &header_.frame_publish_sequence_reserved, odd);
        FrameDescriptor descriptor{};
        descriptor.sequence = even;
        descriptor.session = session;
        descriptor.frame = frame;
        descriptor.bank = last_published_bank_;
        descriptor.format = PixelFormatRgb666A5;
        descriptor.width_height = PlaneWidth | (PlaneHeight << 16);
        descriptor.stride = PlaneStride;
        store_release(&header_.frame.sequence, descriptor.sequence);
        store_release(
            &header_.frame.sequence_reserved,
            descriptor.sequence_reserved);
        store_release(&header_.frame.session, descriptor.session);
        store_release(&header_.frame.frame, descriptor.frame);
        store_release(&header_.frame.bank, descriptor.bank);
        store_release(&header_.frame.format, descriptor.format);
        store_release(
            &header_.frame.width_height, descriptor.width_height);
        store_release(&header_.frame.stride, descriptor.stride);
        device_barrier();
        store_counter(
            &header_.frame_publish_sequence,
            &header_.frame_publish_sequence_reserved, even);
        if (publication_fence_active)
            publication_fence_active->store(false, std::memory_order_release);
        return true;
    }

public:
    std::size_t last_store_count() const
    {
        return last_store_count_;
    }

    // Diagnostics call these only while the owner serializes publication.
    // They expose the exact cached source that produced a descriptor bank,
    // allowing an on-demand comparison with the words actually in DDR.
    bool diagnostic_copy_plane_source(
        std::uint32_t bank, std::uint32_t* output) const noexcept
    {
        if (!output || bank >= 2 || !bank_initialized_[bank]) return false;
        std::memcpy(output, source_banks_[bank].data(), PlaneBytes);
        return true;
    }

    bool diagnostic_copy_engine_b_source(
        std::uint32_t bank, std::uint32_t* output) const noexcept
    {
        if (!output || bank >= EngineBBankCount ||
            !engine_b_bank_initialized_[bank])
            return false;
        std::memcpy(
            output, engine_b_source_banks_[bank].data(), PlaneBytes);
        return true;
    }

private:
    Header& header_;
    std::uint32_t* banks_[2];
    bool write_combined_ = false;
    std::uint32_t* framebuffer_ = nullptr;
    std::array<std::array<std::uint32_t, PlanePixels>, 2> source_banks_ {};
    std::array<std::array<std::uint32_t, PlanePixels>, 2> packed_banks_ {};
    std::array<bool, 2> bank_initialized_ {};
    std::array<std::array<std::uint32_t, PlanePixels>,
               EngineBBankCount> engine_b_source_banks_ {};
    std::array<bool, EngineBBankCount> engine_b_bank_initialized_ {};
    std::uint32_t next_bank_ = 0;
    std::uint32_t next_engine_b_bank_ = 1;
    std::uint32_t last_published_bank_ = 0;
    bool last_published_bank_valid_ = false;
    std::size_t last_store_count_ = 0;
};

class EventConsumer {
public:
    static constexpr std::uint32_t CreditBatchSize = 64;

    EventConsumer(void* mapping, std::size_t mapping_size)
        : bytes_(static_cast<std::byte*>(mapping)), size_(mapping_size)
    {
    }

    bool initialize(std::uint32_t expected_session)
    {
        if (!bytes_ || size_ < HeaderSize) return fail(FaultBadHeader);
        header_ = reinterpret_cast<Header*>(bytes_);
        const auto magic = load_acquire(&header_->magic);
        const auto entry_count = load_acquire(&header_->entry_count);
        if (magic != Magic || load_acquire(&header_->version) != Version ||
            load_acquire(&header_->header_size) != HeaderSize ||
            entry_count < 2 ||
            (entry_count & (entry_count - 1)) != 0 ||
            HeaderSize + std::size_t(entry_count) * EventSize > size_)
            return fail(FaultBadHeader);
        if (load_acquire(&header_->fpga_session) != expected_session)
            return fail(FaultBadSession);

        std::uint32_t request = 0;
        std::uint32_t acknowledged = 0;
        if (!load_counter(
                &header_->quiesce_request,
                &header_->quiesce_request_reserved, request) ||
            !load_counter(
                &header_->quiesce_ack,
                &header_->quiesce_ack_reserved, acknowledged) ||
            request == 0 || acknowledged != request)
            return fail(FaultBadSession);

        session_ = expected_session;
        quiesce_generation_ = request;
        entry_count_ = entry_count;
        credit_batch_size_ =
            entry_count < CreditBatchSize ? entry_count : CreditBatchSize;
        std::uint32_t consumer = 0;
        if (!load_counter(
                &header_->consumer_sequence,
                &header_->consumer_sequence_reserved, consumer) ||
            consumer == std::numeric_limits<std::uint32_t>::max())
            return fail(FaultBadHeader);
        published_consumer_ = consumer;
        expected_ = consumer + 1;
        pending_ = false;
        exhausted_ = false;
        store_release(&header_->accepted_session, session_);
        store_release(
            &header_->service_state,
            static_cast<std::uint32_t>(ServiceState::Ready));
        return true;
    }

    bool peek(Event& output)
    {
        if (!header_ || pending_) return false;
        if (!session_current())
            return fail(FaultBadSession);

        std::uint32_t producer = 0;
        std::uint32_t consumer = 0;
        if (!load_counter(
                &header_->producer_sequence,
                &header_->producer_sequence_reserved, producer) ||
            !load_counter(
                &header_->consumer_sequence,
                &header_->consumer_sequence_reserved, consumer))
            return fail(FaultBadHeader);
        if (consumer != published_consumer_)
            return fail(FaultSequenceGap);
        if (exhausted_) {
            if (producer == consumer &&
                consumer == std::numeric_limits<std::uint32_t>::max())
                return false;
            return fail(FaultSequenceGap);
        }
        if (producer < consumer || producer - consumer > entry_count_)
            return fail(FaultRingOverrun);
        if (producer < expected_) {
            if (published_consumer_ != expected_ - 1 &&
                !publish_credit(expected_ - 1))
                return false;
            return false;
        }

        Event* slot = event_slot(expected_);
        std::uint32_t first_commit = 0;
        if (!load_counter(
                &slot->sequence, &slot->sequence_reserved, first_commit))
            return fail(FaultTornEvent);
        if (first_commit < expected_) return false;
        if (first_commit > expected_) return fail(FaultSequenceGap);

        Event copy{};
        // The first commit snapshot above is the acquire fence for this slot.
        // Copy its six immutable payload words in volatile program order, then
        // complete the entire payload snapshot with one DMB before re-reading
        // the commit fence.  A changed or malformed second commit remains a
        // torn event and none of the copied fields become actionable first.
        copy.address = load_volatile(&slot->address);
        copy.data = load_volatile(&slot->data);
        copy.frame = load_volatile(&slot->frame);
        copy.metadata = load_volatile(&slot->metadata);
        copy.timestamp_low = load_volatile(&slot->timestamp_low);
        copy.timestamp_high = load_volatile(&slot->timestamp_high);
        device_barrier();
#if defined(NDS4MISTER_H3D_TEST_INSTRUMENTATION)
        if (event_payload_snapshot_test_hook)
            event_payload_snapshot_test_hook(slot);
#endif
        copy.sequence = first_commit;
        std::uint32_t second_commit = 0;
        if (!load_counter(
                &slot->sequence, &slot->sequence_reserved, second_commit) ||
            second_commit != first_commit)
            return fail(FaultTornEvent);
        if (!valid_event(copy)) return fail(FaultBadEvent);

        output = copy;
        pending_ = true;
        return true;
    }

    bool acknowledge(bool force_publish = false)
    {
        if (!header_ || !pending_) return false;
        const auto applied = expected_;
        const bool terminal =
            applied == std::numeric_limits<std::uint32_t>::max();
        pending_ = false;
        if (!terminal)
            ++expected_;
        if (terminal || force_publish ||
            applied - published_consumer_ >= credit_batch_size_) {
            if (!publish_credit(applied)) return false;
        }
        if (terminal) exhausted_ = true;
        return true;
    }

    std::uint32_t expected_sequence() const { return expected_; }
    std::uint32_t local_faults() const { return local_faults_; }
    bool session_current() const
    {
        if (!header_) return false;
        return active_session_current(
            *header_, session_, quiesce_generation_, true);
    }

private:
    bool publish_credit(std::uint32_t sequence)
    {
        if (sequence == published_consumer_) return true;
        // The shared fence is the last fully applied event. Validate ownership
        // immediately before its only shared-memory publication.
        if (!session_current()) return fail(FaultBadSession);
        store_counter(
            &header_->consumer_sequence,
            &header_->consumer_sequence_reserved, sequence);
        published_consumer_ = sequence;
        return true;
    }

    Event* event_slot(std::uint32_t sequence) const
    {
        const auto index = (sequence - 1) & (entry_count_ - 1);
        return reinterpret_cast<Event*>(
            bytes_ + HeaderSize + std::size_t(index) * EventSize);
    }

    bool valid_event(const Event& event) const
    {
        const auto type = event_type(event);
        const auto width = event_width(event);
        if (event.sequence != expected_) return false;
        if (static_cast<unsigned>(type) <
                static_cast<unsigned>(EventType::Arm9GpuIoWrite) ||
            static_cast<unsigned>(type) >
                static_cast<unsigned>(EventType::SessionReset))
            return false;
        if (static_cast<unsigned>(width) >
            static_cast<unsigned>(AccessWidth::Word))
            return false;
        if ((type == EventType::Arm9GpuIoWrite ||
             type == EventType::Arm9VramWrite ||
             type == EventType::Arm7VramWrite) &&
            event_byte_enable(event) == 0)
            return false;
        return true;
    }

    bool fail(std::uint32_t fault)
    {
        local_faults_ |= fault;
        // Once the FPGA changes magic/session/quiesce generation, this old
        // consumer is read-only.  Its final permitted shared-memory write is
        // performed by the outer lifecycle as the H3DQ acknowledgement.
        if (header_ && session_current()) {
            const auto current = load_acquire(&header_->hps_fault_bits);
            store_release(&header_->hps_fault_bits, current | fault);
            store_release(
                &header_->service_state,
                static_cast<std::uint32_t>(ServiceState::Fault));
        }
        return false;
    }

    std::byte* bytes_ = nullptr;
    std::size_t size_ = 0;
    Header* header_ = nullptr;
    std::uint32_t session_ = 0;
    std::uint32_t entry_count_ = 0;
    std::uint32_t credit_batch_size_ = 1;
    std::uint32_t published_consumer_ = 0;
    std::uint32_t expected_ = 1;
    std::uint32_t quiesce_generation_ = 0;
    std::uint32_t local_faults_ = 0;
    bool pending_ = false;
    bool exhausted_ = false;
};

} // namespace nds4mister::h3d
