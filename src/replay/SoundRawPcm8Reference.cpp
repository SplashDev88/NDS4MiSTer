// Simulator-only raw pre-blip PCM8 reference for Robert's sound RTL.
//
// Access control is relaxed only while parsing SPU.h in this test translation
// unit. This changes neither the vendored source nor SPU layout/ABI.

#include <algorithm>
#include <array>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <limits>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "Platform.h"
#include "Savestate.h"
#define private public
#include "SPU.h"
#undef private
#include "Args.h"
#include "NDS.h"

namespace {

constexpr std::array<std::uint8_t, 8> kMagic {
    'N', 'D', 'S', 'R', 'A', 'W', '1', '\0'
};
constexpr std::uint16_t kVersion = 1;
constexpr std::uint16_t kHeaderBytes = 40;
constexpr std::uint16_t kRecordBytes = 24;
// Post clamp, post configured degrade stage, and before blip_add_delta.
constexpr std::uint16_t kStageFlags = 0x0007;
constexpr std::uint32_t kSampleBase = 0x02001000;
constexpr std::uint32_t kSampleBytes = 64;
constexpr std::uint64_t kEndTime = 75776;
constexpr std::uint32_t kRawSamples = 74;
constexpr std::size_t kMaxRecords = 1'000'000;

enum class RecordType : std::uint8_t {
    Arm7Write = 1,
    TimeAdvance = 2,
    SampleRead = 3,
    RawStereo = 4,
    Marker = 5,
};

enum class Marker : std::uint32_t {
    SeededMemory = 1,
    ChannelStarted = 2,
    Arm7Halted = 3,
    RawComplete = 4,
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

struct Stats {
    std::size_t records = 0;
    std::size_t writes = 0;
    std::size_t advances = 0;
    std::size_t reads = 0;
    std::size_t raw_samples = 0;
    std::uint64_t end_time = 0;
    std::uint32_t seed_crc = 0;
    std::array<bool, 3> widths {};
    std::array<bool, 2> cpus {};
    bool halt_stall = false;
    bool halt_progress = false;
    bool nonzero = false;
    bool asymmetric = false;
    bool negative = false;
    bool positive = false;
};

constexpr std::array<std::uint8_t, kSampleBytes> kSeed {
    0x80, 0x90, 0xa0, 0xb0, 0xc0, 0xd0, 0xe0, 0xf0,
    0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70,
    0x7f, 0x68, 0x51, 0x3a, 0x23, 0x0c, 0xf5, 0xde,
    0xc7, 0xb0, 0x99, 0x82, 0x9a, 0xb2, 0xca, 0xe2,
    0xfa, 0x12, 0x2a, 0x42, 0x5a, 0x72, 0x6a, 0x52,
    0x3a, 0x22, 0x0a, 0xf2, 0xda, 0xc2, 0xaa, 0x92,
    0x88, 0xa8, 0xc8, 0xe8, 0x08, 0x28, 0x48, 0x68,
    0x78, 0x58, 0x38, 0x18, 0xf8, 0xd8, 0xb8, 0x98,
};

const std::vector<Write>& expected_writes()
{
    static const std::vector<Write> writes {
        {1, 0x04000304u, 0x0001u},
        {1, 0x04000504u, 0x0200u},
        {0, 0x04000500u, 0x007fu},
        {0, 0x04000501u, 0x0080u},
        {2, 0x04000404u, kSampleBase},
        {1, 0x04000408u, 0xf000u},
        {1, 0x0400040au, 0x0000u},
        {2, 0x0400040cu, 0x00000008u},
        {2, 0x04000400u, 0x8820007fu},
        {0, 0x04000301u, 0x0080u},
    };
    return writes;
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
    for (std::size_t index = 0; index < size; ++index) {
        crc ^= data[index];
        for (unsigned bit = 0; bit < 8; ++bit)
            crc = (crc >> 1) ^ (0xedb88320u & (0u - (crc & 1u)));
    }
    return ~crc;
}

std::vector<std::uint8_t> serialize(
    const std::vector<Record>& records, std::uint32_t seed_crc)
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
    append_u16(bytes, kStageFlags);
    append_u32(bytes, static_cast<std::uint32_t>(records.size()));
    append_u32(bytes, crc32(payload.data(), payload.size()));
    append_u32(bytes, seed_crc);
    append_u32(bytes, kRawSamples);
    append_u64(bytes, kEndTime);
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

bool parse(const std::vector<std::uint8_t>& bytes,
    Stats& stats, std::string& error)
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
        read_u16(bytes.data() + 14) != kStageFlags) {
        error = "wrong format or raw stage";
        return false;
    }
    const std::uint32_t count = read_u32(bytes.data() + 16);
    const std::uint32_t expected_crc = read_u32(bytes.data() + 20);
    stats.seed_crc = read_u32(bytes.data() + 24);
    const std::uint32_t declared_raw = read_u32(bytes.data() + 28);
    stats.end_time = read_u64(bytes.data() + 32);
    stats.records = count;
    const std::uint32_t canonical_seed_crc =
        crc32(kSeed.data(), kSeed.size());
    if (stats.seed_crc != canonical_seed_crc ||
        declared_raw != kRawSamples || stats.end_time != kEndTime ||
        count > kMaxRecords ||
        bytes.size() != kHeaderBytes +
            static_cast<std::size_t>(count) * kRecordBytes) {
        error = "noncanonical header values";
        return false;
    }
    const std::uint8_t* payload = bytes.data() + kHeaderBytes;
    const std::size_t payload_size = bytes.size() - kHeaderBytes;
    if (crc32(payload, payload_size) != expected_crc) {
        error = "payload CRC mismatch";
        return false;
    }

    std::vector<Write> writes;
    std::vector<std::pair<Marker, std::uint32_t>> markers;
    std::uint64_t last_record_time = 0;
    std::uint64_t last_shared_time = 0;
    std::uint32_t next_read = 0;
    std::uint32_t next_raw = 0;
    unsigned time_index = 0;

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
        if (time < last_record_time || time > kEndTime) {
            error = "nonmonotonic record time";
            return false;
        }
        last_record_time = time;

        switch (type) {
        case RecordType::Arm7Write: {
            if (flags > 2 || c != 0 ||
                !((a >= 0x04000400u && a < 0x04000520u) ||
                    a == 0x04000304u || a == 0x04000301u)) {
                error = "invalid ARM7 write";
                return false;
            }
            const std::uint32_t width = 1u << flags;
            if ((a & (width - 1u)) != 0 ||
                (flags == 0 && (b & 0xffffff00u) != 0) ||
                (flags == 1 && (b & 0xffff0000u) != 0)) {
                error = "noncanonical write width/alignment";
                return false;
            }
            writes.push_back({flags, a, b});
            stats.widths[flags] = true;
            ++stats.writes;
            break;
        }
        case RecordType::TimeAdvance: {
            if ((flags & ~0x1fu) != 0 || a != 1024u ||
                b != last_shared_time || time < b || c < time) {
                error = "invalid time advance";
                return false;
            }
            const unsigned pair = time_index / 2;
            const unsigned cpu = flags & 1u;
            const unsigned expected_cpu = time_index & 1u;
            const std::uint64_t expected_before =
                static_cast<std::uint64_t>(pair) * 1024;
            const std::uint64_t expected_after =
                expected_before + (expected_cpu ? 1024 : 0);
            const std::uint32_t expected_cpu_time =
                static_cast<std::uint32_t>(expected_before + 1024);
            const std::uint8_t expected_halt =
                pair >= 2 ? 0x18u : 0u;
            if (cpu != expected_cpu || time != expected_after ||
                b != expected_before || c != expected_cpu_time ||
                (flags & 0x1eu) != expected_halt) {
                error = "time sequence or halt state mismatch";
                return false;
            }
            const bool arm7_stably_halted =
                (flags & 0x18u) == 0x18u;
            stats.halt_stall |= arm7_stably_halted &&
                time == b && a != 0;
            stats.halt_progress |= arm7_stably_halted && time > b;
            stats.cpus[cpu] = true;
            last_shared_time = time;
            ++time_index;
            ++stats.advances;
            break;
        }
        case RecordType::SampleRead: {
            if (flags != 2 || c != next_read++ || (a & 3u) != 0 ||
                a < kSampleBase || a >= kSampleBase + kSampleBytes) {
                error = "invalid sample read";
                return false;
            }
            const std::uint32_t offset = a - kSampleBase;
            const std::uint32_t expected_data =
                static_cast<std::uint32_t>(kSeed[offset]) |
                (static_cast<std::uint32_t>(kSeed[offset + 1]) << 8) |
                (static_cast<std::uint32_t>(kSeed[offset + 2]) << 16) |
                (static_cast<std::uint32_t>(kSeed[offset + 3]) << 24);
            if (b != expected_data) {
                error = "sample read data differs from seed";
                return false;
            }
            ++stats.reads;
            break;
        }
        case RecordType::RawStereo: {
            const std::uint64_t expected_time =
                static_cast<std::uint64_t>(next_raw + 1) * 1024;
            if (flags != 0 || a != next_raw || time != expected_time ||
                !canonical_s16(b) || !canonical_s16(c)) {
                error = "invalid raw stereo sample";
                return false;
            }
            const std::int32_t left = decode_s16(b);
            const std::int32_t right = decode_s16(c);
            stats.nonzero |= left != 0 || right != 0;
            stats.asymmetric |= left != right;
            stats.negative |= left < 0 || right < 0;
            stats.positive |= left > 0 || right > 0;
            ++next_raw;
            ++stats.raw_samples;
            break;
        }
        case RecordType::Marker:
            if (flags != 0 ||
                a < static_cast<std::uint32_t>(Marker::SeededMemory) ||
                a > static_cast<std::uint32_t>(Marker::RawComplete) ||
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

    const std::vector<std::pair<Marker, std::uint32_t>> expected_markers {
        {Marker::SeededMemory, canonical_seed_crc},
        {Marker::ChannelStarted, 0},
        {Marker::Arm7Halted, 0},
        {Marker::RawComplete, kRawSamples},
    };
    if (writes != expected_writes() || markers != expected_markers ||
        last_record_time != kEndTime || last_shared_time != kEndTime) {
        error = "write, marker, or end-time contract mismatch";
        return false;
    }
    return true;
}

bool coverage(const Stats& stats, std::string& error)
{
    if (stats.writes != 10 ||
        !std::all_of(stats.widths.begin(), stats.widths.end(),
            [](bool seen) { return seen; })) {
        error = "incomplete exact-width write coverage";
        return false;
    }
    if (stats.advances != kRawSamples * 2 ||
        !stats.cpus[0] || !stats.cpus[1] ||
        !stats.halt_stall || !stats.halt_progress) {
        error = "incomplete normalized time/HALT coverage";
        return false;
    }
    if (stats.reads != 8 || stats.raw_samples != kRawSamples ||
        !stats.nonzero || !stats.asymmetric ||
        !stats.negative) {
        error = "incomplete sample-read or raw-stereo coverage reads=" +
            std::to_string(stats.reads) +
            " raw=" + std::to_string(stats.raw_samples) +
            " nonzero=" + std::to_string(stats.nonzero) +
            " asymmetric=" + std::to_string(stats.asymmetric) +
            " negative=" + std::to_string(stats.negative) +
            " positive=" + std::to_string(stats.positive);
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
                RecordType::SampleRead, 2, shared_time(),
                aligned, value, read_ordinal_++,
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

void advance(TraceNDS& nds, bool arm9)
{
    const bool arm9_before = nds.ARM9.Halted != 0;
    const bool arm7_before = nds.ARM7.Halted != 0;
    const std::uint64_t before = nds.shared_time();
    const std::uint64_t after =
        nds.AdvanceExternalCPU(arm9 ? 0u : 1u, 1024);
    const bool arm9_after = nds.ARM9.Halted != 0;
    const bool arm7_after = nds.ARM7.Halted != 0;
    const std::uint64_t cpu_time = arm9
        ? (nds.ARM9Timestamp >> nds.ARM9ClockShift)
        : nds.ARM7Timestamp;
    nds.records().push_back({
        RecordType::TimeAdvance,
        static_cast<std::uint8_t>((arm9 ? 0u : 1u) |
            (arm9_before ? 0x02u : 0u) |
            (arm9_after ? 0x04u : 0u) |
            (arm7_before ? 0x08u : 0u) |
            (arm7_after ? 0x10u : 0u)),
        after, 1024, static_cast<std::uint32_t>(before),
        static_cast<std::uint32_t>(cpu_time),
    });
}

std::vector<std::uint8_t> generate(std::string& error)
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

    std::copy(kSeed.begin(), kSeed.end(), nds.MainRAM + 0x1000);
    const std::uint32_t seed_crc = crc32(kSeed.data(), kSeed.size());
    marker(nds, Marker::SeededMemory, seed_crc);
    const auto& writes = expected_writes();
    for (std::size_t index = 0; index < writes.size() - 1; ++index)
        arm7_write(nds, writes[index]);
    marker(nds, Marker::ChannelStarted, 0);
    nds.set_read_capture(true);

    if (nds.SPU.MixInterval != 1024 || nds.SPU.Mute ||
        nds.SPU.Degrade10Bit || !nds.SPU.ApplyBias ||
        nds.SPU.Bias != 0x0200 || !(nds.SPU.Cnt & 0x8000)) {
        error = "SPU is not in the declared raw-output configuration";
        return {};
    }

    for (std::uint32_t sample = 0; sample < kRawSamples; ++sample) {
        advance(nds, true);
        advance(nds, false);
        if (nds.shared_time() !=
                static_cast<std::uint64_t>(sample + 1) * 1024 ||
            nds.SchedList[melonDS::Event_SPU].Timestamp !=
                static_cast<std::uint64_t>(sample + 2) * 1024) {
            error = "SPU event did not execute exactly once at 1024 cycles";
            return {};
        }
        const std::int32_t left = nds.SPU.OutputLastSamples[0];
        const std::int32_t right = nds.SPU.OutputLastSamples[1];
        nds.records().push_back({
            RecordType::RawStereo, 0, nds.shared_time(), sample,
            static_cast<std::uint32_t>(left),
            static_cast<std::uint32_t>(right),
        });
        if (sample == 1) {
            arm7_write(nds, writes.back());
            marker(nds, Marker::Arm7Halted, 0);
        }
    }

    const std::array<std::int16_t, 2> raw_before_drain {
        nds.SPU.OutputLastSamples[0], nds.SPU.OutputLastSamples[1]
    };
    nds.SPU.BufferAudio();
    std::array<std::int16_t, 512 * 2> post_blip {};
    (void)nds.SPU.ReadOutput(post_blip.data(), 512);
    if (nds.SPU.OutputLastSamples[0] != raw_before_drain[0] ||
        nds.SPU.OutputLastSamples[1] != raw_before_drain[1]) {
        error = "ReadOutput unexpectedly changed pre-blip last samples";
        return {};
    }
    marker(nds, Marker::RawComplete, kRawSamples);

    auto bytes = serialize(nds.records(), seed_crc);
    Stats stats;
    if (!parse(bytes, stats, error) || !coverage(stats, error))
        return {};
    return bytes;
}

void repair_crc(std::vector<std::uint8_t>& bytes)
{
    const std::uint32_t crc =
        crc32(bytes.data() + kHeaderBytes, bytes.size() - kHeaderBytes);
    for (unsigned shift = 0; shift < 32; shift += 8)
        bytes[20 + shift / 8] = static_cast<std::uint8_t>(crc >> shift);
}

bool malformed_checks(const std::vector<std::uint8_t>& good,
    std::string& error)
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
    auto stage = good;
    stage[14] ^= 1;
    bad.push_back(std::move(stage));

    for (const auto& bytes : bad) {
        Stats ignored;
        std::string rejection;
        if (parse(bytes, ignored, rejection)) {
            error = "malformed raw trace was accepted";
            return false;
        }
    }
    return true;
}

bool read_file(const std::string& path,
    std::vector<std::uint8_t>& bytes, std::string& error)
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

void print_stats(const Stats& stats)
{
    std::cout << "records=" << stats.records
              << " writes=" << stats.writes
              << " advances=" << stats.advances
              << " reads=" << stats.reads
              << " raw=" << stats.raw_samples
              << " end=" << stats.end_time
              << " seed_crc32=" << std::hex << stats.seed_crc << std::dec;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 2 || argc > 3) {
        std::cerr << "usage: nds_sound_raw_pcm8_reference "
                     "generate output | verify input | self-test\n";
        return 2;
    }
    const std::string command = argv[1];
    std::string error;

    if (command == "generate" && argc == 3) {
        auto bytes = generate(error);
        if (bytes.empty() || !write_file(argv[2], bytes, error)) {
            std::cerr << "generate failed: " << error << "\n";
            return 1;
        }
        Stats stats;
        if (!parse(bytes, stats, error)) {
            std::cerr << "internal verify failed: " << error << "\n";
            return 1;
        }
        std::cout << "PASS: generated raw pre-blip PCM8 ";
        print_stats(stats);
        std::cout << " bytes=" << bytes.size() << "\n";
        return 0;
    }

    if (command == "verify" && argc == 3) {
        std::vector<std::uint8_t> bytes;
        Stats stats;
        if (!read_file(argv[2], bytes, error) ||
            !parse(bytes, stats, error) ||
            !coverage(stats, error)) {
            std::cerr << "verify failed: " << error << "\n";
            return 1;
        }
        std::cout << "PASS: verified raw pre-blip PCM8 ";
        print_stats(stats);
        std::cout << "\n";
        return 0;
    }

    if (command == "self-test" && argc == 2) {
        auto first = generate(error);
        auto second = generate(error);
        if (first.empty() || first != second ||
            !malformed_checks(first, error)) {
            if (error.empty()) error = "nondeterministic generation";
            std::cerr << "self-test failed: " << error << "\n";
            return 1;
        }
        Stats stats;
        if (!parse(first, stats, error)) {
            std::cerr << "self-test parse failed: " << error << "\n";
            return 1;
        }
        std::cout << "PASS: deterministic raw generation + six malformed "
                     "rejections ";
        print_stats(stats);
        std::cout << "\n";
        return 0;
    }

    std::cerr << "invalid command or arguments\n";
    return 2;
}
