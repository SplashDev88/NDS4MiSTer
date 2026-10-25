// SPDX-License-Identifier: GPL-3.0-or-later
#include "NDS.h"
#include "GPU3D_Soft.h"
#include <array>
#include <iostream>
#include <memory>
using namespace melonDS;
int main()
{
    NDSArgs args;
    args.JIT = std::nullopt;
    auto machine = std::make_unique<NDS>(std::move(args));
    machine->Reset();
    auto cache = std::make_unique<SoftTexcache>(machine->GPU, SoftTexcacheLoader{});
    std::array<u8, 65536> bytes {};
    std::array<u64, 2> dirty {};
    const u32 start = bytes.size() - 8;
    const auto hash = cache->MaskedHash(bytes.data(), bytes.size(), start, 16);
    bytes[0] = 1;
    dirty[0] = 1;
    if (!cache->CheckInvalid(start, 16, hash, dirty.data(), bytes.data(), bytes.size())) return 1;
    dirty[0] = 0;
    if (cache->CheckInvalid(start, 16, hash, dirty.data(), bytes.data(), bytes.size())) return 2;
    bytes[0] = 0;
    dirty.fill(~u64(0));
    if (cache->CheckInvalid(start, 16, hash, dirty.data(), bytes.data(), bytes.size())) return 3;
    std::cout << "TEXTURE_DIRTY_RANGE_PASS\n";
}
