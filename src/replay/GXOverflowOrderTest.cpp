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

bool color_order(bool external, unsigned initial)
{
    auto nds = make_nds(external);
    auto& gx = nds->GPU.GPU3D;
    for (unsigned i = 0; i < initial; ++i)
        gx.WriteExternalNormalizedCommand(0x20, i);
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
           gx.CmdFIFO.IsEmpty() && gx.CmdStallQueue.IsEmpty();
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
}

int main()
{
    for (bool external : {false, true})
        if (!color_order(external, 600) || !color_order(external, 1400) ||
            !deferred_matrix(external)) return 1;
    std::puts("GX_OVERFLOW_ORDER_PASS ordinary_and_external=1 spill_and_stall=1 deferred_swap=1 partial_matrix=1");
}
