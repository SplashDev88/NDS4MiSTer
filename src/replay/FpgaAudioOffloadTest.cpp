// Directed HPS-side proof for the FPGA-audio offload responder mode.
//
// The offload instance must retain software-visible SPU control/status timing
// while performing no sample-memory reads, sample decoding/mixing, capture
// RAM writes, or frontend audio production.

#include "Args.h"
#include "NDS.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <memory>
#include <utility>

namespace {

constexpr std::uint32_t kSampleBase = 0x02001000;
constexpr std::uint32_t kSampleEnd = 0x02001200;
constexpr std::uint32_t kCaptureBase = 0x02003000;
constexpr std::uint32_t kCaptureEnd = 0x02003100;

class ObservedNDS final : public melonDS::NDS {
public:
    explicit ObservedNDS(melonDS::NDSArgs&& args) noexcept
        : melonDS::NDS(std::move(args))
    {
    }

    std::uint32_t ARM7Read32(std::uint32_t address) override
    {
        if (address >= kSampleBase && address < kSampleEnd)
            ++sample_reads;
        return melonDS::NDS::ARM7Read32(address);
    }

    void ARM7Write32(std::uint32_t address, std::uint32_t value) override
    {
        if (address >= kCaptureBase && address < kCaptureEnd)
            ++capture_writes;
        melonDS::NDS::ARM7Write32(address, value);
    }

    std::uint64_t sample_reads = 0;
    std::uint64_t capture_writes = 0;
};

std::unique_ptr<ObservedNDS> make_nds(bool offload)
{
    melonDS::NDSArgs args;
    args.JIT = std::nullopt;
    args.BitDepth = melonDS::AudioBitDepth::_16Bit;
    args.Interpolation = melonDS::AudioInterpolation::None;
    args.OutputSampleRate = 32768.0;
    auto nds = std::make_unique<ObservedNDS>(std::move(args));
    nds->Reset();
    nds->Start();
    nds->SPU.SetFPGAAudioOffload(offload);

    for (std::uint32_t offset = 0; offset < kSampleEnd - kSampleBase;
         ++offset)
        nds->MainRAM[(kSampleBase + offset) & nds->MainRAMMask] =
            static_cast<std::uint8_t>((offset * 37u) ^ (offset >> 1));

    nds->ARM7Write16(0x04000304, 0x0001); // NDS sound power
    nds->ARM7Write16(0x04000504, 0x0200); // canonical bias
    nds->ARM7Write16(0x04000500, 0x807f); // master and normal mixer

    const auto configure_sampled = [&](unsigned channel,
                                       std::uint32_t format) {
        const std::uint32_t base = 0x04000400u + channel * 0x10u;
        nds->ARM7Write32(base + 0x04,
            kSampleBase + channel * 0x40u);
        nds->ARM7Write16(base + 0x08, 0xf000);
        nds->ARM7Write16(base + 0x0a, 0x0000);
        nds->ARM7Write32(base + 0x0c, 0x00000008);
        // active, one-shot, requested format, full volume
        nds->ARM7Write32(base,
            0x9000007fu | (format << 29));
    };
    configure_sampled(0, 0); // PCM8
    configure_sampled(1, 1); // PCM16
    configure_sampled(2, 2); // ADPCM

    // PSG and noise never auto-finish and exercise both format-3 dispatches.
    nds->ARM7Write16(0x04000488, 0xf800);
    nds->ARM7Write32(0x04000480, 0xe300007f);
    nds->ARM7Write16(0x040004e8, 0xf800);
    nds->ARM7Write32(0x040004e0, 0xe300007f);

    // Capture timer reloads alias channel 1/channel 3 timer registers.
    nds->ARM7Write16(0x04000418, 0xf000);
    nds->ARM7Write16(0x04000438, 0xf000);
    nds->ARM7Write32(0x04000510, kCaptureBase);
    nds->ARM7Write16(0x04000514, 0x0008);
    nds->ARM7Write32(0x04000518, kCaptureBase + 0x80);
    nds->ARM7Write16(0x0400051c, 0x0008);
    nds->ARM7Write8(0x04000508, 0x84); // active, one-shot, PCM16
    nds->ARM7Write8(0x04000509, 0x80); // active, looping, PCM16
    return nds;
}

bool status_equal(ObservedNDS& reference, ObservedNDS& offload)
{
    for (unsigned channel = 0; channel < 16; ++channel) {
        const std::uint32_t address = 0x04000400u + channel * 0x10u;
        if (reference.ARM7Read32(address) != offload.ARM7Read32(address))
            return false;
    }
    return reference.ARM7Read16(0x04000500) ==
               offload.ARM7Read16(0x04000500) &&
           reference.ARM7Read16(0x04000504) ==
               offload.ARM7Read16(0x04000504) &&
           reference.ARM7Read16(0x04000508) ==
               offload.ARM7Read16(0x04000508);
}

} // namespace

int main()
{
#if !NDS4MISTER_FPGA_AUDIO_OFFLOAD
    std::cerr << "FAIL: test requires NDS4MISTER_FPGA_AUDIO_OFFLOAD=1\n";
    return 1;
#else
    auto reference = make_nds(false);
    auto offload = make_nds(true);
    if (!status_equal(*reference, *offload)) {
        std::cerr << "FAIL: initial SPU register state differs\n";
        return 1;
    }

    std::array<bool, 3> sampled_finished {};
    bool capture_finished = false;
    for (unsigned step = 0; step < 800; ++step) {
        for (unsigned cpu = 0; cpu < 2; ++cpu) {
            reference->AdvanceExternalCPU(cpu, 1024);
            offload->AdvanceExternalCPU(cpu, 1024);
        }
        if (!status_equal(*reference, *offload)) {
            std::cerr << "FAIL: SPU status diverged at shared step "
                      << step << "\n";
            return 1;
        }
        for (unsigned channel = 0; channel < 3; ++channel) {
            const auto high = offload->ARM7Read8(
                0x04000403u + channel * 0x10u);
            if (!(high & 0x80))
                sampled_finished[channel] = true;
        }
        if (!(offload->ARM7Read8(0x04000508) & 0x80))
            capture_finished = true;
    }

    if (!std::all_of(sampled_finished.begin(), sampled_finished.end(),
                     [](bool value) { return value; }) ||
        !capture_finished ||
        !(offload->ARM7Read8(0x04000509) & 0x80)) {
        std::cerr << "FAIL: one-shot/loop status coverage incomplete"
                  << " pcm8=" << sampled_finished[0]
                  << " pcm16=" << sampled_finished[1]
                  << " adpcm=" << sampled_finished[2]
                  << " capture0=" << capture_finished
                  << " capture1_active="
                  << ((offload->ARM7Read8(0x04000509) & 0x80) != 0)
                  << "\n";
        return 1;
    }
    if (reference->sample_reads == 0 || reference->capture_writes == 0) {
        std::cerr << "FAIL: reference did not exercise render/capture work\n";
        return 1;
    }
    if (offload->sample_reads != 0 || offload->capture_writes != 0) {
        std::cerr << "FAIL: offload performed sample or capture memory I/O\n";
        return 1;
    }

    std::array<std::int16_t, 32> audio {};
    if (offload->SPU.ReadOutput(audio.data(), 16) != 0) {
        std::cerr << "FAIL: offload produced frontend audio frames\n";
        return 1;
    }
    const auto stats = offload->SPU.GetFPGAAudioOffloadStats();
    const auto reference_stats = reference->SPU.GetFPGAAudioOffloadStats();
    if (stats.MixCallbacks == 0 ||
        stats.HPSRenderCallbacks != 0 ||
        stats.ChannelAdvanceCallbacks == 0 ||
        stats.CaptureAdvanceCallbacks == 0 ||
        reference_stats.HPSRenderCallbacks == 0) {
        std::cerr << "FAIL: offload proof counters did not advance\n";
        return 1;
    }

    std::cout
        << "PASS: FPGA-audio offload preserves channel/capture status timing"
        << " mix_callbacks=" << stats.MixCallbacks
        << " hps_render_callbacks=" << stats.HPSRenderCallbacks
        << " channel_advances=" << stats.ChannelAdvanceCallbacks
        << " capture_advances=" << stats.CaptureAdvanceCallbacks
        << " hps_sample_reads=" << offload->sample_reads
        << " hps_capture_writes=" << offload->capture_writes
        << " hps_audio_frames=0"
        << " reference_sample_reads=" << reference->sample_reads
        << " reference_capture_writes=" << reference->capture_writes
        << "\n";
    return 0;
#endif
}
