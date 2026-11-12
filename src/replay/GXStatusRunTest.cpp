// SPDX-License-Identifier: GPL-3.0-or-later
// Compare actual replay against the pre-optimization Run loop, including
// externally visible busy flags at incomplete commands and SWAP boundaries.
#include "Args.h"
#include "NDS.h"
#include <cstdio>
#include <cstring>
#include <memory>
#include <optional>
#include <stdexcept>

namespace {
using namespace melonDS;
std::unique_ptr<NDS> make_nds(bool external)
{
    NDSArgs args; args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args));
    nds->Reset();
    nds->GPU.GPU3D.SetEnabled(true, true);
    nds->GPU.GPU3D.SetExternalCommandReplay(external);
    return nds;
}

// Frozen Beta10 behavior, intentionally retaining unconditional status stores.
void reference_run(NDS& nds)
{
    auto& gx = nds.GPU.GPU3D;
    auto empty = [&]() { return gx.ExternalCommandReplay ?
        gx.ExternalCommandsEmpty() : gx.CmdPIPE.IsEmpty(); };
    const auto now = nds.ARM9Timestamp >> nds.ARM9ClockShift;
    if (!gx.GeometryEnabled || gx.FlushRequest ||
        (empty() && !(gx.GXStat & (1u << 27)))) {
        gx.Timestamp = now;
        return;
    }
    gx.CycleCount -= static_cast<s32>(now - gx.Timestamp);
    gx.Timestamp = now;
    while (gx.CycleCount <= 0 && !empty()) {
        if (gx.NumPushPopCommands == 0) gx.GXStat &= ~(1u << 14);
        if (gx.NumTestCommands == 0) gx.GXStat &= ~1u;
        gx.ExecuteCommand();
    }
    if (gx.CycleCount <= 0 && empty()) {
        if (gx.GXStat & (1u << 27)) gx.FinishWork(-gx.CycleCount);
        else gx.CycleCount = 0;
        if (gx.NumPushPopCommands == 0) gx.GXStat &= ~(1u << 14);
        if (gx.NumTestCommands == 0) gx.GXStat &= ~1u;
    }
}

struct Pair {
    std::unique_ptr<NDS> reference, candidate;
    unsigned checks = 0, states = 0;
    explicit Pair(bool external) : reference(make_nds(external)), candidate(make_nds(external)) {}
    void compare() {
        const auto& a = reference->GPU.GPU3D;
        const auto& b = candidate->GPU.GPU3D;
#define SAME(field) if (std::memcmp(&a.field, &b.field, sizeof(a.field))) { \
        std::fprintf(stderr, "GX state mismatch check=%u field=%s\n", checks, #field); \
        throw std::runtime_error("state mismatch"); }
        SAME(GXStat); SAME(CycleCount); SAME(Timestamp);
        SAME(NumPushPopCommands); SAME(NumTestCommands);
        SAME(ExecParamCount); SAME(ExecParams); SAME(FlushRequest);
        SAME(VertexPipeline); SAME(NormalPipeline); SAME(PolygonPipeline);
        SAME(VertexSlotCounter); SAME(VertexSlotsFree);
        SAME(ProjMatrix); SAME(PosMatrix); SAME(VecMatrix); SAME(TexMatrix);
        SAME(ProjMatrixStack); SAME(PosMatrixStack); SAME(VecMatrixStack); SAME(TexMatrixStack);
        SAME(ProjMatrixStackPointer); SAME(PosMatrixStackPointer); SAME(TexMatrixStackPointer);
        SAME(PosTestResult); SAME(VecTestResult); SAME(CurVertex); SAME(VertexColor);
        SAME(ExternalBatchRead); SAME(ExternalBatchCount); SAME(GXCommandDrops);
#undef SAME
        if (a.CmdPIPE.Level() != b.CmdPIPE.Level() ||
            a.CmdFIFO.Level() != b.CmdFIFO.Level() ||
            a.CmdStallQueue.Level() != b.CmdStallQueue.Level() ||
            a.ExternalOverflow.size() != b.ExternalOverflow.size())
            throw std::runtime_error("queue mismatch");
        states |= 1u << ((a.GXStat & 1u) | ((a.GXStat >> 13) & 2u));
        ++checks;
    }
    void step(unsigned cycles) {
        reference->ARM9Timestamp += u64(cycles) << reference->ARM9ClockShift;
        candidate->ARM9Timestamp += u64(cycles) << candidate->ARM9ClockShift;
        reference_run(*reference); candidate->GPU.GPU3D.Run(); compare();
    }
    void command(u8 tag, u32 value) {
        reference->GPU.GPU3D.WriteExternalNormalizedCommand(tag, value);
        candidate->GPU.GPU3D.WriteExternalNormalizedCommand(tag, value);
        compare();
    }
    void swap_end() {
        reference->GPU.GPU3D.VBlank(); candidate->GPU.GPU3D.VBlank(); compare();
    }
    void enabled(bool on) {
        reference->GPU.GPU3D.SetEnabled(on, on);
        candidate->GPU.GPU3D.SetEnabled(on, on); compare();
    }
};
}

int main() try {
    unsigned checks = 0;
    for (bool external : {false, true}) {
        Pair p(external);
        // Interleave complete and partial stack/query commands with color work.
        // Step with zero, partial and generous budgets, including empty drains.
        constexpr unsigned budgets[] = {0, 1, 4, 16, 48, 65536};
        for (unsigned round = 0; round < 96; ++round) {
            p.command(0x10, round & 3);
            p.command(0x15, 0);
            p.command(0x11, 0);
            p.command(0x70, 0);
            p.step(budgets[round % 6]);
            p.command(0x70, 0x08000000);
            p.step(budgets[(round + 1) % 6]);
            p.command(0x70, 0x08000800);
            p.command(0x12, 1);
            p.command(0x71, 0x12345678);
            p.step(budgets[(round + 2) % 6]);
            p.command(0x71, 0x00001111);
            p.command(0x72, round * 123);
            for (unsigned i = 0; i < (round % 3 == 0 ? 600u : 13u); ++i)
                p.command(0x20, (round + i) & 0x7fff);
            p.step(65536); p.step(65536);
            p.command(0x50, 0); p.step(65536);
            p.command(0x11, 0);
            p.command(0x71, round); p.step(65536);
            p.command(0x71, 123); p.swap_end();
            p.step(1); p.step(65536); p.step(65536);
            if (round % 8 == 0) {
                p.enabled(false); p.command(0x11, 0); p.step(65536);
                p.enabled(true); p.step(65536);
            }
            if (round % 16 == 0) {
                p.reference->GPU.GPU3D.Reset(); p.candidate->GPU.GPU3D.Reset();
                p.enabled(true);
                p.reference->GPU.GPU3D.SetExternalCommandReplay(external);
                p.candidate->GPU.GPU3D.SetExternalCommandReplay(external);
                p.compare(); p.step(65536);
            }
        }
        if (p.states != 15) throw std::runtime_error("did not cover all four busy-flag states");
        checks += p.checks;
    }
    std::printf("GX_STATUS_RUN_EQUIVALENCE_PASS checks=%u ordinary_and_external=1 busy_states=4 partial_queries=1 stack=1 deferred_swap=1 reset=1 exact_cycles=1\n", checks);
} catch (const std::exception& e) {
    std::fprintf(stderr, "%s\n", e.what()); return 1;
}
