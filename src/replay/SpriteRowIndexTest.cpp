// SPDX-License-Identifier: GPL-3.0-or-later
// The reference uses the unchanged setup traversal, with identical batching.
#define main original_setup_test_main
#include "SpriteSetupCacheTest.cpp"
#undef main
#include "GPU_Soft.h"
#include <array>

static SoftRenderer2D& engine(NDS& n, unsigned which)
{
    auto& r = static_cast<SoftRenderer&>(n.GetRenderer());
    return *static_cast<SoftRenderer2D*>(which ? r.Rend2D_B.get() : r.Rend2D_A.get());
}

static std::unique_ptr<NDS> row_fixture(bool indexed, bool tracked)
{
    setenv("NDS_GPU_SPRITE_ROW_INDEX", indexed ? "1" : "0", 1);
    return fixture(true, tracked); // setup and sprite batching on in BOTH arms
}

static void require(bool ok, const char* message)
{
    if (!ok) throw std::runtime_error(message);
}

static bool equal_output(NDS& a, NDS& b)
{
    for (unsigned e = 0; e < 2; ++e) {
        auto& x = engine(a,e); auto& y = engine(b,e);
        if (x.NumSprites != y.NumSprites ||
            std::memcmp(x.OBJLine,y.OBJLine,sizeof(x.OBJLine)) ||
            std::memcmp(x.OBJWindow,y.OBJWindow,sizeof(x.OBJWindow))) return false;
    }
    return true;
}

static void empty_oam(NDS& n)
{
    for (unsigned i = 0; i < 256; ++i) n.GPU.WriteOAM<u16>(i*8,0x200);
}

static void membership(NDS& original, NDS& indexed, unsigned e)
{
    auto& a = engine(original,e); auto& b = engine(indexed,e);
    a.UpdateSpriteSetup(); b.UpdateSpriteSetup();
    const auto& old = *a.SpriteSetup; const auto& now = *b.SpriteSetup;
    require(old.Count == now.Count, "setup count differs");
    // Row bits are derived independently by the original range predicate.
    for (unsigned line = 0; line < 256; ++line) {
        std::array<u32,4> expected{};
        for (unsigned n = 0; n < old.Count; ++n)
            if (((line-old.Sprites[n].Y)&255) < old.Sprites[n].BoundHeight)
                expected[n/32] |= 1u << (n%32);
        for (unsigned word = 0; word < (old.Count+31)/32; ++word)
            require(expected[word] == now.Rows[line][word], "row membership differs");
    }
}

int main() try
{
    unsigned membershipCases=0, rawLines=0;
    auto old=row_fixture(false,true), indexed=row_fixture(true,true);
    empty_oam(*old); empty_oam(*indexed);
    unsigned prior=0;
    for (unsigned y=0;y<256;++y)
    for (unsigned size=0;size<16;++size)
    for (unsigned type=0;type<4;++type)
    for (int x : {-128,-1,0,255}) {
        const unsigned number=membershipCases%128;
        for (auto* n : {old.get(),indexed.get()}) {
            n->GPU.WriteOAM<u16>(prior*8,0x200);
            n->GPU.WriteOAM<u16>(number*8,u16(y|(type<<8)|((size&3)<<14)));
            n->GPU.WriteOAM<u16>(number*8+2,u16((x&511)|((size>>2)<<14)));
        }
        membership(*old,*indexed,0);
        prior=number; ++membershipCases;
    }
    for (unsigned count : {0u,1u,31u,32u,33u,63u,64u,65u,95u,96u,97u,127u,128u}) {
        for (auto* n : {old.get(),indexed.get()}) {
            empty_oam(*n);
            for (unsigned e=0;e<2;++e) for (unsigned i=0;i<count;++i) {
                const unsigned type=i%3 == 2 ? 3 : i%3;
                const unsigned size=i&15;
                n->GPU.WriteOAM<u16>(e*1024+i*8,u16(((i*19)&255)|(type<<8)|((size&3)<<14)));
                n->GPU.WriteOAM<u16>(e*1024+i*8+2,u16(((i*11)&255)|((size>>2)<<14)));
            }
        }
        for (unsigned e=0;e<2;++e) membership(*old,*indexed,e);
        membershipCases+=2;
        for (unsigned line=0;line<256;++line) {
            for (auto* n : {old.get(),indexed.get()}) {
                for (auto* g : {&n->GPU.GPU2D_A,&n->GPU.GPU2D_B}) {
                    g->Enabled=g->OBJEnable=true; g->DispCnt=0x1000;
                }
                n->GetRenderer().DrawSprites(line);
            }
            require(equal_output(*old,*indexed),"dense/word boundary output differs");
            ++rawLines;
        }
    }
    old.reset(); indexed.reset();
    for (bool tracked : {false,true}) {
        auto a=row_fixture(false,tracked), b=row_fixture(true,tracked);
        for (unsigned frame=0;frame<72;++frame) for (unsigned line=0;line<192;++line) {
            for (auto* n : {a.get(),b.get()}) {
                if (frame==36 && line==0) { engine(*n,0).Reset(); engine(*n,1).Reset(); }
                edit(*n,frame,line,tracked);
                n->GetRenderer().DrawSprites(line);
            }
            require(equal_output(*a,*b),"dynamic exact OBJ buffers/count differ");
            ++rawLines;
        }
    }
    // A deliberate omitted membership bit must be detected even for a
    // transparent sprite, since NumSprites is part of the phase result.
    auto a=row_fixture(false,true), b=row_fixture(true,true);
    for (auto* n : {a.get(),b.get()}) {
        empty_oam(*n); n->GPU.WriteOAM<u16>(0,0); n->GPU.WriteOAM<u16>(2,0);
        n->GPU.GPU2D_A.Enabled=n->GPU.GPU2D_A.OBJEnable=true;
        engine(*n,0).UpdateSpriteSetup();
    }
    engine(*b,0).SpriteSetup->Rows[0][0]&=~1u;
    engine(*a,0).DrawSprites(0); engine(*b,0).DrawSprites(0);
    require(!equal_output(*a,*b),"negative control not detected");
    engine(*b,0).SpriteSetup->Rows[0][0]|=1u;
    engine(*b,0).DrawSprites(0);
    require(equal_output(*a,*b),"negative control restore failed");
    std::cout<<"SPRITE_ROW_INDEX_PASS membership_cases="<<membershipCases
             <<" raw_line_pairs="<<rawLines<<" exact_buffers_and_count=1 all_y_size_type=1"
             <<" tracked_untracked=1 negative_control=1 original_setup_traversal=1\n";
} catch(const std::exception& e) { std::cerr<<e.what()<<'\n'; return 1; }
