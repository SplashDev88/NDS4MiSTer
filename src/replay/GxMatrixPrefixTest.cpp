// SPDX-License-Identifier: GPL-3.0-or-later
#include "replay/GxMatrixPrefix.h"
#include "NDS.h"
#include "Args.h"
#include <cstdio>
#include <cstring>
#include <memory>
#include <optional>
#include <random>
#include <stdexcept>

namespace {
struct Probe {
    std::unique_ptr<melonDS::NDS> nds;
    nds4mister::replay::GxMatrixPrefix prefix;
    unsigned checks = 0;
    Probe() {
        melonDS::NDSArgs args; args.JIT = std::nullopt;
        nds = std::make_unique<melonDS::NDS>(std::move(args));
        nds->Reset(); nds->GPU.GPU3D.SetEnabled(true,true);
        nds->GPU.GPU3D.SetExternalCommandReplay(true);
    }
    void step() { nds->ARM9Timestamp += 65536; nds->GPU.GPU3D.Run(); }
    void command(unsigned tag, std::uint32_t data) {
        prefix.command(tag,data);
        nds->GPU.GPU3D.WriteExternalNormalizedCommand(tag,data); step();
    }
    void vblank() { nds->GPU.GPU3D.VBlank(); prefix.vblank(); }
    void compare() {
        step(); prefix.settle();
        if (!prefix.valid()) throw std::runtime_error("unexpected prefix fallback");
        const auto clip=prefix.clip(); const auto& vec=prefix.vector();
        for(unsigned i=0;i<16;++i)
            if(std::uint32_t(clip[i])!=nds->GPU.GPU3D.Read32(0x04000640+4*i)) {
                std::fprintf(stderr,"clip check=%u word=%u prefix=%08x oracle=%08x\n",
                    checks,i,std::uint32_t(clip[i]),nds->GPU.GPU3D.Read32(0x04000640+4*i));
                throw std::runtime_error("clip mismatch");
            }
        for(unsigned i=0;i<9;++i)
            if(std::uint32_t(vec[(i/3)*4+i%3])!=nds->GPU.GPU3D.Read32(0x04000680+4*i))
                throw std::runtime_error("vector mismatch");
        // Conservative busy is allowed; stack/IRQ/error state must be exact.
        constexpr std::uint32_t mask=0xc000bf02;
        if((prefix.status()&mask)!=(nds->GPU.GPU3D.Read32(0x04000600)&mask))
            throw std::runtime_error("stack status mismatch");
        ++checks;
    }
    void stat(unsigned addr,unsigned value,unsigned bytes) {
        prefix.gxstat(addr,value,bytes);
        if(bytes==1) nds->GPU.GPU3D.Write8(addr,value);
        else if(bytes==2) nds->GPU.GPU3D.Write16(addr,value);
        else nds->GPU.GPU3D.Write32(addr,value);
    }
};
}
namespace {
void audit_matrix_costs()
{
    Probe timing;
    auto& gpu = timing.nds->GPU.GPU3D;
    unsigned total_cases = 0;
    for (unsigned tag=0x11;tag<=0x1c;++tag) {
        const unsigned count = tag==0x16 || tag==0x18 ? 16 :
            tag==0x17 || tag==0x19 ? 12 : tag==0x1a ? 9 :
            tag==0x1b || tag==0x1c ? 3 : 1;
        const unsigned bound = tag<=0x15 ? 64 : 80;
        unsigned cases = 0, maximum = 0;
        auto test = [&](unsigned mode, int polygon, int vertex, int normal,
                        unsigned stack, unsigned value) {
            gpu.Timestamp = timing.nds->ARM9Timestamp = 0;
            gpu.CycleCount = 0;
            gpu.VertexPipeline = vertex; gpu.NormalPipeline = normal;
            gpu.PolygonPipeline = polygon;
            gpu.VertexSlotCounter = 0; gpu.VertexSlotsFree = 1;
            gpu.ExecParamCount = 0; gpu.MatrixMode = mode;
            gpu.ProjMatrixStackPointer = gpu.TexMatrixStackPointer = stack & 1;
            gpu.PosMatrixStackPointer = stack;
            for (auto* m : {gpu.ProjMatrix,gpu.PosMatrix,gpu.VecMatrix,gpu.TexMatrix})
                melonDS::MatrixLoadIdentity(m);
            unsigned cycles = 0;
            for (unsigned word=0;word<count;++word) {
                const std::uint32_t parameter = count==1 ? value :
                    value==0 ? 0u : value==1 ? 4096u :
                    word&1 ? 4096u : std::uint32_t(-4096);
                gpu.CycleCount = 0;
                gpu.WriteExternalNormalizedCommand(tag,parameter);
                gpu.Run();
                if (gpu.CycleCount<=0)
                    throw std::runtime_error("matrix audit command did not execute");
                cycles += gpu.CycleCount;
            }
            if (cycles>bound || gpu.ExecParamCount)
                throw std::runtime_error("matrix total cost bound exceeded or partial command left");
            maximum = std::max(maximum,cycles); ++cases;
        };
        for (unsigned mode=0;mode<4;++mode)
            for (int polygon=0;polygon<=35;++polygon)
                for (int vertex=0;vertex<=7;++vertex)
                    for (int normal=0;normal<=7;++normal)
                        if (count==1) {
                            for (unsigned stack : {0u,1u,30u,31u,32u,63u})
                                for (unsigned value : {0u,1u,31u,32u,63u,0xffffffffu})
                                    test(mode,polygon,vertex,normal,stack,value);
                        } else for (unsigned value=0;value<3;++value)
                            test(mode,polygon,vertex,normal,0,value);
        // All stack slots and signed six-bit pop offsets, including the
        // overflow/underflow transitions, with maximum pipeline delays.
        if (count==1)
            for (unsigned mode=0;mode<4;++mode)
                for (unsigned stack=0;stack<64;++stack)
                    for (unsigned value=0;value<64;++value)
                        test(mode,35,7,7,stack,value);
        if (gpu.GXCommandDrops) throw std::runtime_error("matrix audit lost commands");
        std::printf("GX_MATRIX_PREFIX_MATRIX_COST_TAG_PASS tag=%02x cases=%u max_total_cycles=%u bound=%u\n",tag,cases,maximum,bound);
        total_cases += cases;
    }
    std::printf("GX_MATRIX_PREFIX_MATRIX_COST_PASS cases=%u stack_bound=64 matrix_bound=80\n",total_cases);
}

void matrix_stream_regression()
{
    unsigned streams=0;
    for (unsigned mode=0;mode<4;++mode) {
        Probe stream;
        stream.command(0x10,mode); stream.command(0x15,0);
        stream.command(0x50,0);
        for (unsigned n=0;n<140;++n) {
            stream.command(0x11,0); stream.command(0x12,1);
            stream.command(0x1c,n+1); stream.command(0x1c,2);
            stream.command(0x1c,3);
        }
        if (!stream.prefix.valid())
            throw std::runtime_error("matrix-heavy eligible stream permanently fell back");
        stream.compare(); stream.vblank(); stream.compare();
        if ((stream.prefix.status() | stream.nds->GPU.GPU3D.Read32(0x04000600)) & 0x08000001u)
            throw std::runtime_error("matrix-heavy stream did not settle in one query step");
        ++streams;
    }
    // 370 complete translations consume 29970 of the 30000-cycle bound.
    // One extra parameter is still admitted, but must remain busy.
    Probe partial;
    partial.command(0x50,0);
    for (unsigned n=0;n<1111;++n) partial.command(0x1c,0);
    if (!partial.prefix.valid()) throw std::runtime_error("partial translation rejected early");
    partial.vblank();partial.compare();
    if (!(partial.prefix.status() & 0x08000000u))
        throw std::runtime_error("partial translation lost busy protection");
    nds4mister::replay::GxMatrixPrefix cap;
    cap.command(0x50,0);
    for (unsigned n=0;n<1112;++n) cap.command(0x1c,0);
    if (cap.valid() || cap.invalid_reason()!=3)
        throw std::runtime_error("matrix cost cap no longer enforced");
    std::printf("GX_MATRIX_PREFIX_MATRIX_STREAM_PASS streams=%u operations_per_stream=420 partial_busy=1 real_cost_overflow=1\n",streams);
}

void captured_burst_regression(const char* filename)
{
    // Captured pending words from the diagnostic, replayed from synthetic
    // identity matrices. This tests command ordering and one-query settling;
    // it does not reconstruct all of the game's prior geometry state.
    auto* input=std::fopen(filename,"r");
    if (!input) throw std::runtime_error("captured burst file missing");
    Probe stream;
    stream.command(0x10,1); stream.command(0x15,0); stream.command(0x50,0);
    unsigned tag=0,value=0,words=0;
    while (std::fscanf(input,"%x %x",&tag,&value)==2) {
        stream.command(tag,value); ++words;
        if (!stream.prefix.valid()) {
            std::fclose(input);
            throw std::runtime_error("captured burst still rejected");
        }
    }
    if (!std::feof(input)) { std::fclose(input); throw std::runtime_error("bad captured burst"); }
    std::fclose(input);
    stream.compare();stream.vblank();stream.compare();
    if ((stream.prefix.status() | stream.nds->GPU.GPU3D.Read32(0x04000600)) & 0x08000001u)
        throw std::runtime_error("captured burst did not settle in one query step");
    std::printf("GX_MATRIX_PREFIX_CAPTURED_BURST_PASS words=%u synthetic_initial_state=1\n",words);
}
}

int main(int argc, char** argv) try {
    if (argc==3 && std::strcmp(argv[1],"--captured-burst")==0) {
        captured_burst_regression(argv[2]); return 0;
    }
    if (argc==1 || (argc==2 && std::strcmp(argv[1],"--matrix-cost-audit")==0)) {
        audit_matrix_costs(); matrix_stream_regression();
        if (argc==2) return 0;
    }
    // VTX_16's first word may wait for a polygon slot, while its second
    // word completes the vertex. Audit total command work, including slot
    // patterns broader than the reachable geometry states. A zero-length
    // polygon pipeline with no free slot is not a valid state.
    if (!(argc==2 && std::strcmp(argv[1],"--vertex-stream-regression")==0)) {
        Probe timing;
        auto& gpu = timing.nds->GPU.GPU3D;
        unsigned cases = 0, maximum = 0, first_word_maximum = 0;
        for (unsigned tag=0x23;tag<=0x28;++tag)
            for (int polygon=0;polygon<=35;++polygon)
                for (int counter=0;counter<=9;++counter)
                    for (unsigned slots=0;slots<32;++slots)
                        for (int vertex=0;vertex<=7;++vertex)
                            for (int normal=0;normal<=7;++normal) {
                                if (polygon==0 && !(slots&1)) continue;
                                gpu.Timestamp = timing.nds->ARM9Timestamp = 0;
                                gpu.CycleCount = 0;
                                gpu.VertexPipeline = vertex;
                                gpu.NormalPipeline = normal;
                                gpu.PolygonPipeline = polygon;
                                gpu.VertexSlotCounter = counter;
                                gpu.VertexSlotsFree = slots;
                                gpu.ExecParamCount = 0;
                                gpu.NumVertices = gpu.NumPolygons = 0;
                                gpu.VertexNum = gpu.VertexNumInPoly = 0;
                                gpu.NumConsecutivePolygons = 0;
                                gpu.PolygonMode = 0;
                                gpu.LastStripPolygon = nullptr;
                                gpu.WriteExternalNormalizedCommand(tag,0);
                                gpu.Run();
                                unsigned cycles = gpu.CycleCount;
                                first_word_maximum = std::max(first_word_maximum,cycles);
                                if (tag==0x23) {
                                    gpu.CycleCount = 0;
                                    gpu.WriteExternalNormalizedCommand(tag,0);
                                    gpu.Run();
                                    cycles += gpu.CycleCount;
                                }
                                if (cycles==0 || cycles>64 || gpu.ExecParamCount!=0)
                                    throw std::runtime_error("vertex total cost bound exceeded or partial command left");
                                maximum = std::max(maximum,cycles);
                                ++cases;
                            }
        if (gpu.GXCommandDrops) throw std::runtime_error("vertex audit lost commands");
        std::printf("GX_MATRIX_PREFIX_VERTEX_COST_PASS cases=%u max_total_cycles=%u max_first_word_cycles=%u total_bound=64\n",cases,maximum,first_word_maximum);
        if (argc==2 && std::strcmp(argv[1],"--vertex-cost-audit")==0) return 0;
    }

    // A vertex-heavy tail behind SWAP previously consumed the entire
    // eligibility budget although the real renderer drains it within one
    // query clock step. Exercise every vertex format and primitive mode,
    // then change the matrix so equality proves the whole tail executed.
    {
        unsigned streams=0;
        for (unsigned tag=0x23;tag<=0x28;++tag)
            for (unsigned mode=0;mode<4;++mode) {
                Probe stream;
                stream.command(0x10,0);stream.command(0x15,0);
                stream.command(0x10,2);stream.command(0x15,0);
                stream.command(0x29,0x001f00c0);stream.command(0x40,mode);
                stream.command(0x50,0);
                for (unsigned v=0;v<360;++v) {
                    stream.command(0x22,v*0x10001u);
                    stream.command(tag,(v*977u)^0x08000800u);
                    if (tag==0x23) stream.command(tag,v*133u);
                }
                stream.command(0x10,2);stream.command(0x15,0);
                stream.command(0x1c,1234+tag);stream.command(0x1c,5678+mode);
                stream.command(0x1c,9012);
                if (!stream.prefix.valid())
                    throw std::runtime_error("vertex-heavy eligible stream permanently fell back");
                stream.compare();stream.vblank();stream.compare();
                if ((stream.prefix.status() | stream.nds->GPU.GPU3D.Read32(0x04000600)) & 0x08000001u)
                    throw std::runtime_error("vertex-heavy stream did not settle in one query step");
                ++streams;
            }
        Probe partial;
        partial.command(0x50,0);
        for(unsigned n=0;n<468;++n) {
            partial.command(0x23,0);partial.command(0x23,0);
        }
        partial.command(0x23,0);
        if (!partial.prefix.valid()) throw std::runtime_error("near-budget partial vertex rejected early");
        partial.vblank();partial.compare();
        if (!(partial.prefix.status() & 0x08000000u))
            throw std::runtime_error("partial VTX_16 lost busy protection");
        auto cap=nds4mister::replay::GxMatrixPrefix{};
        cap.command(0x50,0);
        for(unsigned n=0;n<938;++n) cap.command(0x23,0);
        if(cap.valid() || cap.invalid_reason()!=3)
            throw std::runtime_error("VTX_16 cost cap no longer enforced");
        std::printf("GX_MATRIX_PREFIX_VERTEX_STREAM_PASS streams=%u vertices_per_stream=360 partial_busy=1 real_cost_overflow=1\n",streams);
        if (argc==2 && std::strcmp(argv[1],"--vertex-stream-regression")==0) return 0;
    }
    // The settled no-op shortcut must agree with actual geometry readback,
    // including after deferred work and around partial-command boundaries.
    {
        constexpr unsigned ignored[] = {0x20,0x21,0x22,0x24,0x25,0x26,0x27,0x28};
        Probe fast;
        fast.command(0x10,2); fast.command(0x15,0);
        fast.command(0x1c,123); fast.command(0x1c,456); fast.command(0x1c,789);
        for (unsigned iteration=0;iteration<128;++iteration) {
            for (auto tag:ignored) {
                fast.command(tag,iteration*0x010203u); fast.compare();
            }
            fast.command(0x50,0);
            fast.command(0x10,2); fast.command(0x1c,iteration);
            fast.command(0x1c,1); fast.command(0x1c,2);
            for (auto tag:ignored) fast.command(tag,iteration);
            fast.compare(); fast.vblank(); fast.compare();
        }
        for (auto partial : {0x16u,0x23u,0x34u,0x70u,0x71u})
            for (auto tag:ignored) {
                nds4mister::replay::GxMatrixPrefix malformed;
                malformed.command(partial,123);
                malformed.command(tag,456);
                if (malformed.valid() || malformed.invalid_reason()!=2 ||
                    malformed.invalid_tag()!=tag || malformed.invalid_partial()!=partial)
                    throw std::runtime_error("settled shortcut bypassed partial-command rejection");
            }
        std::printf("GX_MATRIX_PREFIX_SETTLED_PASS comparisons=%u partial_rejections=40\n",fast.checks);
    }
    // Check the proposed inexpensive-command bound against the real replay
    // owner, including every possible normal/vertex delay and light mask.
    // These commands never wait for polygon completion. Leave expensive
    // matrix, vertex, SWAP and BOX_TEST bounds unchanged.
    {
        Probe timing;
        auto& gpu = timing.nds->GPU.GPU3D;
        const unsigned cheap[] = {0x00,0x10,0x20,0x21,0x22,0x29,0x2a,
                                  0x2b,0x30,0x31,0x33,0x41,0x60};
        unsigned checked = 0, maximum = 0;
        for (auto tag : cheap)
            for (int vertex=0;vertex<=7;++vertex)
                for (int normal=0;normal<=7;++normal)
                    for (int polygon : {0,35})
                        for (unsigned lights=0;lights<16;++lights) {
                            gpu.Timestamp = timing.nds->ARM9Timestamp = 0;
                            gpu.CycleCount = 0;
                            gpu.VertexPipeline = vertex;
                            gpu.NormalPipeline = normal;
                            gpu.PolygonPipeline = polygon;
                            gpu.CurPolygonAttr = lights;
                            gpu.WriteExternalNormalizedCommand(tag,0x12345678);
                            gpu.Run();
                            if (gpu.CycleCount <= 0 || gpu.CycleCount > 16)
                                throw std::runtime_error("inexpensive GX cost bound exceeded");
                            maximum = std::max(maximum,unsigned(gpu.CycleCount));
                            ++checked;
                        }
        if (gpu.GXCommandDrops) throw std::runtime_error("timing probe lost commands");
        std::printf("GX_MATRIX_PREFIX_COST_PASS cases=%u max_cycles=%u bound=16\n",
                    checked,maximum);
    }
    Probe p; std::mt19937 random(0x234a06);
    // Compare independent position-only BOX_TEST with the unchanged GPU's
    // original clipping implementation, including every incomplete command.
    for (unsigned n=0;n<6000;++n) {
        p.command(0x10,0); p.command(0x15,0);
        p.command(0x10,2); p.command(0x15,0);
        p.command(0x29,(n&1)?0x1000:0); p.command(0x40,0);
        if(n>=4) {
            for(unsigned i=0;i<16;++i) {
                const std::uint32_t value=(i%5==0)?(1024+random()%8193):
                    (i>=12 ? std::int32_t(random()%32769)-16384 : 0);
                p.command(0x16,value);
            }
        }
        const std::uint32_t cases[4][3]={{0,0x08000000,0x08000800},
            {0x00002000,0x08000000,0x08000800},
            {0xf800f800,0x1000f800,0x10001000},
            {0,0x08002000,0x08000800}};
        for(unsigned j=0;j<3;++j) { p.command(0x70,n<4?cases[n][j]:random()); p.compare(); }
        if(n==0 && !(p.prefix.status()&2)) throw std::runtime_error("visible box rejected");
        if(n==1 && (p.prefix.status()&2)) throw std::runtime_error("outside box accepted");
        if(n%23==0) {
            p.command(0x50,0);
            for(unsigned j=0;j<3;++j) p.command(0x70,cases[0][j]);
            p.compare(); p.vblank(); p.compare();
        }
    }
    p.prefix.reset(); p.nds->GPU.GPU3D.Reset();
    p.nds->GPU.GPU3D.SetEnabled(true,true);
    p.nds->GPU.GPU3D.SetExternalCommandReplay(true);
    const unsigned tags[]={0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,0x19,0x1a,0x1b,0x1c};
    for(unsigned n=0;n<12000;++n) {
        const auto tag=tags[random()%13];
        unsigned count=1;
        if(tag==0x16||tag==0x18)count=16;
        if(tag==0x17||tag==0x19)count=12;
        if(tag==0x1a)count=9;
        if(tag==0x1b||tag==0x1c)count=3;
        for(unsigned i=0;i<count;++i) {
            p.command(tag,tag<0x16?random():(random()%32769)-16384);
            p.compare(); // Includes every incomplete matrix prefix.
        }
        if(n%17==0) {
            p.command(0x50,0);
            p.command(0x10,2); p.command(0x15,0);
            p.compare(); // Must still expose pre-SWAP matrices.
            p.vblank(); p.compare();
        }
        if(n%29==0) { p.stat(0x04000601,0x80,1); p.compare(); }
        if(n%31==0) { p.stat(0x04000600,0xc0008000,4); p.compare(); }
        if(n%37==0) { p.stat(0x04000602,0x4000,2); p.compare(); }
    }
    // Pending commands, signed stack pop, status writes after VBlank before
    // fresh geometry time, disabled geometry and reset.
    p.command(0x50,0);p.command(0x10,0);p.command(0x11,0);
    p.vblank();p.stat(0x04000601,0x80,1);p.compare();
    p.command(0x50,0);p.command(0x10,2);p.command(0x15,0);
    p.prefix.power(0x04000304,0,2);p.nds->GPU.GPU3D.SetEnabled(false,false);
    p.command(0x10,0);p.command(0x15,0);p.vblank();p.compare();
    p.prefix.power(0x04000305,0xff,1);p.compare();
    p.prefix.power(0x04000304,12,2);p.nds->GPU.GPU3D.SetEnabled(true,true);
    p.vblank();p.compare();
    // FFTA2's startup can initialize the matrix stack behind SWAP. A word
    // count of 512 wrongly disabled fast replies on otherwise valid boots.
    p.command(0x50,0);
    for (unsigned n=0;n<40;++n) {
        for (unsigned i=0;i<16;++i)
            p.command(0x16,(i%5==0)?4096:(i==12?n:0));
        p.command(0x13,n%31);
    }
    p.compare(); // 680 words remain held until VBlank.
    p.vblank(); p.compare(); // One ordinary query clock step is sufficient.
    // A texture/state-heavy draw queued behind SWAP must not permanently
    // disable fast replies merely because a cheap command was charged like
    // vertex submission. Exercise almost the full 30,000-cycle bound, with
    // lighting and vertices mixed in, then prove the final matrix is visible
    // after exactly one ordinary query step in the unchanged oracle.
    for (unsigned mode=0;mode<4;++mode) {
        p.command(0x29,0x001f00cf);p.command(0x40,mode);
        p.command(0x50,0);
        const unsigned cheap[] = {0x00,0x10,0x20,0x21,0x22,0x29,0x2a,
                                  0x2b,0x30,0x31,0x33,0x41,0x60};
        for (unsigned n=0;n<180;++n) {
            p.command(cheap[n%13],random());
            p.command(0x22,random());
            p.command(0x24,random());
        }
        p.command(0x10,2);p.command(0x15,0);
        p.command(0x1c,1234);p.command(0x1c,5678);p.command(0x1c,9012);
        p.compare();p.vblank();p.compare();
    }
    // Exercise near-budget expensive BOX_TEST work and a long single-word
    // command burst, then make a matrix change whose visibility proves that
    // the real geometry engine also reached the end in one query clock step.
    for (bool boxes : {false, true}) {
        p.command(0x50,0);
        for (unsigned n=0;n<(boxes?56u:220u);++n) {
            if (boxes) {
                p.command(0x70,0);p.command(0x70,0x01000000);p.command(0x70,0x01000100);
            } else p.command(0x20,n);
        }
        p.command(0x10,2);p.command(0x15,0);
        p.command(0x1c,1234);p.command(0x1c,5678);p.command(0x1c,9012);
        p.compare();p.vblank();p.compare();
    }
    // A steady stream can leave the next frame's first command behind each
    // SWAP forever. Retired vector entries must not exhaust the pending-word
    // bound even though the small live tail never becomes completely empty.
    {
        Probe streaming;
        streaming.command(0x50,0);
        for (unsigned frame=0;frame<1200;++frame) {
            streaming.command(0x10,2);streaming.command(0x15,0);
            streaming.command(0x1c,frame);streaming.command(0x1c,123);
            streaming.command(0x1c,456);streaming.command(0x50,0);
            streaming.command(0x20,frame & 0x7fff);
            streaming.vblank();streaming.compare();
        }
        if (streaming.prefix.deferred_peak() > 8)
            throw std::runtime_error("retired words counted as pending work");
        std::printf("GX_MATRIX_PREFIX_STREAM_PASS frames=1200 comparisons=%u\n",
                    streaming.checks);
    }
    auto fallback=nds4mister::replay::GxMatrixPrefix{};
    fallback.command(0x16,123);fallback.command(0x10,2);
    if(fallback.valid())throw std::runtime_error("mixed partial command not rejected");
    fallback.reset();fallback.command(0x50,0);
    for(unsigned i=0;i<513;++i)fallback.command(0x24,i);
    if(fallback.valid() || fallback.invalid_reason()!=3)
        throw std::runtime_error("expensive deferred work cap not enforced");
    fallback.reset();fallback.command(0x50,0);
    for(unsigned i=0;i<1876;++i)fallback.command(0x22,i);
    if(fallback.valid() || fallback.invalid_reason()!=3)
        throw std::runtime_error("inexpensive deferred work cap not enforced");
    fallback.reset();fallback.command(0x50,0);
    for(unsigned i=0;i<4097;++i)fallback.command(0x34,0);
    if(fallback.valid() || fallback.invalid_reason()!=1)
        throw std::runtime_error("live deferred word cap not enforced");
    fallback.reset();if(!fallback.valid())throw std::runtime_error("reset fallback");
    std::printf("GX_MATRIX_PREFIX_PASS comparisons=%u matrix_stack_partial_swap_power=1 bounded_fallback=1\n",p.checks);
} catch(const std::exception& e) { std::fprintf(stderr,"FAIL: %s\n",e.what());return 1; }
