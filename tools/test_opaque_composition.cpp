// Synthetic compositor regression test. Compare actual scanline output with the unchanged
// scalar ColorComposite on the exact generated top/second layers and windows.
#include <bits/stdc++.h>
#include <time.h>
#define private public
#include "NDS.h"
#include "GPU_Soft.h"
#include "GPU2D_Soft.h"
#undef private
using namespace melonDS;
static u32 seed = 0x29c05a7u;
static u32 rnd() { seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; return seed; }
static double seconds(clockid_t id) { timespec t{}; clock_gettime(id, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
int main(int argc, char** argv) try {
    unsetenv("NDS4MISTER_DUAL_CORE_3D");
    NDSArgs args; args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args)); nds->Reset();
    auto& gpu = nds->GPU;
    auto& parent = static_cast<SoftRenderer&>(gpu.GetRenderer());
    alignas(16) std::array<u32,256> threeD{}, out{};
    parent.Output3D = threeD.data();
    gpu.ScreensEnabled = true;
    unsigned long long checks=0, passthroughCases=0, opaquePairs=0, partialNegative=0, effectNegative=0;
    u64 hash = 1469598103934665603ULL;
    const bool bench = argc > 1 && std::string(argv[1]) == "--bench";
    unsigned scenario = bench ? std::stoul(argv[2]) : 0;
    unsigned iterations = bench ? std::stoul(argv[3]) : 0;
    for (unsigned mode=0; mode<8; ++mode) {
        if (bench && mode != scenario) continue;
        auto& e = mode < 4 ? gpu.GPU2D_A : gpu.GPU2D_B;
        SoftRenderer2D r(e,parent);
        const unsigned mode4=mode%4;
        e.Enabled = true; e.ForcedBlank = false;
        e.DispCnt = 0x00010000u | (mode<4 ? 8u : 0u) | (mode4==3 ? 0xE000u : 0u);
        e.LayerEnable = (mode<4 ? 1u : 0u) | (mode4>=2 ? 0x10u : 0u);
        e.OBJEnable = mode4>=2;
        e.Win0Coords[0]=17; e.Win0Coords[1]=193;
        e.Win1Coords[0]=224; e.Win1Coords[1]=9;
        e.Win0Active=1; e.Win1Active=1;
        e.WinCnt[0]=0x3f; e.WinCnt[1]=0x11; e.WinCnt[2]=0x20; e.WinCnt[3]=0x01;
        e.BGMosaicSize[0]=e.BGMosaicSize[1]=0;
        e.OBJMosaicSize[0]=e.OBJMosaicSize[1]=0;
        r.NumSprites = mode4>=2 ? 16 : 0;
        for (auto& x: gpu.Palette) x=rnd();
        for (unsigned x=0;x<256;++x) {
            u32 alpha=31;
            if (mode4==1) alpha=x%3 ? 31 : 0;
            if (mode4>=2) alpha=x%32;
            threeD[x]=(rnd()&0x003f3f3fu)|(alpha<<24);
            const u32 flags[] = {0x10000000u,0x80000000u,0xc0000000u,0xcf000000u};
            r.OBJLine[x]=mode4>=2 && x%3 ?
                (rnd()&0x7fff) | SoftRenderer2D::OBJ_DirectColor |
                SoftRenderer2D::OBJ_IsOpaque | ((x%4)<<16) | flags[(x/4)%4] : 0;
            r.OBJWindow[x]=(x%7)==0;
        }
        const unsigned count=bench ? 1 : 16384;
        for (unsigned blend=0;blend<count;++blend) {
            // Include no-target, forced 3D/OBJ blending, all normal effects,
            // first/second target combinations and effect-window permissions.
            e.BlendCnt=bench ? (mode==0 ? 0 : mode==1 ? 0x3f00 : mode==2 ? 0x3f40 : 0x3fff) : blend;
            e.EVA=blend%17; e.EVB=(blend/17)%17; e.EVY=(blend/289)%17;
            if (bench) {e.EVA=8;e.EVB=8;e.EVY=7;}
            r.DrawScanline_BGOBJ(37,out.data());
            const bool noOrdinaryEffects=((e.BlendCnt&0xc0)==0)||((e.BlendCnt&0x3f)==0);
            passthroughCases += noOrdinaryEffects && !(e.BlendCnt&0x3f00);
            for (unsigned x=0;x<256;++x) {
                const auto expected=r.ColorComposite(x,r.BGOBJLine[x],r.BGOBJLine[256+x]);
                if (out[x]!=expected) {
                    std::cerr<<"MISMATCH mode="<<mode<<" blend="<<blend<<" x="<<x
                             <<" got="<<out[x]<<" expected="<<expected<<"\n";return 1;
                }
                if (noOrdinaryEffects && (r.BGOBJLine[x]&0xc0000000u)==0x40000000u &&
                    ((r.BGOBJLine[x]>>24)&31)!=31 && out[x]!=r.BGOBJLine[x]) ++partialNegative;
                if ((blend&0x80) && out[x]!=r.BGOBJLine[x]) ++effectNegative;
                hash=(hash^out[x])*1099511628211ULL;
                ++checks;
            }
            if (noOrdinaryEffects) for (unsigned x=0;x<256;x+=2) {
                u64 pair; std::memcpy(&pair,&r.BGOBJLine[x],sizeof(pair));
                opaquePairs += (pair&0xDF000000DF000000ULL)==0x5F0000005F000000ULL;
            }
            if (bench) {
                for(unsigned warm=0;warm<192*8;++warm) r.DrawScanline_BGOBJ(37,out.data());
                const auto c0=seconds(CLOCK_PROCESS_CPUTIME_ID),w0=seconds(CLOCK_MONOTONIC);
                for(unsigned n=0;n<iterations;++n) r.DrawScanline_BGOBJ(37,out.data());
                const auto wall=seconds(CLOCK_MONOTONIC)-w0,cpu=seconds(CLOCK_PROCESS_CPUTIME_ID)-c0;
                u64 result=0;for(auto x:out)result=(result*16777619)^x;
                std::cout<<std::setprecision(12)<<"{\"mode\":"<<mode<<",\"lines\":"<<iterations
                         <<",\"cpu_seconds\":"<<cpu<<",\"wall_seconds\":"<<wall<<",\"hash\":"<<result<<"}\n";
            }
        }
    }
    if (!bench) {
        if (!passthroughCases || !opaquePairs || !partialNegative || !effectNegative) return 2;
        std::cout<<"COMPOSITE_ORACLE_PASS pixels="<<checks<<" no_target_cases="<<passthroughCases
                 <<" opaque_pairs="<<opaquePairs<<" partial_negative="<<partialNegative
                 <<" effect_negative="<<effectNegative<<" hash="<<std::hex<<hash<<"\n";
    }
} catch (const std::exception& e) {std::cerr<<e.what()<<"\n";return 3;}
