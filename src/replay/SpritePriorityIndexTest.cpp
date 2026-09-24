// Compare single-pass OBJ indexing with the original four full-width scans.
// Synthetic VRAM, both engines, all priorities, windows, mosaic and midline edits.
#include "Args.h"
#include "NDS.h"
#include <array>
#include <cstring>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
using namespace melonDS;
static u32 randomWord(u32& s) { s^=s<<13; s^=s>>17; s^=s<<5; return s; }
static std::unique_ptr<NDS> fixture(bool indexed)
{
    setenv("NDS_GPU_STANDARD_PALETTE_CACHE", indexed ? "1" : "0", 1);
    setenv("NDS_GPU_SPRITE_PRIORITY_INDEX", indexed ? "1" : "0", 1);
    setenv("NDS_GPU_AFFINE_TILE_CACHE", indexed ? "1" : "0", 1);
    NDSArgs args; args.JIT=std::nullopt;
    auto n=std::make_unique<NDS>(std::move(args)); n->Reset();
    RendererSettings rs{};rs.Threaded=false;rs.ScaleFactor=1;rs.PackedOutput=true;
    n->GetRenderer().SetRenderSettings(rs);
    auto&g=n->GPU;u32 seed=12345;
    for(unsigned bank=0;bank<4;bank++)for(unsigned i=0;i<0x20000;i++)g.VRAM[bank][i]=randomWord(seed);
    g.MapVRAM_AB(0,0x82);g.MapVRAM_AB(1,0x81);g.MapVRAM_CD(2,0x84);g.MapVRAM_CD(3,0x84);
    for(unsigned i=0;i<0x8000;i++){g.VRAM[4][i]=randomWord(seed);g.VRAM[7][i]=randomWord(seed);}
    g.MapVRAM_E(4,0x84);g.MapVRAM_H(7,0x82);
    for(unsigned i=0;i<sizeof(g.Palette);i++)g.Palette[i]=randomWord(seed);
    for(unsigned i=0;i<sizeof(g.OAM);i++)g.OAM[i]=randomWord(seed);
    for(unsigned e=0;e<2;e++)for(unsigned i=0;i<128;i++){
        auto*a=reinterpret_cast<u16*>(g.OAM+e*1024+i*8);
        a[0]=i>=80?0x200:((i*17)%192)|((i%4)<<10)|((i%3)<<14)|((i&1)<<8)|((i&1)<<13)|((i&2)<<11);
        a[1]=((i*13)%512)|(((i/3)&3)<<14)|((i&1)<<12);
        a[2]=(i*3)%256|((i&3)<<10)|((i&15)<<12);
    }
    n->ARM9Write16(0x04000304,0x020f);
    g.SetSpriteOAMWriteTracking(true);g.MarkSpriteOAMWritten(0,2048);
    return n;
}
static void edit(NDS&n,unsigned f,unsigned y)
{
    u32 seed=f*263+y+1;auto&g=n.GPU;
    for(unsigned e=0;e<2;e++){
        u32 base=0x04000000+e*0x1000;
        n.ARM9Write32(base,0x00011f00|(f%8)|((f%8)<<13)|((f&3)<<4)|((f&1)<<31)|(((f/2)&1)<<30));
        for(unsigned b=0;b<4;b++){
            n.ARM9Write16(base+8+b*2,((b+f)&3)|(((f/8)&1)<<7)|((f&1)<<6)|((b+8)<<8)|(((f/16)&3)<<14)|(((f/4)&1)<<13));
            n.ARM9Write16(base+0x10+b*4,f*3+y/11);
        }
        n.ARM9Write16(base+0x20,(f&1?-1:1)*(256+(f%5)*23));n.ARM9Write16(base+0x24,(f&2?-1:1)*(f%7)*13);
        n.ARM9Write32(base+0x28,((int(f%9)-3)*256)&0x0fffffff);
        n.ARM9Write32(base+0x2c,((int(y)-4)*256)&0x0fffffff);
        n.ARM9Write16(base+0x30,256);n.ARM9Write16(base+0x34,0);
        n.ARM9Write16(base+0x40,(20<<8)|230);n.ARM9Write16(base+0x42,(200<<8)|60);
        n.ARM9Write16(base+0x44,192);n.ARM9Write16(base+0x46,(40<<8)|160);
        n.ARM9Write16(base+0x48,0x3f00|((f+y/31)&63));n.ARM9Write16(base+0x4a,0x123f);
        n.ARM9Write16(base+0x4c,((f&15)<<8)|((f&7)<<12)|(f&3));
        n.ARM9Write16(base+0x50,0x3f3f|((f&3)<<6));n.ARM9Write16(base+0x52,0x0808);
        n.ARM9Write16(base+0x54,f%17);
        if(y==51||y==143){
            n.ARM9Write16(0x07000000+e*1024+((f*14+y*8)&1022),randomWord(seed));
            n.ARM9Write16(0x05000000+e*1024+((f*2+y*4)&1022),randomWord(seed));
            n.ARM9Write32((e?0x06600000:0x06400000)+((f*16)&0x1fffc),randomWord(seed));
            const u32 bgbase=e?0x06200000:0x06000000;
            n.ARM9Write32(bgbase+((f*16)&0x1fffc),randomWord(seed));
            n.ARM9Write32(bgbase+0x4000+((f*4)&0xffc),randomWord(seed));
            // Palette banks can be written by external replay while mapped
            // as extended palettes. Mark the physical dirty pages as replay
            // does, so the next draw must see the new palette contents.
            const unsigned bank=e?7:4;
            for(unsigned slot=0;slot<4;slot++){
                const u32 offset=slot*8192+((f*2)&0x1ffe);
                const u16 color=randomWord(seed);
                std::memcpy(g.VRAM[bank]+offset,&color,sizeof(color));
                g.VRAMDirty[bank][offset/VRAMDirtyGranularity]=true;
            }
            g.MarkExternalRenderVRAM(bank);
        }
    }
}
int main()try{
    auto plain=fixture(false),indexed=fixture(true);unsigned comparisons=0;unsigned varied=0;
    for(unsigned f=0;f<72;f++)for(unsigned y=0;y<263;y++){
        for(auto*n:{plain.get(),indexed.get()}){
            unsigned vb=y>=192&&y<262;
            auto phase=[&](unsigned kind){if(!n->GPU.ApplyExternalRendererPhase(kind,y,y,vb|(kind==1?2:0),vb|(kind==1?2:0),f,true,f==0&&y==0&&kind==2,true))throw std::runtime_error("phase rejected");};
            phase(y==0?2:0);edit(*n,f,y);phase(1);
        }
        if(y>=192)continue;
        u32 *a[2],*b[2];
        if(!plain->GetRenderer().GetRenderedScanlines(y,&a[0],&a[1])||!indexed->GetRenderer().GetRenderedScanlines(y,&b[0],&b[1]))throw std::runtime_error("missing row");
        for(unsigned e=0;e<2;e++){
            if(std::memcmp(a[e],b[e],256*sizeof(u32)))throw std::runtime_error("pixel mismatch frame="+std::to_string(f)+" line="+std::to_string(y)+" engine="+std::to_string(e));
            for(unsigned x=1;x<256;x++)varied+=a[e][x]!=a[e][0];
            comparisons+=256;
        }
    }
    if(varied<10000)throw std::runtime_error("flat fixture");
    std::cout<<"SPRITE_PRIORITY_AFFINE_ORACLE_PASS pixels="<<comparisons<<" nonflat_pixels="<<varied<<" both_engines=1\n";
}catch(std::exception&e){std::cerr<<e.what()<<'\n';return 1;}
