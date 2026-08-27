// Copyright-free simulator-only melonDS references for PCM16, ADPCM, PSG,
// and noise. This is intentionally independent of the pinned PCM8 v1 tool.

#include "Args.h"
#include "NDS.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr std::array<std::uint8_t, 8> kMagic {
    'N', 'D', 'S', 'A', 'U', 'D', '2', '\0'
};
constexpr std::uint16_t kVersion = 2;
constexpr std::uint16_t kHeaderBytes = 40;
constexpr std::uint16_t kRecordBytes = 24;
constexpr std::uint32_t kSampleBase = 0x02002000;
constexpr std::uint32_t kSampleBytes = 64;
constexpr std::size_t kMaxRecords = 1'000'000;

enum class SoundCase : std::uint32_t {
    Pcm16 = 1,
    Adpcm = 2,
    Psg = 3,
    Noise = 4,
};

enum class RecordType : std::uint8_t {
    Arm7Write = 1,
    TimeAdvance = 2,
    SampleRead = 3,
    AudioSample = 4,
    Marker = 5,
};

enum class Marker : std::uint32_t {
    CaseSeed = 1,
    ChannelStarted = 2,
    AudioDrained = 3,
};

struct Record {
    RecordType type {};
    std::uint8_t flags = 0;
    std::uint64_t time = 0;
    std::uint32_t a = 0;
    std::uint32_t b = 0;
    std::uint32_t c = 0;
};

struct Write {
    unsigned access = 0;
    std::uint32_t address = 0;
    std::uint32_t value = 0;

    bool operator==(const Write& other) const
    {
        return access == other.access && address == other.address &&
            value == other.value;
    }
};

struct CaseSpec {
    SoundCase id {};
    const char* name = "";
    std::uint32_t channel_base = 0;
    std::uint32_t control = 0;
    bool uses_memory = false;
    std::uint16_t loop_words = 0;
    std::uint32_t length_words = 0;
};

struct TraceStats {
    SoundCase sound_case {};
    std::size_t records = 0;
    std::size_t writes = 0;
    std::size_t advances = 0;
    std::size_t sample_reads = 0;
    std::size_t audio_frames = 0;
    std::uint64_t end_time = 0;
    std::uint32_t seed_crc = 0;
    std::array<bool, 3> widths {};
    std::array<bool, 2> cpus {};
    bool unilateral_stall = false;
    bool catchup_progress = false;
    bool nonzero_audio = false;
    bool stereo_difference = false;
    bool negative_audio = false;
    bool positive_audio = false;
};

constexpr std::array<CaseSpec, 4> kCases {{
    {SoundCase::Pcm16, "pcm16", 0x04000420u, 0xa818007fu,
        true, 0, 16},
    {SoundCase::Adpcm, "adpcm", 0x04000430u, 0xc868007fu,
        true, 1, 15},
    {SoundCase::Psg, "psg", 0x04000480u, 0xe328007fu,
        false, 0, 0},
    {SoundCase::Noise, "noise", 0x040004e0u, 0xe058007fu,
        false, 0, 0},
}};

const CaseSpec* find_case(SoundCase id)
{
    for (const CaseSpec& spec : kCases)
        if (spec.id == id) return &spec;
    return nullptr;
}

const CaseSpec* find_case(const std::string& name)
{
    for (const CaseSpec& spec : kCases)
        if (name == spec.name) return &spec;
    return nullptr;
}

void append_u16(std::vector<std::uint8_t>& out, std::uint16_t value)
{
    out.push_back(static_cast<std::uint8_t>(value));
    out.push_back(static_cast<std::uint8_t>(value >> 8));
}

void append_u32(std::vector<std::uint8_t>& out, std::uint32_t value)
{
    for (unsigned shift = 0; shift < 32; shift += 8)
        out.push_back(static_cast<std::uint8_t>(value >> shift));
}

void append_u64(std::vector<std::uint8_t>& out, std::uint64_t value)
{
    for (unsigned shift = 0; shift < 64; shift += 8)
        out.push_back(static_cast<std::uint8_t>(value >> shift));
}

std::uint16_t read_u16(const std::uint8_t* data)
{
    return static_cast<std::uint16_t>(data[0]) |
        (static_cast<std::uint16_t>(data[1]) << 8);
}

std::uint32_t read_u32(const std::uint8_t* data)
{
    std::uint32_t value = 0;
    for (unsigned shift = 0; shift < 32; shift += 8)
        value |= static_cast<std::uint32_t>(data[shift / 8]) << shift;
    return value;
}

std::uint64_t read_u64(const std::uint8_t* data)
{
    std::uint64_t value = 0;
    for (unsigned shift = 0; shift < 64; shift += 8)
        value |= static_cast<std::uint64_t>(data[shift / 8]) << shift;
    return value;
}

std::uint32_t crc32(const std::uint8_t* data, std::size_t size)
{
    std::uint32_t crc = 0xffffffffu;
    for (std::size_t i = 0; i < size; ++i) {
        crc ^= data[i];
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

std::array<std::uint8_t, kSampleBytes> case_seed(SoundCase sound_case)
{
    std::array<std::uint8_t, kSampleBytes> seed {};
    if (sound_case == SoundCase::Pcm16) {
        for (unsigned index = 0; index < kSampleBytes / 2; ++index) {
            const auto sample = static_cast<std::int16_t>(
                static_cast<std::int32_t>((index * 7919u + 12345u) & 0xffffu) -
                32768);
            seed[index * 2] = static_cast<std::uint8_t>(sample);
            seed[index * 2 + 1] =
                static_cast<std::uint8_t>(static_cast<std::uint16_t>(sample) >> 8);
        }
    } else if (sound_case == SoundCase::Adpcm) {
        // IMA-ADPCM header: initial sample -4096, initial index 32.
        seed[0] = 0x00;
        seed[1] = 0xf0;
        seed[2] = 0x20;
        seed[3] = 0x00;
        for (unsigned index = 4; index < kSampleBytes; ++index)
            seed[index] = static_cast<std::uint8_t>(
                (index * 73u) ^ (index * 11u) ^ 0x5au);
    }
    return seed;
}

std::vector<Write> expected_writes(const CaseSpec& spec)
{
    std::vector<Write> writes {
        {1, 0x04000304u, 0x0001u},
        {1, 0x04000504u, 0x0200u},
        {0, 0x04000500u, 0x007fu},
        {0, 0x04000501u, 0x0080u},
    };
    if (spec.uses_memory) {
        writes.push_back({2, spec.channel_base + 4u, kSampleBase});
        writes.push_back({1, spec.channel_base + 8u, 0xfe00u});
        writes.push_back({1, spec.channel_base + 0xau, spec.loop_words});
        writes.push_back({2, spec.channel_base + 0xcu, spec.length_words});
    } else {
        writes.push_back({1, spec.channel_base + 8u, 0xfe00u});
    }
    writes.push_back({2, spec.channel_base, spec.control});
    return writes;
}

std::vector<std::uint8_t> serialize(const CaseSpec& spec,
    const std::vector<Record>& records, std::uint32_t seed_crc,
    std::uint64_t end_time)
{
    std::vector<std::uint8_t> payload;
    payload.reserve(records.size() * kRecordBytes);
    for (const Record& record : records) {
        payload.push_back(static_cast<std::uint8_t>(record.type));
        payload.push_back(record.flags);
        append_u16(payload, 0);
        append_u64(payload, record.time);
        append_u32(payload, record.a);
        append_u32(payload, record.b);
        append_u32(payload, record.c);
    }

    std::vector<std::uint8_t> bytes;
    bytes.reserve(kHeaderBytes + payload.size());
    bytes.insert(bytes.end(), kMagic.begin(), kMagic.end());
    append_u16(bytes, kVersion);
    append_u16(bytes, kHeaderBytes);
    append_u16(bytes, kRecordBytes);
    append_u16(bytes, 0);
    append_u32(bytes, static_cast<std::uint32_t>(spec.id));
    append_u32(bytes, static_cast<std::uint32_t>(records.size()));
    append_u32(bytes, crc32(payload.data(), payload.size()));
    append_u32(bytes, seed_crc);
    append_u64(bytes, end_time);
    bytes.insert(bytes.end(), payload.begin(), payload.end());
    return bytes;
}

bool canonical_s16(std::uint32_t value)
{
    return value <= 0x00007fffu || value >= 0xffff8000u;
}

std::int32_t decode_s16(std::uint32_t value)
{
    if (value <= 0x7fffu) return static_cast<std::int32_t>(value);
    return -static_cast<std::int32_t>((~value) + 1u);
}

bool parse_trace(const std::vector<std::uint8_t>& bytes,
    TraceStats& stats, std::string& error)
{
    stats = {};
    if (bytes.size() < kHeaderBytes) {
        error = "truncated header";
        return false;
    }
    if (!std::equal(kMagic.begin(), kMagic.end(), bytes.begin())) {
        error = "bad magic";
        return false;
    }
    if (read_u16(bytes.data() + 8) != kVersion ||
        read_u16(bytes.data() + 10) != kHeaderBytes ||
        read_u16(bytes.data() + 12) != kRecordBytes ||
        read_u16(bytes.data() + 14) != 0) {
        error = "noncanonical header";
        return false;
    }
    stats.sound_case = static_cast<SoundCase>(read_u32(bytes.data() + 16));
    const CaseSpec* spec = find_case(stats.sound_case);
    if (!spec) {
        error = "unknown sound case";
        return false;
    }
    const std::uint32_t count = read_u32(bytes.data() + 20);
    const std::uint32_t expected_crc = read_u32(bytes.data() + 24);
    stats.seed_crc = read_u32(bytes.data() + 28);
    stats.end_time = read_u64(bytes.data() + 32);
    stats.records = count;
    if (count > kMaxRecords ||
        bytes.size() != kHeaderBytes +
            static_cast<std::size_t>(count) * kRecordBytes) {
        error = "record count/length mismatch";
        return false;
    }
    const std::uint8_t* payload = bytes.data() + kHeaderBytes;
    const std::size_t payload_size = bytes.size() - kHeaderBytes;
    if (crc32(payload, payload_size) != expected_crc) {
        error = "payload CRC mismatch";
        return false;
    }

    const auto seed = case_seed(spec->id);
    const std::uint32_t canonical_seed_crc =
        spec->uses_memory ? crc32(seed.data(), seed.size()) : 0;
    if (stats.seed_crc != canonical_seed_crc) {
        error = "seed CRC mismatch";
        return false;
    }

    std::vector<Write> writes;
    std::uint64_t last_record_time = 0;
    std::uint64_t last_shared_time = 0;
    std::uint32_t next_read = 0;
    std::uint32_t next_audio = 0;
    unsigned time_index = 0;
    std::vector<std::pair<Marker, std::uint32_t>> markers;
    for (std::uint32_t index = 0; index < count; ++index) {
        const std::uint8_t* raw =
            payload + static_cast<std::size_t>(index) * kRecordBytes;
        const auto type = static_cast<RecordType>(raw[0]);
        const std::uint8_t flags = raw[1];
        const std::uint16_t reserved = read_u16(raw + 2);
        const std::uint64_t time = read_u64(raw + 4);
        const std::uint32_t a = read_u32(raw + 12);
        const std::uint32_t b = read_u32(raw + 16);
        const std::uint32_t c = read_u32(raw + 20);
        if (reserved != 0) {
            error = "nonzero record reserved field";
            return false;
        }
        if (time < last_record_time || time > stats.end_time) {
            error = "nonmonotonic or out-of-range record time";
            return false;
        }
        last_record_time = time;

        switch (type) {
        case RecordType::Arm7Write: {
            if (flags > 2 || c != 0 ||
                !((a >= 0x04000400u && a < 0x04000520u) ||
                    a == 0x04000304u)) {
                error = "invalid ARM7 write";
                return false;
            }
            const std::uint32_t width = 1u << flags;
            if ((a & (width - 1u)) != 0 ||
                (flags == 0 && (b & 0xffffff00u) != 0) ||
                (flags == 1 && (b & 0xffff0000u) != 0)) {
                error = "noncanonical ARM7 write width/alignment";
                return false;
            }
            writes.push_back({flags, a, b});
            stats.widths[flags] = true;
            ++stats.writes;
            break;
        }
        case RecordType::TimeAdvance: {
            if ((flags & ~1u) != 0 || b != last_shared_time ||
                time < b || c < time) {
                error = "invalid normalized time advance";
                return false;
            }
            const unsigned cpu = flags & 1u;
            const std::uint32_t expected_cycles =
                time_index < 2 ? 4096u : 8192u;
            const unsigned expected_cpu = time_index & 1u;
            std::uint64_t expected_before = 0;
            std::uint64_t expected_after = 0;
            std::uint32_t expected_cpu_time = 4096;
            if (time_index == 1) {
                expected_after = 4096;
            } else if (time_index >= 2) {
                const std::uint64_t pair =
                    static_cast<std::uint64_t>((time_index - 2) / 2);
                expected_before = 4096 + pair * 8192;
                expected_after = expected_before +
                    ((time_index & 1u) ? 8192 : 0);
                expected_cpu_time =
                    static_cast<std::uint32_t>(expected_before + 8192);
            }
            if (a != expected_cycles || cpu != expected_cpu ||
                b != expected_before || time != expected_after ||
                c != expected_cpu_time) {
                error = "unexpected deterministic timing sequence";
                return false;
            }
            stats.cpus[cpu] = true;
            if (a != 0 && time == b) stats.unilateral_stall = true;
            if (time > b) stats.catchup_progress = true;
            last_shared_time = time;
            ++time_index;
            ++stats.advances;
            break;
        }
        case RecordType::SampleRead: {
            if (!spec->uses_memory || flags != 2 || c != next_read++ ||
                (a & 3u) != 0 || a < kSampleBase ||
                a >= kSampleBase + kSampleBytes) {
                error = "invalid sample-memory read";
                return false;
            }
            const std::uint32_t offset = a - kSampleBase;
            const std::uint32_t expected_data =
                static_cast<std::uint32_t>(seed[offset]) |
                (static_cast<std::uint32_t>(seed[offset + 1]) << 8) |
                (static_cast<std::uint32_t>(seed[offset + 2]) << 16) |
                (static_cast<std::uint32_t>(seed[offset + 3]) << 24);
            if (b != expected_data) {
                error = "sample-memory read data differs from canonical seed";
                return false;
            }
            ++stats.sample_reads;
            break;
        }
        case RecordType::AudioSample: {
            if (flags != 0 || a != next_audio++ ||
                !canonical_s16(b) || !canonical_s16(c) ||
                time != stats.end_time) {
                error = "invalid signed stereo sample";
                return false;
            }
            const std::int32_t left = decode_s16(b);
            const std::int32_t right = decode_s16(c);
            stats.nonzero_audio |= left != 0 || right != 0;
            stats.stereo_difference |= left != right;
            stats.negative_audio |= left < 0 || right < 0;
            stats.positive_audio |= left > 0 || right > 0;
            ++stats.audio_frames;
            break;
        }
        case RecordType::Marker:
            if (flags != 0 ||
                a < static_cast<std::uint32_t>(Marker::CaseSeed) ||
                a > static_cast<std::uint32_t>(Marker::AudioDrained) ||
                c != 0) {
                error = "invalid marker";
                return false;
            }
            markers.emplace_back(static_cast<Marker>(a), b);
            break;
        default:
            error = "unknown record type";
            return false;
        }
    }

    if (writes != expected_writes(*spec)) {
        error = "ARM7 write sequence differs from case contract";
        return false;
    }
    const std::vector<std::pair<Marker, std::uint32_t>> expected_markers {
        {Marker::CaseSeed, canonical_seed_crc},
        {Marker::ChannelStarted, static_cast<std::uint32_t>(spec->id)},
        {Marker::AudioDrained, next_audio},
    };
    if (markers != expected_markers) {
        error = "phase marker sequence differs from case contract";
        return false;
    }
    if (last_record_time != stats.end_time ||
        last_shared_time != stats.end_time) {
        error = "end-time mismatch";
        return false;
    }
    return true;
}

bool coverage_ok(const TraceStats& stats, std::string& error)
{
    const CaseSpec* spec = find_case(stats.sound_case);
    if (!spec) {
        error = "unknown case in coverage";
        return false;
    }
    const std::size_t expected_write_count =
        expected_writes(*spec).size();
    if (stats.writes != expected_write_count ||
        !std::all_of(stats.widths.begin(), stats.widths.end(),
            [](bool seen) { return seen; })) {
        error = "incomplete exact-width register coverage";
        return false;
    }
    if (stats.advances != 18 || !stats.cpus[0] || !stats.cpus[1] ||
        !stats.unilateral_stall || !stats.catchup_progress ||
        stats.end_time != 69632) {
        error = "incomplete normalized shared-time coverage";
        return false;
    }
    if ((spec->uses_memory && stats.sample_reads < 8) ||
        (!spec->uses_memory && stats.sample_reads != 0)) {
        error = "wrong sample-memory coverage for format";
        return false;
    }
    if (stats.audio_frames < 16 || !stats.nonzero_audio ||
        !stats.stereo_difference || !stats.negative_audio ||
        !stats.positive_audio) {
        error = "incomplete signed stereo coverage";
        return false;
    }
    return true;
}

class TraceNDS final : public melonDS::NDS {
public:
    explicit TraceNDS(melonDS::NDSArgs&& args) noexcept
        : melonDS::NDS(std::move(args))
    {
    }

    std::vector<Record>& records() { return records_; }
    std::uint64_t shared_time() const { return SysTimestamp; }
    void set_read_capture(bool enabled) { capture_reads_ = enabled; }

    std::uint32_t ARM7Read32(std::uint32_t address) override
    {
        const std::uint32_t aligned = address & ~3u;
        const std::uint32_t value = melonDS::NDS::ARM7Read32(address);
        if (capture_reads_) {
            records_.push_back({
                RecordType::SampleRead, 2, shared_time(), aligned, value,
                read_ordinal_++,
            });
        }
        return value;
    }

private:
    std::vector<Record> records_;
    std::uint32_t read_ordinal_ = 0;
    bool capture_reads_ = false;
};

void marker(TraceNDS& nds, Marker value, std::uint32_t detail)
{
    nds.records().push_back({
        RecordType::Marker, 0, nds.shared_time(),
        static_cast<std::uint32_t>(value), detail, 0,
    });
}

void arm7_write(TraceNDS& nds, const Write& write)
{
    switch (write.access) {
    case 0:
        nds.ARM7Write8(write.address,
            static_cast<std::uint8_t>(write.value));
        break;
    case 1:
        nds.ARM7Write16(write.address,
            static_cast<std::uint16_t>(write.value));
        break;
    case 2:
        nds.ARM7Write32(write.address, write.value);
        break;
    default:
        return;
    }
    nds.records().push_back({
        RecordType::Arm7Write,
        static_cast<std::uint8_t>(write.access),
        nds.shared_time(), write.address, write.value, 0,
    });
}

void advance(TraceNDS& nds, bool arm9, std::uint32_t cycles)
{
    const std::uint64_t before = nds.shared_time();
    const std::uint64_t after =
        nds.AdvanceExternalCPU(arm9 ? 0u : 1u, cycles);
    const std::uint64_t cpu_time = arm9
        ? (nds.ARM9Timestamp >> nds.ARM9ClockShift)
        : nds.ARM7Timestamp;
    nds.records().push_back({
        RecordType::TimeAdvance,
        static_cast<std::uint8_t>(arm9 ? 0u : 1u),
        after, cycles, static_cast<std::uint32_t>(before),
        static_cast<std::uint32_t>(cpu_time),
    });
}

std::vector<std::uint8_t> generate(const CaseSpec& spec, std::string& error)
{
    melonDS::NDSArgs args;
    args.JIT = std::nullopt;
    args.BitDepth = melonDS::AudioBitDepth::_16Bit;
    args.Interpolation = melonDS::AudioInterpolation::None;
    args.OutputSampleRate = 32768.0;
    auto storage = std::make_unique<TraceNDS>(std::move(args));
    TraceNDS& nds = *storage;
    nds.Reset();
    nds.Start();

    const auto seed = case_seed(spec.id);
    const std::uint32_t seed_crc =
        spec.uses_memory ? crc32(seed.data(), seed.size()) : 0;
    if (spec.uses_memory)
        std::copy(seed.begin(), seed.end(), nds.MainRAM + 0x2000);
    marker(nds, Marker::CaseSeed, seed_crc);

    for (const Write& write : expected_writes(spec))
        arm7_write(nds, write);
    marker(nds, Marker::ChannelStarted,
        static_cast<std::uint32_t>(spec.id));
    // Capture every ARM7 word read after channel start. Memory-backed cases
    // must stay inside the seeded window; PSG/noise must produce none at all.
    nds.set_read_capture(true);

    advance(nds, true, 4096);
    advance(nds, false, 4096);
    for (unsigned bucket = 0; bucket < 8; ++bucket) {
        advance(nds, true, 8192);
        advance(nds, false, 8192);
    }

    nds.SPU.BufferAudio();
    std::array<std::int16_t, 512 * 2> stereo {};
    const int frames = nds.SPU.ReadOutput(stereo.data(), 512);
    if (frames <= 0) {
        error = "melonDS produced no audio";
        return {};
    }
    for (int index = 0; index < frames; ++index) {
        const auto left = static_cast<std::int32_t>(stereo[index * 2]);
        const auto right = static_cast<std::int32_t>(stereo[index * 2 + 1]);
        nds.records().push_back({
            RecordType::AudioSample, 0, nds.shared_time(),
            static_cast<std::uint32_t>(index),
            static_cast<std::uint32_t>(left),
            static_cast<std::uint32_t>(right),
        });
    }
    marker(nds, Marker::AudioDrained,
        static_cast<std::uint32_t>(frames));

    auto bytes =
        serialize(spec, nds.records(), seed_crc, nds.shared_time());
    TraceStats stats;
    if (!parse_trace(bytes, stats, error) || !coverage_ok(stats, error))
        return {};
    return bytes;
}

void repair_crc(std::vector<std::uint8_t>& bytes)
{
    const std::uint32_t crc =
        crc32(bytes.data() + kHeaderBytes, bytes.size() - kHeaderBytes);
    for (unsigned shift = 0; shift < 32; shift += 8)
        bytes[24 + shift / 8] = static_cast<std::uint8_t>(crc >> shift);
}

bool malformed_checks(const CaseSpec& spec,
    const std::vector<std::uint8_t>& good, std::string& error)
{
    std::vector<std::vector<std::uint8_t>> bad;
    auto magic = good;
    magic[0] ^= 0x80;
    bad.push_back(std::move(magic));
    auto truncated = good;
    truncated.pop_back();
    bad.push_back(std::move(truncated));
    auto payload = good;
    payload.back() ^= 1;
    bad.push_back(std::move(payload));
    auto type = good;
    type[kHeaderBytes] = 0xff;
    repair_crc(type);
    bad.push_back(std::move(type));
    auto reserved = good;
    reserved[kHeaderBytes + 2] = 1;
    repair_crc(reserved);
    bad.push_back(std::move(reserved));
    auto wrong_case = good;
    const std::uint32_t other =
        spec.id == SoundCase::Noise
            ? static_cast<std::uint32_t>(SoundCase::Pcm16)
            : static_cast<std::uint32_t>(spec.id) + 1;
    for (unsigned shift = 0; shift < 32; shift += 8)
        wrong_case[16 + shift / 8] =
            static_cast<std::uint8_t>(other >> shift);
    bad.push_back(std::move(wrong_case));

    for (const auto& bytes : bad) {
        TraceStats ignored;
        std::string rejection;
        if (parse_trace(bytes, ignored, rejection)) {
            error = std::string(spec.name) + " accepted malformed input";
            return false;
        }
    }
    return true;
}

bool read_file(const std::string& path, std::vector<std::uint8_t>& bytes,
    std::string& error)
{
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        error = "cannot open input: " + path;
        return false;
    }
    input.seekg(0, std::ios::end);
    const std::streamoff length = input.tellg();
    constexpr std::uint64_t max_bytes =
        kHeaderBytes + kMaxRecords * kRecordBytes;
    if (length < 0 ||
        static_cast<std::uint64_t>(length) > max_bytes) {
        error = "invalid input length";
        return false;
    }
    input.seekg(0, std::ios::beg);
    bytes.resize(static_cast<std::size_t>(length));
    if (!bytes.empty() &&
        !input.read(reinterpret_cast<char*>(bytes.data()), length)) {
        error = "short input read";
        return false;
    }
    return true;
}

bool write_file(const std::string& path,
    const std::vector<std::uint8_t>& bytes, std::string& error)
{
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    if (!output) {
        error = "cannot open output: " + path;
        return false;
    }
    output.write(reinterpret_cast<const char*>(bytes.data()),
        static_cast<std::streamsize>(bytes.size()));
    if (!output) {
        error = "short output write";
        return false;
    }
    return true;
}

void print_stats(const TraceStats& stats)
{
    const CaseSpec* spec = find_case(stats.sound_case);
    std::cout << "case=" << (spec ? spec->name : "unknown")
              << " records=" << stats.records
              << " writes=" << stats.writes
              << " advances=" << stats.advances
              << " reads=" << stats.sample_reads
              << " audio=" << stats.audio_frames
              << " end=" << stats.end_time
              << " seed_crc32=" << std::hex << stats.seed_crc << std::dec;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 2 || argc > 4) {
        std::cerr << "usage: nds_sound_format_reference_suite "
                     "generate case output | verify input | self-test\n";
        return 2;
    }
    const std::string command = argv[1];
    std::string error;

    if (command == "generate" && argc == 4) {
        const CaseSpec* spec = find_case(argv[2]);
        if (!spec) {
            std::cerr << "unknown case\n";
            return 2;
        }
        auto bytes = generate(*spec, error);
        if (bytes.empty() || !write_file(argv[3], bytes, error)) {
            std::cerr << "generate failed: " << error << "\n";
            return 1;
        }
        TraceStats stats;
        if (!parse_trace(bytes, stats, error)) {
            std::cerr << "internal verify failed: " << error << "\n";
            return 1;
        }
        std::cout << "PASS: generated ";
        print_stats(stats);
        std::cout << " bytes=" << bytes.size() << "\n";
        return 0;
    }

    if (command == "verify" && argc == 3) {
        std::vector<std::uint8_t> bytes;
        TraceStats stats;
        if (!read_file(argv[2], bytes, error) ||
            !parse_trace(bytes, stats, error) ||
            !coverage_ok(stats, error)) {
            std::cerr << "verify failed: " << error << "\n";
            return 1;
        }
        std::cout << "PASS: verified ";
        print_stats(stats);
        std::cout << "\n";
        return 0;
    }

    if (command == "self-test" && argc == 2) {
        for (const CaseSpec& spec : kCases) {
            auto first = generate(spec, error);
            auto second = generate(spec, error);
            if (first.empty() || first != second ||
                !malformed_checks(spec, first, error)) {
                if (error.empty()) error = "nondeterministic generation";
                std::cerr << "self-test failed for " << spec.name
                          << ": " << error << "\n";
                return 1;
            }
            TraceStats stats;
            if (!parse_trace(first, stats, error)) {
                std::cerr << "self-test parse failed: " << error << "\n";
                return 1;
            }
            std::cout << "PASS: deterministic + six malformed rejections ";
            print_stats(stats);
            std::cout << "\n";
        }
        return 0;
    }

    std::cerr << "invalid command or arguments\n";
    return 2;
}
