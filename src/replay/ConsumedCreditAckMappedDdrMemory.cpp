#include "replay/ConsumedCreditAckMappedDdrMemory.h"

#include <atomic>
#include <stdexcept>

namespace nds4mister {

ConsumedCreditAckMappedDdrMemory::ConsumedCreditAckMappedDdrMemory(
    volatile void* mapping,
    std::size_t mappedBytes) {
    if (mapping == nullptr)
        throw std::invalid_argument(
            "consumed-credit DDR mapping is null");
    const auto address = reinterpret_cast<std::uintptr_t>(mapping);
    if ((address & (alignof(std::uint64_t) - 1u)) != 0)
        throw std::invalid_argument(
            "consumed-credit DDR mapping is not 64-bit aligned");
    if (mappedBytes == 0 ||
        (mappedBytes % sizeof(std::uint64_t)) != 0)
        throw std::invalid_argument(
            "consumed-credit DDR mapping size is not whole 64-bit words");

    words32_ = static_cast<volatile std::uint32_t*>(mapping);
    wordCount64_ = mappedBytes / sizeof(std::uint64_t);
}

void ConsumedCreditAckMappedDdrMemory::compilerBarrier() noexcept {
    std::atomic_signal_fence(std::memory_order_seq_cst);
}

void ConsumedCreditAckMappedDdrMemory::fullBarrier() noexcept {
    std::atomic_thread_fence(std::memory_order_seq_cst);
}

void ConsumedCreditAckMappedDdrMemory::validateRange(
    std::size_t firstWord,
    std::size_t count) const {
    if (firstWord > wordCount64_ ||
        count > wordCount64_ - firstWord)
        throw std::out_of_range(
            "consumed-credit DDR mapping access is out of range");
}

volatile std::uint32_t*
ConsumedCreditAckMappedDdrMemory::halfWord(
    std::size_t word,
    bool upperHalf) const {
    validateRange(word, 1);
    return words32_ + word * 2u + static_cast<std::size_t>(upperHalf);
}

void ConsumedCreditAckMappedDdrMemory::invalidateFpgaWrites(
    std::size_t firstWord,
    std::size_t count) {
    validateRange(firstWord, count);
    compilerBarrier();
    fullBarrier();
    compilerBarrier();
}

std::uint32_t ConsumedCreditAckMappedDdrMemory::loadAcquire32(
    std::size_t word,
    bool upperHalf) {
    auto* source = halfWord(word, upperHalf);
    compilerBarrier();
    const auto value = *source;
    fullBarrier();
    compilerBarrier();
    return value;
}

void ConsumedCreditAckMappedDdrMemory::storeRelaxed64(
    std::size_t word,
    std::uint64_t value) {
    auto* low = halfWord(word, false);
    auto* high = halfWord(word, true);
    compilerBarrier();
    *low = static_cast<std::uint32_t>(value);
    *high = static_cast<std::uint32_t>(value >> 32);
    compilerBarrier();
}

void ConsumedCreditAckMappedDdrMemory::storeRelaxed32(
    std::size_t word,
    bool upperHalf,
    std::uint32_t value) {
    auto* destination = halfWord(word, upperHalf);
    compilerBarrier();
    *destination = value;
    compilerBarrier();
}

void ConsumedCreditAckMappedDdrMemory::storeRelease32(
    std::size_t word,
    bool upperHalf,
    std::uint32_t value) {
    auto* destination = halfWord(word, upperHalf);
    compilerBarrier();
    fullBarrier();
    *destination = value;
    compilerBarrier();
}

void ConsumedCreditAckMappedDdrMemory::cleanCpuWrites(
    std::size_t firstWord,
    std::size_t count) {
    validateRange(firstWord, count);
    compilerBarrier();
    fullBarrier();
    compilerBarrier();
}

} // namespace nds4mister
