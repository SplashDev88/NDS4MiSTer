// SPDX-License-Identifier: GPL-3.0-or-later
// Exact unchanged background spans. Model and unmatched-background bounds in
// both frames redraw; a common ordered subsequence proves all other pixels.
// The caller excludes neighbor effects/shadows and commits completed frames.
#pragma once
#include "GPU3D.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <vector>
namespace melonDS {
class NDS4MiSTerBackgroundSpanCache {
    static constexpr unsigned Max=256;
    struct Key {
        u32* words=nullptr;
        unsigned size=0;
        u32 hash=2166136261u;
        void add(u32 value) { words[size++]=value; }
        template<class T,size_t N> void add(const T(&a)[N]) {for(auto v:a)add(u32(v));}
        template<bool Hash = true> void build(const Polygon& p) {
            size=0;hash=2166136261u;
            add(p.NumVertices);add(p.WBuffer);add(p.Attr);add(p.TexParam);add(p.TexPalette);
            add(p.Degenerate);add(p.FacingView);add(p.Translucent);add(p.IsShadowMask);add(p.IsShadow);
            add(p.Type);add(p.VTop);add(p.VBottom);add(p.YTop);add(p.YBottom);add(p.XTop);add(p.XBottom);add(p.SortKey);
            for(unsigned i=0;i<p.NumVertices;++i) {
                add(p.FinalZ[i]);add(p.FinalW[i]);auto& v=*p.Vertices[i];
                add(v.FinalPosition);add(v.FinalColor);add(v.TexCoords);
            }
            // Small lookup hash; the complete key is always compared below.
            if constexpr (Hash) for(unsigned i=0;i<std::min(size,30u);++i)hash=(hash^words[i])*16777619u;
        }
        bool equal(const Key& other)const {return size==other.size&&!std::memcmp(words,other.words,size*sizeof(u32));}
    };

    struct Bounds { s16 left=256,right=0,top=0,bottom=0; };
    struct Span { s16 left=256,right=0; };
    using Spans=std::array<Span,192>;
    std::array<Key,Max> keys[2];
    std::array<u32,Max*54> storage[2];
    std::array<Bounds,Max> bounds[2];
    std::array<u16,(Max+1)*(Max+1)> lcs;
    Spans previousModels{};
    std::array<u32,83> regs{};
    unsigned previousCount=0,previousBank=0;
    bool valid=false,pendingValid=false;
    static Bounds extent(const Polygon& p) {
        s32 first=256,last=0;
        for(unsigned i=0;i<p.NumVertices;++i){first=std::min(first,p.Vertices[i]->FinalPosition[0]);last=std::max(last,p.Vertices[i]->FinalPosition[0]);}
        Bounds b;
        b.left=first>2?first-2:0;b.right=last<253?last+3:256;
        b.top=std::clamp(p.YTop,0,192);b.bottom=std::clamp(p.YBottom,0,192);
        if(p.YTop==p.YBottom&&p.YTop>=0&&p.YTop<192)b.bottom=b.top+1;
        return b;
    }
    static void mark(Spans& spans,const Bounds& b) {
        if(b.left>=b.right)return;
        for(int y=b.top;y<b.bottom;++y){spans[y].left=std::min(spans[y].left,b.left);spans[y].right=std::max(spans[y].right,b.right);}
    }
    static std::array<u32,83> registers(const GPU3D& g,u32 effectiveDispCnt) {
        std::array<u32,83> r{};unsigned i=0;r[i++]=effectiveDispCnt;
        for(auto v:{g.RenderDispCnt,u32(g.RenderAlphaRef),g.RenderFogColor,g.RenderFogOffset,g.RenderFogShift,g.RenderClearAttr1,g.RenderClearAttr2,u32(g.RenderXPos)})r[i++]=v;
        for(auto v:g.RenderToonTable)r[i++]=v;
        for(auto v:g.RenderEdgeTable)r[i++]=v;
        for(auto v:g.RenderFogDensityTable)r[i++]=v;
        return r;
    }
    struct PositionalDraw {
        std::array<u32,128> words;
        Bounds extent;
    };
    std::vector<PositionalDraw> previousDraws;
    bool usedPositions = false;
public:
    std::array<bool,192> reusable{};
    std::array<s16,192> dirtyStart{},dirtyEnd{};
    unsigned hitRows=0,reusedPixels=0;
    void invalidate(){valid=pendingValid=false;reusable.fill(false);dirtyStart.fill(0);dirtyEnd.fill(256);hitRows=reusedPixels=0;}
    void commit(){valid=pendingValid;}
    template<typename IsRetained>
    void preparePositions(const GPU3D& g, u32 effective, IsRetained retained)
    {
        reusable.fill(false);
        dirtyStart.fill(0);
        dirtyEnd.fill(256);
        hitRows = reusedPixels = 0;
        pendingValid = false;
        const auto currentRegs = registers(g, effective);
        const bool canReuse = valid && usedPositions && regs == currentRegs;
        usedPositions = true;
        valid = false;
        const unsigned count = g.RenderNumPolygons;
        if (count > 2048) return;
        const auto oldCount = previousDraws.size();
        if (oldCount < count) previousDraws.resize(count);
        Spans dirty{};
        for (unsigned i = 0; i < count; ++i) {
            const auto* p = g.RenderPolygonRAM[i];
            if (!p || p->Degenerate || p->NumVertices < 3 || p->NumVertices > 10 || p->IsShadow || p->IsShadowMask)
                return;
            std::array<u32,128> current;
            Key key;
            key.words = current.data();
            key.build<false>(*p);
            for (unsigned v = 0; v < p->NumVertices; ++v) key.add(p->Vertices[v]->HiresPosition);
            auto& last = previousDraws[i];
            bool equal = canReuse && i < oldCount && std::memcmp(last.words.data(), current.data(), key.size * sizeof(u32)) == 0;
            if (equal && (!(effective & 1u) || ((p->TexParam >> 26) & 7u) == 0u || retained(*p)))
                continue;
            if (canReuse && i < oldCount) mark(dirty,last.extent);
            const Bounds b = extent(*p);
            if (canReuse) mark(dirty,b);
            last.extent = b;
            std::memcpy(last.words.data(), current.data(), key.size * sizeof(u32));
        }
        if (canReuse) {
            for (unsigned i = count; i < oldCount; ++i) mark(dirty,previousDraws[i].extent);
            for (unsigned y=0; y<192; ++y) {
                dirtyStart[y]=dirty[y].left; dirtyEnd[y]=dirty[y].right;
                reusable[y]=dirtyStart[y]>=dirtyEnd[y];
                hitRows+=reusable[y];
                reusedPixels+=256-std::max(0,int(dirtyEnd[y]-dirtyStart[y]));
            }
        }
        previousDraws.resize(count);
        regs = currentRegs;
        pendingValid = true;
    }

    void prepare(const GPU3D& g,u32 effectiveDispCnt,bool textureUnchanged) {
        if (usedPositions) invalidate();
        usedPositions = false;
        pendingValid=false;reusable.fill(false);dirtyStart.fill(0);dirtyEnd.fill(256);hitRows=reusedPixels=0;
        if((effectiveDispCnt&((1u<<4)|(1u<<5)|(1u<<7)|(1u<<14)))||g.RenderNumPolygons>2048){invalidate();return;}
        for(unsigned i=0;i<g.RenderNumPolygons;++i){const auto* p=g.RenderPolygonRAM[i];if(!p||p->NumVertices>10||p->IsShadow||p->IsShadowMask){invalidate();return;}}
        const auto currentRegs=registers(g,effectiveDispCnt);
        const bool shared=valid&&textureUnchanged&&regs==currentRegs;
        auto& previous=keys[previousBank];auto& current=keys[previousBank^1];
        auto& oldBounds=bounds[previousBank];auto& newBounds=bounds[previousBank^1];
        Spans models{};unsigned count=0,wordOffset=0;
        for(unsigned i=0;i<g.RenderNumPolygons;++i){const auto& p=*g.RenderPolygonRAM[i];if(p.Degenerate)continue;
            bool background=p.NumVertices==4;
            if(background)for(unsigned v=1;v<4;++v)background=background&&p.FinalW[v]==p.FinalW[0]&&p.FinalZ[v]==p.FinalZ[0];
            const auto b=extent(p);
            if(!background){mark(models,b);continue;}
            if(count==Max){invalidate();return;}
            auto& k=current[count];k.words=storage[previousBank^1].data()+wordOffset;k.build(p);wordOffset+=k.size;
            newBounds[count++]=b;
        }
        if(shared){
            const unsigned stride=previousCount+1;
            auto at=[&](unsigned i,unsigned j)->u16&{return lcs[i*stride+j];};
            auto same=[&](unsigned i,unsigned j){return current[i].hash==previous[j].hash&&current[i].equal(previous[j]);};
            for(unsigned j=0;j<=previousCount;++j)at(0,j)=0;
            for(unsigned i=1;i<=count;++i){at(i,0)=0;for(unsigned j=1;j<=previousCount;++j)at(i,j)=same(i-1,j-1)?at(i-1,j-1)+1:std::max(at(i-1,j),at(i,j-1));}
            std::array<bool,Max> keepCurrent{},keepPrevious{};unsigned i=count,j=previousCount;
            while(i&&j){if(same(i-1,j-1)){keepCurrent[--i]=true;keepPrevious[--j]=true;}else if(at(i-1,j)>=at(i,j-1))--i;else --j;}
            auto dirty=models;
            for(unsigned y=0;y<192;++y){dirty[y].left=std::min(dirty[y].left,previousModels[y].left);dirty[y].right=std::max(dirty[y].right,previousModels[y].right);}
            for(i=0;i<count;++i)if(!keepCurrent[i])mark(dirty,newBounds[i]);
            for(j=0;j<previousCount;++j)if(!keepPrevious[j])mark(dirty,oldBounds[j]);
            for(unsigned y=0;y<192;++y){dirtyStart[y]=dirty[y].left;dirtyEnd[y]=dirty[y].right;reusable[y]=dirtyStart[y]>=dirtyEnd[y];hitRows+=reusable[y];reusedPixels+=256-std::max(0,int(dirtyEnd[y]-dirtyStart[y]));}
        }
        previousModels=models;previousCount=count;previousBank^=1;regs=currentRegs;
        valid=false;pendingValid=true;
    }
};
}
