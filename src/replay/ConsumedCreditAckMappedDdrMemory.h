#pragma once

#include "replay/ConsumedCreditAckDdrProducer.h"

#include <cstddef>
#include <cstdint>

namespace nds4mister {

// Non-owning view of a coherent or uncached /dev/mem-style DDR mapping.
//
// Every device access is performed through a volatile 32-bit lvalue. In
// particular, a 64-bit ABI word is two ordinary 32-bit stores and is never
// claimed to be atomic. The reverse-ring protocol gets atomic publication
// solely from storeRelease32() writing the low 32-bit sequence commit last.
//
// The supplied mapping must already have the cache attributes required for
// coherent HPS/FPGA observation. Barriers order that mapping; they cannot turn
// an incorrectly cached normal-memory mapping into coherent device memory.
class ConsumedCreditAckMappedDdrMemory final
    : public ConsumedCreditAckDdrMemory {
public:
    ConsumedCreditAckMappedDdrMemory(
        volatile void* mapping,
        std::size_t mappedBytes);

    std::size_t wordCount() const override { return wordCount64_; }

    void invalidateFpgaWrites(
        std::size_t firstWord,
        std::size_t wordCount) override;
    std::uint32_t loadAcquire32(
        std::size_t word,
        bool upperHalf) override;
    void storeRelaxed64(
        std::size_t word,
        std::uint64_t value) override;
    void storeRelaxed32(
        std::size_t word,
        bool upperHalf,
        std::uint32_t value) override;
    void storeRelease32(
        std::size_t word,
        bool upperHalf,
        std::uint32_t value) override;
    void cleanCpuWrites(
        std::size_t firstWord,
        std::size_t wordCount) override;

private:
    static void compilerBarrier() noexcept;
    static void fullBarrier() noexcept;
    void validateRange(
        std::size_t firstWord,
        std::size_t wordCount) const;
    volatile std::uint32_t* halfWord(
        std::size_t word,
        bool upperHalf) const;

    volatile std::uint32_t* words32_ = nullptr;
    std::size_t wordCount64_ = 0;
};

} // namespace nds4mister
