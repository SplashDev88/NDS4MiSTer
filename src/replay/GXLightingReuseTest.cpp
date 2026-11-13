// SPDX-License-Identifier: GPL-3.0-or-later
// Exact lighting-result cache: differential output and command invalidation.
#include "Args.h"
#include "NDS.h"
#include "Savestate.h"
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <optional>
#include <stdexcept>
#include <vector>
using namespace melonDS;
#include "testdata/GXLightingBeta12.h"

namespace {
u32 random_state=0x457cab91;
u32 random_word() {
    random_state^=random_state<<13; random_state^=random_state>>17;
    random_state^=random_state<<5; return random_state;
}
std::unique_ptr<NDS> make_nds() {
    NDSArgs args; args.JIT=std::nullopt;
    auto nds=std::make_unique<NDS>(std::move(args)); nds->Reset(); return nds;
}
void setup(GPU3D& g,unsigned mask,unsigned mode) {
    g.LightingCacheValid=0;
    g.TexParam=(random_word()&0x3fffffff)|(mode<<30);
    g.CurPolygonAttr=(random_word()&~15u)|mask;
    for(auto& v:g.Normal)v=s16(random_word()%1024)-512;
    for(auto& v:g.TexCoords)v=s16(random_word());
    for(auto& v:g.RawTexCoords)v=s16(random_word());
    for(auto& v:g.VertexColor)v=u8(random_word());
    for(auto& v:g.TexMatrix)v=s32(random_word());
    for(auto& v:g.VecMatrix)v=s32(random_word()%65536)-32768;
    for(auto& a:g.LightDirection)for(auto& v:a)v=s16(random_word()%2048)-1024;
    for(auto& a:g.LightColor)for(auto& v:a)v=random_word()%32;
    for(auto& v:g.SpecRecip)v=random_word()%262145;
    for(auto& v:g.MatDiffuse)v=u8(random_word());
    for(auto& v:g.MatAmbient)v=u8(random_word());
    for(auto& v:g.MatSpecular)v=u8(random_word());
    for(auto& v:g.MatEmission)v=u8(random_word());
    for(auto& v:g.ShininessTable)v=u8(random_word());
    g.UseShininessTable=(random_word()&1)!=0;
    g.NormalPipeline=random_word()%16; g.VertexPipeline=random_word()%128;
    g.PolygonPipeline=random_word()%128; g.VertexSlotCounter=random_word()%10;
    g.VertexSlotsFree=random_word()&255; g.CycleCount=random_word()%10000;
}
void copy_state(const GPU3D& a,GPU3D& b) {
#define COPY(f) std::memcpy(&b.f,&a.f,sizeof(a.f));
    COPY(TexParam); COPY(CurPolygonAttr); COPY(Normal); COPY(TexCoords);
    COPY(RawTexCoords); COPY(VertexColor); COPY(TexMatrix); COPY(VecMatrix);
    COPY(LightDirection); COPY(LightColor); COPY(SpecRecip); COPY(MatDiffuse);
    COPY(MatAmbient); COPY(MatSpecular); COPY(MatEmission); COPY(ShininessTable);
    COPY(UseShininessTable); COPY(NormalPipeline); COPY(VertexPipeline);
    COPY(PolygonPipeline); COPY(VertexSlotCounter); COPY(VertexSlotsFree); COPY(CycleCount);
#undef COPY
}
void compare(const GPU3D& a,const GPU3D& b) {
#define SAME(f) if(std::memcmp(&a.f,&b.f,sizeof(a.f))) throw std::runtime_error("UNLIT_MISMATCH " #f);
    SAME(TexParam); SAME(CurPolygonAttr); SAME(Normal); SAME(TexCoords);
    SAME(RawTexCoords); SAME(VertexColor); SAME(TexMatrix); SAME(VecMatrix);
    SAME(LightDirection); SAME(LightColor); SAME(SpecRecip); SAME(MatDiffuse);
    SAME(MatAmbient); SAME(MatSpecular); SAME(MatEmission); SAME(ShininessTable);
    SAME(UseShininessTable); SAME(NormalPipeline); SAME(VertexPipeline);
    SAME(PolygonPipeline); SAME(VertexSlotCounter); SAME(VertexSlotsFree); SAME(CycleCount);
#undef SAME
}
}
namespace {
unsigned comparisons=0, commands=0, invalidations=0, detectors=0;
void exact(GPU3D& g,GPU3D& ref) {
    copy_state(g,ref);
    reference_lighting_beta12(ref);
    g.CalculateLighting();compare(g,ref);++comparisons;
}
void command(NDS& n,u8 op,u32 value=0) {
    auto& g=n.GPU.GPU3D;
    g.WriteExternalNormalizedCommand(op,value);
    n.ARM9Timestamp+=u64(65536)<<n.ARM9ClockShift;g.Run();++commands;
    if(!g.CmdPIPE.IsEmpty() || !g.CmdFIFO.IsEmpty() ||
       g.ExternalBatchRead!=g.ExternalBatchCount)
    {
        std::fprintf(stderr,"unconsumed op=%02x count=%u fifo=%u pipe=%u batch=%u/%u cycles=%d timestamp=%llu arm=%llu flush=%u enabled=%u external=%u\n",
            op,commands,g.CmdFIFO.Level(),g.CmdPIPE.Level(),g.ExternalBatchRead,g.ExternalBatchCount,
            g.CycleCount,(unsigned long long)g.Timestamp,(unsigned long long)n.ARM9Timestamp,
            g.FlushRequest,g.GeometryEnabled,g.ExternalCommandReplay);
        throw std::runtime_error("command not consumed");
    }
}
void normal_command(NDS& n,GPU3D& ref,u32 value) {
    command(n,0x21,value);
    auto& g=n.GPU.GPU3D;
    copy_state(g,ref);reference_lighting_beta12(ref);
    if(std::memcmp(g.VertexColor,ref.VertexColor,sizeof(g.VertexColor)) ||
       std::memcmp(g.TexCoords,ref.TexCoords,sizeof(g.TexCoords)))
        throw std::runtime_error("command lighting mismatch");
    ++comparisons;
    // Independent comparison of every pipeline/cycle field on cached hit.
    exact(g,ref);
}
void invalidated(GPU3D& g) {
    if(g.LightingCacheValid)throw std::runtime_error("missed invalidation");
    ++invalidations;
}
}
int main() try {
    auto a=make_nds(),b=make_nds();auto& g=a->GPU.GPU3D;auto& ref=b->GPU.GPU3D;
    // Full inputs, every mask/mode, misses, exact hits, index collisions,
    // independent COLOR, and changed UV/matrix inputs on texture-mode2 hits.
    for(unsigned round=0;round<128;++round)
    for(unsigned mask=0;mask<16;++mask)for(unsigned mode=0;mode<4;++mode) {
        setup(g,mask,mode);
        s16 saved[3];std::memcpy(saved,g.Normal,sizeof(saved));
        for(unsigned repeat=0;repeat<12;++repeat) {
            if(repeat%3==0)for(auto& v:g.Normal)v=s16(random_word()%1024)-512;
            if(repeat==9)std::memcpy(g.Normal,saved,sizeof(saved));
            for(auto& v:g.VertexColor)v=u8(random_word());
            for(auto& v:g.RawTexCoords)v=s16(random_word());
            for(auto& v:g.TexMatrix)v=s32(random_word());
            exact(g,ref);exact(g,ref);
        }
    }
    for(bool external:{false,true}) {
        a->Reset();g.SetEnabled(true,true);g.SetExternalCommandReplay(external);g.SetLightingResultReuseEnabled(true);
        for(unsigned round=0;round<64;++round) {
            command(*a,0x29,round&15);command(*a,0x40,0);
            u32 normal=random_word();normal_command(*a,ref,normal);
            for(unsigned op=0x30;op<=0x34;++op) {
                unsigned count=op==0x34?32:1;
                for(unsigned i=0;i<count;++i)command(*a,op,random_word());
                invalidated(g);normal_command(*a,ref,normal);
            }
            // Explicit COLOR and texcoords cannot replace the cached RGB.
            command(*a,0x20,random_word());command(*a,0x22,random_word());
            command(*a,0x2a,(round&3)<<30);normal_command(*a,ref,normal);
            for(unsigned mode=0;mode<4;++mode) {
                command(*a,0x10,mode);
                const unsigned ops[]={0x15,0x16,0x17,0x18,0x19,0x1a,0x1b,0x1c};
                const unsigned sizes[]={1,16,12,16,12,9,3,3};
                for(unsigned j=0;j<8;++j) {
                    for(unsigned i=0;i<sizes[j];++i)command(*a,ops[j],random_word());
                    if(mode==2 && ops[j]!=0x1b)invalidated(g);
                    normal_command(*a,ref,normal);
                }
                command(*a,0x13,0);command(*a,0x14,0);
                if(mode==1 || mode==2)invalidated(g);
                normal_command(*a,ref,normal);
                command(*a,0x11);command(*a,0x12,1);
                if(mode==1 || mode==2)invalidated(g);
                normal_command(*a,ref,normal);
            }
            // A different begin mask must miss without erasing raw state.
            command(*a,0x29,(round+1)&15);command(*a,0x40,0);
            normal_command(*a,ref,normal);
            if(round%8==0) {
                Savestate out;g.DoSavestate(&out);out.Finish();
                if(out.Error)throw std::runtime_error("save failed");
                command(*a,0x31,random_word());normal_command(*a,ref,normal);
                g.LightingCacheValid=0xffff;
                for(auto& slot:g.LightingCache)slot.ColorAndCycles=0x017fff;
                Savestate in(out.Buffer(),out.Length(),false);g.DoSavestate(&in);
                if(in.Error)throw std::runtime_error("load failed");
                invalidated(g);normal_command(*a,ref,normal);
                // Reset the owner clock as well as GPU state, matching a
                // real system reset (GPU-only Reset zeroes its timestamp).
                a->Reset();invalidated(g);g.SetEnabled(true,true);
                g.SetExternalCommandReplay(external);g.SetLightingResultReuseEnabled(true);normal_command(*a,ref,normal);
            }
        }
    }
    // Disabled policy must ignore even deliberately poisoned valid slots.
    for(bool external:{false,true}) {
        a->Reset();g.SetEnabled(true,true);g.SetExternalCommandReplay(external);
        for(unsigned round=0;round<128;++round) {
            setup(g,round&15,(round>>4)&3);
            g.SetLightingResultReuseEnabled(false);
            g.LightingCacheValid=0xffff;
            for(auto& slot:g.LightingCache) {slot.NormalKey=0;slot.ColorAndCycles=0xffffffff;}
            command(*a,0x21,0);
            copy_state(g,ref);reference_lighting_beta12(ref);
            if(std::memcmp(g.VertexColor,ref.VertexColor,sizeof(g.VertexColor)) ||
               std::memcmp(g.TexCoords,ref.TexCoords,sizeof(g.TexCoords)))
                throw std::runtime_error("disabled lighting cache used stale result");
            ++comparisons;
            g.SetLightingResultReuseEnabled(true);invalidated(g);
            normal_command(*a,ref,0);
            g.SetLightingResultReuseEnabled(false);invalidated(g);
        }
    }
    // Prove output comparison detects a stale RGB hit. Prove a hash
    // collision with a different exact key recomputes instead of reusing it.
    setup(g,15,0);exact(g,ref);
    const u32 key=(u32(g.Normal[0])&1023)|((u32(g.Normal[1])&1023)<<10)|((u32(g.Normal[2])&1023)<<20);
    auto& slot=g.LightingCache[(key*0x9e3779b1u)>>28];
    slot.ColorAndCycles^=1;
    try {exact(g,ref);}catch(const std::runtime_error&) {++detectors;}
    if(detectors!=1)throw std::runtime_error("stale RGB detector failed");
    slot.NormalKey^=1;exact(g,ref);
    // Texture mode2 must run even on RGB hits: compute expected from the
    // current RawTexCoords and TexMatrix, rather than reusing cached UV.
    setup(g,1,2);exact(g,ref);
    for(auto& v:g.RawTexCoords)v^=0x5555;
    for(auto& v:g.TexMatrix)v^=0x55aa55aa;
    exact(g,ref);
    std::printf("GX_LIGHTING_REUSE_PASS comparisons=%u commands=%u invalidations=%u stale_rgb_detectors=%u ordinary_and_external=1 all_masks_and_texmodes=1\n",comparisons,commands,invalidations,detectors);
    return 0;
}catch(const std::exception& e) {std::fprintf(stderr,"%s\n",e.what());return 1;}
