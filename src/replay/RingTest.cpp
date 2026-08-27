#include "replay/HpsGpuRing.h"
#include <array>
#include <cstdint>
#include <iostream>
#include <thread>
#include <vector>

int main() {
    nds4mister::HpsGpuRingControl control; control.capacity = 4096;
    std::vector<std::byte> storage(control.capacity);
    nds4mister::HpsGpuRing ring(control, storage.data());
    std::array<std::uint8_t, 257> input{}, output{};
    std::uint32_t written = 0, read = 0;
    while (read < 100000) {
        if (written < 100000) {
            const std::uint16_t size = 1 + (written * 73u) % input.size();
            for (std::uint16_t i=0; i<size; i++) input[i] = static_cast<std::uint8_t>(written + i);
            if (ring.push(static_cast<std::uint16_t>((written % 5) + 1), input.data(), size)) written++;
        }
        std::uint16_t type=0, size=0;
        if (ring.pop(type, output.data(), output.size(), size)) {
            const std::uint16_t expected_size = 1 + (read * 73u) % input.size();
            if (type != (read % 5) + 1 || size != expected_size) return 1;
            for (std::uint16_t i=0; i<size; i++) if (output[i] != static_cast<std::uint8_t>(read+i)) return 1;
            read++;
        }
    }
    control.producer.store(0); control.consumer.store(0);
    constexpr std::uint32_t concurrent_records = 1000000;
    std::thread producer([&] {
        std::array<std::uint8_t, 257> data{};
        for (std::uint32_t n=0; n<concurrent_records;) {
            const std::uint16_t size = 1 + (n * 73u) % data.size();
            for (std::uint16_t i=0; i<size; i++) data[i] = static_cast<std::uint8_t>(n+i);
            if (ring.push(static_cast<std::uint16_t>((n%5)+1), data.data(), size)) n++;
            else std::this_thread::yield();
        }
    });
    for (std::uint32_t n=0; n<concurrent_records;) {
        std::uint16_t type=0, size=0;
        if (!ring.pop(type, output.data(), output.size(), size)) { std::this_thread::yield(); continue; }
        const std::uint16_t expected = 1 + (n * 73u) % output.size();
        if (type != (n%5)+1 || size != expected) return 1;
        for (std::uint16_t i=0; i<size; i++) if (output[i] != static_cast<std::uint8_t>(n+i)) return 1;
        n++;
    }
    producer.join();
    std::cout << "HPS GPU ring test\nsequential_records: " << read
              << "\nconcurrent_records: " << concurrent_records
              << "\nwraparound: passed\nordering: passed\npublication: passed\n";
}
