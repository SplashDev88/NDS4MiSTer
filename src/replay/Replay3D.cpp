#include "Args.h"
#include "GPU.h"
#include "NDS.h"
#include "NDS4MiSTer_2DTrace.h"
#include "melonds/MelonDsBackend.h"
#include "replay/HpsGpuRing.h"
#include "replay/LiveHgsEncoder.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <thread>
#include <vector>

using namespace melonDS;
using namespace melonDS::NDS4MiSTer;

namespace {
struct Oracle { u32 frame = ~0u; std::array<u32, 256 * 192> pixels{}; std::array<bool, 192> lines{}; };

struct ConservativeLineCacheKey {
    Trace2DScanlinePacket scanline{};
    Trace2DInternal2DLatchPacket latch{};
    Trace2DExtendedPaletteMapPacket extended_palette{};
    u64 memory_revision = 0;
};

struct MemoryRevisions {
    u64 sequence = 0;
    std::array<u64, 13> region{};
    std::array<u64, 4> palette_page{};
    std::array<u64, 4> oam_page{};

    void update(u8 region_index, u32 offset, std::size_t bytes) {
        if (region_index >= region.size()) return;
        const u64 revision = ++sequence;
        region[region_index] = revision;
        if (region_index != 0 && region_index != 1) return;
        auto& pages = region_index == 0 ? palette_page : oam_page;
        const u32 first = offset / 512;
        const u32 last = static_cast<u32>((offset + bytes - 1) / 512);
        for (u32 page = first; page <= last && page < pages.size(); ++page)
            pages[page] = revision;
    }

    u64 for_engine(
        unsigned engine, const Trace2DScanlinePacket& scanline,
        const Trace2DExtendedPaletteMapPacket& extended_palette) const {
        u64 revision = 0;
        const unsigned first_page = engine * 2;
        for (unsigned page = first_page; page < first_page + 2; ++page) {
            revision = std::max(revision, palette_page[page]);
            revision = std::max(revision, oam_page[page]);
        }

        u32 bank_mask = 0;
        if (engine == 0) {
            for (u32 mapping : scanline.VRAMMapABG) bank_mask |= mapping;
            for (u32 mapping : scanline.VRAMMapAOBJ) bank_mask |= mapping;
            for (u32 mapping : extended_palette.ABG) bank_mask |= mapping;
            bank_mask |= extended_palette.AOBJ;
            revision = std::max(revision, region[11]);
        } else {
            for (u32 mapping : scanline.VRAMMapBBG) bank_mask |= mapping;
            for (u32 mapping : scanline.VRAMMapBOBJ) bank_mask |= mapping;
            for (u32 mapping : extended_palette.BBG) bank_mask |= mapping;
            bank_mask |= extended_palette.BOBJ;
            revision = std::max(revision, region[12]);
        }
        for (unsigned bank = 0; bank < 9; ++bank)
            if ((bank_mask & (1u << bank)) != 0)
                revision = std::max(revision, region[bank + 2]);
        return revision;
    }
};

ConservativeLineCacheKey make_cache_key(
    unsigned engine, const Trace2DScanlinePacket& scanline,
    const Trace2DInternal2DLatchPacket& latch,
    const Trace2DExtendedPaletteMapPacket& extended_palette,
    const MemoryRevisions& revisions) {
    ConservativeLineCacheKey key{};
    key.scanline = scanline;
    key.scanline.Frame = 0;
    key.scanline.OAMDirty = 0;
    key.scanline.PaletteDirty = 0;
    key.scanline.Engine[1 - engine] = {};
    if (engine == 0) {
        key.scanline.MasterBrightnessB = 0;
        std::memset(key.scanline.VRAMMapBBG, 0,
                    sizeof(key.scanline.VRAMMapBBG));
        std::memset(key.scanline.VRAMMapBOBJ, 0,
                    sizeof(key.scanline.VRAMMapBOBJ));
    } else {
        key.scanline.MasterBrightnessA = 0;
        std::memset(key.scanline.VRAMMapABG, 0,
                    sizeof(key.scanline.VRAMMapABG));
        std::memset(key.scanline.VRAMMapAOBJ, 0,
                    sizeof(key.scanline.VRAMMapAOBJ));
    }
    key.latch = latch;
    key.latch.Record = {};
    key.latch.Frame = 0;
    key.latch.Engine[1 - engine] = {};
    key.extended_palette = extended_palette;
    key.extended_palette.Record = {};
    key.extended_palette.Frame = 0;
    if (engine == 0) {
        std::memset(key.extended_palette.BBG, 0,
                    sizeof(key.extended_palette.BBG));
        key.extended_palette.BOBJ = 0;
    } else {
        std::memset(key.extended_palette.ABG, 0,
                    sizeof(key.extended_palette.ABG));
        key.extended_palette.AOBJ = 0;
    }
    key.memory_revision = revisions.for_engine(
        engine, scanline, extended_palette);
    return key;
}

bool read_exact(std::ifstream& in, void* data, std::size_t size) {
    return static_cast<bool>(in.read(static_cast<char*>(data), static_cast<std::streamsize>(size)));
}
u64 hash_bytes(const u8* data,std::size_t size) { u64 h=1469598103934665603ULL; for(std::size_t i=0;i<size;i++){h^=data[i];h*=1099511628211ULL;} return h; }
void hash_append(u64& hash, const void* data, std::size_t size) {
    const auto* bytes=static_cast<const u8*>(data);
    for(std::size_t i=0;i<size;++i){hash^=bytes[i];hash*=1099511628211ULL;}
}

void map_vram(GPU& gpu, const u8* cnt) {
    gpu.MapVRAM_AB(0, cnt[0]); gpu.MapVRAM_AB(1, cnt[1]);
    gpu.MapVRAM_CD(2, cnt[2]); gpu.MapVRAM_CD(3, cnt[3]);
    gpu.MapVRAM_E(4, cnt[4]); gpu.MapVRAM_FG(5, cnt[5]); gpu.MapVRAM_FG(6, cnt[6]);
    gpu.MapVRAM_H(7, cnt[7]); gpu.MapVRAM_I(8, cnt[8]);
}

void apply_delta(GPU& gpu, const Trace2DMemoryDeltaHeader& h, const std::vector<u8>& data) {
    if (h.Region == 0) { if (h.Offset + data.size() > 2048) throw std::runtime_error("palette delta out of bounds"); std::memcpy(gpu.Palette+h.Offset, data.data(), data.size()); return; }
    if (h.Region == 1) { if (h.Offset + data.size() > 2048) throw std::runtime_error("OAM delta out of bounds"); std::memcpy(gpu.OAM+h.Offset, data.data(), data.size()); return; }
    if (h.Region == 11) { if (h.Offset + data.size() > sizeof(gpu.VRAMFlat_AOBJ)) throw std::runtime_error("flat AOBJ delta out of bounds"); std::memcpy(gpu.VRAMFlat_AOBJ+h.Offset,data.data(),data.size()); return; }
    if (h.Region == 12) { if (h.Offset + data.size() > sizeof(gpu.VRAMFlat_BOBJ)) throw std::runtime_error("flat BOBJ delta out of bounds"); std::memcpy(gpu.VRAMFlat_BOBJ+h.Offset,data.data(),data.size()); return; }
    if (h.Region > 10) return;
    const u32 bank = h.Region - 2;
    if (h.Offset + data.size() > gpu.VRAMMask[bank] + 1) throw std::runtime_error("VRAM delta out of bounds");
    std::memcpy(gpu.VRAM[bank] + h.Offset, data.data(), data.size());
    constexpr u32 granularity = VRAMDirtyGranularity;
    gpu.VRAMDirty[bank].SetRange(h.Offset / granularity, static_cast<u32>(data.size()) / granularity);
}

void fill_engine(GPU2D& out, const Trace2DEngine& in) {
    out.DispCnt=in.DispCnt; out.LayerEnable=in.LayerEnable; out.OBJEnable=in.OBJEnable; out.ForcedBlank=in.ForcedBlank;
    std::memcpy(out.BGCnt,in.BGCnt,sizeof(in.BGCnt)); std::memcpy(out.BGXPos,in.BGXPos,sizeof(in.BGXPos));
    std::memcpy(out.BGYPos,in.BGYPos,sizeof(in.BGYPos)); std::memcpy(out.BGXRef,in.BGXRef,sizeof(in.BGXRef));
    std::memcpy(out.BGYRef,in.BGYRef,sizeof(in.BGYRef)); std::memcpy(out.BGRotA,in.BGRotA,sizeof(in.BGRotA));
    std::memcpy(out.BGRotB,in.BGRotB,sizeof(in.BGRotB)); std::memcpy(out.BGRotC,in.BGRotC,sizeof(in.BGRotC));
    std::memcpy(out.BGRotD,in.BGRotD,sizeof(in.BGRotD)); std::memcpy(out.Win0Coords,in.Win0Coords,sizeof(in.Win0Coords));
    std::memcpy(out.Win1Coords,in.Win1Coords,sizeof(in.Win1Coords)); std::memcpy(out.WinCnt,in.WinCnt,sizeof(in.WinCnt));
    out.Win0Active=in.Win0Active; out.Win1Active=in.Win1Active;
    std::memcpy(out.BGMosaicSize,in.BGMosaicSize,sizeof(in.BGMosaicSize)); std::memcpy(out.OBJMosaicSize,in.OBJMosaicSize,sizeof(in.OBJMosaicSize));
    out.BlendCnt=in.BlendCnt; out.BlendAlpha=in.BlendAlpha; out.EVA=in.EVA; out.EVB=in.EVB; out.EVY=in.EVY;
}

void apply_video_maps(GPU& gpu, const Trace2DScanlinePacket& p) {
    std::memcpy(gpu.VRAMMap_ABG,p.VRAMMapABG,sizeof(p.VRAMMapABG));
    std::memcpy(gpu.VRAMMap_AOBJ,p.VRAMMapAOBJ,sizeof(p.VRAMMapAOBJ));
    std::memcpy(gpu.VRAMMap_BBG,p.VRAMMapBBG,sizeof(p.VRAMMapBBG));
    std::memcpy(gpu.VRAMMap_BOBJ,p.VRAMMapBOBJ,sizeof(p.VRAMMapBOBJ));
}

void apply_latch(GPU2D& out, const Trace2DInternal2DEngine& in) {
    std::memcpy(out.BGXRefInternal,in.BGXRefInternal,sizeof(in.BGXRefInternal));
    std::memcpy(out.BGYRefInternal,in.BGYRefInternal,sizeof(in.BGYRefInternal));
    out.BGMosaicY=in.BGMosaicY; out.BGMosaicYMax=in.BGMosaicYMax; out.OBJMosaicY=in.OBJMosaicY;
    out.BGMosaicLatch=in.Flags&1; out.OBJMosaicLatch=in.Flags&2;
    out.BGMosaicLine=in.BGMosaicLine; out.OBJMosaicLine=in.OBJMosaicLine;
}

void dump_frame(GPU& gpu, u32 frame) {
    const char* requested = std::getenv("NDS_GPU_DUMP_FRAME");
    if (!requested || frame != static_cast<u32>(std::strtoul(requested,nullptr,10))) return;
    void *top=nullptr,*bottom=nullptr; if (!gpu.GetFramebuffers(&top,&bottom)) return;
    for (const auto& item : {std::pair<const char*,void*>("top",top), {"bottom",bottom}}) {
        std::ofstream out(std::string("native-frame-")+std::to_string(frame)+"-"+item.first+".ppm",std::ios::binary);
        out << "P6\n256 192\n255\n"; const u32* pixels=static_cast<const u32*>(item.second);
        for (u32 i=0;i<256*192;i++) { const char rgb[3]={char((pixels[i]>>16)&255),char((pixels[i]>>8)&255),char(pixels[i]&255)}; out.write(rgb,3); }
    }
}
}

int main(int argc, char** argv) {
    const bool ring_mode = argc == 3 && std::string(argv[1]) == "--ring";
    const bool live_mode = argc == 4 && std::string(argv[1]) == "--live-rom";
    if (argc != 2 && !ring_mode && !live_mode) { std::cerr << "usage: nds_gpu_replay [--ring] <trace|hgs> | --live-rom <rom> <frames>\n"; return 2; }
    try {
        std::ifstream in;
        Trace2DFileHeader file{};
        bool compact=live_mode;
        if (!live_mode) {
            in.open(argv[ring_mode ? 2 : 1],std::ios::binary);
            if (!read_exact(in, &file, sizeof(file))) throw std::runtime_error("bad input header");
            compact = file.Magic == 0x31534748; // HGS1
            if ((!compact && (file.Magic != Trace2DMagic || file.Version < 6)) || (compact && (file.Version < 1 || file.Version > 2)))
                throw std::runtime_error("not a supported trace or HGS file");
        }

        NDSArgs args; args.JIT = std::nullopt;
        auto nds = std::make_unique<NDS>(std::move(args), nullptr);
        if (live_mode) melonDS::NDS4MiSTer::Trace2DThreadSuppressed=true;
        const bool skip_2d = std::getenv("NDS_GPU_SKIP_2D") != nullptr;
        const bool skip_sprites = std::getenv("NDS_GPU_SKIP_SPRITES") != nullptr;
        const bool parallel_2d = std::getenv("NDS_GPU_PARALLEL_2D") != nullptr;
        const bool packed_output =
            std::getenv("NDS_GPU_PACKED_OUTPUT") != nullptr;
        const bool threaded_3d =
            std::getenv("NDS_GPU_THREADED_3D") != nullptr;
        const bool disable_engine_a =
            std::getenv("NDS_GPU_DISABLE_ENGINE_A") != nullptr;
        const bool disable_engine_b =
            std::getenv("NDS_GPU_DISABLE_ENGINE_B") != nullptr;
        const bool cache_analysis =
            std::getenv("NDS_GPU_CACHE_ANALYZE") != nullptr;
        const bool cache_apply =
            std::getenv("NDS_GPU_CACHE_APPLY") != nullptr;
        const bool cache_external_hint =
            std::getenv("NDS_GPU_CACHE_EXTERNAL_HINT") != nullptr;
        const char* cache_engine=std::getenv("NDS_GPU_CACHE_ENGINE");
        const bool cache_apply_a=cache_apply &&
            (!cache_engine || std::strcmp(cache_engine,"B")!=0);
        const bool cache_apply_b=cache_apply &&
            (!cache_engine || std::strcmp(cache_engine,"A")!=0);
        const bool cache_key_analysis = cache_external_hint ||
            std::getenv("NDS_GPU_CACHE_KEY_ANALYZE") != nullptr;
        const bool profile = std::getenv("NDS_GPU_PROFILE") != nullptr;
        const u32 max_frames = std::getenv("NDS_GPU_MAX_FRAMES")
            ? static_cast<u32>(std::strtoul(
                std::getenv("NDS_GPU_MAX_FRAMES"), nullptr, 10)) : 0;
        const char* output_dump_path=std::getenv("NDS_GPU_OUTPUT_DUMP");
        const u32 cache_debug_frame=std::getenv("NDS_GPU_CACHE_DEBUG_FRAME")
            ? static_cast<u32>(std::strtoul(
                std::getenv("NDS_GPU_CACHE_DEBUG_FRAME"),nullptr,10)) : ~0u;
        const u32 cache_debug_line=std::getenv("NDS_GPU_CACHE_DEBUG_LINE")
            ? static_cast<u32>(std::strtoul(
                std::getenv("NDS_GPU_CACHE_DEBUG_LINE"),nullptr,10)) : ~0u;
        std::ofstream output_dump;
        if(output_dump_path) {
            output_dump.open(output_dump_path,std::ios::binary);
            if(!output_dump) throw std::runtime_error("cannot open output dump");
        }
        const bool exact_geometry_timing =
            std::getenv("NDS_GPU_EXACT_GEOMETRY_TIMING") != nullptr;
        const bool batch_geometry = !exact_geometry_timing &&
            std::getenv("NDS_GPU_BATCH_GEOMETRY") != nullptr;
        const bool external_command_replay =
            std::getenv("NDS_GPU_EXTERNAL_COMMAND_REPLAY") != nullptr;
        const bool verify_geometry_output =
            std::getenv("NDS_GPU_GEOMETRY_OUTPUT_HASH") != nullptr;
        const bool analyze_geometry_delta =
            std::getenv("NDS_GPU_GEOMETRY_DELTA_ANALYZE") != nullptr;
        constexpr u32 GeometryRunBatch = 64;
        u64 sprite_profile_ns=0,scanline_profile_ns=0,scanline_profile_calls=0;
        std::array<std::array<std::array<u32,256>,192>,2> previous_lines{};
        std::array<std::array<bool,192>,2> previous_line_valid{};
        u64 cache_window_lines=0,cache_window_top_hits=0;
        u64 cache_window_bottom_hits=0,cache_total_lines=0;
        u64 cache_total_top_hits=0,cache_total_bottom_hits=0;
        u32 cache_window_frames=0;
        MemoryRevisions memory_revisions{};
        Trace2DInternal2DLatchPacket latest_latch{};
        Trace2DExtendedPaletteMapPacket latest_extended_palette{};
        std::array<std::array<ConservativeLineCacheKey,192>,2>
            previous_cache_keys{};
        std::array<std::array<bool,192>,2> previous_cache_key_valid{};
        std::array<std::array<std::array<u32,256>,192>,2>
            previous_engine_lines{};
        std::array<std::array<bool,192>,2> previous_engine_line_valid{};
        u64 cache_key_candidates=0,cache_key_true_hits=0;
        u64 cache_key_false_hits=0,cache_key_repeat_misses=0;
        std::array<u64,2> cache_key_engine_candidates{};
        std::array<u64,2> cache_key_engine_true_hits{};
        u64 cache_output_hash=1469598103934665603ULL;
        u64 geometry_output_hash=1469598103934665603ULL;
        std::array<std::array<u32, 256 * 192>, 2>
            previous_geometry_banks{};
        std::array<bool, 2> previous_geometry_bank_valid{};
        u64 geometry_delta_frames = 0;
        u64 geometry_delta_pixels = 0;
        u64 geometry_delta_same_pixels = 0;
        u64 geometry_delta_blocks = 0;
        u64 geometry_delta_same_blocks = 0;
        const auto replay_profile_start=std::chrono::steady_clock::now();
        auto replay_profile_checkpoint=replay_profile_start;
        nds->Reset();
        nds->GPU.GPU3D.SetEnabled(true, true);
        nds->GPU.GPU3D.SetExternalCommandReplay(external_command_replay);
        nds->GPU.GPU2D_A.Enabled = !disable_engine_a;
        nds->GPU.GPU2D_B.Enabled = !disable_engine_b;
        if (parallel_2d || packed_output || threaded_3d || profile) {
            melonDS::RendererSettings settings {
                1, threaded_3d, false, false,
                packed_output, parallel_2d, cache_apply, profile};
            nds->GPU.GetRenderer().SetRenderSettings(settings);
        }
        Oracle oracle;
        u64 compared = 0, mismatches = 0, rgb_mismatches = 0, actual_zero = 0, oracle_zero = 0;
        u64 scanout_3d_compared=0,scanout_3d_mismatches=0;
        u64 framebuffer_compared = 0, framebuffer_mismatches = 0;
        u64 target_top_mismatches=0,target_bottom_mismatches=0; u32 first_bad_frame=~0u;
        u64 framebuffer_top_mismatches=0,framebuffer_bottom_mismatches=0;
        u32 first_bad_line=~0u,first_bad_x=~0u,first_bad_actual=0,first_bad_expected=0;
        u32 rendered = 0, oracle_frames = 0, geometry_count_mismatches = 0;
        u64 obj_hash_records=0,obj_line_hash_mismatches=0,obj_window_hash_mismatches=0;
        u64 obj_a_line_hash_mismatches=0,obj_b_line_hash_mismatches=0;
        u64 obj_input_records=0,oam_a_hash_mismatches=0,flat_aobj_hash_mismatches=0;
        u32 first_bad_obj_frame=~0u,first_bad_obj_line=~0u;
        u64 replay_clock = 0;
        u32 pending_geometry_commands = 0;
        u32 max_gx_fifo_level = 0;
        u32 max_gx_pipe_level = 0;
        u32 max_gx_stall_queue_level = 0;
        u64 gx_commands_replayed = 0;
        u64 gx_register_writes_replayed = 0;
        u64 gx_frame_records_replayed = 0;
        u64 gx_stall_transitions = 0;
        bool gx_was_stalled = false;
        auto sample_gx_state = [&] {
            max_gx_fifo_level =
                std::max(max_gx_fifo_level, nds->GPU.GPU3D.CmdFIFO.Level());
            max_gx_pipe_level =
                std::max(max_gx_pipe_level, nds->GPU.GPU3D.CmdPIPE.Level());
            max_gx_stall_queue_level = std::max(
                max_gx_stall_queue_level,
                nds->GPU.GPU3D.CmdStallQueue.Level());
            const bool stalled =
                (nds->CPUStop & CPUStop_GXStall) != 0;
            if (stalled && !gx_was_stalled)
                ++gx_stall_transitions;
            gx_was_stalled = stalled;
        };

        nds4mister::HpsGpuRingControl ring_control;
        ring_control.capacity = 1u << 20;
        std::vector<std::byte> ring_storage(ring_control.capacity);
        nds4mister::HpsGpuRing ring(ring_control, ring_storage.data());
        std::atomic<bool> producer_done{false};
        std::thread producer;
        std::string producer_error;
        if (live_mode) producer = std::thread([&] {
            nds4mister::MelonDsBackend backend;
            if (!backend.load_rom(argv[2],producer_error)) { producer_done.store(true,std::memory_order_release); return; }
            nds4mister::LiveHgsEncoder encoder(ring);
            backend.set_2d_trace_sink([](const void* data,std::size_t size,void* userdata) {
                static_cast<nds4mister::LiveHgsEncoder*>(userdata)->feed(data,size);
            },&encoder);
            const u32 frames=static_cast<u32>(std::strtoul(argv[3],nullptr,10));
            nds4mister::FrameTimings timings{};
            for (u32 frame=0;frame<frames;frame++) if (!backend.run_frame(timings,producer_error)) break;
            backend.set_2d_trace_sink(nullptr,nullptr);
            if (!encoder.finish() && producer_error.empty()) producer_error="live HGS encoder ended with a partial record";
            producer_done.store(true,std::memory_order_release);
        });
        else if (ring_mode) producer = std::thread([&] {
            Trace2DRecordHeader h{};
            while (read_exact(in, &h, sizeof(h))) {
                if (h.Size < sizeof(h) || h.Size > 4096) break;
                std::vector<u8> p(h.Size - sizeof(h));
                if (!read_exact(in, p.data(), p.size())) break;
                while (!ring.push(h.Type, p.data(), static_cast<u16>(p.size())))
                    std::this_thread::sleep_for(std::chrono::microseconds(50));
            }
            producer_done.store(true, std::memory_order_release);
        });

        Trace2DRecordHeader record{};
        for (;;) {
            std::vector<u8> payload;
            if (ring_mode || live_mode) {
                std::array<u8, 4092> buffer{}; u16 type=0, size=0;
                while (!ring.pop(type, buffer.data(), buffer.size(), size)) {
                    if (producer_done.load(std::memory_order_acquire)) break;
                    if (live_mode) std::this_thread::sleep_for(std::chrono::microseconds(50));
                    else std::this_thread::yield();
                }
                if (!size && producer_done.load(std::memory_order_acquire)) break;
                record = {type, static_cast<u16>(size + sizeof(record))};
                payload.assign(buffer.begin(), buffer.begin() + size);
            } else {
                if (!read_exact(in, &record, sizeof(record))) break;
                if (record.Size < sizeof(record) || record.Size > 4096) throw std::runtime_error("bad record size");
                payload.resize(record.Size - sizeof(record));
                if (!read_exact(in, payload.data(), payload.size())) throw std::runtime_error("truncated record");
            }
            if (record.Size < sizeof(record)) throw std::runtime_error("bad record size");
            if (record.Size > 4096) throw std::runtime_error("oversized record");
            const auto type = static_cast<Trace2DRecordType>(record.Type);
            const bool geometry_command_record =
                (!compact && type == Trace2DRecordType::GeometryCommand) ||
                (compact && record.Type == 3);
            if (batch_geometry && pending_geometry_commands != 0 &&
                !geometry_command_record) {
                nds->GPU.GPU3D.Run();
                pending_geometry_commands = 0;
            }
            if ((!compact && type == Trace2DRecordType::MemoryDelta) || (compact && (record.Type == 1 || record.Type == 6))) {
                if (payload.size() < sizeof(Trace2DMemoryDeltaHeader) - sizeof(record)) throw std::runtime_error("bad VRAM delta");
                Trace2DMemoryDeltaHeader h{}; h.Record = record;
                std::memcpy(reinterpret_cast<u8*>(&h) + sizeof(record), payload.data(), sizeof(h) - sizeof(record));
                std::vector<u8> bytes(payload.begin() + static_cast<std::ptrdiff_t>(sizeof(h) - sizeof(record)), payload.end());
                apply_delta(nds->GPU, h, bytes);
                memory_revisions.update(h.Region, h.Offset, bytes.size());
                if (h.Region == 0)
                    nds->GPU.MarkExternalRenderPalette(
                        h.Offset, static_cast<u32>(bytes.size()));
                else if (h.Region == 1)
                    nds->GPU.MarkExternalRenderOAM(
                        h.Offset, static_cast<u32>(bytes.size()));
                else if (h.Region >= 2 && h.Region <= 10)
                    nds->GPU.MarkExternalRenderVRAM(h.Region - 2);
            } else if (!compact && type == Trace2DRecordType::Scanline) {
                if (payload.size() != sizeof(Trace2DScanlinePacket)) throw std::runtime_error("bad scanline");
                const auto* p = reinterpret_cast<const Trace2DScanlinePacket*>(payload.data());
                map_vram(nds->GPU, p->VRAMCNT);
                apply_video_maps(nds->GPU,*p);
                nds->GPU.ScreensEnabled=p->ScreensEnabled; nds->GPU.ScreenSwap=p->ScreenSwap; nds->GPU.VCount=p->VCount;
                nds->GPU.MasterBrightnessA=p->MasterBrightnessA; nds->GPU.MasterBrightnessB=p->MasterBrightnessB;
                fill_engine(nds->GPU.GPU2D_A,p->Engine[0]); fill_engine(nds->GPU.GPU2D_B,p->Engine[1]);
                std::array<ConservativeLineCacheKey,2> current_cache_keys{};
                std::array<bool,2> current_cache_candidates{};
                if (cache_key_analysis) {
                    for (unsigned engine=0;engine<2;++engine) {
                        current_cache_keys[engine]=make_cache_key(
                            engine,*p,latest_latch,
                            latest_extended_palette,memory_revisions);
                        current_cache_candidates[engine]=
                            p->CaptureEnable==0 &&
                            p->ScreensEnabled!=0 &&
                            ((p->Engine[engine].DispCnt>>16)&
                                (engine==0?3u:1u))==1u &&
                            previous_cache_key_valid[engine][p->Line] &&
                            std::memcmp(
                                &previous_cache_keys[engine][p->Line],
                                &current_cache_keys[engine],
                                sizeof(ConservativeLineCacheKey))==0;
                    }
                    const bool uses_3d=(p->Engine[0].DispCnt&(1u<<3))!=0 &&
                        (p->Engine[0].LayerEnable&1u)!=0;
                    if (uses_3d) current_cache_candidates[0]=false;
                }
                if (!skip_2d) {
                    auto profile_start=std::chrono::steady_clock::now();
                    if (!skip_sprites) nds->GPU.GetRenderer().DrawSprites(p->Line);
                    auto profile_middle=std::chrono::steady_clock::now();
                    nds->GPU.GetRenderer().DrawScanline(p->Line);
                    auto profile_end=std::chrono::steady_clock::now();
                    if(profile){sprite_profile_ns+=std::chrono::duration_cast<std::chrono::nanoseconds>(profile_middle-profile_start).count();scanline_profile_ns+=std::chrono::duration_cast<std::chrono::nanoseconds>(profile_end-profile_middle).count();scanline_profile_calls++;}
                }
            } else if (compact && record.Type == 2) {
                if (payload.size() != 16) throw std::runtime_error("bad HGS map");
                map_vram(nds->GPU, payload.data() + 4);
            } else if ((!compact && type == Trace2DRecordType::ExtendedPaletteMap) || (compact && record.Type == 9)) {
                if (payload.size() != sizeof(Trace2DExtendedPaletteMapPacket) - sizeof(record)) throw std::runtime_error("bad extended palette map");
                Trace2DExtendedPaletteMapPacket p{}; p.Record=record;
                std::memcpy(reinterpret_cast<u8*>(&p)+sizeof(record),payload.data(),sizeof(p)-sizeof(record));
                std::memcpy(nds->GPU.VRAMMap_ABGExtPal,p.ABG,sizeof(p.ABG)); nds->GPU.VRAMMap_AOBJExtPal=p.AOBJ;
                std::memcpy(nds->GPU.VRAMMap_BBGExtPal,p.BBG,sizeof(p.BBG)); nds->GPU.VRAMMap_BOBJExtPal=p.BOBJ;
                latest_extended_palette=p;
            } else if (compact && record.Type == 7) {
                if (payload.size() != sizeof(Trace2DScanlinePacket)) throw std::runtime_error("bad HGS scanline");
                const auto* p=reinterpret_cast<const Trace2DScanlinePacket*>(payload.data());
                map_vram(nds->GPU,p->VRAMCNT); apply_video_maps(nds->GPU,*p); nds->GPU.ScreensEnabled=p->ScreensEnabled; nds->GPU.ScreenSwap=p->ScreenSwap;
                nds->GPU.VCount=p->VCount;
                nds->GPU.MasterBrightnessA=p->MasterBrightnessA; nds->GPU.MasterBrightnessB=p->MasterBrightnessB;
                fill_engine(nds->GPU.GPU2D_A,p->Engine[0]); fill_engine(nds->GPU.GPU2D_B,p->Engine[1]);
                std::array<ConservativeLineCacheKey,2> current_cache_keys{};
                std::array<bool,2> current_cache_candidates{};
                if (cache_key_analysis) {
                    for (unsigned engine=0;engine<2;++engine) {
                        current_cache_keys[engine]=make_cache_key(
                            engine,*p,latest_latch,
                            latest_extended_palette,memory_revisions);
                        current_cache_candidates[engine]=
                            p->CaptureEnable==0 &&
                            p->ScreensEnabled!=0 &&
                            ((p->Engine[engine].DispCnt>>16)&
                                (engine==0?3u:1u))==1u &&
                            previous_cache_key_valid[engine][p->Line] &&
                            std::memcmp(
                                &previous_cache_keys[engine][p->Line],
                                &current_cache_keys[engine],
                                sizeof(ConservativeLineCacheKey))==0;
                    }
                }
                if (cache_apply && cache_external_hint)
                    nds->GPU.GetRenderer().SetExternalLineCacheReuse(
                        p->Line,cache_apply_a&&current_cache_candidates[0],
                        cache_apply_b&&current_cache_candidates[1]);
                if (!skip_2d) {
                    auto profile_start=std::chrono::steady_clock::now();
                    if (!skip_sprites) nds->GPU.GetRenderer().DrawSprites(p->Line);
                    auto profile_middle=std::chrono::steady_clock::now();
                    nds->GPU.GetRenderer().DrawScanline(p->Line);
                    auto profile_end=std::chrono::steady_clock::now();
                    if(profile){sprite_profile_ns+=std::chrono::duration_cast<std::chrono::nanoseconds>(profile_middle-profile_start).count();scanline_profile_ns+=std::chrono::duration_cast<std::chrono::nanoseconds>(profile_end-profile_middle).count();scanline_profile_calls++;}
                }
                if (cache_key_analysis && !skip_2d) {
                    if(cache_apply) {
                        bool reused_a=false,reused_b=false;
                        if(!nds->GPU.GetRenderer().GetExternalLineCacheResult(
                                reused_a,reused_b))
                            throw std::runtime_error(
                                "renderer has no external cache result");
                        current_cache_candidates[0]=reused_a;
                        current_cache_candidates[1]=reused_b;
                    }
                    u32 *top=nullptr,*bottom=nullptr;
                    if (!nds->GPU.GetRenderer().GetRenderedScanlines(
                            p->Line,&top,&bottom) || !top || !bottom)
                        throw std::runtime_error(
                            "no rendered scanline for cache-key analysis");
                    const std::array<u32*,2> engine_lines = p->ScreenSwap
                        ? std::array<u32*,2>{top,bottom}
                        : std::array<u32*,2>{bottom,top};
                    hash_append(cache_output_hash,top,256*sizeof(u32));
                    hash_append(cache_output_hash,bottom,256*sizeof(u32));
                    if(output_dump) {
                        output_dump.write(reinterpret_cast<const char*>(top),
                            256*sizeof(u32));
                        output_dump.write(reinterpret_cast<const char*>(bottom),
                            256*sizeof(u32));
                    }
                    for (unsigned engine=0;engine<2;++engine) {
                        const bool repeat=
                            previous_engine_line_valid[engine][p->Line] &&
                            std::memcmp(
                                previous_engine_lines[engine][p->Line].data(),
                                engine_lines[engine],256*sizeof(u32))==0;
                        if(p->Frame==cache_debug_frame &&
                           p->Line==cache_debug_line)
                            std::cerr<<"cache_debug engine="<<engine
                                <<" candidate="
                                <<current_cache_candidates[engine]
                                <<" repeat="<<repeat
                                <<" screen_swap="<<unsigned(p->ScreenSwap)
                                <<" pixel219=0x"<<std::hex
                                <<engine_lines[engine][219]<<std::dec<<"\n";
                        if (current_cache_candidates[engine]) {
                            ++cache_key_candidates;
                            ++cache_key_engine_candidates[engine];
                            if (repeat) {
                                ++cache_key_true_hits;
                                ++cache_key_engine_true_hits[engine];
                            }
                            else ++cache_key_false_hits;
                        } else if (repeat) {
                            ++cache_key_repeat_misses;
                        }
                        std::memcpy(
                            previous_engine_lines[engine][p->Line].data(),
                            engine_lines[engine],256*sizeof(u32));
                        previous_engine_line_valid[engine][p->Line]=true;
                        previous_cache_keys[engine][p->Line]=
                            current_cache_keys[engine];
                        previous_cache_key_valid[engine][p->Line]=true;
                    }
                }
                if (cache_analysis && !skip_2d) {
                    u32 *top=nullptr,*bottom=nullptr;
                    if (!nds->GPU.GetRenderer().GetRenderedScanlines(
                            p->Line,&top,&bottom) || !top || !bottom)
                        throw std::runtime_error("no rendered scanline for cache analysis");
                    const std::array<u32*,2> lines{top,bottom};
                    for (std::size_t screen=0;screen<lines.size();++screen) {
                        if (previous_line_valid[screen][p->Line] &&
                            std::memcmp(previous_lines[screen][p->Line].data(),
                                lines[screen],256*sizeof(u32))==0) {
                            if (screen==0) {++cache_window_top_hits;++cache_total_top_hits;}
                            else {++cache_window_bottom_hits;++cache_total_bottom_hits;}
                        }
                        std::memcpy(previous_lines[screen][p->Line].data(),
                            lines[screen],256*sizeof(u32));
                        previous_line_valid[screen][p->Line]=true;
                    }
                    ++cache_window_lines;
                    ++cache_total_lines;
                    if (p->Line==191 && ++cache_window_frames==60) {
                        std::cerr<<"cache_window end_frame="<<p->Frame
                            <<" lines="<<cache_window_lines
                            <<" top_same="<<cache_window_top_hits
                            <<" bottom_same="<<cache_window_bottom_hits<<"\n";
                        cache_window_frames=0;cache_window_lines=0;
                        cache_window_top_hits=0;cache_window_bottom_hits=0;
                    }
                }
                if (p->Line==191) { nds->GPU.GetRenderer().SwapBuffers(); dump_frame(nds->GPU,p->Frame); }
            } else if ((!compact && record.Type == 9) || (compact && record.Type == 8)) {
                if (payload.size()!=sizeof(Trace2DInternal2DLatchPacket)-sizeof(record)) throw std::runtime_error("bad internal 2D latch");
                Trace2DInternal2DLatchPacket p{}; p.Record=record;
                std::memcpy(reinterpret_cast<u8*>(&p)+sizeof(record),payload.data(),sizeof(p)-sizeof(record));
                apply_latch(nds->GPU.GPU2D_A,p.Engine[0]); apply_latch(nds->GPU.GPU2D_B,p.Engine[1]);
                latest_latch=p;
            } else if (!compact && type == Trace2DRecordType::OBJBufferHash) {
                if (payload.size()!=sizeof(Trace2DOBJBufferHashPacket)-sizeof(record)) throw std::runtime_error("bad OBJ buffer hash");
                Trace2DOBJBufferHashPacket p{}; p.Record=record;
                std::memcpy(reinterpret_cast<u8*>(&p)+sizeof(record),payload.data(),sizeof(p)-sizeof(record));
                u64 actual[4]{}; if (!nds->GPU.GetRenderer().GetOBJBufferHashes(actual)) throw std::runtime_error("no OBJ buffer hashes");
                if (p.Line != 0) {
                    obj_hash_records++;
                    const bool line_bad=actual[0]!=p.Hashes[0] || actual[2]!=p.Hashes[2];
                    const bool window_bad=actual[1]!=p.Hashes[1] || actual[3]!=p.Hashes[3];
                    obj_line_hash_mismatches+=line_bad; obj_window_hash_mismatches+=window_bad;
                    obj_a_line_hash_mismatches+=actual[0]!=p.Hashes[0]; obj_b_line_hash_mismatches+=actual[2]!=p.Hashes[2];
                    if ((line_bad||window_bad) && first_bad_obj_frame==~0u) { first_bad_obj_frame=p.Frame; first_bad_obj_line=p.Line; }
                }
            } else if (!compact && type == Trace2DRecordType::OBJInputHash) {
                if (payload.size()!=sizeof(Trace2DOBJInputHashPacket)-sizeof(record)) throw std::runtime_error("bad OBJ input hash");
                Trace2DOBJInputHashPacket p{}; p.Record=record;
                std::memcpy(reinterpret_cast<u8*>(&p)+sizeof(record),payload.data(),sizeof(p)-sizeof(record));
                obj_input_records++;
                oam_a_hash_mismatches += hash_bytes(nds->GPU.OAM,1024)!=p.OAMA;
                flat_aobj_hash_mismatches += hash_bytes(nds->GPU.VRAMFlat_AOBJ,sizeof(nds->GPU.VRAMFlat_AOBJ))!=p.FlatAOBJ;
            } else if (!compact && record.Type == 8) {
                if (payload.size() != sizeof(Trace2DFramebufferScanlinePacket)-sizeof(record)) throw std::runtime_error("bad framebuffer oracle");
                Trace2DFramebufferScanlinePacket p{}; p.Record=record;
                std::memcpy(reinterpret_cast<u8*>(&p)+sizeof(record),payload.data(),sizeof(p)-sizeof(record));
                u32 *top=nullptr,*bottom=nullptr;
                if (!nds->GPU.GetRenderer().GetRenderedScanlines(p.Line,&top,&bottom)) throw std::runtime_error("no rendered scanline");
                for (u32 x=0;x<256;x++) {
                    const bool top_bad=top[x]!=p.Top[x], bottom_bad=bottom[x]!=p.Bottom[x];
                    framebuffer_compared+=2; framebuffer_mismatches += top_bad + bottom_bad;
                    framebuffer_top_mismatches+=top_bad; framebuffer_bottom_mismatches+=bottom_bad;
                    if ((top_bad||bottom_bad) && first_bad_frame==~0u) {
                        first_bad_frame=p.Frame; first_bad_line=p.Line; first_bad_x=x;
                        first_bad_actual=top_bad?top[x]:bottom[x]; first_bad_expected=top_bad?p.Top[x]:p.Bottom[x];
                        const u32* d3=nds->GPU.GetRenderer().Get3DScanline(p.Line);
                        std::cerr << "first_bad_3d=0x" << std::hex << d3[x]
                                  << " dispcnt=0x" << nds->GPU.GPU2D_A.DispCnt
                                  << " blendcnt=0x" << nds->GPU.GPU2D_A.BlendCnt
                                  << " blendalpha=0x" << nds->GPU.GPU2D_A.BlendAlpha
                                  << " eva=" << std::dec << unsigned(nds->GPU.GPU2D_A.EVA)
                                  << " evb=" << unsigned(nds->GPU.GPU2D_A.EVB) << "\n";
                    }
                    if (p.Frame==599) { target_top_mismatches+=top_bad; target_bottom_mismatches+=bottom_bad; }
                }
                if (p.Line==191) { nds->GPU.GetRenderer().SwapBuffers(); dump_frame(nds->GPU,p.Frame); }
            } else if (!compact && type == Trace2DRecordType::Renderer3DScanline) {
                u32 frame; u16 line, count;
                std::memcpy(&frame, payload.data(), 4); std::memcpy(&line, payload.data()+4, 2); std::memcpy(&count, payload.data()+6, 2);
                if (count != 256 || line >= 192) throw std::runtime_error("bad oracle line");
                if (oracle.frame != frame) { oracle = {}; oracle.frame = frame; }
                std::memcpy(&oracle.pixels[line*256], payload.data()+8, 1024); oracle.lines[line] = true;
                const u32* scanout=nds->GPU.GetRenderer().Get3DScanline(line);
                for (u32 x=0;x<256;x++) { scanout_3d_compared++; scanout_3d_mismatches += scanout[x]!=oracle.pixels[line*256+x]; }
            } else if ((!compact && type == Trace2DRecordType::GeometryCommand) || (compact && record.Type == 3)) {
                if (payload.size() != sizeof(Trace2DGeometryCommandPacket) - sizeof(record)) throw std::runtime_error("bad command record");
                Trace2DGeometryCommandPacket p{}; p.Record = record;
                std::memcpy(reinterpret_cast<u8*>(&p)+sizeof(record), payload.data(), sizeof(p)-sizeof(record));
                nds->NumFrames = p.Frame;
                if (exact_geometry_timing) {
                    nds->ARM9Timestamp = p.Timestamp;
                    nds->GPU.GPU3D.Run();
                    sample_gx_state();
                } else {
                    nds->ARM9Timestamp = replay_clock;
                }
                if (external_command_replay)
                    nds->GPU.GPU3D.WriteExternalNormalizedCommand(
                        p.Command, p.Parameter);
                else
                    nds->GPU.GPU3D.Write32(
                        0x04000400 + static_cast<u32>(p.Command)*4,
                        p.Parameter);
                if (exact_geometry_timing)
                    ++gx_commands_replayed;
                sample_gx_state();
                if (!exact_geometry_timing) {
                    replay_clock += 1u << 16;
                    if (!batch_geometry ||
                        ++pending_geometry_commands == GeometryRunBatch) {
                        nds->ARM9Timestamp = replay_clock;
                        nds->GPU.GPU3D.Run();
                        pending_geometry_commands = 0;
                    }
                }
            } else if ((!compact && type == Trace2DRecordType::GeometryRegister) || (compact && record.Type == 4)) {
                if (payload.size() != sizeof(Trace2DGeometryRegisterPacket) - sizeof(record)) throw std::runtime_error("bad register record");
                Trace2DGeometryRegisterPacket p{}; p.Record = record;
                std::memcpy(reinterpret_cast<u8*>(&p)+sizeof(record), payload.data(), sizeof(p)-sizeof(record));
                nds->NumFrames = p.Frame;
                if (exact_geometry_timing) {
                    nds->ARM9Timestamp = p.Timestamp;
                    nds->GPU.GPU3D.Run();
                    sample_gx_state();
                } else {
                    nds->ARM9Timestamp = replay_clock;
                }
                if (p.Width == 1) nds->GPU.GPU3D.Write8(p.Address, static_cast<u8>(p.Value));
                else if (p.Width == 2) nds->GPU.GPU3D.Write16(p.Address, static_cast<u16>(p.Value));
                else if (p.Width == 4) nds->GPU.GPU3D.Write32(p.Address, p.Value);
                else throw std::runtime_error("bad register width");
                if (exact_geometry_timing)
                    ++gx_register_writes_replayed;
                sample_gx_state();
            } else if ((!compact && type == Trace2DRecordType::GeometryFrame) || (compact && record.Type == 5)) {
                if (payload.size() != sizeof(Trace2DGeometryFramePacket) - sizeof(record)) throw std::runtime_error("bad frame record");
                Trace2DGeometryFramePacket p{}; p.Record = record;
                std::memcpy(reinterpret_cast<u8*>(&p)+sizeof(record), payload.data(), sizeof(p)-sizeof(record));
                nds->NumFrames = p.Frame;
                if (exact_geometry_timing) {
                    nds->ARM9Timestamp = p.Timestamp;
                } else {
                    replay_clock += 1u << 16;
                    nds->ARM9Timestamp = replay_clock;
                }
                nds->GPU.GPU3D.Run();
                sample_gx_state();
                geometry_count_mismatches += nds->GPU.GPU3D.NumVertices != p.Vertices || nds->GPU.GPU3D.NumPolygons != p.Polygons;
                if (oracle.frame == p.Frame) {
                    oracle_frames++;
                    for (u32 y=0; y<192; y++) if (oracle.lines[y]) {
                        const u32* actual = nds->GPU.GetRenderer().Get3DScanline(y);
                        for (u32 x=0; x<256; x++) {
                            const u32 expected = oracle.pixels[y*256+x];
                            compared++; mismatches += actual[x] != expected;
                            rgb_mismatches += (actual[x] & 0x00FFFFFF) != (expected & 0x00FFFFFF);
                            actual_zero += actual[x] == 0 && expected != 0;
                            oracle_zero += expected == 0 && actual[x] != 0;
                        }
                    }
                }
                nds->GPU.GPU3D.VBlank();
                nds->GPU.GetRenderer().Start3DRendering(); nds->GPU.GetRenderer().Finish3DRendering();
                if (analyze_geometry_delta) {
                    constexpr u32 BlockPixels = 16;
                    const auto bank = rendered & 1u;
                    auto& previous = previous_geometry_banks[bank];
                    if (previous_geometry_bank_valid[bank]) {
                        ++geometry_delta_frames;
                        for (u32 y = 0; y < 192; ++y) {
                            const u32* actual =
                                nds->GPU.GetRenderer().Get3DScanline(y);
                            for (u32 x = 0; x < 256; x += BlockPixels) {
                                const auto offset = y * 256 + x;
                                ++geometry_delta_blocks;
                                if (std::memcmp(
                                        actual + x, previous.data() + offset,
                                        BlockPixels * sizeof(u32)) == 0)
                                    ++geometry_delta_same_blocks;
                                for (u32 lane = 0; lane < BlockPixels; ++lane) {
                                    ++geometry_delta_pixels;
                                    if (actual[x + lane] == previous[offset + lane])
                                        ++geometry_delta_same_pixels;
                                }
                            }
                            std::memcpy(
                                previous.data() + y * 256, actual,
                                256 * sizeof(u32));
                        }
                    } else {
                        for (u32 y = 0; y < 192; ++y)
                            std::memcpy(
                                previous.data() + y * 256,
                                nds->GPU.GetRenderer().Get3DScanline(y),
                                256 * sizeof(u32));
                        previous_geometry_bank_valid[bank] = true;
                    }
                }
                if (verify_geometry_output) {
                    for (u32 y = 0; y < 192; ++y)
                        hash_append(
                            geometry_output_hash,
                            nds->GPU.GetRenderer().Get3DScanline(y),
                            256 * sizeof(u32));
                }
                rendered++;
                if (profile && rendered % 60 == 0) {
                    const auto now=std::chrono::steady_clock::now();
                    std::cerr<<"profile_window end_frame="<<p.Frame
                        <<" frames=60 ms="
                        <<std::chrono::duration<double,std::milli>(
                            now-replay_profile_checkpoint).count()<<"\n";
                    replay_profile_checkpoint=now;
                }
                if (max_frames && rendered >= max_frames) break;
                if (exact_geometry_timing)
                    ++gx_frame_records_replayed;
            }
        }
        if (pending_geometry_commands != 0)
            nds->GPU.GPU3D.Run();
        if (producer.joinable()) producer.join();
        if (!producer_error.empty()) throw std::runtime_error(producer_error);
        const auto replay_profile_end=std::chrono::steady_clock::now();
        std::cout << "NDS4MiSTer native 3D replay\nframes_rendered: " << rendered
                  << "\noracle_frames: " << oracle_frames << "\npixels_compared: " << compared
                  << "\npixel_mismatches: " << mismatches << "\nrgb_mismatches: " << rgb_mismatches
                  << "\nscanout_3d_pixels_compared: " << scanout_3d_compared
                  << "\nscanout_3d_pixel_mismatches: " << scanout_3d_mismatches
                  << "\ngeometry_count_mismatches: " << geometry_count_mismatches
                  << "\nobj_hash_records: " << obj_hash_records
                  << "\nobj_line_hash_mismatches: " << obj_line_hash_mismatches
                  << "\nobj_a_line_hash_mismatches: " << obj_a_line_hash_mismatches
                  << "\nobj_b_line_hash_mismatches: " << obj_b_line_hash_mismatches
                  << "\nobj_window_hash_mismatches: " << obj_window_hash_mismatches
                  << "\nfirst_bad_obj: " << first_bad_obj_frame << "," << first_bad_obj_line
                  << "\nobj_input_records: " << obj_input_records
                  << "\noam_a_hash_mismatches: " << oam_a_hash_mismatches
                  << "\nflat_aobj_hash_mismatches: " << flat_aobj_hash_mismatches
                  << "\nactual_zero_only: " << actual_zero << "\noracle_zero_only: " << oracle_zero << "\n";
        if (verify_geometry_output)
            std::cout << "geometry_output_hash: " << std::hex
                      << geometry_output_hash << std::dec << "\n";
        if (analyze_geometry_delta)
            std::cout << "geometry_delta_frames: " << geometry_delta_frames
                      << "\ngeometry_delta_pixels: " << geometry_delta_pixels
                      << "\ngeometry_delta_same_pixels: "
                      << geometry_delta_same_pixels
                      << "\ngeometry_delta_blocks: " << geometry_delta_blocks
                      << "\ngeometry_delta_same_blocks: "
                      << geometry_delta_same_blocks << "\n";
        std::cout << "framebuffer_pixels_compared: " << framebuffer_compared
                  << "\nframebuffer_pixel_mismatches: " << framebuffer_mismatches
                  << "\nframebuffer_top_mismatches: " << framebuffer_top_mismatches
                  << "\nframebuffer_bottom_mismatches: " << framebuffer_bottom_mismatches
                  << "\nfirst_bad_frame: " << first_bad_frame
                  << "\nfirst_bad_pixel: " << first_bad_line << "," << first_bad_x
                  << " actual=0x" << std::hex << first_bad_actual << " expected=0x" << first_bad_expected << std::dec
                  << "\nframe_599_top_mismatches: " << target_top_mismatches
                  << "\nframe_599_bottom_mismatches: " << target_bottom_mismatches << "\n";
        if(profile) {
            const auto renderer_profile =
                nds->GPU.GetRenderer().GetExternalRendererStageProfile();
            std::cout << "renderer_3d_polygon_frames: "
                      << renderer_profile.ThreeDPolygonFrames
                      << "\nrenderer_3d_polygons: "
                      << renderer_profile.ThreeDPolygons
                      << "\nrenderer_3d_polygon_scanlines: "
                      << renderer_profile.ThreeDPolygonScanlines
                      << "\nrenderer_3d_max_polygons: "
                      << renderer_profile.ThreeDMaxPolygons
                      << "\nrenderer_3d_scheduled_polygon_frames: "
                      << renderer_profile.ThreeDScheduledPolygonFrames
                      << "\n";
            std::cout<<"profile_total_ms: "<<std::chrono::duration<double,std::milli>(replay_profile_end-replay_profile_start).count()
            <<"\nprofile_sprite_ms: "<<sprite_profile_ns/1000000.0<<"\nprofile_scanline_ms: "<<scanline_profile_ns/1000000.0
            <<"\nprofile_scanline_calls: "<<scanline_profile_calls<<"\n";
        }
        if(cache_analysis) std::cout<<"cache_total_lines: "<<cache_total_lines
            <<"\ncache_top_same: "<<cache_total_top_hits
            <<"\ncache_bottom_same: "<<cache_total_bottom_hits<<"\n";
        if(cache_key_analysis) std::cout
            <<"cache_key_candidates: "<<cache_key_candidates
            <<"\ncache_key_true_hits: "<<cache_key_true_hits
            <<"\ncache_key_false_hits: "<<cache_key_false_hits
            <<"\ncache_key_repeat_misses: "<<cache_key_repeat_misses
            <<"\ncache_key_engine_a_candidates: "
            <<cache_key_engine_candidates[0]
            <<"\ncache_key_engine_b_candidates: "
            <<cache_key_engine_candidates[1]
            <<"\ncache_key_engine_a_true_hits: "
            <<cache_key_engine_true_hits[0]
            <<"\ncache_key_engine_b_true_hits: "
            <<cache_key_engine_true_hits[1]
            <<"\ncache_apply: "<<(cache_apply?1:0)
            <<"\ncache_output_hash: "<<std::hex<<cache_output_hash
            <<std::dec<<"\n";
        if (exact_geometry_timing)
            std::cout << "gx_exact_timing: 1"
                      << "\ngx_commands_replayed: " << gx_commands_replayed
                      << "\ngx_register_writes_replayed: "
                      << gx_register_writes_replayed
                      << "\ngx_frame_records_replayed: "
                      << gx_frame_records_replayed
                      << "\ngx_max_fifo_level: " << max_gx_fifo_level
                      << "\ngx_max_pipe_level: " << max_gx_pipe_level
                      << "\ngx_max_stall_queue_level: "
                      << max_gx_stall_queue_level
                      << "\ngx_stall_transitions: "
                      << gx_stall_transitions << "\n";
        if (batch_geometry)
            std::cout << "gx_batched_geometry: 1"
                      << "\ngx_geometry_batch_size: "
                      << GeometryRunBatch << "\n";
        if (external_command_replay)
            std::cout << "gx_external_command_replay: 1\n";
        return (mismatches || framebuffer_mismatches) ? 1 : 0;
    } catch (const std::exception& e) { std::cerr << "3D replay failed: " << e.what() << "\n"; return 1; }
}
