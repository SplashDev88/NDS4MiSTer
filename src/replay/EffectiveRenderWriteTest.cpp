// Standalone audit of the real private service write boundary. Reuse the
// accepted Engine B renderer fixture; no ROM or physical mappings are used.
#define main nds_hybrid_service_program_main
#include "Hybrid3DService.cpp"
#undef main
#include <ctime>
#define main nds_engine_b_cache_program_main
#include "EngineBLineCacheTest.cpp"
#undef main

namespace {
struct EffectiveRenderWriteTest {
    inline static bool paired_mode = false;
    static std::uint64_t cpu_ns()
    {
        timespec ts {};
        if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts))
            throw std::runtime_error("thread CPU clock unavailable");
        return std::uint64_t(ts.tv_sec) * 1000000000ull + ts.tv_nsec;
    }
    static unsigned count(const char* name, unsigned fallback)
    {
        const auto* value = std::getenv(name);
        if (!value) return fallback;
        const auto parsed = std::strtoul(value, nullptr, 10);
        if (!parsed || parsed > 10000000) throw std::runtime_error("invalid benchmark count");
        return parsed;
    }
    static std::uint64_t digest(const void* source, unsigned bytes)
    {
        auto* data = static_cast<const unsigned char*>(source);
        std::uint64_t hash = 14695981039346656037ull;
        for (unsigned i = 0; i < bytes; ++i) hash = (hash ^ data[i]) * 1099511628211ull;
        return hash;
    }
    struct Case {
        Fixture memory {0x12345678, true};
        std::unique_ptr<Hybrid3DService> service;
        explicit Case(bool cache) : service(std::make_unique<Hybrid3DService>(
            memory.bytes.data(), memory.bytes.size(), std::string {},
            false, false, false, false, false, false, nullptr, nullptr,
            false, false, true))
        {
            if (!service->initialize()) self_test_fail("effective-write init");
            service->nds_ = fixture(cache, paired_mode);
        }
        melonDS::NDS& nds() { return *service->nds_; }
    };
    static frame_packet::Record record(unsigned address, unsigned bytes, unsigned value)
    {
        const auto kind = (address >> 24) == 5 ?
            nds4mister::arm_video::RecordKind::PaletteWrite :
            nds4mister::arm_video::RecordKind::OamWrite;
        const unsigned lane = address & 3;
        return nds4mister::arm_video::make_record(kind,
            bytes == 1 ? 0 : bytes == 2 ? 1 : 2,
            ((1u << bytes) - 1) << lane, address, value << (lane * 8));
    }
    static void write(Case& c, unsigned address, unsigned bytes, unsigned value)
    {
        const auto r = record(address, bytes, value);
        if (!nds4mister::arm_video::validate_record(r) ||
            !c.service->apply_arm_video_write(r))
            self_test_fail("effective-write record rejected");
    }
    static unsigned read(Case& c, unsigned address, unsigned bytes)
    {
        const auto* memory = (address >> 24) == 5 ? c.nds().GPU.Palette : c.nds().GPU.OAM;
        unsigned value = 0;
        std::memcpy(&value, memory + (address & 0x7ff), bytes);
        return value;
    }
    static void normal_write(melonDS::NDS& nds, unsigned address, unsigned bytes, unsigned value)
    {
        if (bytes == 1) nds.ARM9Write8(address, value);
        else if (bytes == 2) nds.ARM9Write16(address, value);
        else nds.ARM9Write32(address, value);
    }
    static int run(bool benchmark, bool paired)
    {
        paired_mode = paired;
        if (benchmark) {
            const unsigned iterations = count("NDS_EFFECTIVE_WRITE_CALLS", 400000);
            const unsigned frames = count("NDS_EFFECTIVE_RENDER_FRAMES", 240);
            for (unsigned region : {5u, 7u})
                for (bool changed : {false, true}) {
                    Case c(true);
                    const unsigned address = (region << 24) | 0x422;
                    const auto started = cpu_ns();
                    for (unsigned i = 0; i < iterations; ++i)
                        write(c, address, 2, changed ? (i & 1) : 0);
                    const auto ns = cpu_ns() - started;
                    std::cout << "EFFECTIVE_WRITE_BENCH region=" << region
                        << " changed=" << changed << " count=" << iterations
                        << " thread_ns=" << ns << " revision=" << c.nds().GPU.ExternalRenderMemorySequence
                        << " palette_hash=" << std::hex << digest(c.nds().GPU.Palette, 2048)
                        << " oam_hash=" << digest(c.nds().GPU.OAM, 2048) << std::dec << '\n';
                }
            for (unsigned scene : {0u,1u,2u,3u}) {
                Case c(true);
                const auto started = cpu_ns();
                unsigned hits = 0;
                for (unsigned f = 0; f < frames; ++f)
                    for (unsigned y = 0; y < 263; ++y) {
                        phase(c.nds(), f, y, y == 0 ? 2 : 0);
                        if (y < 192) {
                            write(c, 0x05000422, 2, scene == 1 ? (f & 1) :
                                scene == 2 ? ((f + y) & 1) : 0);
                            write(c, 0x07000402, 2, 0x4011 +
                                (scene == 3 ? (f & 7) : scene == 2 ? (y & 7) : 0));
                        }
                        phase(c.nds(), f, y, 1);
                        bool a = false, b = false;
                        c.nds().GPU.GetRenderer().GetExternalLineCacheResult(a, b);
                        if (y < 192) hits += b;
                    }
                const auto ns = cpu_ns() - started;
                std::array<std::uint32_t, PlanePixels> final_pixels {};
                for (unsigned y = 0; y < 192; ++y)
                    std::memcpy(final_pixels.data() + y * 256, pixels(c.nds(), y), 1024);
                std::cout << "EFFECTIVE_RENDER_BENCH scene=" << scene
                    << " frames=" << frames << " thread_ns=" << ns << " hits=" << hits
                    << " final_frame_hash=" << std::hex << digest(final_pixels.data(), sizeof(final_pixels))
                    << std::dec << '\n';
            }
            return 0;
        }
        unsigned writer_cases = 0, redundant_marks = 0, changed_marks_missing = 0;
        {
            Case c(true);
            auto ordinary = fixture(false);
            for (unsigned region : {5u, 7u})
                for (unsigned offset : {0u,1u,2u,3u,0x1fcu,0x1feu,0x1ffu,
                     0x3fcu,0x3feu,0x3ffu,0x400u,0x401u,0x402u,0x403u,
                     0x5fcu,0x5feu,0x5ffu,0x7fcu,0x7feu,0x7ffu})
                    for (unsigned bytes : {1u,2u,4u}) {
                        if (offset & (bytes - 1)) continue;
                        for (bool power : {false, true}) {
                            c.nds().ARM9Write16(0x04000304, power ? 0x020f : 0);
                            ordinary->ARM9Write16(0x04000304, power ? 0x020f : 0);
                            for (unsigned repeat = 0; repeat < 2; ++repeat) {
                                const unsigned address = (region << 24) | offset;
                                const auto before = read(c, address & ~3u, 4);
                                const auto revision = c.nds().GPU.ExternalRenderMemorySequence;
                                std::array<melonDS::u64, 8> old_pages {};
                                std::memcpy(old_pages.data(), c.nds().GPU.ExternalRenderPaletteRevision, 32);
                                std::memcpy(old_pages.data() + 4, c.nds().GPU.ExternalRenderOAMRevision, 32);
                                write(c, address, bytes, 0xa5c37b19);
                                normal_write(*ordinary, address, bytes, 0xa5c37b19);
                                const bool changed = read(c, address & ~3u, 4) != before;
                                const bool marked = c.nds().GPU.ExternalRenderMemorySequence != revision;
                                redundant_marks += !changed && marked;
                                changed_marks_missing += changed && !marked;
                                if (changed) {
                                    std::array<melonDS::u64, 8> new_pages {};
                                    std::memcpy(new_pages.data(), c.nds().GPU.ExternalRenderPaletteRevision, 32);
                                    std::memcpy(new_pages.data() + 4, c.nds().GPU.ExternalRenderOAMRevision, 32);
                                    const unsigned page = (region == 5 ? 0 : 4) + offset / 512;
                                    for (unsigned i = 0; i < 8; ++i)
                                        if ((i == page) != (new_pages[i] != old_pages[i]))
                                            self_test_fail("changed write marked the wrong page");
                                }
                                if (std::memcmp(c.nds().GPU.Palette, ordinary->GPU.Palette, 0x800) ||
                                    std::memcmp(c.nds().GPU.OAM, ordinary->GPU.OAM, 0x800) ||
                                    c.nds().GPU.PaletteDirty != ordinary->GPU.PaletteDirty ||
                                    c.nds().GPU.OAMDirty != ordinary->GPU.OAMDirty)
                                    self_test_fail("normal write bytes/dirty side effects changed");
                                ++writer_cases;
                            }
                        }
                    }
            for (unsigned region : {5u, 7u}) {
                for (unsigned offset : {0x800u,0xfffu,0x1000u,0x100000u})
                    if (nds4mister::arm_video::validate_record(record((region << 24) | offset, 1, 0)))
                        self_test_fail("mirror escaped compact address validation");
                if (nds4mister::arm_video::validate_record(record((region << 24) | 0x401, 2, 0)))
                    self_test_fail("unaligned halfword escaped validation");
            }
        }
        std::cout << "EFFECTIVE_WRITER_RESULT cases=" << writer_cases
            << " redundant_marks=" << redundant_marks
            << " changed_marks_missing=" << changed_marks_missing << '\n';
        unsigned hits = 0, misses = 0, negative_differences = 0;
        std::uint64_t output_hash = 14695981039346656037ull;
        {
            Case oracle(false), candidate(true);
            for (unsigned f = 0; f < 72; ++f)
                for (unsigned y = 0; y < 263; ++y) {
                    for (auto* c : {&oracle, &candidate}) {
                        if (f == 42 && y == 0) c->nds().GPU.GetRenderer().Reset();
                        if (f == 43 && y == 20) {
                            c->nds().GPU.GetRenderer().PreSavestate();
                            c->nds().GPU.GetRenderer().PostSavestate();
                        }
                        phase(c->nds(), f, y, y == 0 ? 2 : 0);
                        if (y < 192) {
                            write(*c, 0x05000422, 2, read(*c, 0x05000422, 2));
                            write(*c, 0x07000402, 2, read(*c, 0x07000402, 2));
                            if (f == 3 && y == 50) write(*c, 0x05000422, 2, 0x7c1f);
                            if (f == 6 && y == 20) write(*c, 0x07000402, 2, 0x4030);
                            if (f == 9 && y == 70) write(*c, 0x05000423, 1, 0xff);
                            if (f == 12 && y == 80) {
                                c->nds().ARM9Write16(0x04000304, 0);
                                write(*c, 0x07000402, 2, 0x4060);
                                c->nds().ARM9Write16(0x04000304, 0x020f);
                            }
                            if (y == 20) {
                                auto& gpu = c->nds().GPU;
                                if (f == 9) {
                                    c->nds().ARM9Write32(0x06600004, 0x10203040);
                                    gpu.MarkExternalRenderVRAM(3);
                                }
                                if (f == 12 || f == 15) {
                                    gpu.MapVRAM_CD(3, f == 12 ? 0x80 : 0x84);
                                    gpu.MarkExternalRenderVRAM(3);
                                }
                                if (f == 18) {
                                    write(*c, 0x07000400, 2, 0x3014);
                                    c->nds().ARM9Write16(0x0400104c, 0x3300);
                                }
                                if (f == 21) {
                                    write(*c, 0x07000400, 2, 0x2814);
                                    c->nds().ARM9Write32(0x04001000, 0x00019110);
                                    c->nds().ARM9Write16(0x0400104a, 0x3f00);
                                }
                                if (f == 24) {
                                    write(*c, 0x07000400, 2, 0x3014);
                                    write(*c, 0x07000402, 2, 0x5030);
                                    c->nds().ARM9Write16(0x0400104c, 0x1200);
                                }
                                if (f == 27) {
                                    write(*c, 0x07000400, 2, 0x2114);
                                    write(*c, 0x07000402, 2, 0x4030);
                                    write(*c, 0x07000406, 2, 0x100);
                                    write(*c, 0x0700040e, 2, 0);
                                    write(*c, 0x07000416, 2, 0);
                                    write(*c, 0x0700041e, 2, 0x100);
                                }
                                if (f == 30) c->nds().ARM9Write16(0x04000304, 0);
                                if (f == 31) c->nds().ARM9Write16(0x04000304, 0x020f);
                            }
                            if (y == 0 && (f == 36 || f == 38)) {
                                c->nds().GPU.CaptureEnable = f == 36;
                                c->nds().GPU.CaptureCnt = f == 36 ? 0x80000000u : 0;
                            }
                        }
                        // Retain the accepted cache oracle's broader midline
                        // register, mapping, affine, window and blend scenarios.
                        edit(c->nds(), f, y);
                        phase(c->nds(), f, y, 1);
                    }
                    if (y >= 192) continue;
                    if (std::memcmp(pixels(oracle.nds(), y), pixels(candidate.nds(), y), 1024)) {
                        bool a = false, b = false;
                        candidate.nds().GPU.GetRenderer().GetExternalLineCacheResult(a, b);
                        std::cerr << "EFFECTIVE_RENDER_MISMATCH frame=" << f << " line=" << y
                            << " reused=" << b << '\n';
                        self_test_fail("rendered line differs from always-render oracle");
                    }
                    for (unsigned x = 0; x < 256; ++x)
                        output_hash = (output_hash ^ pixels(oracle.nds(), y)[x]) * 1099511628211ull;
                    bool a = false, b = false;
                    candidate.nds().GPU.GetRenderer().GetExternalLineCacheResult(a, b);
                    if (b) ++hits; else ++misses;
                }
        }
        // A deliberately missing changed-palette revision must corrupt the
        // warmed actual line cache, proving the oracle detects this failure.
        {
            Case oracle(false), broken(true);
            for (unsigned f = 0; f < 4; ++f)
                for (unsigned y = 0; y < 263; ++y) {
                    for (auto* c : {&oracle, &broken}) {
                        phase(c->nds(), f, y, y == 0 ? 2 : 0);
                        if (f == 2 && y == 50) {
                            auto& gpu = c->nds().GPU;
                            const auto old = gpu.ExternalRenderPaletteRevision[2];
                            write(*c, 0x05000422, 2, 0x7c1f);
                            if (c == &broken) gpu.ExternalRenderPaletteRevision[2] = old;
                        }
                        phase(c->nds(), f, y, 1);
                    }
                    if (y < 192)
                        negative_differences += std::memcmp(pixels(oracle.nds(), y), pixels(broken.nds(), y), 1024) != 0;
                }
        }
        std::cout << "EFFECTIVE_WRITE_RESULT cases=" << writer_cases
            << " paired=" << paired_mode
            << " redundant_marks=" << redundant_marks << " changed_marks_missing=" << changed_marks_missing
            << " pixels=" << 72*192*256 << " hits=" << hits << " misses=" << misses
            << " negative_different_lines=" << negative_differences
            << " hash=" << std::hex << output_hash << std::dec << '\n';
        if (redundant_marks || changed_marks_missing || hits < 1000 || negative_differences == 0)
            self_test_fail("effective revision/cache-work contract failed");
        std::cout << "EFFECTIVE_WRITE_TEST_PASS\n";
        return 0;
    }
};
}

int main(int argc, char** argv)
try {
    bool benchmark = false, paired = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--benchmark") == 0) benchmark = true;
        else if (std::strcmp(argv[i], "--paired") == 0) paired = true;
        else throw std::runtime_error("unknown test option");
    }
    return EffectiveRenderWriteTest::run(benchmark, paired);
}
catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
