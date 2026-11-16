// Exact composition-cache oracle. No ROM or physical device is accessed.
#include "Args.h"
#include "NDS.h"
#include "GPU_Soft.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <iostream>
#include <memory>
#include <optional>
#include <stdexcept>
using namespace melonDS;

// Deterministic completed 3D rows let the test change 3D independently of 2D.
// Reject any future-row request from sprite preparation, including line262->0.
struct Guarded3D final : SoftRenderer3D {
    std::array<std::array<u32,256>,192> rows{};
    unsigned allowedLine=999, calls=0;
    Guarded3D(GPU3D& gpu,SoftRenderer& parent):SoftRenderer3D(gpu,parent){}
    void RenderFrame() override {}
    void RestartFrame() override {}
    void FinishRendering() override {}
    u32* GetLine(int line) override {
        if(line<0 || unsigned(line)>=192 || unsigned(line)!=allowedLine)
            throw std::runtime_error("future/invalid 3D row requested");
        ++calls;return rows[line].data();
    }
    void frame(unsigned f) {
        for(unsigned y=0;y<192;++y) for(unsigned x=0;x<256;++x)
            rows[y][x]=(x>=80 && x<125 && y>=40 && y<135) ?
                ((f/4%3==0?15u:31u)<<24) | (((f/4*3+y)&63)<<16) |
                (((x+f/4*11)&63)<<8) | ((x+y)&63) : 0;
    }
};
static void require(bool v,const char* message){if(!v)throw std::runtime_error(message);}
static std::unique_ptr<NDS> fixture(bool cache) {
    NDSArgs args;args.JIT=std::nullopt;auto n=std::make_unique<NDS>(std::move(args));n->Reset();auto& g=n->GPU;
    for(unsigned bank=0;bank<4;++bank){
        for(unsigned i=0;i<0x20000;++i)g.VRAM[bank][i]=1+(i*13+i/8*17+bank*29)%255;
        if(bank==0 || bank==2)for(unsigned i=0;i<1024;++i)
            reinterpret_cast<u16*>(g.VRAM[bank]+0x4000)[i]=i%96;
    }
    for(unsigned e=0;e<2;++e){
        for(unsigned i=0;i<512;++i)reinterpret_cast<u16*>(g.Palette+e*0x400)[i]=
            ((i*7)&31)|(((i*11+e*9)&31)<<5)|(((i*13)&31)<<10);
        auto* o=reinterpret_cast<u16*>(g.OAM+e*0x400);
        for(unsigned i=0;i<128;++i){o[i*4]=i<16?u16(0x2000+(i*11)%160):0x0200;
            o[i*4+1]=0x4000+((i*17)%240);o[i*4+2]=(i*4)%128;}
    }
    g.MapVRAM_AB(0,0x81);g.MapVRAM_AB(1,0x82);
    g.MapVRAM_CD(2,0x84);g.MapVRAM_CD(3,0x84);
    n->ARM9Write16(0x04000304,0x820f);
    n->ARM9Write32(0x04000000,0x00011308);
    n->ARM9Write16(0x04000008,0x0000);n->ARM9Write16(0x0400000a,0x0881);
    n->ARM9Write32(0x04001000,0x00011100);n->ARM9Write16(0x04001008,0x0881);
    RendererSettings s{};s.ScaleFactor=1;s.PackedOutput=true;s.PairedBCache=true;s.PairedACache=cache;
    g.GetRenderer().SetRenderSettings(s);
    auto& soft=static_cast<SoftRenderer&>(g.GetRenderer());
    soft.Rend3D=std::make_unique<Guarded3D>(g.GPU3D,soft);
    return n;
}
static Guarded3D& rows(NDS& n){return static_cast<Guarded3D&>(*static_cast<SoftRenderer&>(n.GPU.GetRenderer()).Rend3D);}
static void phase(NDS& n,unsigned f,unsigned y,unsigned kind) {
    rows(n).allowedLine=y;const unsigned vb=y>=192 && y<262;
    require(n.GPU.ApplyExternalRendererPhase(kind,y,y,vb|(kind==1?2:0),vb|(kind==1?2:0),f,true,false,true),"phase rejected");
}
static void edit(NDS& n,unsigned f,unsigned y) {
    auto& g=n.GPU;
    // Composition-time changes after the preceding line prepared these OBJ
    // pixels. Stable following frames must not reuse the old prepared row.
    if(y==50)switch(f){
    case 3:n.ARM9Write16(0x05000022,0x7c1f);g.MarkExternalRenderPalette(0x22,2);break;
    case 6:n.ARM9Write32(0x06000020,0x08070605);g.MarkExternalRenderVRAM(0);break;
    case 9:n.ARM9Write16(0x04000014,13);break;
    case 12:n.ARM9Write16(0x0400006c,0x4008);break;
    case 15:n.ARM9Write16(0x0400006c,0);break;
    case 18:n.ARM9Write32(0x04000000,0x00011388);break;
    case 21:n.ARM9Write32(0x04000000,0x00011308);break;
    case 24:n.ARM9Write16(0x04000304,0x020f);break;
    case 27:n.ARM9Write16(0x04000304,0x020e);break;
    case 30:n.ARM9Write16(0x04000304,0x020f);break;
    case 33:n.ARM9Write32(0x04000000,0x00013308);n.ARM9Write16(0x04000040,0x30c0);
        n.ARM9Write16(0x04000044,0x10a0);n.ARM9Write16(0x04000048,0x003f);n.ARM9Write16(0x0400004a,0);break;
    case 36:n.ARM9Write16(0x0400000a,0x08c1);n.ARM9Write16(0x0400004c,0x3333);break;
    case 39:g.MapVRAM_AB(0,0x80);break;
    case 42:g.MapVRAM_AB(0,0x81);break;
    case 45:n.ARM9Write32(0x04000000,0x00010000);break;
    case 48:n.ARM9Write32(0x04000000,0x00011308);break;
    case 51:n.ARM9Write16(0x07000002,0x4040);g.MarkExternalRenderOAM(2,2);break;
    case 54:n.ARM9Write16(0x05000222,0x001f);g.MarkExternalRenderPalette(0x222,2);break;
    case 57:n.ARM9Write32(0x06400020,0x090a0b0c);g.MarkExternalRenderVRAM(1);break;
    case 60:n.ARM9Write16(0x07000002,0x5040);g.MarkExternalRenderOAM(2,2);break;
    case 63:n.ARM9Write32(0x04000000,0x00011402);n.ARM9Write16(0x0400000c,0x0881);
        n.ARM9Write16(0x04000020,0x0100);n.ARM9Write16(0x04000026,0x0100);break;
    case 66:n.ARM9Write16(0x04000022,0x0011);n.ARM9Write32(0x04000028,0x00001200);break;
    case 69:n.ARM9Write32(0x04000000,0x00011308);break;
    case 72:n.ARM9Write16(0x04000304,0x820d);break; // A disabled, OBJ buffers retained
    case 75:n.ARM9Write16(0x07000002,0x4054);g.MarkExternalRenderOAM(2,2);break;
    case 78:n.ARM9Write16(0x04000304,0x820f);break;
    case 81:g.MapVRAM_AB(1,0x80);break;
    case 84:g.MapVRAM_AB(1,0x82);break;
    case 87:g.ResetVRAMCache();break;
    case 90:n.ARM9Write32(0x04000000,0x00021300);break; // VRAM display
    case 93:n.ARM9Write32(0x04000000,0x00031300);break; // FIFO display
    case 96:n.ARM9Write32(0x04000000,0x00011308);break;
    case 99:n.ARM9Write16(0x04000050,0x0841);n.ARM9Write16(0x04000052,0x0808);break;
    case 102:n.ARM9Write16(0x04000050,0x0081);n.ARM9Write16(0x04000054,8);break;
    case 105:n.ARM9Write16(0x04000050,0);break;
    case 108:n.ARM9Write16(0x0400004c,0);break;
    case 111:n.ARM9Write32(0x04000000,0x00011300);break;
    case 114:n.ARM9Write32(0x04000000,0x00011308);break;
    default:break;
    }
    if(y==0 && f>=120){
        g.MapVRAM_AB(1,0x80);
        const unsigned mode=(f-120)%4;
        n.ARM9Write32(0x04000064,0x80000000u|(mode<<29)|((f&1)?1u<<24:0)|
            ((f&2)?1u<<25:0)|(3u<<20)|(1u<<16)|0x0808);
    }
}
static void equalState(NDS& a,NDS& b){
    constexpr unsigned sizes[]={0x20000,0x20000,0x20000,0x20000,0x10000,0x4000,0x4000,0x8000,0x4000};
    for(unsigned bank=0;bank<9;++bank)require(std::memcmp(a.GPU.VRAM[bank],b.GPU.VRAM[bank],sizes[bank])==0,"capture/VRAM differs");
    for(auto pair:{std::pair<GPU2D*,GPU2D*>{&a.GPU.GPU2D_A,&b.GPU.GPU2D_A},{&a.GPU.GPU2D_B,&b.GPU.GPU2D_B}}){
        require(std::memcmp(pair.first->BGXRefInternal,pair.second->BGXRefInternal,sizeof(pair.first->BGXRefInternal))==0,"affine X differs");
        require(std::memcmp(pair.first->BGYRefInternal,pair.second->BGYRefInternal,sizeof(pair.first->BGYRefInternal))==0,"affine Y differs");
        require(pair.first->OBJMosaicLine==pair.second->OBJMosaicLine && pair.first->BGMosaicLine==pair.second->BGMosaicLine,"mosaic state differs");
    }
}
int main(int argc,char** argv)try{
    const bool bench=argc==2 && std::strcmp(argv[1],"--benchmark")==0;
    require(argc==1 || bench,"unknown argument");
    if(bench){
        for(bool cache:{false,true}){auto n=fixture(cache);const auto start=std::chrono::steady_clock::now();
            for(unsigned f=0;f<240;++f){rows(*n).frame(f);for(unsigned y=0;y<263;++y){phase(*n,f,y,y==0?2:0);phase(*n,f,y,1);}}
            std::cout<<"PAIRED_A_CPU_KERNEL cache="<<cache<<" frames=240 us="<<std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-start).count()<<'\n';}
        return 0;
    }
    u64 hits=0,misses=0,pixels=0,gets=0;
    for(bool direct:{false,true}){
        auto a=fixture(false),b=fixture(true);
        using Plane=std::array<u32,256*192+4>;
        auto out=std::make_unique<std::array<std::array<Plane,2>,2>>();
        for(auto& slot:*out)for(auto& plane:slot)plane.fill(0xdeadbeef);
        std::array<Plane,2> completed{};
        for(unsigned f=0;f<136;++f){rows(*a).frame(f);rows(*b).frame(f);
            for(unsigned y=0;y<263;++y){
                if(direct && y==0)require(b->GetRenderer().SetExternalFramebuffers((*out)[f&1][0].data()+2,(*out)[f&1][1].data()+2),"direct output rejected");
                for(auto* n:{a.get(),b.get()}){phase(*n,f,y,y==0?2:0);edit(*n,f,y);phase(*n,f,y,1);}
                if(y>=192)continue;
                u32 *ap[2],*bp[2];require(a->GetRenderer().GetRenderedScanlines(y,&ap[0],&ap[1]),"reference row missing");
                require(b->GetRenderer().GetRenderedScanlines(y,&bp[0],&bp[1]),"candidate row missing");
                for(unsigned s=0;s<2;++s){if(std::memcmp(ap[s],bp[s],256*sizeof(u32))){
                    std::cerr<<"mismatch f="<<f<<" y="<<y<<" screen="<<s<<'\n';return 1;}pixels+=256;}
                bool hitA=false,hitB=false;b->GetRenderer().GetExternalLineCacheResult(hitA,hitB);if(hitA)++hits;else ++misses;
                if(y==191){equalState(*a,*b);if(direct){
                    for(auto& plane:(*out)[f&1])require(plane[0]==0xdeadbeef && plane[1]==0xdeadbeef && plane[plane.size()-1]==0xdeadbeef && plane[plane.size()-2]==0xdeadbeef,"plane guard overwritten");
                    if(f)require((*out)[(f^1)&1]==completed,"completed frame overwritten");completed=(*out)[f&1];b->GetRenderer().SetExternalFramebuffers(nullptr,nullptr);
                }}
            }
        }
        require(rows(*a).calls==rows(*b).calls,"cache changed 3D request count");gets+=rows(*b).calls;
    }
    require(hits>1000 && misses>1000,"insufficient cache hit/miss coverage");
    std::cout<<"PAIRED_A_LINE_CACHE_ORACLE_PASS frames=272 pixels="<<pixels<<" hits="<<hits<<" misses="<<misses<<" current_3d_requests="<<gets<<" future_3d_requests=0\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}
