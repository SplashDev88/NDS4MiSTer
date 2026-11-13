// SPDX-License-Identifier: GPL-3.0-or-later
// Compare the production lighting routine with the frozen Beta11 body.
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
#include "testdata/GXLightingBeta11.h"

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
    b.LightingCacheValid=0; // this test injects raw state directly
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
int main(int argc,char** argv) try {
    auto a=make_nds(),b=make_nds(); unsigned checks=0;
    if(argc==3 && std::strcmp(argv[1],"--census")==0) {
        std::ifstream f(argv[2],std::ios::binary|std::ios::ate);
        if(!f)throw std::runtime_error("snapshot open");
        const auto size=f.tellg(); f.seekg(0);std::vector<u8> bytes(size);
        f.read(reinterpret_cast<char*>(bytes.data()),bytes.size());
        Savestate state(bytes.data(),bytes.size(),false);a->GPU.DoSavestate(&state);
        if(state.Error)throw std::runtime_error("snapshot load");
        auto& g=a->GPU.GPU3D;unsigned masks[16]={};
        for(unsigned i=0;i<g.RenderNumPolygons;++i)++masks[g.RenderPolygonRAM[i]->Attr&15];
        std::printf("{\"polygons\":%u,\"no_lights\":%u,\"light_masks\":[",g.RenderNumPolygons,masks[0]);
        for(unsigned i=0;i<16;++i)std::printf("%s%u",i?",":"",masks[i]);
        std::puts("]}");return 0;
    }
    for(unsigned mode=0;mode<4;++mode)for(unsigned mask=0;mask<16;++mask)
        for(unsigned sample=0;sample<1024;++sample) {
            auto& x=a->GPU.GPU3D;auto& y=b->GPU.GPU3D;
            setup(x,mask,mode);copy_state(x,y);
            reference_lighting_beta11(x); y.CalculateLighting(); compare(x,y);++checks;
        }
    // Prove the oracle observes texture coordinates, emission and timing.
    unsigned detectors=0;
    for(unsigned field=0;field<3;++field) {
        auto& x=a->GPU.GPU3D;auto& y=b->GPU.GPU3D;setup(x,0,2);copy_state(x,y);
        reference_lighting_beta11(x);y.CalculateLighting();
        if(field==0)y.TexCoords[0]^=1;
        if(field==1)y.VertexColor[0]^=1;
        if(field==2)y.CycleCount^=1;
        try {compare(x,y);}catch(const std::runtime_error&) {++detectors;}
    }
    if(detectors!=3)throw std::runtime_error("oracle missed changed result");
    std::printf("GX_UNLIT_LIGHTING_PASS comparisons=%u output_detectors=%u\n",checks,detectors);
    return 0;
}catch(const std::exception& e) {std::fprintf(stderr,"%s\n",e.what());return 1;}
