// Compare single-engine output/capture against the ordinary paired renderer.
// All graphics are generated here; no ROMs, saves, or device mappings are used.
#include "Args.h"
#include "NDS.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
using namespace melonDS;

static std::unique_ptr<NDS> fixture(bool aOnly, bool profile)
{
    NDSArgs args; args.JIT = std::nullopt;
    auto nds = std::make_unique<NDS>(std::move(args)); nds->Reset();
    auto& g = nds->GPU;
    for (unsigned bank = 0; bank < 4; ++bank) {
        for (unsigned i = 0; i < 0x20000; ++i)
            g.VRAM[bank][i] = 1 + (i * 13 + (i/8) * 17 + bank * 29) % 255;
        if (bank == 0 || bank == 2)
            for (unsigned i = 0; i < 1024; ++i)
                reinterpret_cast<u16*>(g.VRAM[bank] + 0x4000)[i] = i % 96;
    }
    for (unsigned engine = 0; engine < 2; ++engine) {
        for (unsigned i = 0; i < 512; ++i)
            reinterpret_cast<u16*>(g.Palette + engine * 0x400)[i] =
                ((i*7)&31) | (((i*11+engine*9)&31)<<5) | (((i*13)&31)<<10);
        auto* oam = reinterpret_cast<u16*>(g.OAM + engine * 0x400);
        for (unsigned i = 0; i < 128; ++i) {
            oam[i*4] = i < 32 ? u16(0x2000 | ((i*7)%160)) : u16(0x0200);
            oam[i*4+1] = 0x4000 | ((i*17)%240);
            oam[i*4+2] = (i*4)%128;
        }
    }
    g.MapVRAM_AB(0, 0x81); g.MapVRAM_AB(1, 0x82);
    g.MapVRAM_CD(2, 0x84); g.MapVRAM_CD(3, 0x84);
    nds->ARM9Write16(0x04000304, 0x820f);
    for (unsigned off : {0u, 0x1000u}) {
        nds->ARM9Write32(0x04000000 + off, 0x00011100);
        nds->ARM9Write16(0x04000008 + off, 0x0881);
    }
    RendererSettings s{}; s.ScaleFactor = 1; s.PackedOutput = true;
    s.PairedBCache = true; s.StageProfile = profile; s.EngineAOnly = aOnly;
    g.GetRenderer().SetRenderSettings(s);
    return nds;
}

static void phase(NDS& n, unsigned f, unsigned y, unsigned kind)
{
    const unsigned vb = y >= 192 && y < 262;
    if (!n.GPU.ApplyExternalRendererPhase(kind, y, y, vb | (kind==1 ? 2 : 0),
            vb | (kind==1 ? 2 : 0), f, true, f==0 && y==0 && kind==2, true))
        throw std::runtime_error("phase rejected");
}

static void edit(NDS& n, unsigned f, unsigned y)
{
    // Moving scroll, palette/OAM changes and mid-frame screen routing exercise
    // A's normal composition while B remains independently busy.
    if (y == 0) for (unsigned off : {0u,0x1000u}) {
        n.ARM9Write16(0x04000010+off, f*3);
        n.ARM9Write16(0x04000012+off, f*5);
    }
    if (y == 64) {
        n.ARM9Write16(0x04000304, (f&1) ? 0x020f : 0x820f);
        n.ARM9Write16(0x05000022, (f*379)&0x7fff);
        n.GPU.MarkExternalRenderPalette(0x22,2);
        n.ARM9Write16(0x07000002, 0x4000 | ((f*9)%240));
        n.GPU.MarkExternalRenderOAM(2,2);
    }
    if (y == 96) {
        n.ARM9Write16(0x0400006c, f%3 == 0 ? 0x4008 : f%3 == 1 ? 0x800c : 0);
        if (f == 2) n.ARM9Write32(0x04000000, 0x00011180); // forced blank
        if (f == 4) n.ARM9Write16(0x04000304, 0x820e); // screens disabled
    }
    if (y == 128) {
        n.ARM9Write32(0x04000000, 0x00011100);
        n.ARM9Write16(0x04000304, 0x820f);
    }
    if (y == 0 && f >= 6) {
        // Capture can write a bank that is not currently feeding 2D. Alternate
        // A/VRAM/FIFO/blended capture; compare the resulting VRAM byte-for-byte.
        n.GPU.MapVRAM_AB(1, 0x80);
        const unsigned mode = (f-6)%4;
        const u32 source3d = f&1 ? (1u<<24) : 0;
        const u32 fifo = f&2 ? (1u<<25) : 0;
        n.ARM9Write32(0x04000064, 0x80000000u | (mode<<29) | source3d | fifo |
            (3u<<20) | (1u<<16) | 0x0808);
    }
}

int main(int argc,char** argv)
try {
    const bool bench=argc==2 && std::strcmp(argv[1],"--benchmark")==0;
    if (argc>1 && !bench) throw std::runtime_error("unknown option");
    if (bench) {
        // Compare the same On/Off work in ABBA order. A busy B screen is not
        // representative of the cheaper cached auxiliary screen in every game.
        for (const char* scene : {"moving_b", "static_b", "blank_b"})
          for (bool aOnly : {false,true,true,false}) {
            auto n=fixture(aOnly,false);
            if (std::strcmp(scene,"blank_b")==0)
                n->ARM9Write32(0x04001000,0);
            const auto start=std::chrono::steady_clock::now();
            for (unsigned f=0;f<2400;++f) for(unsigned y=0;y<263;++y) {
                phase(*n,f,y,y==0?2:0);
                if(y==0) for(unsigned off:{0u,0x1000u})
                    if(off==0 || std::strcmp(scene,"moving_b")==0)
                        n->ARM9Write16(0x04000010+off,f*3);
                phase(*n,f,y,1);
            }
            const auto us=std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now()-start).count();
            std::cout<<"ENGINE_A_ONLY_BENCH scene="<<scene<<" a_only="<<aOnly
                     <<" frames=2400 us="<<us<<'\n';
        }
        return 0;
    }
    std::uint64_t checked=0,captureBytes=0;
    for (bool direct : {false,true}) {
        auto ref=fixture(false,true),test=fixture(true,true);
        using Plane=std::array<u32,256*192+4>;
        auto out=std::make_unique<std::array<std::array<Plane,2>,2>>();
        for(auto& slot:*out) for(auto& plane:slot) plane.fill(0xdeadbeef);
        std::array<Plane,2> completed{};
        bool varied=false;
        for(unsigned f=0;f<14;++f) for(unsigned y=0;y<263;++y) {
            if(direct && y==0 && !test->GPU.GetRenderer().SetExternalFramebuffers(
                    (*out)[f&1][0].data()+2,(*out)[f&1][1].data()+2))
                throw std::runtime_error("external framebuffer rejected");
            for(auto* n:{ref.get(),test.get()}) {
                phase(*n,f,y,y==0?2:0);edit(*n,f,y);phase(*n,f,y,1);
            }
            if(y<192) {
                u32 *r[2],*t[2];
                if(!ref->GPU.GetRenderer().GetRenderedScanlines(y,&r[0],&r[1]) ||
                   !test->GPU.GetRenderer().GetRenderedScanlines(y,&t[0],&t[1]))
                    throw std::runtime_error("scanline unavailable");
                const auto* a=r[ref->GPU.ScreenSwap?0:1];
                for(unsigned s=0;s<2;++s) for(unsigned x=0;x<256;++x) {
                    if(a[x]!=t[s][x]) {
                        std::cerr<<"mismatch direct="<<direct<<" f="<<f<<" y="<<y<<" x="<<x<<" s="<<s<<'\n';
                        throw std::runtime_error("single-engine pixel differs from A reference");
                    }
                    ++checked;
                    if(x && a[x]!=a[0]) varied=true;
                }
                if(f>=6) {
                    if(std::memcmp(ref->GPU.VRAM[1],test->GPU.VRAM[1],0x20000))
                        throw std::runtime_error("display capture differs");
                    captureBytes+=0x20000;
                }
            }
            if(direct && y==191) {
                for(auto& p:(*out)[f&1])
                    if(p[0]!=0xdeadbeef || p[1]!=0xdeadbeef || p[p.size()-2]!=0xdeadbeef || p.back()!=0xdeadbeef)
                        throw std::runtime_error("framebuffer guard damaged");
                if(f && (*out)[(f^1)&1]!=completed)
                    throw std::runtime_error("completed buffer overwritten");
                completed=(*out)[f&1];test->GPU.GetRenderer().SetExternalFramebuffers(nullptr,nullptr);
            }
        }
        const auto on=ref->GPU.GetRenderer().GetExternalRendererStageProfile();
        const auto off=test->GPU.GetRenderer().GetExternalRendererStageProfile();
        if(!varied || on.EngineBNs==0 || on.SpritesBNs==0 || off.EngineBNs || off.SpritesBNs || off.CompositeBNs)
            throw std::runtime_error("fixture flat or omitted B work still ran");
        // Retire the synthetic capture bookkeeping before these fixtures are
        // destroyed, as in DisplayCaptureOracleTest. No live CPU consumes it.
        for (auto* n : {ref.get(), test.get()})
            for (unsigned block = 0; block < 4; ++block)
                n->GPU.SyncVRAM_LCDC(0x06820000u + block * 0x8000u, true);
    }
    std::cout<<"ENGINE_A_ONLY_ORACLE_PASS pixels="<<checked<<" capture_bytes="<<captureBytes
             <<" screen_swap=1 forced_blank=1 power=1 brightness=1 direct_guards=1 b_pixel_sprite_work=0\n";
    return 0;
} catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
