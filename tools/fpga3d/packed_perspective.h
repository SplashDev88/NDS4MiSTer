// SPDX-License-Identifier: GPL-3.0-only
#pragma once

#include "codec.h"

namespace fpga3d {

// With perspective interpolation and a W buffer the FPGA takes both endpoints
// directly. These fields have no linear recurrence to initialize. Keep all
// other span shapes, including malformed inputs, on the reference encoder.
inline PackedCommand packedPerspectiveW(const Span& s)
{
    const auto interpolation = s.flags & (Linear | WBuffer);
    if (interpolation != WBuffer)
        return pack(span(s));

    const int64_t offset = int64_t(s.first) - s.origin;
    const uint32_t shape = s.flags | (s.alphaRef << 8);
    const uint32_t attr = s.polyAttr | ((s.flags & Back) ? 16u : 0u);
    const uint32_t address = s.texture & ~3u;
    const uint32_t format = s.texture & 3u;
    const uint32_t coords = s.shiftS | (s.shiftT << 4) | (s.wrap << 8) | (format << 12);
    const uint32_t state = s.polyAlpha | (s.depthWrite ? 32u : 0u) | (s.yEdge << 6) | (s.mode << 10);

    // A signed 16-bit value biased by 32768 fits in unsigned 16 bits.
    uint32_t endpoints = 0;
    for (unsigned i = 0; i < 5; ++i)
        endpoints |= (uint32_t(s.left[i]) + 32768u) | (uint32_t(s.right[i]) + 32768u);

    if (s.first < 0 || s.end > 256 || s.first >= s.end || s.width < 1 || s.width > 256 ||
        offset < 0 || offset + (s.end - s.first) > s.width ||
        ((uint32_t(s.w0) | uint32_t(s.w1) | endpoints) >> 16) ||
        ((uint32_t(s.z0) | uint32_t(s.z1)) >> 24) || s.flags > 63 ||
        s.alphaRef > 31 || s.shiftS < 3 || s.shiftS > 10 || s.shiftT < 3 || s.shiftT > 10 ||
        s.polyAlpha > 31 || s.mode > 4 || (s.yEdge & ~12u) ||
        s.leftEnd > s.rightBegin || s.rightBegin > 256 || (attr & ~0x3f008010u) ||
        ((s.flags & Textured) && (address < Textures || address >= Textures + TextureBytes ||
            (address & 7) || s.wrap > 15 || format == 3 || (format == 1 && (address & 63)))))
        return pack(span(s));

    PackedCommand p{};
    put<0, 3>(p, 2);
    put<3, 8>(p, s.first);
    put<11, 8>(p, s.end);
    put<19, 8>(p, s.width);
    put<27, 8>(p, uint32_t(offset));
    put<35, 6>(p, shape);
    put<41, 5>(p, s.alphaRef);
    put<46, 5>(p, s.polyAlpha);
    put<51, 1>(p, s.depthWrite);
    put<52, 2>(p, s.yEdge >> 2);
    put<54, 24>(p, s.z0);
    put<78, 24>(p, s.z1);
    put<102, 32>(p, uint32_t(s.w0) | (uint32_t(s.w1) << 16));
    put<134, 17>(p, (address - Textures) >> 3);
    put<151, 3>(p, s.shiftS - 3);
    put<154, 3>(p, s.shiftT - 3);
    put<157, 4>(p, s.wrap);
    put<161, 6>(p, attr >> 24);
    put<167, 1>(p, attr >> 4);
    put<168, 1>(p, attr >> 15);

    auto coverage = [](uint32_t c) {
        return (c & 1023) | (((c >> 12) & 1023) << 10) | ((c >> 31) << 20);
    };
    put<169, 21>(p, coverage(s.leftCov));
    put<190, 21>(p, coverage(s.rightCov));
    put<211, 9>(p, s.leftEnd);
    put<220, 9>(p, s.rightBegin);

    auto pair = [&](unsigned i) {
        return uint16_t(s.left[i]) | (uint32_t(uint16_t(s.right[i])) << 16);
    };
    put<229, 32>(p, pair(0));
    put<261, 32>(p, pair(1));
    put<293, 32>(p, pair(2));
    put<325, 32>(p, pair(3));
    put<357, 32>(p, pair(4));
    put<495, 2>(p, state >> 10);
    put<498, 1>(p, state >> 12);
    put<497, 1>(p, coords >> 12);
    put<509, 1>(p, coords >> 13);
    return p;
}

} // namespace fpga3d
