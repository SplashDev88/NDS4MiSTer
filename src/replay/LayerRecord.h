#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace nds4mister {

struct LayerRecord {
    std::array<std::uint32_t,6> pixels{};
    std::array<std::uint8_t,3> ranks{};
    std::uint8_t valid{};
    std::uint16_t blendCnt{};
    std::uint8_t eva{},evb{},evy{},flags{};
    std::array<std::uint8_t,3> tag{};
    std::array<std::uint8_t,3> reserved{};

    void setTag(std::uint16_t x,std::uint16_t y) {
        const std::uint32_t value=(static_cast<std::uint32_t>(y&0x1ff)<<10)|(x&0x3ff);
        tag={static_cast<std::uint8_t>(value),static_cast<std::uint8_t>(value>>8),static_cast<std::uint8_t>(value>>16)};
    }
};

constexpr std::uint64_t kLayerPublicationMagic=0x315542504c53444eULL;
constexpr std::uint32_t kLayerPublicationAbi=1;
constexpr std::uint32_t kLayerFrameRecords=512u*192u;
constexpr std::uint32_t kLayerFrameBytes=kLayerFrameRecords*sizeof(LayerRecord);
constexpr std::uint32_t kLayerSlotBytes=4u*1024u*1024u;

// A cache-line control block. Generation is odd while the HPS writes a slot
// and even once that slot may be consumed. Readers require both generation
// copies to match, which rejects a torn header snapshot.
struct alignas(64) LayerPublication {
    std::uint64_t magic{};
    std::uint32_t abi{},headerBytes{};
    std::uint64_t generation{};
    std::uint32_t activeSlot{},frameBytes{},recordBytes{},recordCount{};
    std::uint64_t frameSequence{},generationCheck{},reserved{};
};
static_assert(std::is_trivially_copyable_v<LayerRecord>);
static_assert(sizeof(LayerRecord)==40);
static_assert(offsetof(LayerRecord,ranks)==24);
static_assert(offsetof(LayerRecord,valid)==27);
static_assert(offsetof(LayerRecord,blendCnt)==28);
static_assert(offsetof(LayerRecord,eva)==30);
static_assert(offsetof(LayerRecord,tag)==34);
static_assert(sizeof(LayerPublication)==64);
static_assert(alignof(LayerPublication)==64);
static_assert(offsetof(LayerPublication,generation)==16);
static_assert(offsetof(LayerPublication,generationCheck)==48);

} // namespace nds4mister
