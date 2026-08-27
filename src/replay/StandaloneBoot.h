#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace nds4mister {

// Keep the 4 MiB DS image beside our dedicated mailbox page.  The start of
// MiSTer's reserved HPS/FPGA DDR aperture at 0x20000000 is actively reused by
// the framework and cannot safely hold persistent core-private RAM.
constexpr std::uintptr_t kStandaloneMainRamPhysical = 0x2c100000;
constexpr std::size_t kStandaloneMainRamBytes = 0x00400000;
constexpr std::uintptr_t kStandaloneSharedWramPhysical = 0x2c010000;
constexpr std::size_t kStandaloneSharedWramBytes = 0x00008000;
constexpr std::uintptr_t kStandaloneArm7WramPhysical = 0x2c020000;
constexpr std::size_t kStandaloneArm7WramBytes = 0x00010000;
// FPGA-posted, HPS-consumed writes live in the unused 64 KiB immediately
// after ARM7 WRAM. The current producer uses 1,024 fixed 24-byte entries plus
// a 64-byte header; the larger mapping leaves room for a versioned expansion.
constexpr std::uintptr_t kPostedWriteRingPhysical = 0x2c030000;
constexpr std::size_t kPostedWriteRingBytes = 0x00010000;
constexpr std::size_t kPostedWriteRingHeaderBytes = 64;
constexpr std::uint32_t kPostedWriteRingEntries = 1024;
constexpr std::size_t kPostedWriteEntryBytes = 24;
constexpr std::uint32_t kPostedWriteRingMagic = 0x5257444e; // "NDWR"
constexpr std::uint32_t kPostedWriteRingVersion = 2;
// HPS-produced, FPGA-consumed time/IRQ transaction batches use a separate
// reverse-direction ring in the unused 256 KiB gap below main RAM. Physical
// addresses are byte addresses; the FPGA bridge consumes 64-bit word
// addresses, hence the explicit /8 base constant and alignment assertions.
constexpr std::uintptr_t kConsumedCreditAckRingPhysical = 0x2c0c0000;
constexpr std::size_t kConsumedCreditAckRingBytes = 0x00010000;
constexpr std::size_t kConsumedCreditAckRingHeaderWords64 = 8;
constexpr std::size_t kConsumedCreditAckRingConsumerWordOffset = 0;
constexpr std::size_t kConsumedCreditAckRingDescriptorWordOffset = 1;
constexpr std::size_t kConsumedCreditAckRingEntryWords64 = 3;
constexpr std::size_t kConsumedCreditAckRingEntryBytes =
    kConsumedCreditAckRingEntryWords64 * sizeof(std::uint64_t);
constexpr std::size_t kConsumedCreditAckRingEntries = 1024;
constexpr std::uint32_t kConsumedCreditAckRingMagic = 0x4341434b; // "CACK"
constexpr std::uintptr_t kConsumedCreditAckRingBaseWord =
    kConsumedCreditAckRingPhysical / sizeof(std::uint64_t);
constexpr std::size_t kConsumedCreditAckRingRequiredBytes =
    kConsumedCreditAckRingHeaderWords64 * sizeof(std::uint64_t) +
    kConsumedCreditAckRingEntries * kConsumedCreditAckRingEntryBytes;
constexpr std::uintptr_t kStandaloneBootDescriptorPhysical = 0x2c001000;
constexpr std::uintptr_t kCompactPublicationPhysical = 0x30000000;
constexpr std::uintptr_t kCompactInputPhysical =
    kCompactPublicationPhysical + 64;
constexpr std::uint32_t kCompactInputMagic = 0x4a53444e; // "NDSJ"
constexpr std::uint32_t kStandaloneBootMagic = 0x4253444e; // "NDSB"
constexpr std::uint32_t kStandaloneBootVersion = 3;

inline std::uint32_t boot_crc32(const void* data, std::size_t bytes) {
    auto* cursor = static_cast<const std::uint8_t*>(data);
    std::uint32_t crc = 0xffffffffu;
    while (bytes--) {
        crc ^= *cursor++;
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

constexpr std::uint32_t mister_joystick_to_ds_key_mask(std::uint32_t joystick) {
    std::uint32_t keys = 0x0fffu;
    const unsigned joystick_bits[12] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
    const unsigned ds_bits[12] = {4, 5, 7, 6, 0, 1, 2, 3, 8, 9, 10, 11};
    for (unsigned index = 0; index < 12; ++index)
        if (joystick & (1u << joystick_bits[index]))
            keys &= ~(1u << ds_bits[index]);
    return keys;
}

static_assert(mister_joystick_to_ds_key_mask(0) == 0x0fff);
static_assert(mister_joystick_to_ds_key_mask(0x0011) == 0x0fee);
static_assert(mister_joystick_to_ds_key_mask(0x0fff) == 0);

struct StandaloneBootDescriptor {
    std::uint32_t magic = kStandaloneBootMagic;
    std::uint32_t version = kStandaloneBootVersion;
    std::uint32_t generation = 0;
    // Value installed by direct boot at DTCM[0x3ffc]. The ARM9 BIOS loads
    // this word as the game's IRQ handler address.
    std::uint32_t arm9_dtcm_irq_vector = 0;
    std::uint32_t main_ram_bytes = kStandaloneMainRamBytes;
    // Version 3 makes the retirement breakpoint runtime-configurable. HPS
    // already verifies every copied main-RAM byte before publishing this
    // descriptor, so the former informational RAM CRC word can carry the
    // ARM9 trigger without expanding or relocating the atomic descriptor.
    // Zero disables capture; any aligned main-RAM execute PC is valid.
    std::uint32_t arm9_trace_trigger = 0;
    std::uint32_t arm9_entry = 0;
    std::uint32_t arm7_entry = 0;
    std::uint32_t arm9_current_sp = 0x03002f7c;
    std::uint32_t arm9_irq_sp = 0x03003f80;
    std::uint32_t arm9_saved_sp = 0x03003fc0;
    std::uint32_t arm7_current_sp = 0x0380fd80;
    std::uint32_t arm7_irq_sp = 0x0380ff80;
    std::uint32_t arm7_saved_sp = 0x0380ffc0;
    std::uint32_t initial_cpsr = 0x000000d3;
    std::uint32_t descriptor_crc32 = 0;

    void seal(std::uint32_t published_generation) {
        generation = published_generation;
        descriptor_crc32 = 0;
        descriptor_crc32 = boot_crc32(this, offsetof(
            StandaloneBootDescriptor, descriptor_crc32));
    }
};

static_assert(sizeof(StandaloneBootDescriptor) == 64);
static_assert(offsetof(StandaloneBootDescriptor, generation) == 8);
static_assert(offsetof(StandaloneBootDescriptor, descriptor_crc32) == 60);
static_assert(kPostedWriteRingHeaderBytes +
              kPostedWriteRingEntries * kPostedWriteEntryBytes <=
              kPostedWriteRingBytes);
static_assert(kConsumedCreditAckRingBaseWord == 0x05818000);
static_assert(kConsumedCreditAckRingPhysical % sizeof(std::uint64_t) == 0);
static_assert(kConsumedCreditAckRingBytes % sizeof(std::uint64_t) == 0);
static_assert(kConsumedCreditAckRingHeaderWords64 >= 2);
static_assert(kConsumedCreditAckRingConsumerWordOffset <
              kConsumedCreditAckRingHeaderWords64);
static_assert(kConsumedCreditAckRingDescriptorWordOffset <
              kConsumedCreditAckRingHeaderWords64);
static_assert(kConsumedCreditAckRingConsumerWordOffset !=
              kConsumedCreditAckRingDescriptorWordOffset);
static_assert(kConsumedCreditAckRingEntries >= 2 &&
              (kConsumedCreditAckRingEntries &
               (kConsumedCreditAckRingEntries - 1)) == 0);
static_assert(kConsumedCreditAckRingRequiredBytes <=
              kConsumedCreditAckRingBytes);

constexpr bool physical_regions_disjoint(
    std::uintptr_t firstBase,
    std::size_t firstBytes,
    std::uintptr_t secondBase,
    std::size_t secondBytes) {
    return firstBase + firstBytes <= secondBase ||
           secondBase + secondBytes <= firstBase;
}

static_assert(physical_regions_disjoint(
    kConsumedCreditAckRingPhysical, kConsumedCreditAckRingBytes,
    kStandaloneMainRamPhysical, kStandaloneMainRamBytes));
static_assert(physical_regions_disjoint(
    kConsumedCreditAckRingPhysical, kConsumedCreditAckRingBytes,
    kStandaloneSharedWramPhysical, kStandaloneSharedWramBytes));
static_assert(physical_regions_disjoint(
    kConsumedCreditAckRingPhysical, kConsumedCreditAckRingBytes,
    kStandaloneArm7WramPhysical, kStandaloneArm7WramBytes));
static_assert(physical_regions_disjoint(
    kConsumedCreditAckRingPhysical, kConsumedCreditAckRingBytes,
    kPostedWriteRingPhysical, kPostedWriteRingBytes));
// The descriptor owns one mmap page even though its atomic payload is 64 B.
static_assert(physical_regions_disjoint(
    kConsumedCreditAckRingPhysical, kConsumedCreditAckRingBytes,
    kStandaloneBootDescriptorPhysical, 0x1000));
static_assert(kConsumedCreditAckRingPhysical +
              kConsumedCreditAckRingBytes <=
              kCompactPublicationPhysical);

} // namespace nds4mister
