// SPDX-License-Identifier: GPL-3.0-only
#define main original_raster_benchmark_main
#include "benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
static SoftRenderer3D& soft(NDS& n) {
    return *static_cast<SoftRenderer3D*>(static_cast<SoftRenderer&>(n.GetRenderer()).Rend3D.get());
}
int main() try {
    auto ref=machine(true), test=machine(true);
    auto& cache=soft(*ref).TextureCache;
    // Collision saturation, zero-length ranges, overlapping ranges and same
    // offset in different backing regions must never return another key's hash.
    unsigned calls=0,checks=0;
    auto value=[](const void* p,u32 region,u32 start,u32 size) {
        return uint64_t(reinterpret_cast<uintptr_t>(p)) ^
            (uint64_t(start)<<32) ^ (uint64_t(size)<<1) ^ region;
    };
    for(unsigned epoch=0;epoch<3;++epoch) {
        NDS4MiSTerTextureRangeHashes hashes;
        for(unsigned pass=0;pass<2;++pass) for(unsigned i=0;i<4096;++i) {
            const auto* p=(i&1)?ref->GPU.VRAMFlat_Texture:ref->GPU.VRAMFlat_TexPal;
            const u32 region=(i&1)?524288:131072,start=(i*512)%region,size=i%4?1024:0;
            const auto expected=value(p,region,start,size)+epoch;
            require(hashes.Get(p,region,start,size,[&]{++calls;return expected;})==expected,"range identity or table overflow");++checks;
        }
        unsigned repeated=0;NDS4MiSTerTextureRangeHashes repeatedHashes;
        for(unsigned i=0;i<32;++i) require(repeatedHashes.Get(ref.get(),512,0,64,[&]{++repeated;return 42;})==42,"repeat result");
        require(repeated==1,"duplicate source was hashed again");
    }
    for(unsigned kind=0;kind<2;++kind) {
        auto* bytes=kind?ref->GPU.VRAMFlat_TexPal:ref->GPU.VRAMFlat_Texture;
        const u32 region=kind?131072:524288;
        for(u32 i=0;i<region;++i)bytes[i]=u8(i*37+(i>>8));
        const std::pair<u32,u32> ranges[]={{0,0},{0,16},{0,region},{region-8,32},{region-512,region*2},{512,1024}};
        for(unsigned epoch=0;epoch<4;++epoch) {
            NDS4MiSTerTextureRangeHashes hashes;
            u64 dirty[16]{};if(epoch&1) for(auto& word:dirty)word=~u64(0);else dirty[0]=2;
            bytes[region-1]^=u8(epoch+1);
            for(auto [start,size]:ranges) for(unsigned old=0;old<3;++old) {
                const auto expectedHash=cache.MaskedHash(bytes,region,start,size);
                const auto oldHash=expectedHash^(old?uint64_t(old)*123:0);
                const bool expected=cache.CheckInvalid(start,size,oldHash,dirty,bytes,region);
                require(cache.CheckInvalid(start,size,oldHash,dirty,bytes,region,&hashes)==expected,"dirty range or wrapped source mismatch");++checks;
            }
        }
    }
    unsigned frames=0;
    for(unsigned format:{0u,1u,2u,3u,4096u}) {
        ref=machine(true);test=machine(true);
        soft(*ref).TextureCache.RangeHashReuseEnabled=false;
        soft(*test).TextureCache.RangeHashReuseEnabled=true;
        for(auto* n:{ref.get(),test.get()}) {
            frame(*n,format);auto& gpu=n->GPU;
            for(unsigned i=0;i<32768;++i)gpu.VRAM_E[i]=u8(i*7+(i>>6));
            for(unsigned i=0;i<131072;++i)gpu.VRAM_A[i]=u8(i*19+(i>>9));
            for(unsigned i=0;i<gpu.GPU3D.RenderNumPolygons;++i) {
                auto* p=gpu.GPU3D.RenderPolygonRAM[i];p->TexParam|=(5u<<20)|(5u<<23);p->TexPalette=i*32;
            }
        }
        for(unsigned step=0;step<7;++step) {
            for(auto* n:{ref.get(),test.get()}) {
                if(step==2 || step==5)n->GPU.VRAM_A[33]^=255;
                if(step==3)n->GPU.VRAM_E[129]^=31;
                if(step==4)n->GPU.MapVRAM_AB(0,0x80);
                if(step==5)n->GPU.MapVRAM_AB(0,0x83);
                if(step!=1) {
                    std::memset(n->GPU.VRAMDirty[0].Data,255,sizeof(n->GPU.VRAMDirty[0].Data));
                    std::memset(n->GPU.VRAMDirty[4].Data,255,sizeof(n->GPU.VRAMDirty[4].Data));
                }
                render(*n);
            }
            auto& a=soft(*ref);auto& b=soft(*test);
            require(!std::memcmp(a.ColorBuffer,b.ColorBuffer,sizeof(a.ColorBuffer)),"color differs");
            require(!std::memcmp(a.DepthBuffer,b.DepthBuffer,sizeof(a.DepthBuffer)),"depth differs");
            require(!std::memcmp(a.AttrBuffer,b.AttrBuffer,sizeof(a.AttrBuffer)),"attributes differ");++frames;
        }
    }
    std::printf("TEXTURE_RANGE_HASH_PASS checks=%u oracle_calls=%u render_frames=%u all_color_depth_attribute_planes_equal=1\n",checks,calls,frames);return 0;
} catch(const std::exception& e) {std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
