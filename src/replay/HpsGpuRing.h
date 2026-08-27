#pragma once
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace nds4mister {
struct alignas(64) HpsGpuRingControl {
    std::uint32_t magic = 0x31475248; // HRG1
    std::uint16_t version = 1;
    std::uint16_t header_size = sizeof(HpsGpuRingControl);
    std::uint32_t capacity = 0;
    std::uint32_t reserved = 0;
    alignas(64) std::atomic<std::uint32_t> producer{0};
    alignas(64) std::atomic<std::uint32_t> consumer{0};
};

struct HpsGpuRecordHeader { std::uint16_t type; std::uint16_t size; };

class HpsGpuRing {
public:
    HpsGpuRing(HpsGpuRingControl& control, std::byte* bytes) : control_(control), bytes_(bytes) {}
    bool push(std::uint16_t type, const void* payload, std::uint16_t payload_size) {
        const std::uint32_t size = sizeof(HpsGpuRecordHeader) + payload_size;
        if (size > control_.capacity || size > UINT16_MAX) return false;
        const auto producer = control_.producer.load(std::memory_order_relaxed);
        const auto consumer = control_.consumer.load(std::memory_order_acquire);
        if (producer - consumer > control_.capacity - size) return false;
        const HpsGpuRecordHeader header{type, static_cast<std::uint16_t>(size)};
        copy_in(producer, &header, sizeof(header));
        copy_in(producer + sizeof(header), payload, payload_size);
        control_.producer.store(producer + size, std::memory_order_release);
        return true;
    }
    bool pop(std::uint16_t& type, void* payload, std::uint16_t capacity, std::uint16_t& payload_size) {
        const auto consumer = control_.consumer.load(std::memory_order_relaxed);
        const auto producer = control_.producer.load(std::memory_order_acquire);
        if (producer == consumer) return false;
        if (producer - consumer < sizeof(HpsGpuRecordHeader)) return false;
        HpsGpuRecordHeader header{}; copy_out(consumer, &header, sizeof(header));
        if (header.size < sizeof(header) || header.size > control_.capacity || header.size > producer - consumer)
            return false;
        payload_size = header.size - sizeof(header);
        if (payload_size > capacity) return false;
        type = header.type; copy_out(consumer + sizeof(header), payload, payload_size);
        control_.consumer.store(consumer + header.size, std::memory_order_release);
        return true;
    }
private:
    void copy_in(std::uint32_t position, const void* source, std::uint32_t size) {
        const auto offset = position % control_.capacity;
        const auto first = size < control_.capacity - offset ? size : control_.capacity - offset;
        std::memcpy(bytes_ + offset, source, first);
        std::memcpy(bytes_, static_cast<const std::byte*>(source) + first, size - first);
    }
    void copy_out(std::uint32_t position, void* destination, std::uint32_t size) const {
        const auto offset = position % control_.capacity;
        const auto first = size < control_.capacity - offset ? size : control_.capacity - offset;
        std::memcpy(destination, bytes_ + offset, first);
        std::memcpy(static_cast<std::byte*>(destination) + first, bytes_, size - first);
    }
    HpsGpuRingControl& control_; std::byte* bytes_;
};
}
