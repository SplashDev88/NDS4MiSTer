// SPDX-License-Identifier: GPL-3.0-or-later
#include "NDS.h"
#include "GPU3D_Soft.h"
#include <array>
#include <cstring>
#include <iostream>
#include <memory>
#include <random>
#include <vector>

using namespace melonDS;

int main()
{
    NDSArgs argsA, argsB;
    argsA.JIT = argsB.JIT = std::nullopt;
    auto a = std::make_unique<NDS>(std::move(argsA));
    auto b = std::make_unique<NDS>(std::move(argsB));
    a->Reset();
    b->Reset();
    auto control = std::make_unique<SoftTexcache>(a->GPU, SoftTexcacheLoader{});
    auto candidate = std::make_unique<SoftTexcache>(b->GPU, SoftTexcacheLoader{});
    candidate->ContentIdentityEnabled = true;

    std::mt19937 random(0x43564c35);
    std::array<std::vector<u8>, 4> textures, palettes;
    for (unsigned version = 0; version < textures.size(); ++version)
    {
        textures[version].resize(0x40000);
        palettes[version].resize(0x4000);
        for (auto& value : textures[version]) value = random();
        for (auto& value : palettes[version]) value = random();
    }

    unsigned checks = 0;
    for (unsigned round = 0; round < 300; ++round)
    {
        const unsigned version = round % (round < 150 ? 2 : 4);
        for (auto* machine : {a.get(), b.get()})
        {
            auto& gpu = machine->GPU;
            gpu.MapVRAM_AB(0, 0x83);
            gpu.MapVRAM_AB(1, 0x8b);
            gpu.MapVRAM_FG(6, 0x83);
            std::memcpy(gpu.VRAM_A, textures[version].data(), 0x20000);
            std::memcpy(gpu.VRAM_B, textures[version].data() + 0x20000, 0x20000);
            std::memcpy(gpu.VRAM_G, palettes[version].data(), 0x4000);
            for (unsigned bank : {0, 1, 6})
                for (auto& word : gpu.VRAMDirty[bank].Data) word = ~u64(0);
        }
        u8 dirty = 0;
        control->Update(dirty);
        candidate->Update(dirty);
        for (unsigned format = 1; format <= 7; ++format)
        for (unsigned start : {0u, 0xffffu})
        for (unsigned transparent : {0u, 1u})
        {
            constexpr unsigned width = 32, height = 32;
            constexpr unsigned stride = width * height + height;
            const u32 parameter = (format << 26) | (2u << 20) | (2u << 23) |
                                  (transparent << 29) | start;
            u32 *pixelsA, *pixelsB, *helper, layerA, layerB;
            control->GetTexture(parameter, 0, pixelsA, layerA, helper);
            candidate->GetTexture(parameter, 0, pixelsB, layerB, helper);
            if (std::memcmp(pixelsA + layerA * stride, pixelsB + layerB * stride,
                            stride * sizeof(u32)))
            {
                std::cerr << "Texture differs: round=" << round << " format="
                          << format << " start=" << start << '\n';
                return 1;
            }
            ++checks;
        }
        if (candidate->SnapshotBytes > candidate->MaxSnapshotBytes ||
            candidate->ContentHistoryBytes > candidate->MaxHistoryBytes)
            return 2;
        if (round == 112 || round == 224)
        {
            control->Reset();
            candidate->Reset();
            if (candidate->SnapshotBytes || candidate->ContentHistoryBytes ||
                !candidate->ContentHistory.empty()) return 3;
        }
    }
    if (!candidate->ContentHistoryHits) return 4;

    // Dirty masks contain 64 blocks per word. A wrapped range must inspect
    // word zero, not a word beyond the bitset. Independent of cache history.
    std::array<u8, 65536> bytes {};
    std::array<u64, 2> bits {};
    const u32 start = bytes.size() - 8;
    const auto hash = control->MaskedHash(bytes.data(), bytes.size(), start, 16);
    bytes[0] = 1;
    bits[0] = 1;
    if (!control->CheckInvalid(start, 16, hash, bits.data(), bytes.data(), bytes.size()))
        return 5;
    bits[0] = 0;
    if (control->CheckInvalid(start, 16, hash, bits.data(), bytes.data(), bytes.size()))
        return 6;
    std::cout << "TEXTURE_HISTORY_PASS comparisons=" << checks
              << " hits=" << candidate->ContentHistoryHits
              << " misses=" << candidate->ContentHistoryMisses << '\n';
    control->Reset();
    candidate->Reset();
    for (u32 palette = 0; palette < 8000; ++palette)
    {
        u32 *pixels, *helper, layer;
        candidate->GetTexture(4u << 26, palette, pixels, layer, helper);
        if (candidate->SnapshotBytes > candidate->MaxSnapshotBytes) return 7;
    }
    if (candidate->SnapshotBytes < candidate->MaxSnapshotBytes - 576) return 8;
    unsigned uncachedInputs = 0;
    for (const auto& item : candidate->Cache)
        uncachedInputs += item.second.SourceBytes[0].empty();
    if (!uncachedInputs) return 9;
    candidate->Reset();
    if (candidate->SnapshotBytes || candidate->ContentHistoryBytes) return 10;
    std::cout << "TEXTURE_HISTORY_BUDGET_PASS entries=8000 fallback="
              << uncachedInputs << '\n';
}
