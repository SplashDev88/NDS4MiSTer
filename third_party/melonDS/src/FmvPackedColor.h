// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include "FmvPostfilter.h"
#ifdef NDS4MISTER_EXPERIMENTAL_FMV_VIDEO_DECODE
#include "FmvVideoDecoder.h"
#endif

namespace melonDS::ExperimentalFmv {

// Private experiment: a patched guest uploads planar movie data through the
// existing ordered LCDC write stream. Only a complete transaction is converted.
// This changes physical guest VRAM contents and is NOT a general DS feature.
// The ordinary build does not instantiate this receiver.
struct PackedColor {
    static constexpr unsigned Width = 256, Height = 192;
    static constexpr unsigned LumaBytes = Width * Height;
    static constexpr unsigned ChromaBytes = LumaBytes / 2;
    static constexpr unsigned TableBytes = 800;
    static constexpr unsigned PayloadBytes = LumaBytes + ChromaBytes + TableBytes;
    static constexpr unsigned OldTableBytes = 1568;
    static constexpr unsigned OldPayloadBytes = LumaBytes + ChromaBytes + OldTableBytes;
    static constexpr unsigned FilterPayloadBytes = PayloadBytes + 400;
    static constexpr unsigned Header = 0x1f000;
    static constexpr std::uint32_t Begin = 0x31564d46;
    static constexpr std::uint32_t Dimensions = 0x00c00100;
    static constexpr std::uint32_t Format = 0x334e0001;
    static constexpr std::uint32_t OldFormat = 0x314e0001;
    static constexpr std::uint32_t FilterFormat = 0x334e0002;
    static constexpr std::uint32_t DecodeFormat = 0x334e0010;
    static constexpr std::uint32_t CachedFormat = 0x334e0011;
    static constexpr std::uint32_t CachedFilterFormat = 0x334e0012;
    static constexpr std::uint32_t DecodeTableFormat = 0x334e0013;
    static constexpr std::uint32_t CachedStreamFormat = 0x334e0021;
    static constexpr std::uint32_t CachedStreamFilterFormat = 0x334e0022;
    static constexpr std::uint32_t DecodeVxFormat = 0x31580010;
    static constexpr std::uint32_t CachedVxFormat = 0x31580021;
    static constexpr std::uint32_t Offset16K = 0x100;
    static constexpr std::uint32_t Commit = 0x54494d43;

    std::array<unsigned, 4> Next {};
    std::array<unsigned, 4> OutputOffset {};
    std::array<bool, 4> Armed {};
    std::array<bool, 4> DirtyAll {};
    struct Transaction {
        std::array<std::uint8_t, 0x20000> Visible;
        std::array<std::uint8_t, OldPayloadBytes> Pending;
    };
    // Most games never use this private protocol. Allocate staging only for
    // banks that receive a recognized transaction.
    std::array<std::unique_ptr<Transaction>, 4> Transactions;
    std::array<std::uint8_t, OldPayloadBytes> Scratch {};
    std::uint64_t Conversions = 0;
    std::uint64_t FilterConversions = 0;
#ifdef NDS4MISTER_EXPERIMENTAL_FMV_VIDEO_DECODE
    VideoDecoder Video;
    std::uint64_t VideoDecodes = 0, VideoErrors = 0, CachedConversions = 0;
#endif

    static std::uint32_t Word(const std::uint8_t* p) {
        std::uint32_t v;
        std::memcpy(&v, p, sizeof(v));
        return v;
    }

    void Abort(unsigned bank, std::uint8_t* data) {
        if (Armed[bank] && Next[bank]) {
            std::memcpy(data + OutputOffset[bank], Transactions[bank]->Pending.data(), Next[bank]);
            DirtyAll[bank] = true;
        }
        Armed[bank] = false;
        Next[bank] = 0;
    }

    bool Write(unsigned bank, unsigned offset, unsigned bytes, std::uint8_t* data) {
        if (bank >= Armed.size()) return false;
        if ((offset | bytes) & 3u || bytes == 0 || offset + bytes > 0x20000) {
            Abort(bank, data);
            return false;
        }
        if (offset <= Header && offset + bytes > Header) {
            Abort(bank, data);
            Armed[bank] = Word(data + Header) == Begin;
            Next[bank] = 0;
            if (Armed[bank]) {
                if (!Transactions[bank]) Transactions[bank] = std::make_unique<Transaction>();
                std::memcpy(Transactions[bank]->Visible.data(), data, 0x20000);
            }
        }
        if (!Armed[bank]) return false;
        // A new begin still sees the previous transaction's remaining header
        // words. Do not validate mixed old/new fields before payload or commit.
        if (offset >= Header && offset + bytes <= Header + 12) return false;
        const auto formatWord = Word(data + Header + 8);
        auto format = formatWord & ~Offset16K;
        const unsigned outputOffset = (formatWord & Offset16K) ? 0x4000 : 0;
        unsigned payloadBytes = format == OldFormat ? OldPayloadBytes :
            format == FilterFormat ? FilterPayloadBytes : PayloadBytes;
#ifdef NDS4MISTER_EXPERIMENTAL_FMV_VIDEO_DECODE
        if (format == DecodeFormat || format == DecodeTableFormat
#ifdef NDS4MISTER_EXPERIMENTAL_FMV_VX_DECODE
            || format == DecodeVxFormat
#endif
        ) {
            payloadBytes = Word(data + Header + 4);
            // Header words arrive separately, before any payload.
            if (payloadBytes < 20 || payloadBytes > 65536 || (payloadBytes & 3) || outputOffset) {
                Abort(bank, data);
                ++VideoErrors;
                return false;
            }
        } else if (format == CachedFormat || format == CachedFilterFormat) {
            payloadBytes = 4 + TableBytes + (format == CachedFilterFormat ? 400 : 0);
        } else if (format == CachedStreamFormat || format == CachedStreamFilterFormat) {
            payloadBytes = 8 + TableBytes + (format == CachedStreamFilterFormat ? 400 : 0);
        }
#ifdef NDS4MISTER_EXPERIMENTAL_FMV_VX_DECODE
        else if (format == CachedVxFormat) payloadBytes = 8 + OldTableBytes;
#endif
#endif
        if (offset < outputOffset + payloadBytes) {
            if (offset != outputOffset + Next[bank] || offset + bytes > outputOffset + payloadBytes) {
                Abort(bank, data);
                return false;
            }
            OutputOffset[bank] = outputOffset;
            std::memcpy(Transactions[bank]->Pending.data() + Next[bank], data + offset, bytes);
            // Replay can render between chunks of a guest upload. Keep raw
            // codec bytes out of the visible RGB bank until the commit.
            std::memcpy(data + offset, Transactions[bank]->Visible.data() + offset, bytes);
            Next[bank] += bytes;
        } else if (offset < Header || offset + bytes > Header + 16) {
            Abort(bank, data);
            return false;
        }
        if (!(offset <= Header + 12 && offset + bytes > Header + 12))
            return false;
        bool validFormat = format == Format || format == OldFormat || format == FilterFormat;
        bool validDimensions = Word(data + Header + 4) == Dimensions;
#ifdef NDS4MISTER_EXPERIMENTAL_FMV_VIDEO_DECODE
        validFormat |= format == DecodeFormat || format == CachedFormat || format == CachedFilterFormat;
        validFormat |= format == DecodeTableFormat || format == CachedStreamFormat || format == CachedStreamFilterFormat;
        validDimensions |= format == DecodeFormat || format == DecodeTableFormat;
#ifdef NDS4MISTER_EXPERIMENTAL_FMV_VX_DECODE
        validFormat |= format == DecodeVxFormat || format == CachedVxFormat;
        validDimensions |= format == DecodeVxFormat;
#endif
#endif
        if (Next[bank] != payloadBytes || Word(data + Header) != Begin ||
            !validDimensions || !validFormat ||
            Word(data + Header + 12) != Commit) {
            Abort(bank, data);
            return false;
        }

        const auto* pending = Transactions[bank]->Pending.data();
#ifdef NDS4MISTER_EXPERIMENTAL_FMV_VIDEO_DECODE
        if (format == DecodeFormat || format == DecodeTableFormat
#ifdef NDS4MISTER_EXPERIMENTAL_FMV_VX_DECODE
            || format == DecodeVxFormat
#endif
        ) {
            Armed[bank] = false;
            Next[bank] = 0;
            const unsigned length = Word(pending + 8);
            const unsigned tableBytes = format == DecodeTableFormat ? 4096 : 0;
            const bool vx = format == DecodeVxFormat;
            const unsigned prefix = vx ? 20 : 16;
            if (payloadBytes < prefix + tableBytes || length < 2 ||
                ((length + 3u) & ~3u) != payloadBytes - prefix - tableBytes ||
                !Video.Decode(Word(pending), Word(pending + 4), pending + prefix + tableBytes,
                              length, Word(pending + 12), tableBytes ? pending + prefix : nullptr,
                              vx ? 1 : 0, vx ? Word(pending + 16) : 0))
                ++VideoErrors;
            else
                ++VideoDecodes;
            return false;
        }
        if (format == CachedFormat || format == CachedFilterFormat ||
            format == CachedStreamFormat || format == CachedStreamFilterFormat
#ifdef NDS4MISTER_EXPERIMENTAL_FMV_VX_DECODE
            || format == CachedVxFormat
#endif
        ) {
            const bool vx = format == CachedVxFormat;
            const bool withStream = vx || format == CachedStreamFormat || format == CachedStreamFilterFormat;
            const unsigned prefix = withStream ? 8 : 4;
            const auto* frame = Video.Find(Word(pending), withStream ? Word(pending + 4) : 0);
            if (!frame || frame->Codec != (vx ? 1u : 0u)) {
                Armed[bank] = false;
                Next[bank] = 0;
                ++VideoErrors;
                return false;
            }
            std::memcpy(Scratch.data(), frame->Pixels.data(), LumaBytes + ChromaBytes);
            std::memcpy(Scratch.data() + LumaBytes + ChromaBytes, pending + prefix, payloadBytes - prefix);
            format = vx ? OldFormat :
                (format == CachedFilterFormat || format == CachedStreamFilterFormat) ? FilterFormat : Format;
            ++CachedConversions;
        } else
#endif
        std::memcpy(Scratch.data(), pending, payloadBytes);
        if (format == FilterFormat) {
            const auto* metadata = Scratch.data() + PayloadBytes;
            const unsigned thresholds = Word(metadata), mode = Word(metadata + 4);
            if (thresholds > 0xffff || mode > 2 || Word(metadata + 8) || Word(metadata + 12)) {
                Abort(bank, data);
                return false;
            }
            Postfilter(Scratch.data(), Scratch.data() + LumaBytes, thresholds, mode,
                       metadata + 16 + 64);
            ++FilterConversions;
        }
        Armed[bank] = false;
        const auto* y = Scratch.data();
        const auto* uv = y + LumaBytes;
        if (format == OldFormat) {
            const auto* table = uv + ChromaBytes + 272;
            for (unsigned row = 0; row < Height; ++row) {
                const auto* chroma = uv + (row / 2) * 256;
                for (unsigned col = 0; col < Width; col += 2) {
                    const int u = int(chroma[col]) - 128;
                    const int v = int(chroma[col + 1]) - 128;
                    auto pixel = [&](unsigned x) {
                        const int l = int(y[row * Width + x]) - (((row ^ x) & 1) ? 4 : 0);
                        // ARM ASR rounds negative chroma toward minus infinity.
                        const int halfU = u >= 0 ? u / 2 : -((-u + 1) / 2);
                        return std::uint32_t(table[l + 2 * v]) +
                            (std::uint32_t(table[l - v - halfU]) << 5) +
                            (std::uint32_t(table[l + 2 * u + 768]) << 10);
                    };
                    const std::uint32_t pair = pixel(col) + (pixel(col + 1) << 16);
                    std::memcpy(data + outputOffset + 2 * (row * Width + col), &pair, 4);
                }
            }
            ++Conversions;
            return true;
        }
        const auto* table = uv + ChromaBytes + 16 + 256;
        for (unsigned row = 0; row < Height; ++row) {
            const auto* chroma = uv + (row / 2) * 256;
            for (unsigned col = 0; col < Width; col += 2) {
                const int u = int(chroma[col / 2]) - 128;
                const int v = int(chroma[128 + col / 2]) - 128;
                // Preserve all table bytes, including the original boundary
                // behavior, rather than replacing them with assumed clamping.
                auto pixel = [&](unsigned x) {
                    const int l = int(y[row * Width + x]) - (((row ^ x) & 1) ? 4 : 0);
                    return std::uint32_t(table[l + u - v]) +
                        (std::uint32_t(table[l + v]) << 5) +
                        (std::uint32_t(table[l - u - v]) << 10);
                };
                // The original ARM code adds the high pixel to the low word;
                // preserve even overflow from nonstandard table bytes.
                const std::uint32_t pair = ((pixel(col) | 0x8000u) +
                    (pixel(col + 1) << 16)) | 0x80000000u;
                std::memcpy(data + outputOffset + 2 * (row * Width + col), &pair, 4);
            }
        }
        ++Conversions;
        return true;
    }
};
}
