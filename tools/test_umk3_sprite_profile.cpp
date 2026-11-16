// SPDX-License-Identifier: GPL-3.0-only
#define main original_raster_benchmark_main
#include "benchmark_raster_batch.cpp"
#undef main
#include "GPU_Soft.h"
#include "GPU3D_Soft.h"
#include "replay/GameQueryProfile.h"

int main() try {
    using namespace nds4mister::replay;
    const GameQuerySelection qualified {GameQueryProfile::Fast, {{{'Y','U','T','E'}},0,0x6c631035u},true};
    require(umk3_sprite_raster_profile(qualified),"qualified UMK3 header rejected");
    auto bad=qualified;bad.identified=false;require(!umk3_sprite_raster_profile(bad),"unidentified admitted");
    bad=qualified;bad.identity.revision=1;require(!umk3_sprite_raster_profile(bad),"unknown revision admitted");
    bad=qualified;bad.identity.code[3]='P';require(!umk3_sprite_raster_profile(bad),"unknown region admitted");
    bad=qualified;bad.identity.header_crc32^=1;require(!umk3_sprite_raster_profile(bad),"changed header admitted");
    auto a=machine(true),b=machine(true);
    for(auto* n:{a.get(),b.get()}) {
        n->GPU.GPU3D.SetIntegralTextureSpansEnabled(false);
        n->GPU.GPU3D.SetTextureRangeHashReuseEnabled(true);
    }
    a->GPU.GPU3D.SetSpriteRasterSpansEnabled(false);
    b->GPU.GPU3D.SetSpriteRasterSpansEnabled(true);
    unsigned frames=0,prepared=0;
    for(unsigned variant=0;variant<8;++variant)for(unsigned base=0;base<64;++base) {
        const unsigned scenario=base | (variant&1 ? 16384u:0u) |
            (variant&2 ? 8192u:0u) | (variant&4 ? 32768u|65536u:0u);
        frame(*a,scenario);frame(*b,scenario);render(*a);render(*b);
        auto& ra=static_cast<SoftRenderer&>(a->GetRenderer());
        auto& rb=static_cast<SoftRenderer&>(b->GetRenderer());
        auto& sa=*static_cast<SoftRenderer3D*>(ra.Rend3D.get());
        auto& sb=*static_cast<SoftRenderer3D*>(rb.Rend3D.get());
        require(!std::memcmp(sa.ColorBuffer,sb.ColorBuffer,sizeof(sa.ColorBuffer)),"sprite color differs");
        require(!std::memcmp(sa.DepthBuffer,sb.DepthBuffer,sizeof(sa.DepthBuffer)),"sprite depth differs");
        require(!std::memcmp(sa.AttrBuffer,sb.AttrBuffer,sizeof(sa.AttrBuffer)),"sprite attributes differ");
        for(int i=0;i<sb.CurrentPolygonCount;++i)prepared+=sb.PolygonList[i].PixelState.PreparedRectangle;
        ++frames;
    }
    require(prepared>0,"prepared rectangles not exercised");
    std::printf("UMK3_SPRITE_PROFILE_PASS frames=%u prepared_rectangles=%u native_color_depth_attributes_equal=1 qualified_header_only=1\n",frames,prepared);
    return 0;
}catch(const std::exception& e){std::fprintf(stderr,"FAIL %s\n",e.what());return 1;}
