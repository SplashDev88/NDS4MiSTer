// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise the actual geometry queues across deferred SWAP_BUFFERS, spills,
// and a new burst arriving while an older matrix is only partly executed.
#include "Args.h"
#include "NDS.h"

#include <cstdio>
#include <memory>
#include <optional>

namespace {
using melonDS::u32;

std::unique_ptr<melonDS::NDS> make_nds(bool external)
{
    melonDS::NDSArgs args;
    args.JIT = std::nullopt;
    auto nds = std::make_unique<melonDS::NDS>(std::move(args));
    nds->Reset();
    nds->GPU.GPU3D.SetEnabled(true, true);
    nds->GPU.GPU3D.SetExternalCommandReplay(external);
    return nds;
}

bool color_order(bool external, unsigned initial, bool ordinary_tail = false)
{
    auto nds = make_nds(external);
    auto& gx = nds->GPU.GPU3D;
    if (ordinary_tail) gx.SetExternalCommandReplay(false);
    for (unsigned i = 0; i < initial; ++i) {
        // A pre-existing ordinary FIFO tail prevents the contiguous replay
        // bank from accepting this burst. Preserve every command in order.
        if (ordinary_tail && i == 100) gx.SetExternalCommandReplay(true);
        gx.WriteExternalNormalizedCommand(0x20, i);
    }
    if (ordinary_tail && gx.ExternalOverflowPeak == 0) return false;
    for (unsigned i = 0; i < initial + 3; ++i)
    {
        if (i == 512)
            gx.WriteExternalNormalizedCommandTriple(
                0x202020, initial, initial + 1, initial + 2);
        gx.ExecuteCommand();
        const u32 got = gx.VertexColor[0] | (gx.VertexColor[1] << 5) |
                        (gx.VertexColor[2] << 10);
        if (got != i)
        {
            std::fprintf(stderr, "GX order external=%d depth=%u expected=%u got=%u\n",
                         external, initial, i, got);
            return false;
        }
    }
    return gx.GXCommandDrops == 0 && gx.CmdPIPE.IsEmpty() &&
           gx.CmdFIFO.IsEmpty() && gx.CmdStallQueue.IsEmpty() &&
           gx.ExternalOverflow.empty();
}

bool overflow_reset()
{
    auto nds = make_nds(false);
    auto& gx = nds->GPU.GPU3D;
    for (unsigned i = 0; i < 30000; ++i) {
        if (i == 100) gx.SetExternalCommandReplay(true);
        gx.WriteExternalNormalizedCommand(0x20, i);
    }
    if (gx.ExternalOverflow.empty()) return false;
    gx.Reset();
    if (!gx.ExternalOverflow.empty() || gx.ExternalOverflowPeak != 0 ||
        !gx.CmdPIPE.IsEmpty() || !gx.CmdFIFO.IsEmpty() ||
        !gx.CmdStallQueue.IsEmpty()) return false;
    gx.SetEnabled(true, true);
    gx.SetExternalCommandReplay(true);
    gx.WriteExternalNormalizedCommand(0x20, 123);
    gx.ExecuteCommand();
    const u32 color = gx.VertexColor[0] | (gx.VertexColor[1] << 5) |
                      (gx.VertexColor[2] << 10);
    return color == 123 && gx.CmdPIPE.IsEmpty() && gx.ExternalOverflow.empty();
}

bool deferred_matrix(bool external)
{
    auto nds = make_nds(external);
    auto& gx = nds->GPU.GPU3D;
    gx.WriteExternalNormalizedCommand(0x50, 0);
    nds->ARM9Timestamp += 65536;
    gx.Run();
    if (!gx.FlushRequest) return false;
    for (unsigned i = 0; i < 510; ++i)
        gx.WriteExternalNormalizedCommand(0x20, i);
    for (unsigned i = 0; i < 16; ++i)
        gx.WriteExternalNormalizedCommand(0x16, 100 + i);
    for (unsigned i = 526; i < 600; ++i)
        gx.WriteExternalNormalizedCommand(0x20, i);
    nds->ARM9Timestamp += 65536;
    gx.Run();
    // The queued matrix must remain untouched until the pending swap releases.
    if (gx.ExecParamCount || !gx.FlushRequest) return false;
    gx.VBlank();
    for (unsigned i = 0; i < 512; ++i) gx.ExecuteCommand();
    if (gx.ExecParamCount != 2) return false;
    for (unsigned i = 0; i < 16; ++i)
        gx.WriteExternalNormalizedCommand(0x16, 200 + i);
    for (unsigned i = 512; i < 616; ++i) gx.ExecuteCommand();
    for (unsigned i = 0; i < 16; ++i)
        if (gx.ProjMatrix[i] != static_cast<int>(200 + i))
        {
            std::fprintf(stderr, "GX matrix external=%d index=%u expected=%u got=%d\n",
                         external, i, 200 + i, gx.ProjMatrix[i]);
            return false;
        }
    // Once the old tail drains, the normal fast-bank case must work again.
    gx.WriteExternalNormalizedCommand(0x20, 777);
    nds->ARM9Timestamp += 65536;
    gx.Run();
    const u32 color = gx.VertexColor[0] | (gx.VertexColor[1] << 5) |
                      (gx.VertexColor[2] << 10);
    return color == 777 && gx.ExecParamCount == 0 && gx.GXCommandDrops == 0 &&
           gx.CmdPIPE.IsEmpty() && gx.CmdFIFO.IsEmpty() && gx.CmdStallQueue.IsEmpty();
}

bool large_deferred_burst(unsigned colors)
{
    auto nds = make_nds(true);
    auto& gx = nds->GPU.GPU3D;
    gx.WriteExternalNormalizedCommand(0x50, 0);
    nds->ARM9Timestamp += 65536;
    gx.Run();
    if (!gx.FlushRequest) return false;
    for (unsigned i = 0; i < colors; ++i)
        gx.WriteExternalNormalizedCommand(0x20, i & 0x7fff);
    // Put a two-word vertex across the old total capacity (17,156 entries).
    // Losing its second word leaves a parameter that shifts every subsequent
    // projection load, as observed in SM64 DS on the board.
    gx.WriteExternalNormalizedCommand(0x23, 0x12345678);
    gx.WriteExternalNormalizedCommand(0x23, 0x00010000);
    if (gx.GXCommandDrops)
    {
        std::fprintf(stderr, "GX deferred burst=%u dropped=%llu\n", colors,
                     static_cast<unsigned long long>(gx.GXCommandDrops));
        return false;
    }
    nds->ARM9Timestamp += 65536;
    gx.Run();
    if (!gx.FlushRequest || gx.ExecParamCount) return false;
    gx.VBlank();
    for (unsigned i = 0; i < colors; ++i)
    {
        gx.ExecuteCommand();
        const u32 got = gx.VertexColor[0] | (gx.VertexColor[1] << 5) |
                        (gx.VertexColor[2] << 10);
        if (got != (i & 0x7fff)) return false;
    }
    gx.ExecuteCommand();
    if (gx.ExecParamCount != 1) return false;
    // Append while the previous vertex remains partially executed.
    constexpr melonDS::s32 projection[16] = {
        719,0,0,0, 0,959,0,0, 0,0,-256,-256, 0,0,-512,0};
    gx.WriteExternalNormalizedCommand(0x10, 0);
    for (const auto word : projection)
        gx.WriteExternalNormalizedCommand(0x16, static_cast<u32>(word));
    gx.ExecuteCommand(); // second vertex word, before the new matrix
    if (gx.ExecParamCount != 0 || gx.CurVertex[0] != 0x5678 ||
        gx.CurVertex[1] != 0x1234 || gx.CurVertex[2] != 0) return false;
    for (unsigned i = 0; i < 17; ++i) gx.ExecuteCommand();
    for (unsigned i = 0; i < 16; ++i)
        if (gx.ProjMatrix[i] != projection[i]) return false;
    if (gx.ExecParamCount || gx.GXCommandDrops) return false;
    gx.Reset();
    gx.SetEnabled(true, true);
    gx.SetExternalCommandReplay(true);
    gx.WriteExternalNormalizedCommand(0x20, 777);
    nds->ARM9Timestamp += 65536;
    gx.Run();
    const u32 color = gx.VertexColor[0] | (gx.VertexColor[1] << 5) |
                      (gx.VertexColor[2] << 10);
    return color == 777 && gx.GXCommandDrops == 0 && gx.ExecParamCount == 0;
}
}

int main()
{
    for (bool external : {false, true})
        if (!color_order(external, 600) || !color_order(external, 1400) ||
            !color_order(external, 2048) ||
            !deferred_matrix(external)) return 1;
    if (!color_order(true, 30000) || !color_order(true, 30000, true)) return 1;
    if (!overflow_reset()) return 1;
    for (unsigned colors : {17155u, 30000u, 35000u, 42000u, 70000u})
        if (!large_deferred_burst(colors)) return 1;
    std::puts("GX_OVERFLOW_ORDER_PASS ordinary_and_external=1 spill_and_stall=1 deferred_swap=1 partial_matrix=1 large_burst=70000 ordinary_tail_overflow=1 overflow_reset=1 reset=1");
}
