// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/mem.h>
// Private FFmpeg extension; its bounded-table patch is required at link time.
int nds_mobiclip_set_clamp(AVCodecContext*, const std::uint8_t*, unsigned);
}

namespace melonDS::ExperimentalFmv {

// Private MODSN3 experiment. The guest preserves the game's queue and display
// decisions; this cache only replaces a verified decoder's YUV output.
class VideoStream {
public:
    static constexpr unsigned ImageBytes = 256 * 192 * 3 / 2;
    struct Image {
        std::uint32_t Key = 0;
        unsigned Codec = 0;
        std::array<std::uint8_t, ImageBytes> Pixels;
    };
    ~VideoStream() { Clear(); }
    VideoStream() = default;
    VideoStream(const VideoStream&) = delete;
    VideoStream& operator=(const VideoStream&) = delete;

    void Clear() {
        av_frame_free(&Frame);
        av_packet_free(&Packet);
        avcodec_free_context(&Context);
        for (auto& image : Images) image.reset();
        NextFrame = 0;
        SourceCodec = 0;
        Quantizer = 0;
    }

    bool Decode(std::uint32_t sequence, std::uint32_t key,
                const std::uint8_t* bytes, unsigned length,
                const std::uint8_t* clamp, unsigned sourceCodec = 0,
                unsigned quantizer = 0) {
        if (key < 0x02000000 || key > 0x023f4000 || (key & 3) ||
            length < 2 || length > 65520) return false;
        if (sourceCodec > 1 || (sourceCodec && (clamp || quantizer < 12 || quantizer > 161)))
            return false;
#ifndef NDS4MISTER_EXPERIMENTAL_FMV_VX_DECODE
        if (sourceCodec) return false;
#endif
        if (sequence == 0) {
            Clear();
            AVCodecID id = AV_CODEC_ID_MOBICLIP;
#ifdef NDS4MISTER_EXPERIMENTAL_FMV_VX_DECODE
            if (sourceCodec) id = AV_CODEC_ID_ACTIMAGINE_VX;
#endif
            const AVCodec* codec = avcodec_find_decoder(id);
            if (!codec) return false;
            Context = avcodec_alloc_context3(codec);
            Packet = av_packet_alloc();
            Frame = av_frame_alloc();
            if (!Context || !Packet || !Frame) return false;
            Context->width = 256;
            Context->height = 192;
            Context->thread_count = 1;
            if (sourceCodec) {
                Context->extradata = static_cast<std::uint8_t*>(av_mallocz(4 + AV_INPUT_BUFFER_PADDING_SIZE));
                if (!Context->extradata) return false;
                Context->extradata_size = 4;
                Context->extradata[0] = static_cast<std::uint8_t>(quantizer);
            }
            if (avcodec_open2(Context, codec, nullptr) < 0) return false;
            SourceCodec = sourceCodec;
            Quantizer = quantizer;
        }
        if (!Context || sequence != NextFrame || sourceCodec != SourceCodec || quantizer != Quantizer)
            return false;
        if (!sourceCodec) {
            if (clamp) std::memcpy(Clamp.data(), clamp, Clamp.size());
            if (nds_mobiclip_set_clamp(Context, clamp ? Clamp.data() : nullptr,
                                       clamp ? unsigned(Clamp.size()) : 0) < 0) return false;
        }
        std::unique_ptr<Image>* slot = nullptr;
        for (auto& image : Images) {
            if (image && image->Key == key) { slot = &image; break; }
            if (!image && !slot) slot = &image;
        }
        if (!slot) return false;
        av_packet_unref(Packet);
        av_frame_unref(Frame);
        const unsigned prefix = sourceCodec ? 4 : 0;
        if (av_new_packet(Packet, length + prefix) < 0) return false;
        if (prefix) std::memset(Packet->data, 0, prefix);
        std::memcpy(Packet->data + prefix, bytes, length);
        if (avcodec_send_packet(Context, Packet) < 0 ||
            avcodec_receive_frame(Context, Frame) < 0 ||
            Frame->format != AV_PIX_FMT_YUV420P ||
            Frame->width != 256 || Frame->height != 192) return false;
        if (!*slot) *slot = std::make_unique<Image>();
        auto& image = **slot;
        image.Key = key;
        image.Codec = sourceCodec;
        for (unsigned row = 0; row < 192; ++row)
            std::memcpy(image.Pixels.data() + row * 256,
                        Frame->data[0] + row * Frame->linesize[0], 256);
        // MODSN3 stores V then U; the older VX converter expects U,V pairs.
        for (unsigned row = 0; row < 96; ++row) {
            auto* out = image.Pixels.data() + 49152 + row * 256;
            if (!sourceCodec) {
                std::memcpy(out, Frame->data[2] + row * Frame->linesize[2], 128);
                std::memcpy(out + 128, Frame->data[1] + row * Frame->linesize[1], 128);
            } else {
                for (unsigned col = 0; col < 128; ++col) {
                    out[col * 2] = Frame->data[1][row * Frame->linesize[1] + col];
                    out[col * 2 + 1] = Frame->data[2][row * Frame->linesize[2] + col];
                }
            }
        }
        ++NextFrame;
        return true;
    }

    const Image* Find(std::uint32_t key) const {
        for (const auto& image : Images)
            if (image && image->Key == key) return image.get();
        return nullptr;
    }

private:
    AVCodecContext* Context = nullptr;
    AVPacket* Packet = nullptr;
    AVFrame* Frame = nullptr;
    std::uint32_t NextFrame = 0;
    unsigned SourceCodec = 0, Quantizer = 0;
    std::array<std::uint8_t, 4096> Clamp;
    std::array<std::unique_ptr<Image>, 16> Images;
};

class VideoDecoder {
public:
    void Clear() { for (auto& stream : Streams) stream.reset(); }
    bool Decode(std::uint32_t sequence, std::uint32_t key,
                const std::uint8_t* bytes, unsigned length,
                unsigned stream = 0, const std::uint8_t* clamp = nullptr,
                unsigned sourceCodec = 0, unsigned quantizer = 0) {
        if (stream >= Streams.size()) return false;
        if (!Streams[stream]) {
            if (sequence != 0) return false;
            Streams[stream] = std::make_unique<VideoStream>();
        }
        return Streams[stream]->Decode(sequence, key, bytes, length, clamp, sourceCodec, quantizer);
    }
    const VideoStream::Image* Find(std::uint32_t key, unsigned stream = 0) const {
        return stream < Streams.size() && Streams[stream] ? Streams[stream]->Find(key) : nullptr;
    }
private:
    // One legacy stream plus the two explicitly identified Ni no Kuni planes.
    std::array<std::unique_ptr<VideoStream>, 3> Streams;
};
}
