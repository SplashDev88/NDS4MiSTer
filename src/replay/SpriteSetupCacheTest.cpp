// Differential sprite-phase oracle and CPU-only benchmark. Synthetic data only.
#include "Args.h"
#include "NDS.h"
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
using namespace melonDS;
static u32 randomWord(u32& s) { s ^= s<<13; s ^= s>>17; s ^= s<<5; return s; }
static std::unique_ptr<NDS> fixture(bool cache, bool tracked)
{
    setenv("NDS_GPU_SPRITE_SETUP_CACHE", cache ? "1" : "0", 1);
    setenv("NDS_GPU_SPRITE_BATCH", cache ? "1" : "0", 1);
    unsetenv("NDS_GPU_SPRITE_PHASE_CACHE");
    NDSArgs args; args.JIT=std::nullopt;
    auto n=std::make_unique<NDS>(std::move(args)); n->Reset();
    RendererSettings rs{};rs.Threaded=false;rs.ScaleFactor=1;
    n->GetRenderer().SetRenderSettings(rs);
    auto& g=n->GPU;
    u32 seed=12345;
    for (unsigned bank : {0u,3u})
        for(unsigned i=0;i<0x20000;i++)g.VRAM[bank][i]=randomWord(seed);
    g.MapVRAM_AB(0,0x82); g.MapVRAM_CD(3,0x84);
    for(unsigned i=0;i<sizeof(g.Palette);i++)g.Palette[i]=randomWord(seed);
    for(unsigned i=0;i<sizeof(g.OAM);i++)g.OAM[i]=randomWord(seed);
    // Include many disabled entries, like ordinary games, plus every size/type.
    for(unsigned e=0;e<2;e++)for(unsigned i=0;i<128;i++){
        auto* a=reinterpret_cast<u16*>(g.OAM+e*1024+i*8);
        if(i>=40)a[0]=0x200;
        else {a[0]=(a[0]&0x3fff)|((i&3)<<14);a[1]=(a[1]&0x3fff)|(((i>>2)&3)<<14);}
    }
    g.SetSpriteOAMWriteTracking(tracked); g.MarkSpriteOAMWritten(0,2048);
    return n;
}
static void edit(NDS& n,unsigned frame,unsigned line,bool tracked)
{
    auto& g=n.GPU;u32 seed=1+frame*192+line;
    if(line==31||line==140){
        const u32 addr=((frame*22+line*14)&2046);
        u16 value=randomWord(seed);
        if(tracked)g.WriteOAM<u16>(addr,value);
        else std::memcpy(g.OAM+addr,&value,2);
    }
    if(line==50){ // affine coefficients and priority/tile fields change too
        const u32 addr=(frame*16+6)&2046;
        u16 value=randomWord(seed);std::memcpy(g.OAM+addr,&value,2);
        if(tracked)g.MarkExternalRenderOAM(addr,2);
    }
    if(line==71){g.WriteOAM<u16>(4,g.ReadOAM<u16>(4));g.WriteOAM<u16>(1028,g.ReadOAM<u16>(1028));}
    if(line==96){n.ARM9Write32(0x06400000+((frame*16)&0x1fffc),randomWord(seed));n.ARM9Write32(0x06600000+((frame*16)&0x1fffc),randomWord(seed));}
    for(auto* e : {&g.GPU2D_A,&g.GPU2D_B}){
        e->Enabled=!(frame%9==3&&line>70&&line<90);
        e->OBJEnable=!(frame%7==2&&line>130&&line<145);
        e->OBJMosaicLine=(line/((frame%16)+1))*((frame%16)+1);
        e->DispCnt=0x1000 | ((frame&7)<<4) | ((frame&3)<<20) | ((frame&1)<<22);
    }
}
int main(int argc,char**argv)try{
    if(argc>1 && std::strcmp(argv[1],"--benchmark")==0){
        for(bool enabled : {false,true,true,false}){
            auto n=fixture(enabled,true);auto&g=n->GPU;
            g.GPU2D_A.Enabled=g.GPU2D_B.Enabled=true;
            g.GPU2D_A.OBJEnable=g.GPU2D_B.OBJEnable=true;
            g.GPU2D_A.DispCnt=g.GPU2D_B.DispCnt=0x1000;
            auto begin=std::chrono::steady_clock::now();
            for(unsigned f=0;f<1200;f++){
                g.WriteOAM<u16>(2,(f%256)|0x4000);
                for(unsigned y=0;y<192;y++)n->GetRenderer().DrawSprites(y);
            }
            auto us=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-begin).count();
            std::cout<<"sprite_setup="<<enabled<<" frames=1200 us="<<us<<'\n';
        }return 0;
    }
    unsigned comparisons=0;
    for(bool tracked : {false,true}){
        auto plain=fixture(false,tracked),cached=fixture(true,tracked);
        for(unsigned f=0;f<72;f++)for(unsigned y=0;y<192;y++){
            for(auto*n:{plain.get(),cached.get()}){
                edit(*n,f,y,tracked);n->GetRenderer().DrawSprites(y);
            }
            u64 a[4],b[4];plain->GetRenderer().GetOBJBufferHashes(a);cached->GetRenderer().GetOBJBufferHashes(b);
            if(std::memcmp(a,b,sizeof(a)))throw std::runtime_error("sprite mismatch frame="+std::to_string(f)+" line="+std::to_string(y)+" tracked="+std::to_string(tracked));
            comparisons++;
        }
    }
    std::cout<<"SPRITE_SETUP_ORACLE_PASS comparisons="<<comparisons<<" both_engines=1 tracked_and_direct_writes=1\n";
}catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}
