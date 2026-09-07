#include "GPU3D_Soft.h"

#include <array>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <fstream>
#include <vector>

using melonDS::u32;

static u32 referenceAntiAlias(u32 top, u32 bottom, u32 attr)
{
    if (!(attr & 0xFu)) return top;
    u32 coverage = (attr >> 8) & 0x1Fu;
    if (coverage == 0x1Fu) return top;
    if (coverage == 0) return bottom;

    u32 topR = top & 0x3Fu;
    u32 topG = (top >> 8) & 0x3Fu;
    u32 topB = (top >> 16) & 0x3Fu;
    u32 topA = (top >> 24) & 0x1Fu;
    const u32 botR = bottom & 0x3Fu;
    const u32 botG = (bottom >> 8) & 0x3Fu;
    const u32 botB = (bottom >> 16) & 0x3Fu;
    const u32 botA = (bottom >> 24) & 0x1Fu;

    ++coverage;
    if (botA > 0)
    {
        topR = ((topR * coverage) + (botR * (32 - coverage))) >> 5;
        topG = ((topG * coverage) + (botG * (32 - coverage))) >> 5;
        topB = ((topB * coverage) + (botB * (32 - coverage))) >> 5;
    }
    topA = ((topA * coverage) + (botA * (32 - coverage))) >> 5;
    return topR | (topG << 8) | (topB << 16) | (topA << 24);
}

extern "C" __attribute__((noinline)) bool
nds_test_antialias_block_has_edge(const u32* attributes)
{
    return melonDS::NDS4MiSTerAntiAliasBlockHasEdge(attributes);
}

extern "C" __attribute__((noinline)) u32
nds_test_apply_antialias_pixel(u32 top, u32 bottom, u32 attr)
{
    melonDS::NDS4MiSTerApplyAntiAliasPixel(&top, &bottom, attr);
    return top;
}

extern "C" __attribute__((noinline)) void
nds_test_apply_antialias_scanline(
    u32* top, const u32* bottom, const u32* attributes, int count)
{
    melonDS::NDS4MiSTerApplyAntiAliasScanline(
        top, bottom, attributes, count);
}

static bool verifyAntiAliasOnlyFixture(const char* path)
{
    std::ifstream input(path, std::ios::binary);
    if (!input) return false;

    std::array<std::uint8_t, 16> fileHeader {};
    input.read(reinterpret_cast<char*>(fileHeader.data()), fileHeader.size());
    if (!input) return false;

    const auto load16 = [](const std::uint8_t* bytes) {
        std::uint16_t value;
        std::memcpy(&value, bytes, sizeof(value));
        return value;
    };
    const auto load32 = [](const std::uint8_t* bytes) {
        std::uint32_t value;
        std::memcpy(&value, bytes, sizeof(value));
        return value;
    };
    const auto load64 = [](const std::uint8_t* bytes) {
        std::uint64_t value;
        std::memcpy(&value, bytes, sizeof(value));
        return value;
    };

    if (load32(fileHeader.data()) != 0x31534748u ||
        load16(fileHeader.data() + 4) != 1 ||
        load16(fileHeader.data() + 6) != fileHeader.size())
        return false;
    input.seekg(0, std::ios::end);
    const auto fileSize = input.tellg();
    if (fileSize < 0 ||
        load64(fileHeader.data() + 8) != static_cast<std::uint64_t>(fileSize))
        return false;
    input.seekg(fileHeader.size(), std::ios::beg);

    std::uint32_t dispCnt = 0;
    unsigned geometryFrames = 0;
    unsigned antiAliasOnlyFrames = 0;
    unsigned inactiveFrames = 0;
    unsigned polygonRecords = 0;
    unsigned antiAliasOnlyPolygonRecords = 0;
    unsigned dispCntWrites = 0;
    for (;;)
    {
        std::array<std::uint8_t, 4> recordHeader {};
        input.read(
            reinterpret_cast<char*>(recordHeader.data()),
            recordHeader.size());
        if (input.eof() && input.gcount() == 0) break;
        if (!input) return false;

        const auto type = load16(recordHeader.data());
        const auto size = load16(recordHeader.data() + 2);
        if (size < recordHeader.size() || size > 4096) return false;
        std::vector<std::uint8_t> payload(size - recordHeader.size());
        input.read(reinterpret_cast<char*>(payload.data()), payload.size());
        if (!input) return false;

        if (type == 4)
        {
            // Compact HGS geometry-register payload: frame, timestamp,
            // address, value, width, three reserved bytes.
            if (payload.size() != 24) return false;
            const auto address = load32(payload.data() + 12);
            if (address == 0x04000060u)
            {
                const auto width = payload[20];
                if (width != 2 && width != 4) return false;
                const auto value = load32(payload.data() + 16);
                dispCnt = (value & 0x4FFFu) | (dispCnt & 0x3000u);
                if (value & (1u << 12)) dispCnt &= ~(1u << 12);
                if (value & (1u << 13)) dispCnt &= ~(1u << 13);
                ++dispCntWrites;
            }
        }
        else if (type == 5)
        {
            // Compact HGS geometry-frame payload: frame, timestamp,
            // vertices, polygons, flush attributes.
            if (payload.size() != 24) return false;
            const auto frame = load32(payload.data());
            const auto polygons = load32(payload.data() + 16);
            if (frame != geometryFrames) return false;
            const auto finalPassClass = dispCnt & 0xB0u;
            if (geometryFrames < 16)
            {
                if (finalPassClass != 0) return false;
                ++inactiveFrames;
            }
            else
            {
                if (finalPassClass != 0x10u) return false;
                ++antiAliasOnlyFrames;
            }
            if (polygons != 0)
            {
                ++polygonRecords;
                if (finalPassClass == 0x10u)
                    ++antiAliasOnlyPolygonRecords;
            }
            ++geometryFrames;
        }
    }

    if (geometryFrames != 600 || antiAliasOnlyFrames != 584 ||
        inactiveFrames != 16 || polygonRecords != 286 ||
        antiAliasOnlyPolygonRecords != polygonRecords ||
        dispCntWrites != 1207)
        return false;

    std::printf(
        "H3D_FINAL_PASS_AA_FIXTURE_ORACLE_PASS frames=%u "
        "aa_only_frames=%u inactive_frames=%u polygon_records=%u "
        "dispcnt_writes=%u\n",
        geometryFrames, antiAliasOnlyFrames, inactiveFrames,
        polygonRecords, dispCntWrites);
    return true;
}

int main(int argc, char** argv)
{
    if (argc > 2) return 6;
    std::uint64_t pixelComparisons = 0;
    std::uint64_t blockComparisons = 0;
    u32 randomState = 0x5a17c9e3u;
    const auto randomWord = [&randomState]() {
        randomState ^= randomState << 13;
        randomState ^= randomState >> 17;
        randomState ^= randomState << 5;
        return randomState;
    };

    constexpr u32 channelValues[] {0, 1, 31, 32, 62, 63};
    for (u32 coverage = 0; coverage < 32; ++coverage)
    for (u32 edgeFlags = 0; edgeFlags < 16; ++edgeFlags)
    for (u32 topR : channelValues)
    for (u32 topA = 0; topA < 32; ++topA)
    for (u32 botB : channelValues)
    for (u32 botA = 0; botA < 32; ++botA)
    {
        const u32 top = topR | (((topR + 17) & 63) << 8) |
            (((topR + 41) & 63) << 16) | (topA << 24);
        const u32 bottom = ((botB + 29) & 63) |
            (((botB + 7) & 63) << 8) | (botB << 16) | (botA << 24);
        const u32 attr = edgeFlags | (coverage << 8) |
            (randomWord() & 0xffffc0f0u);
        ++pixelComparisons;
        if (nds_test_apply_antialias_pixel(top, bottom, attr) !=
            referenceAntiAlias(top, bottom, attr))
            return 1;
    }

    for (unsigned iteration = 0; iteration < 1000000; ++iteration)
    {
        const u32 top = randomWord() & 0x1f3f3f3fu;
        const u32 bottom = randomWord() & 0x1f3f3f3fu;
        const u32 attr = randomWord();
        ++pixelComparisons;
        if (nds_test_apply_antialias_pixel(top, bottom, attr) !=
            referenceAntiAlias(top, bottom, attr))
            return 2;
    }

    std::array<u32, 4> attributes {};
    for (u32 flags = 0; flags < 65536; ++flags)
    {
        for (unsigned lane = 0; lane < attributes.size(); ++lane)
            attributes[lane] = ((flags >> (lane * 4)) & 0xfu) |
                (randomWord() & 0xfffffff0u);
        const bool expected = (flags & 0xffffu) != 0;
        ++blockComparisons;
        if (nds_test_antialias_block_has_edge(attributes.data()) != expected)
            return 3;
    }

    for (u32 dispCnt = 0; dispCnt < 65536; ++dispCnt)
    {
        const bool expected = (dispCnt & 0xb0u) == 0x10u;
        if (melonDS::NDS4MiSTerUseAntiAliasOnlyFinalPass(dispCnt) !=
            expected)
            return 4;
    }

    std::array<u32, 260> referenceTop {};
    std::array<u32, 260> candidateTop {};
    std::array<u32, 260> bottom {};
    std::array<u32, 260> scanlineAttributes {};
    std::uint64_t scanlineComparisons = 0;
    for (int offset = 0; offset < 4; ++offset)
    for (int count = 0; count <= 256; ++count)
    for (int pattern = 0; pattern < 8; ++pattern)
    {
        referenceTop.fill(0x1D2A1723u);
        candidateTop.fill(0x1D2A1723u);
        for (int lane = 0; lane < count; ++lane)
        {
            const int index = offset + lane;
            referenceTop[index] = randomWord() & 0x1f3f3f3fu;
            candidateTop[index] = referenceTop[index];
            bottom[index] = randomWord() & 0x1f3f3f3fu;
            u32 attr = randomWord();
            if (pattern == 0)
                attr &= ~0xFu;
            else if (pattern == 1)
                attr = (attr & ~0x1F0Fu) | 0x1F01u;
            else if (pattern == 2)
                attr = (attr & ~0x1F0Fu) | 0x0001u;
            else if (pattern == 3 && (lane & 15) != 0)
                attr &= ~0xFu;
            scanlineAttributes[index] = attr;
            referenceTop[index] = referenceAntiAlias(
                referenceTop[index], bottom[index], attr);
        }
        nds_test_apply_antialias_scanline(
            candidateTop.data() + offset,
            bottom.data() + offset,
            scanlineAttributes.data() + offset, count);
        for (std::size_t lane = 0; lane < candidateTop.size(); ++lane)
        {
            ++scanlineComparisons;
            if (candidateTop[lane] != referenceTop[lane])
                return 5;
        }
    }

    std::printf(
        "PASS: final-pass antialias pixel=%llu block=%llu "
        "scanline=%llu dispatch=65536\n",
        static_cast<unsigned long long>(pixelComparisons),
        static_cast<unsigned long long>(blockComparisons),
        static_cast<unsigned long long>(scanlineComparisons));
    if (argc == 2 && !verifyAntiAliasOnlyFixture(argv[1])) return 6;
    return 0;
}
