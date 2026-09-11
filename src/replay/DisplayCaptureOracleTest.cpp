// Focused oracle for the DS display-capture path used by dual-screen games.
// It drives melonDS's real software renderer without a ROM, so the test covers
// the implementation linked into the HPS service rather than a copied model.

#include "Args.h"
#include "NDS.h"
#include "replay/Hybrid3DAbi.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

namespace {

using melonDS::u16;
using melonDS::u32;

std::unique_ptr<melonDS::NDS> make_nds()
{
    melonDS::NDSArgs args;
    args.JIT = std::nullopt;
    auto nds = std::make_unique<melonDS::NDS>(std::move(args));
    nds->Reset();
    return nds;
}

u16 capture_source_a(u32 color)
{
    const u32 red = (color >> 1) & 0x1f;
    const u32 green = (color >> 9) & 0x1f;
    const u32 blue = (color >> 17) & 0x1f;
    const u32 alpha = (color >> 24) ? 0x8000 : 0;
    return static_cast<u16>(red | (green << 5) | (blue << 10) | alpha);
}

u16 capture_blend(u32 source_a, u16 source_b, u32 eva, u32 evb)
{
    eva = std::min(eva, 16u);
    evb = std::min(evb, 16u);
    const u32 red_a = (source_a >> 1) & 0x1f;
    const u32 green_a = (source_a >> 9) & 0x1f;
    const u32 blue_a = (source_a >> 17) & 0x1f;
    const u32 alpha_a = (source_a >> 24) != 0;
    const u32 red_b = source_b & 0x1f;
    const u32 green_b = (source_b >> 5) & 0x1f;
    const u32 blue_b = (source_b >> 10) & 0x1f;
    const u32 alpha_b = source_b >> 15;
    const auto channel = [](u32 a, u32 aa, u32 ea,
                            u32 b, u32 ab, u32 eb) {
        return std::min(((a * aa * ea) + (b * ab * eb) + 8) >> 4,
                        0x1fu);
    };
    const u32 red = channel(red_a, alpha_a, eva, red_b, alpha_b, evb);
    const u32 green = channel(
        green_a, alpha_a, eva, green_b, alpha_b, evb);
    const u32 blue = channel(blue_a, alpha_a, eva, blue_b, alpha_b, evb);
    const u32 alpha = ((eva != 0) && alpha_a) |
                      ((evb != 0) && alpha_b);
    return static_cast<u16>(red | (green << 5) | (blue << 10) |
                            (alpha << 15));
}

u16* bank_words(melonDS::GPU& gpu, unsigned bank)
{
    return reinterpret_cast<u16*>(gpu.VRAM[bank]);
}

bool source_a_and_destination_offset(bool engine_b_only = false,
                                     bool pixels_enabled = true)
{
    auto nds = make_nds();
    melonDS::RendererSettings settings {};
    settings.EngineBOnly = engine_b_only;
    settings.EngineBPixelsEnabled = pixels_enabled;
    nds->GPU.GetRenderer().SetRenderSettings(settings);
    constexpr unsigned line = 7;
    constexpr unsigned destination_bank = 1;
    constexpr unsigned destination_offset = 2;
    constexpr unsigned width = 128;
    constexpr u16 sentinel = 0x4a55;
    auto* destination = bank_words(nds->GPU, destination_bank);
    std::fill_n(destination, 0x10000, sentinel);

    auto* source = nds->GPU.GetRenderer().Get3DScanline(line);
    if (!source) return false;
    for (unsigned x = 0; x < 256; ++x) {
        const u32 red = (x * 3 + 1) & 0x3f;
        const u32 green = (x * 5 + 2) & 0x3f;
        const u32 blue = (x * 7 + 3) & 0x3f;
        source[x] = red | (green << 8) | (blue << 16) |
                    ((x & 1) ? 0x1f000000u : 0u);
    }

    nds->GPU.VRAMMap_LCDC = 1u << destination_bank;
    nds->GPU.VCount = line;
    nds->GPU.CaptureEnable = true;
    nds->GPU.CaptureCnt = (1u << 31) | (1u << 24) |
        (destination_bank << 16) | (destination_offset << 18);
    nds->GPU.GetRenderer().DrawScanline(line);

    const unsigned base = ((destination_offset << 14) + line * width) &
                          0xffff;
    if (base == 0 || destination[base - 1] != sentinel ||
        destination[base + width] != sentinel)
        return false;
    for (unsigned x = 0; x < width; ++x)
        if (destination[base + x] != capture_source_a(source[x]))
            return false;
    return true;
}

bool source_b_fifo(bool engine_b_only = false, bool pixels_enabled = true)
{
    auto nds = make_nds();
    melonDS::RendererSettings settings {};
    settings.EngineBOnly = engine_b_only;
    settings.EngineBPixelsEnabled = pixels_enabled;
    nds->GPU.GetRenderer().SetRenderSettings(settings);
    constexpr unsigned line = 3;
    constexpr unsigned destination_bank = 2;
    constexpr unsigned destination_offset = 1;
    constexpr unsigned width = 256;
    auto* destination = bank_words(nds->GPU, destination_bank);
    std::fill_n(destination, 0x10000, u16 {0});
    for (unsigned x = 0; x < width; ++x)
        nds->GPU.DispFIFOBuffer[x] = static_cast<u16>(
            0x8000u | ((x * 37u) & 0x7fffu));

    nds->GPU.VRAMMap_LCDC = 1u << destination_bank;
    nds->GPU.VCount = line;
    nds->GPU.CaptureEnable = true;
    nds->GPU.CaptureCnt = (1u << 31) | (1u << 25) | (1u << 29) |
        (destination_bank << 16) | (destination_offset << 18) |
        (1u << 20);
    nds->GPU.GetRenderer().DrawScanline(line);

    const unsigned base = ((destination_offset << 14) + line * width) &
                          0xffff;
    for (unsigned x = 0; x < width; ++x)
        if (destination[base + x] != nds->GPU.DispFIFOBuffer[x])
            return false;
    return true;
}

bool source_b_vram_offset(bool engine_b_only = false, bool pixels_enabled = true)
{
    auto nds = make_nds();
    melonDS::RendererSettings settings {};
    settings.EngineBOnly = engine_b_only;
    settings.EngineBPixelsEnabled = pixels_enabled;
    nds->GPU.GetRenderer().SetRenderSettings(settings);
    constexpr unsigned line = 4;
    constexpr unsigned source_bank = 0;
    constexpr unsigned source_offset = 2;
    constexpr unsigned destination_bank = 3;
    constexpr unsigned destination_offset = 3;
    constexpr unsigned width = 128;
    auto* source = bank_words(nds->GPU, source_bank);
    auto* destination = bank_words(nds->GPU, destination_bank);
    std::fill_n(source, 0x10000, u16 {0});
    std::fill_n(destination, 0x10000, u16 {0});
    const unsigned source_base = ((source_offset << 14) + line * 256) &
                                 0xffff;
    for (unsigned x = 0; x < width; ++x)
        source[source_base + x] = static_cast<u16>(
            0x8000u | ((x * 53u + 9u) & 0x7fffu));

    nds->GPU.GPU2D_A.DispCnt = 1u << 16;
    nds->GPU.VRAMMap_LCDC = (1u << source_bank) |
                           (1u << destination_bank);
    nds->GPU.VCount = line;
    nds->GPU.CaptureEnable = true;
    nds->GPU.CaptureCnt = (1u << 31) | (1u << 29) |
        (destination_bank << 16) | (destination_offset << 18) |
        (source_offset << 26);
    nds->GPU.GetRenderer().DrawScanline(line);

    const unsigned destination_base =
        ((destination_offset << 14) + line * width) & 0xffff;
    for (unsigned x = 0; x < width; ++x)
        if (destination[destination_base + x] != source[source_base + x])
            return false;
    return true;
}

bool production_engine_b_source_b_capture(bool pixels_enabled = true)
{
    auto nds = make_nds();
    constexpr unsigned source_bank = 0;
    constexpr unsigned source_offset = 2;
    constexpr unsigned destination_bank = 3;
    constexpr unsigned destination_offset = 1;
    constexpr unsigned width = 128;
    constexpr u16 sentinel = 0x2d15;
    auto* source = bank_words(nds->GPU, source_bank);
    auto* destination = bank_words(nds->GPU, destination_bank);
    std::fill_n(source, 0x10000, u16 {0});
    std::fill_n(destination, 0x10000, sentinel);
    const unsigned source_base = source_offset << 14;
    for (unsigned x = 0; x < width; ++x)
        source[source_base + x] = static_cast<u16>(
            0x8000u | ((x * 41u + 5u) & 0x7fffu));

    nds->GPU.GPU2D_A.DispCnt = 1u << 16;
    nds->GPU.VRAMMap_LCDC = (1u << source_bank) |
                           (1u << destination_bank);
    nds->GPU.CaptureCnt = (1u << 31) | (1u << 29) |
        (destination_bank << 16) | (destination_offset << 18) |
        (source_offset << 26);

    // Match Hybrid3DService's split-video settings and phase calls. Source B
    // is deliberately selected so this regression isolates whether the
    // Engine-B-only path executes display capture; it does not depend on the
    // intentionally omitted Engine-A renderer or independent 3D output.
    melonDS::RendererSettings settings {
        1, false, false, false, true, false, false, false, true, true,
        pixels_enabled};
    auto& renderer = nds->GPU.GetRenderer();
    renderer.SetRenderSettings(settings);
    const bool phases_ok = nds->GPU.ApplyExternalRendererPhase(
        2, 0, 0, 0, 0, 17, true, true, true);
    const bool capture_armed = nds->GPU.CaptureEnable;
    const bool draw_ok = phases_ok && nds->GPU.ApplyExternalRendererPhase(
        1, 0, 0, 2, 2, 17, true, false, true);

    const unsigned destination_base = destination_offset << 14;
    bool matched = phases_ok && capture_armed && draw_ok &&
        destination[destination_base - 1] == sentinel &&
        destination[destination_base + width] == sentinel;
    for (unsigned x = 0; matched && x < width; ++x)
        matched = destination[destination_base + x] ==
                  source[source_base + x];

    // CheckCaptureStart deliberately tracks the captured block until a CPU
    // access needs synchronization. Clear that oracle bookkeeping before the
    // fixture is destroyed so a later fixture cannot inherit allocator bytes
    // that resemble a live capture before its renderer has been installed.
    nds->GPU.SyncVRAM_LCDC(
        0x06800000u + destination_bank * 0x20000u +
            destination_offset * 0x8000u,
        true);
    return matched;
}

bool production_engine_b_source_a_capture(bool source_3d)
{
    constexpr unsigned destination_bank = 1;
    constexpr unsigned width = 128;
    using CapturedLine = std::array<u16, width>;

    const auto render = [=](bool engine_b_only, bool pixels_enabled,
                           CapturedLine& captured) {
        auto nds = make_nds();
        auto* destination = bank_words(nds->GPU, destination_bank);
        std::fill_n(destination, 0x10000, u16 {0x1357});
        auto* palette = reinterpret_cast<u16*>(nds->GPU.Palette);
        palette[0] = 0x4210;
        nds->ARM9Write16(0x04000304, 0x020f);
        nds->ARM9Write32(
            0x04000000,
            (1u << 16) | (source_3d ? 0u : ((1u << 8) | (1u << 3))));
        nds->GPU.GPU2D_A.DispCntLatch[0] = nds->GPU.GPU2D_A.DispCnt;
        nds->GPU.GPU2D_A.DispCntLatch[1] = nds->GPU.GPU2D_A.DispCnt;
        nds->GPU.GPU2D_A.DispCntLatch[2] = nds->GPU.GPU2D_A.DispCnt;
        nds->GPU.GPU2D_A.LayerEnable = source_3d ? 0 : 1;
        nds->GPU.VRAMMap_LCDC = 1u << destination_bank;

        melonDS::RendererSettings settings {
            1, false, false, false, true, false, false, false, true,
            engine_b_only, pixels_enabled};
        auto& renderer = nds->GPU.GetRenderer();
        renderer.SetRenderSettings(settings);
        auto* source = renderer.Get3DScanline(0);
        if (!source) return false;
        for (unsigned x = 0; x < 256; ++x) {
            const u32 red = (x * 3 + 1) & 0x3f;
            const u32 green = (x * 5 + 2) & 0x3f;
            const u32 blue = (x * 7 + 3) & 0x3f;
            source[x] = red | (green << 8) | (blue << 16) |
                        0x1f000000u;
        }

        nds->GPU.CaptureCnt = (1u << 31) |
            (destination_bank << 16) | (source_3d ? (1u << 24) : 0u);
        const bool start_ok = nds->GPU.ApplyExternalRendererPhase(
            2, 0, 0, 0, 0, 19, true, true, engine_b_only);
        const bool armed = nds->GPU.CaptureEnable;
        const bool draw_ok = start_ok &&
            nds->GPU.ApplyExternalRendererPhase(
                1, 0, 0, 2, 2, 19, true, false, engine_b_only);
        std::copy_n(destination, width, captured.begin());
        nds->GPU.SyncVRAM_LCDC(0x06820000u, true);
        return start_ok && armed && draw_ok;
    };

    CapturedLine oracle {};
    CapturedLine engine_b {};
    CapturedLine disabled_b {};
    return render(false, true, oracle) && render(true, true, engine_b) &&
           render(true, false, disabled_b) &&
           oracle == engine_b && oracle == disabled_b &&
           std::any_of(oracle.begin(), oracle.end(),
               [](u16 pixel) { return pixel != 0 && pixel != 0x1357; });
}

bool blended_sources(bool engine_b_only = false, bool pixels_enabled = true)
{
    auto nds = make_nds();
    melonDS::RendererSettings settings {};
    settings.EngineBOnly = engine_b_only;
    settings.EngineBPixelsEnabled = pixels_enabled;
    nds->GPU.GetRenderer().SetRenderSettings(settings);
    constexpr unsigned line = 0;
    constexpr unsigned destination_bank = 0;
    constexpr unsigned width = 256;
    constexpr unsigned eva = 12;
    constexpr unsigned evb = 7;
    auto* destination = bank_words(nds->GPU, destination_bank);
    std::fill_n(destination, 0x10000, u16 {0});
    auto* source_a = nds->GPU.GetRenderer().Get3DScanline(line);
    if (!source_a) return false;
    for (unsigned x = 0; x < width; ++x) {
        source_a[x] = ((x + 13) & 0x3f) |
            (((x * 3 + 7) & 0x3f) << 8) |
            (((x * 5 + 11) & 0x3f) << 16) | 0x1f000000u;
        nds->GPU.DispFIFOBuffer[x] = static_cast<u16>(
            0x8000u | ((x * 29u + 17u) & 0x7fffu));
    }

    nds->GPU.VRAMMap_LCDC = 1u << destination_bank;
    nds->GPU.VCount = line;
    nds->GPU.CaptureEnable = true;
    nds->GPU.CaptureCnt = (1u << 31) | (1u << 24) | (1u << 25) |
        (2u << 29) | (1u << 20) | eva | (evb << 8);
    nds->GPU.GetRenderer().DrawScanline(line);

    for (unsigned x = 0; x < width; ++x)
        if (destination[x] != capture_blend(
                source_a[x], nds->GPU.DispFIFOBuffer[x], eva, evb))
            return false;
    return true;
}

bool powcnt1_screen_swap()
{
    auto render = [](bool swap, u32& top_pixel, u32& bottom_pixel) {
        auto nds = make_nds();
        auto* palette = reinterpret_cast<u16*>(nds->GPU.Palette);
        palette[0] = 0x001f;
        palette[0x200] = 0x7c00;
        nds->ARM9Write32(0x04000000, 1u << 16);
        nds->ARM9Write32(0x04001000, 1u << 16);
        nds->ARM9Write16(0x04000304, swap ? 0x820f : 0x020f);
        nds->GPU.ScreensEnabled = true;
        nds->GPU.VCount = 0;
        nds->GPU.GetRenderer().DrawScanline(0);
        u32* top = nullptr;
        u32* bottom = nullptr;
        if (!nds->GPU.GetRenderer().GetRenderedScanlines(
                0, &top, &bottom) || !top || !bottom)
            return false;
        top_pixel = top[0];
        bottom_pixel = bottom[0];
        return true;
    };

    u32 normal_top = 0;
    u32 normal_bottom = 0;
    u32 swapped_top = 0;
    u32 swapped_bottom = 0;
    return render(false, normal_top, normal_bottom) &&
           render(true, swapped_top, swapped_bottom) &&
           normal_top != normal_bottom &&
           normal_top == swapped_bottom &&
           normal_bottom == swapped_top;
}

bool production_engine_b_publication(bool swap)
{
    using namespace nds4mister::h3d;
    auto nds = make_nds();

    // Build a varied 8bpp text background in VRAM C, mapped exactly as an
    // Engine-B BG bank. A solid backdrop would not detect row/pixel ordering
    // mistakes in the publication path.
    auto* vram = nds->GPU.VRAM[2];
    std::fill_n(vram, 0x20000, std::uint8_t {0});
    for (unsigned tile = 0; tile < 96; ++tile) {
        for (unsigned y = 0; y < 8; ++y) {
            for (unsigned x = 0; x < 8; ++x) {
                vram[tile * 64 + y * 8 + x] = static_cast<std::uint8_t>(
                    1 + ((tile * 11 + y * 17 + x * 23) % 255));
            }
        }
    }
    auto* map = reinterpret_cast<u16*>(vram + 0x4000);
    for (unsigned y = 0; y < 32; ++y)
        for (unsigned x = 0; x < 32; ++x)
            map[y * 32 + x] = static_cast<u16>((y * 32 + x) % 96);
    auto* palette = reinterpret_cast<u16*>(nds->GPU.Palette) + 0x200;
    for (unsigned index = 0; index < 256; ++index) {
        palette[index] = static_cast<u16>(
            (index & 0x1f) | (((index * 3) & 0x1f) << 5) |
            (((index * 7) & 0x1f) << 10));
    }

    nds->GPU.MapVRAM_CD(2, 0x84);
    nds->ARM9Write16(0x04000304, swap ? 0x820f : 0x020f);
    nds->ARM9Write32(0x04001000, 0x00010100);
    nds->ARM9Write16(0x04001008, 0x0880);

    // Match Hybrid3DService::reset_machine(): packed native pixels and only
    // GPU2D-B are produced while the independent 3D worker remains enabled.
    melonDS::RendererSettings settings {
        1, true, false, false, true, false, false, false, true, true};
    auto& renderer = nds->GPU.GetRenderer();
    renderer.SetRenderSettings(settings);
    renderer.Finish3DRendering();

    std::vector<u32> engine_b(PlanePixels);
    for (unsigned line = 0; line < PlaneHeight; ++line) {
        if (!nds->GPU.ApplyExternalRendererPhase(
                line == 0 ? 2u : 0u, line, line, 0, 0, 9, true,
                line == 0, true) ||
            !nds->GPU.ApplyExternalRendererPhase(
                1, line, line, 2, 2, 9, true, false, true))
            return false;
        u32* top = nullptr;
        u32* bottom = nullptr;
        if (!renderer.GetRenderedScanlines(line, &top, &bottom) ||
            !top || !bottom)
            return false;
        const auto* source = nds->GPU.ScreenSwap ? bottom : top;
        std::memcpy(
            engine_b.data() + line * PlaneWidth, source,
            PlaneWidth * sizeof(u32));
    }
    if (std::adjacent_find(engine_b.begin(), engine_b.end(),
            std::not_equal_to<u32>()) == engine_b.end())
        return false;

    Header header{};
    header.magic = Magic;
    header.version = Version;
    header.header_size = HeaderSize;
    header.fpga_session = 41;
    header.accepted_session = 41;
    std::vector<u32> plane(PlanePixels);
    std::vector<u32> bank0(PlanePixels);
    std::vector<u32> bank1(PlanePixels);
    std::vector<u32> engine_b_banks(
        EngineBBankCount * (EngineBBankStride / sizeof(u32)));
    for (std::size_t index = 0; index < plane.size(); ++index) {
        const auto x = static_cast<u32>(index % PlaneWidth);
        const auto y = static_cast<u32>(index / PlaneWidth);
        plane[index] = ((x + 3) & 0x3f) |
            (((y + 7) & 0x3f) << 8) |
            (((x + y + 11) & 0x3f) << 16) | 0x1f000000u;
    }

    PlanePublisher publisher(
        header, bank0.data(), bank1.data(), false, engine_b_banks.data());
    if (!publisher.publish(
            41, 9, plane.data(), nullptr, engine_b.data(), swap))
        return false;
    if (header.frame.format != PixelFormatRgb666A5EngineB ||
        ((header.frame.bank >> 2) & 1u) != static_cast<u32>(swap))
        return false;
    const auto plane_bank = header.frame.bank & 1u;
    const auto screen_bank = (header.frame.bank >> 1) & 1u;
    const auto* published_plane = plane_bank ? bank1.data() : bank0.data();
    const auto* published_screen = engine_b_banks.data() +
        screen_bank * (EngineBBankStride / sizeof(u32));
    for (std::size_t index = 0; index < PlanePixels; ++index) {
        if (published_plane[index] != pack_melonds_pixel(plane[index]) ||
            published_screen[index] !=
                (pack_melonds_pixel(engine_b[index]) & 0x0003ffffu))
            return false;
    }
    return true;
}

} // namespace

int main()
{
    for (bool pixels_enabled : {false, true}) {
        if (!source_a_and_destination_offset(true, pixels_enabled) ||
            !source_b_fifo(true, pixels_enabled) ||
            !source_b_vram_offset(true, pixels_enabled) ||
            !blended_sources(true, pixels_enabled) ||
            !production_engine_b_source_b_capture(pixels_enabled)) {
            std::cerr << "FAIL: capture changed with Engine B pixels "
                      << pixels_enabled << '\n';
            return 1;
        }
    }
    if (!source_a_and_destination_offset()) {
        std::cerr << "FAIL: display capture source A or destination offset\n";
        return 1;
    }
    if (!source_b_fifo()) {
        std::cerr << "FAIL: display capture FIFO source B\n";
        return 1;
    }
    if (!source_b_vram_offset()) {
        std::cerr << "FAIL: display capture VRAM source B offset\n";
        return 1;
    }
    if (!production_engine_b_source_b_capture()) {
        std::cerr << "FAIL: Engine-B-only renderer skipped display capture\n";
        return 1;
    }
    if (!production_engine_b_source_a_capture(false) ||
        !production_engine_b_source_a_capture(true)) {
        std::cerr << "FAIL: Engine-B-only source-A capture differs from "
                     "the full-renderer oracle\n";
        return 1;
    }
    if (!blended_sources()) {
        std::cerr << "FAIL: display capture A+B blend\n";
        return 1;
    }
    if (!powcnt1_screen_swap()) {
        std::cerr << "FAIL: POWCNT1 physical-screen swap\n";
        return 1;
    }
    if (!production_engine_b_publication(false) ||
        !production_engine_b_publication(true)) {
        std::cerr << "FAIL: production Engine-B renderer/publication path\n";
        return 1;
    }
    std::cout << "PASS: DISPCAPCNT sources, offsets, RGB666-to-RGB555 "
                 "capture, blending, POWCNT1 screen swap, and production "
                 "Engine-B publication; Off/On capture equivalence\n";
    return 0;
}
