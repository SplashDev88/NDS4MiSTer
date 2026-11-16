// SPDX-License-Identifier: GPL-3.0-only
// ROM-free decoder oracle. --kernel is CPU-only: no service, FPGA or game run.
#define main original_raster_benchmark_main
#include "benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include "replay/GameQueryProfile.h"
#include <array>
#include <vector>

static SoftRenderer3D& soft(NDS& n) {
    return *static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n.GetRenderer()).Rend3D.get());
}
static void seedFlat(GPU& g, unsigned epoch) {
    u32 state=0x93ad724bu+epoch;
    auto next=[&] { state^=state<<13;state^=state>>17;state^=state<<5;return u8(state); };
    for(auto& b:g.VRAMFlat_Texture)b=next();
    for(auto& b:g.VRAMFlat_TexPal)b=next();
}
static void compareDecode(GPU& g,u32 w,u32 h,u32 addr,u32 pal,bool transparent) {
    constexpr u32 guard=0xfedcba98;
    std::vector<u32> a(w*h+16,guard),b(w*h+16,guard);
    // Unmodified legacy converter is the independent pixel oracle.
    ConvertNColorsTexture<outputFmt_RGB6A5,8>(w,h,a.data()+8,addr,pal,transparent,g);
    NDS4MiSTerConvertNColors8TextureRGB6A5(w,h,b.data()+8,addr,pal,transparent,g);
    require(a==b,"8bpp decoder pixel mismatch");
    for(unsigned i=0;i<8;++i)require(a[i]==guard && a[w*h+8+i]==guard,"decoder guard overwritten");
}

[[gnu::noinline]] static void legacy(GPU& g,u32 w,u32 h,u32* out) {
    ConvertNColorsTexture<outputFmt_RGB6A5,8>(w,h,out,0,0,true,g);
}
[[gnu::noinline]] static void staged(GPU& g,u32 w,u32 h,u32* out) {
    NDS4MiSTerConvertNColors8TextureRGB6A5(w,h,out,0,0,true,g);
}
static int kernel() {
    auto n=machine(true);seedFlat(n->GPU,3);
    volatile u32 checksum=0;
    for(auto [w,h]:std::array<std::pair<u32,u32>,11>{{
        {8,8},{8,16},{16,16},{16,32},{32,32},{32,64},
        {64,64},{128,128},{256,256},{512,512},{1024,1024}}}) {
        std::vector<u32> output(w*h);
        const unsigned iterations=std::max(8u,8388608u/(w*h));
        std::array<double,3> oldNs{},newNs{};
        for(unsigned round=0;round<3;++round)for(unsigned order=0;order<2;++order) {
            const bool candidate=(round+order)%2;
            auto fn=candidate?staged:legacy;
            for(unsigned i=0;i<16;++i)fn(n->GPU,w,h,output.data());
            const auto start=std::chrono::steady_clock::now();
            for(unsigned i=0;i<iterations;++i) {
                fn(n->GPU,w,h,output.data());
                asm volatile("" : : "r"(output.data()) : "memory");
            }
            const auto stop=std::chrono::steady_clock::now();
            checksum=checksum^output[round];
            (candidate?newNs:oldNs)[round]=std::chrono::duration<double,std::nano>(stop-start).count()/iterations;
        }
        std::sort(oldNs.begin(),oldNs.end());std::sort(newNs.begin(),newNs.end());
        std::printf("NCOLOR8_KERNEL texels=%u width=%u height=%u iterations=%u legacy_ns=%.3f staged_ns=%.3f saved_percent=%.3f legacy_min_ns=%.3f legacy_max_ns=%.3f staged_min_ns=%.3f staged_max_ns=%.3f\n",
            w*h,w,h,iterations,oldNs[1],newNs[1],100*(1-newNs[1]/oldNs[1]),oldNs[0],oldNs[2],newNs[0],newNs[2]);
        std::fflush(stdout);
    }
    std::printf("NCOLOR8_KERNEL_DONE checksum=%u\n",unsigned(checksum));return 0;
}

int main(int argc,char** argv) try {
    if(argc==2 && !std::strcmp(argv[1],"--kernel"))return kernel();
    require(argc==1,"expected no arguments or --kernel");
    using namespace nds4mister::replay;
    const GameQuerySelection qualified {GameQueryProfile::Fast, {{{'Y','U','T','E'}},0,0x6c631035u},true};
    require(umk3_palette_decode_profile(qualified),"qualified palette profile");
    auto bad=qualified;bad.identified=false;require(!umk3_palette_decode_profile(bad),"unidentified palette profile");
    bad=qualified;bad.identity.revision=1;require(!umk3_palette_decode_profile(bad),"unknown revision");
    bad=qualified;bad.identity.code[3]='P';require(!umk3_palette_decode_profile(bad),"unknown region");
    bad=qualified;bad.identity.header_crc32^=1;require(!umk3_palette_decode_profile(bad),"changed header");
    unsigned transitions=0;
    for(const char* setting:{static_cast<const char*>(nullptr),"auto","0","1","invalid"}) {
        if(setting)setenv("NDS4MISTER_NCOLOR8_PALETTE",setting,1);else unsetenv("NDS4MISTER_NCOLOR8_PALETTE");
        auto n=machine(true);auto& g=n->GPU.GPU3D;
        require(!g.NColor8PaletteExpansionEnabled(),"fresh session inherited palette policy");
        for(bool policy:{false,true,false,true,false}) {
            g.SetNColor8PaletteExpansionEnabled(policy);frame(*n,0);render(*n);
            const bool expected=!setting || !std::strcmp(setting,"auto") ? policy : !std::strcmp(setting,"1");
            require(soft(*n).TextureCache.NColor8PaletteExpansionEnabled==expected,"palette policy transition");++transitions;
        }
    }
    unsetenv("NDS4MISTER_NCOLOR8_PALETTE");
    auto n=machine(true);unsigned cases=0;
    for(unsigned epoch=0;epoch<2;++epoch) {
        seedFlat(n->GPU,epoch);
        for(u32 w=8;w<=1024;w*=2)for(u32 h=8;h<=1024;h*=2)
            for(auto [addr,pal]:std::array<std::pair<u32,u32>,4>{{{0,0},{0x7fff8,0x1fff0},{24,48},{0x40008,0x10010}}})
                for(bool transparent:{false,true}) {
                    compareDecode(n->GPU,w,h,addr,pal,transparent);++cases;
                }
    }
    // Every 16-bit palette value, every index, including alpha on index zero.
    for(unsigned i=0;i<256;++i)n->GPU.VRAMFlat_Texture[i]=u8(i);
    for(unsigned block=0;block<256;++block) {
        for(unsigned i=0;i<256;++i) {
            const u16 color=u16(block*256+i);
            std::memcpy(n->GPU.VRAMFlat_TexPal+i*2,&color,2);
        }
        for(bool transparent:{false,true}) {compareDecode(n->GPU,16,16,0,0,transparent);++cases;}
    }
    n.reset();
    unsigned frames=0,changes=0,stagedBindings=0,fallbackBindings=0;
    for(auto [wl,hl]:std::array<std::pair<u32,u32>,8>{{{0,0},{0,1},{1,1},{1,2},{2,2},{3,3},{4,4},{5,5}}})
        for(bool transparent:{false,true}) {
            auto a=machine(true),b=machine(true);
            for(auto* current:{a.get(),b.get()}) {
                current->GPU.GPU3D.SetIntegralTextureSpansEnabled(false);
                current->GPU.GPU3D.SetSpriteRasterSpansEnabled(true);
                current->GPU.GPU3D.SetTextureRangeHashReuseEnabled(true);
                current->GPU.GPU3D.SetNColor8PaletteExpansionEnabled(current==b.get());
                frame(*current,16384u|8192u);
                for(unsigned i=0;i<131072;++i)current->GPU.VRAM_A[i]=u8(i*19+(i>>9));
                for(unsigned i=0;i<65536;++i)current->GPU.VRAM_E[i]=u8(i*7+(i>>6));
                auto& g=current->GPU.GPU3D;
                for(unsigned i=0;i<g.RenderNumPolygons;++i) {
                    auto* p=g.RenderPolygonRAM[i];
                    p->TexParam=(4u<<26)|(3u<<16)|(wl<<20)|(hl<<23)|(u32(transparent)<<29);
                    p->TexPalette=i*32;
                }
            }
            std::vector<u32> previous;
            for(unsigned step=0;step<8;++step) {
                for(auto* current:{a.get(),b.get()}) {
                    auto& g=current->GPU;
                    if(step==2 || step==6)for(unsigned i=0;i<65536;++i)g.VRAM_A[i]^=255;
                    if(step==3)for(unsigned i=0;i<65536;++i)g.VRAM_E[i]^=31;
                    if(step==4)g.MapVRAM_E(4,0x80);
                    if(step==5)g.MapVRAM_E(4,0x83);
                    if(step==6)g.MapVRAM_AB(0,0x80);
                    if(step==7)g.MapVRAM_AB(0,0x83);
                    if(step!=1) {
                        std::memset(g.VRAMDirty[0].Data,255,sizeof(g.VRAMDirty[0].Data));
                        std::memset(g.VRAMDirty[4].Data,255,sizeof(g.VRAMDirty[4].Data));
                    }
                    render(*current);
                }
                auto& sa=soft(*a);auto& sb=soft(*b);
                require(!std::memcmp(sa.ColorBuffer,sb.ColorBuffer,sizeof(sa.ColorBuffer)),"cache render color mismatch");
                require(!std::memcmp(sa.DepthBuffer,sb.DepthBuffer,sizeof(sa.DepthBuffer)),"cache render depth mismatch");
                require(!std::memcmp(sa.AttrBuffer,sb.AttrBuffer,sizeof(sa.AttrBuffer)),"cache render attribute mismatch");
                require(!sb.TextureCache.Cache.empty(),"no textures exercised");
                for(const auto& item:sb.TextureCache.Cache) {
                    const auto texels=item.second.TextureRAMSize[0];
                    if(texels>=NDS4MiSTerNColor8PaletteMinTexels)++stagedBindings;else ++fallbackBindings;
                }
                const auto* begin=reinterpret_cast<const u32*>(sa.ColorBuffer);
                std::vector<u32> pixels(begin,begin+sizeof(sa.ColorBuffer)/sizeof(u32));
                if(step==1)require(pixels==previous,"unchanged frame changed");
                else if(step && pixels!=previous)++changes;
                previous=std::move(pixels);++frames;
            }
        }
    require(changes>0 && stagedBindings>0 && fallbackBindings>0,"render coverage missing");
    std::printf("NCOLOR8_PALETTE_PASS decoder_cases=%u all_palette_values=65536 render_frames=%u changed_frames=%u staged_bindings=%u fallback_bindings=%u policy_transitions=%u color_depth_attributes_equal=1 wraps_guards_and_dirty_remaps=1\n",
        cases,frames,changes,stagedBindings,fallbackBindings,transitions);
    return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
