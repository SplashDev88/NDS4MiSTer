// SPDX-License-Identifier: GPL-3.0-or-later
#include "replay/GxMatrixPrefix.h"
#include "NDS.h"
#include "Args.h"
#include <cstdio>
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
int main() try {
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
    for(unsigned i=0;i<513;++i)fallback.command(0x20,i);
    if(fallback.valid())throw std::runtime_error("excess deferred queue not rejected");
    fallback.reset();fallback.command(0x50,0);
    for(unsigned i=0;i<4097;++i)fallback.command(0x34,0);
    if(fallback.valid() || fallback.invalid_reason()!=1)
        throw std::runtime_error("live deferred word cap not enforced");
    fallback.reset();if(!fallback.valid())throw std::runtime_error("reset fallback");
    std::printf("GX_MATRIX_PREFIX_PASS comparisons=%u matrix_stack_partial_swap_power=1 bounded_fallback=1\n",p.checks);
} catch(const std::exception& e) { std::fprintf(stderr,"FAIL: %s\n",e.what());return 1; }
