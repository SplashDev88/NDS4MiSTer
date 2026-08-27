// Deterministic simulator-only melonDS sound reference trace.
//
// This deliberately drives the same ARM7 I/O and external-CPU scheduler seams
// used by the NDS4MiSTer hybrid responder.  It does not modify melonDS and it
// does not participate in the MiSTer build.

#include "Args.h"
#include "NDS.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr std::array<std::uint8_t, 8> kMagic {
    'N', 'D', 'S', 'A', 'U', 'D', '1', '\0'
};
constexpr std::uint16_t kVersion = 1;
constexpr std::uint16_t kHeaderBytes = 32;
constexpr std::uint16_t kRecordBytes = 24;
constexpr std::uint32_t kSampleBase = 0x02001000;
constexpr std::uint32_t kSampleBytes = 64;
constexpr std::size_t kMaxRecords = 1'000'000;

enum class RecordType : std::uint8_t {
    Arm7Write = 1,
    TimeAdvance = 2,
    SampleRead = 3,
    AudioSample = 4,
    Marker = 5,
};

enum class Marker : std::uint32_t {
    SeededMemory = 1,
    ChannelStarted = 2,
    Arm7Halted = 3,
    AudioDrained = 4,
};

struct Record {
    RecordType type {};
    std::uint8_t flags = 0;
    std::uint64_t time = 0;
    std::uint32_t a = 0;
    std::uint32_t b = 0;
    std::uint32_t c = 0;
};

struct TraceStats {
    std::size_t writes = 0;
    std::size_t advances = 0;
    std::size_t sample_reads = 0;
    std::size_t audio_frames = 0;
    std::array<bool, 3> write_widths {};
    std::array<bool, 2> timing_cpus {};
    bool saw_halted_stall = false;
    bool saw_halted_progress = false;
    bool saw_nonzero_audio = false;
    bool saw_stereo_difference = false;
    bool saw_negative_audio = false;
    bool saw_positive_audio = false;
    std::uint64_t end_time = 0;
};

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

std::vector<std::uint8_t> serialize(
    const std::vector<Record>& records, std::uint64_t end_time)
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
    append_u32(bytes, static_cast<std::uint32_t>(records.size()));
    append_u32(bytes, crc32(payload.data(), payload.size()));
    append_u64(bytes, end_time);
    bytes.insert(bytes.end(), payload.begin(), payload.end());
    return bytes;
}

bool is_canonical_s16(std::uint32_t value)
{
    const auto signed_value = static_cast<std::int32_t>(value);
    return signed_value >= std::numeric_limits<std::int16_t>::min() &&
        signed_value <= std::numeric_limits<std::int16_t>::max();
}

bool allowed_write_address(std::uint32_t address)
{
    return (address >= 0x04000400u && address < 0x04000520u) ||
        address == 0x04000304u || address == 0x04000301u;
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
    if (read_u16(bytes.data() + 8) != kVersion) {
        error = "unsupported version";
        return false;
    }
    if (read_u16(bytes.data() + 10) != kHeaderBytes ||
        read_u16(bytes.data() + 12) != kRecordBytes ||
        read_u16(bytes.data() + 14) != 0) {
        error = "noncanonical header";
        return false;
    }

    const std::uint32_t count = read_u32(bytes.data() + 16);
    const std::uint32_t expected_crc = read_u32(bytes.data() + 20);
    stats.end_time = read_u64(bytes.data() + 24);
    if (count > kMaxRecords) {
        error = "record count exceeds safety bound";
        return false;
    }
    if (bytes.size() != kHeaderBytes +
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

    std::uint64_t last_record_time = 0;
    std::uint64_t last_shared_time = 0;
    std::uint32_t next_sample_read = 0;
    std::uint32_t next_audio_frame = 0;
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
            if (flags > 2 || !allowed_write_address(a) || c != 0) {
                error = "invalid ARM7 write record";
                return false;
            }
            const std::uint32_t bytes_per_access = 1u << flags;
            if ((a & (bytes_per_access - 1u)) != 0 ||
                (flags == 0 && (b & 0xffffff00u) != 0) ||
                (flags == 1 && (b & 0xffff0000u) != 0)) {
                error = "noncanonical ARM7 write width/alignment";
                return false;
            }
            ++stats.writes;
            stats.write_widths[flags] = true;
            break;
        }
        case RecordType::TimeAdvance: {
            if ((flags & ~0x1fu) != 0 || b != last_shared_time ||
                time < b || c < time) {
                error = "invalid shared-time advance";
                return false;
            }
            const unsigned cpu = flags & 1u;
            const bool arm9_halt_before = (flags & 0x02u) != 0;
            const bool arm9_halt_after = (flags & 0x04u) != 0;
            const bool arm7_halt_before = (flags & 0x08u) != 0;
            const bool arm7_halt_after = (flags & 0x10u) != 0;
            const bool stable_halt =
                (arm9_halt_before && arm9_halt_after) ||
                (arm7_halt_before && arm7_halt_after);
            stats.timing_cpus[cpu] = true;
            ++stats.advances;
            if (stable_halt && time == b && a != 0)
                stats.saw_halted_stall = true;
            if (stable_halt && time > b)
                stats.saw_halted_progress = true;
            last_shared_time = time;
            break;
        }
        case RecordType::SampleRead:
            if (flags != 2 || (a & 3u) != 0 ||
                a < kSampleBase || a >= kSampleBase + kSampleBytes ||
                c != next_sample_read++) {
                error = "invalid sample-memory read";
                return false;
            }
            ++stats.sample_reads;
            break;
        case RecordType::AudioSample: {
            if (flags != 0 || a != next_audio_frame++ ||
                !is_canonical_s16(b) || !is_canonical_s16(c) ||
                time != stats.end_time) {
                error = "invalid signed stereo record";
                return false;
            }
            const auto left = static_cast<std::int32_t>(b);
            const auto right = static_cast<std::int32_t>(c);
            ++stats.audio_frames;
            stats.saw_nonzero_audio |= left != 0 || right != 0;
            stats.saw_stereo_difference |= left != right;
            stats.saw_negative_audio |= left < 0 || right < 0;
            stats.saw_positive_audio |= left > 0 || right > 0;
            break;
        }
        case RecordType::Marker:
            if (flags != 0 ||
                a < static_cast<std::uint32_t>(Marker::SeededMemory) ||
                a > static_cast<std::uint32_t>(Marker::AudioDrained) ||
                c != 0) {
                error = "invalid marker record";
                return false;
            }
            break;
        default:
            error = "unknown record type";
            return false;
        }
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
    if (stats.writes < 8 ||
        !std::all_of(stats.write_widths.begin(), stats.write_widths.end(),
            [](bool present) { return present; })) {
        error = "trace does not cover 8/16/32-bit ARM7 sound writes";
        return false;
    }
    if (stats.advances < 6 || !stats.timing_cpus[0] ||
        !stats.timing_cpus[1] || !stats.saw_halted_stall ||
        !stats.saw_halted_progress) {
        std::ostringstream detail;
        detail << "trace does not cover dual-CPU shared time and HALT gating"
               << " advances=" << stats.advances
               << " arm9=" << stats.timing_cpus[0]
               << " arm7=" << stats.timing_cpus[1]
               << " halt_stall=" << stats.saw_halted_stall
               << " halt_progress=" << stats.saw_halted_progress;
        error = detail.str();
        return false;
    }
    if (stats.sample_reads < 8) {
        error = "trace does not cover SPU sample-memory reads";
        return false;
    }
    if (stats.audio_frames < 16 || !stats.saw_nonzero_audio ||
        !stats.saw_stereo_difference || !stats.saw_negative_audio ||
        !stats.saw_positive_audio) {
        error = "trace does not cover signed, nonzero asymmetric stereo";
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

    void set_sample_capture(bool enabled) { sample_capture_ = enabled; }

    std::uint32_t ARM7Read32(std::uint32_t address) override
    {
        const std::uint32_t aligned = address & ~3u;
        const std::uint32_t value = melonDS::NDS::ARM7Read32(address);
        if (sample_capture_ && aligned >= kSampleBase &&
            aligned < kSampleBase + kSampleBytes) {
            records_.push_back(Record {
                RecordType::SampleRead,
                2,
                shared_time(),
                aligned,
                value,
                sample_read_ordinal_++,
            });
        }
        return value;
    }

private:
    std::vector<Record> records_;
    std::uint32_t sample_read_ordinal_ = 0;
    bool sample_capture_ = false;
};

void add_marker(TraceNDS& nds, Marker marker, std::uint32_t detail = 0)
{
    nds.records().push_back(Record {
        RecordType::Marker,
        0,
        nds.shared_time(),
        static_cast<std::uint32_t>(marker),
        detail,
        0,
    });
}

void arm7_write(TraceNDS& nds, unsigned access,
    std::uint32_t address, std::uint32_t value)
{
    switch (access) {
    case 0:
        nds.ARM7Write8(address, static_cast<std::uint8_t>(value));
        value &= 0xffu;
        break;
    case 1:
        nds.ARM7Write16(address, static_cast<std::uint16_t>(value));
        value &= 0xffffu;
        break;
    case 2:
        nds.ARM7Write32(address, value);
        break;
    default:
        return;
    }
    nds.records().push_back(Record {
        RecordType::Arm7Write,
        static_cast<std::uint8_t>(access),
        nds.shared_time(),
        address,
        value,
        0,
    });
}

void advance_cpu(TraceNDS& nds, bool arm9, std::uint32_t cycles)
{
    const bool arm9_halt_before = nds.ARM9.Halted != 0;
    const bool arm7_halt_before = nds.ARM7.Halted != 0;
    const std::uint64_t before = nds.shared_time();
    const std::uint64_t after = nds.AdvanceExternalCPU(arm9 ? 0u : 1u, cycles);
    const bool arm9_halt_after = nds.ARM9.Halted != 0;
    const bool arm7_halt_after = nds.ARM7.Halted != 0;
    const std::uint64_t cpu_time = arm9
        ? (nds.ARM9Timestamp >> nds.ARM9ClockShift)
        : nds.ARM7Timestamp;
    nds.records().push_back(Record {
        RecordType::TimeAdvance,
        static_cast<std::uint8_t>((arm9 ? 0u : 1u) |
            (arm9_halt_before ? 0x02u : 0u) |
            (arm9_halt_after ? 0x04u : 0u) |
            (arm7_halt_before ? 0x08u : 0u) |
            (arm7_halt_after ? 0x10u : 0u)),
        after,
        cycles,
        static_cast<std::uint32_t>(before),
        static_cast<std::uint32_t>(cpu_time),
    });
}

std::vector<std::uint8_t> generate_trace(std::string& error)
{
    melonDS::NDSArgs args;
    args.JIT = std::nullopt;
    args.BitDepth = melonDS::AudioBitDepth::_16Bit;
    args.Interpolation = melonDS::AudioInterpolation::None;
    args.OutputSampleRate = 32768.0;

    auto nds_storage = std::make_unique<TraceNDS>(std::move(args));
    TraceNDS& nds = *nds_storage;
    nds.Reset();
    nds.Start();

    // Alternating signed PCM8 values, deliberately asymmetric when panned.
    static constexpr std::array<std::uint8_t, kSampleBytes> samples {
        0x80, 0x90, 0xa0, 0xb0, 0xc0, 0xd0, 0xe0, 0xf0,
        0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70,
        0x7f, 0x68, 0x51, 0x3a, 0x23, 0x0c, 0xf5, 0xde,
        0xc7, 0xb0, 0x99, 0x82, 0x9a, 0xb2, 0xca, 0xe2,
        0xfa, 0x12, 0x2a, 0x42, 0x5a, 0x72, 0x6a, 0x52,
        0x3a, 0x22, 0x0a, 0xf2, 0xda, 0xc2, 0xaa, 0x92,
        0x88, 0xa8, 0xc8, 0xe8, 0x08, 0x28, 0x48, 0x68,
        0x78, 0x58, 0x38, 0x18, 0xf8, 0xd8, 0xb8, 0x98,
    };
    std::copy(samples.begin(), samples.end(), nds.MainRAM + 0x1000);
    add_marker(nds, Marker::SeededMemory,
        crc32(samples.data(), samples.size()));

    // Use the physical ARM7 bus path and all three supported access widths.
    arm7_write(nds, 1, 0x04000304, 0x0001);       // POWCNT2: SPU on
    arm7_write(nds, 1, 0x04000504, 0x0200);       // SOUNDBIAS
    arm7_write(nds, 0, 0x04000500, 0x007f);       // master volume
    arm7_write(nds, 0, 0x04000501, 0x0080);       // master enable
    arm7_write(nds, 2, 0x04000404, kSampleBase);  // SOUND0SAD
    arm7_write(nds, 1, 0x04000408, 0xf000);       // SOUND0TMR
    arm7_write(nds, 1, 0x0400040a, 0x0000);       // SOUND0PNT
    arm7_write(nds, 2, 0x0400040c, 0x00000008);  // 32-byte loop
    arm7_write(nds, 2, 0x04000400, 0x8820007f);  // PCM8, loop, pan 32
    add_marker(nds, Marker::ChannelStarted);
    nds.set_sample_capture(true);

    // Prove shared time is the minimum normalized CPU time.
    advance_cpu(nds, true, 4096);   // ARM9 alone: no shared progress.
    advance_cpu(nds, false, 2048);  // ARM7 catches shared time to 2048.

    arm7_write(nds, 0, 0x04000301, 0x80); // HALTCNT
    add_marker(nds, Marker::Arm7Halted);
    advance_cpu(nds, true, 8192);   // Halted ARM7 remains the shared floor.
    advance_cpu(nds, false, 8192);  // Wall-clock bucket advances while halted.

    // Keep both reported clocks moving in deterministic coarse buckets.
    for (unsigned bucket = 0; bucket < 8; ++bucket) {
        advance_cpu(nds, true, 8192);
        advance_cpu(nds, false, 8192);
    }

    nds.SPU.BufferAudio();
    std::array<std::int16_t, 512 * 2> stereo {};
    const int frames = nds.SPU.ReadOutput(stereo.data(), 512);
    if (frames <= 0) {
        error = "melonDS produced no audio frames";
        return {};
    }
    for (int index = 0; index < frames; ++index) {
        const auto left = static_cast<std::int32_t>(stereo[index * 2]);
        const auto right = static_cast<std::int32_t>(stereo[index * 2 + 1]);
        nds.records().push_back(Record {
            RecordType::AudioSample,
            0,
            nds.shared_time(),
            static_cast<std::uint32_t>(index),
            static_cast<std::uint32_t>(left),
            static_cast<std::uint32_t>(right),
        });
    }
    add_marker(nds, Marker::AudioDrained,
        static_cast<std::uint32_t>(frames));

    auto bytes = serialize(nds.records(), nds.shared_time());
    TraceStats stats;
    if (!parse_trace(bytes, stats, error) || !coverage_ok(stats, error))
        return {};
    return bytes;
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
    constexpr std::uint64_t max_file_bytes =
        kHeaderBytes + kMaxRecords * kRecordBytes;
    if (length < 0 ||
        static_cast<std::uint64_t>(length) >
            std::min<std::uint64_t>(
                std::numeric_limits<std::size_t>::max(), max_file_bytes)) {
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

void repair_payload_crc(std::vector<std::uint8_t>& bytes)
{
    const std::uint32_t crc =
        crc32(bytes.data() + kHeaderBytes, bytes.size() - kHeaderBytes);
    bytes[20] = static_cast<std::uint8_t>(crc);
    bytes[21] = static_cast<std::uint8_t>(crc >> 8);
    bytes[22] = static_cast<std::uint8_t>(crc >> 16);
    bytes[23] = static_cast<std::uint8_t>(crc >> 24);
}

bool malformed_self_test(const std::vector<std::uint8_t>& good,
    std::string& error)
{
    TraceStats stats;
    std::string rejected;
    if (!parse_trace(good, stats, rejected) || !coverage_ok(stats, rejected)) {
        error = "valid trace rejected during self-test: " + rejected;
        return false;
    }

    std::vector<std::pair<std::string, std::vector<std::uint8_t>>> cases;
    auto bad_magic = good;
    bad_magic[0] ^= 0x80;
    cases.emplace_back("bad magic", std::move(bad_magic));

    auto truncated = good;
    truncated.pop_back();
    cases.emplace_back("truncation", std::move(truncated));

    auto bad_crc = good;
    bad_crc.back() ^= 0x01;
    cases.emplace_back("CRC corruption", std::move(bad_crc));

    auto unknown_type = good;
    unknown_type[kHeaderBytes] = 0xff;
    repair_payload_crc(unknown_type);
    cases.emplace_back("unknown record type", std::move(unknown_type));

    auto nonzero_reserved = good;
    nonzero_reserved[kHeaderBytes + 2] = 1;
    repair_payload_crc(nonzero_reserved);
    cases.emplace_back("nonzero reserved field", std::move(nonzero_reserved));

    for (const auto& test_case : cases) {
        TraceStats ignored;
        std::string parse_error;
        if (parse_trace(test_case.second, ignored, parse_error)) {
            error = "malformed case accepted: " + test_case.first;
            return false;
        }
    }
    return true;
}

void print_stats(const TraceStats& stats)
{
    std::cout << "writes=" << stats.writes
              << " advances=" << stats.advances
              << " sample_reads=" << stats.sample_reads
              << " audio_frames=" << stats.audio_frames
              << " end_time=" << stats.end_time;
}

} // namespace

int main(int argc, char** argv)
{
    if (argc < 2 || argc > 3) {
        std::cerr << "usage: nds_sound_reference_trace "
                     "generate output | verify input | self-test\n";
        return 2;
    }

    const std::string command = argv[1];
    std::string error;
    if (command == "generate" && argc == 3) {
        auto bytes = generate_trace(error);
        if (bytes.empty() || !write_file(argv[2], bytes, error)) {
            std::cerr << "generate failed: " << error << "\n";
            return 1;
        }
        TraceStats stats;
        if (!parse_trace(bytes, stats, error)) {
            std::cerr << "internal verification failed: " << error << "\n";
            return 1;
        }
        std::cout << "PASS: generated canonical melonDS sound trace ";
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
        std::cout << "PASS: verified canonical melonDS sound trace ";
        print_stats(stats);
        std::cout << "\n";
        return 0;
    }

    if (command == "self-test" && argc == 2) {
        auto first = generate_trace(error);
        auto second = generate_trace(error);
        if (first.empty() || second.empty() || first != second) {
            if (error.empty()) error = "two generated traces differ";
            std::cerr << "self-test failed: " << error << "\n";
            return 1;
        }
        if (!malformed_self_test(first, error)) {
            std::cerr << "self-test failed: " << error << "\n";
            return 1;
        }
        TraceStats stats;
        if (!parse_trace(first, stats, error)) {
            std::cerr << "self-test failed: " << error << "\n";
            return 1;
        }
        std::cout << "PASS: deterministic generation and five malformed-input "
                     "rejections ";
        print_stats(stats);
        std::cout << "\n";
        return 0;
    }

    std::cerr << "invalid command or arguments\n";
    return 2;
}
