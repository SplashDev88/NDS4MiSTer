// SPDX-License-Identifier: GPL-3.0-or-later
// Exact row reuse for fixed backgrounds.
// Nonuniform-depth/w geometry is never reused; its old and new rows redraw.
// Only candidate background quads receive complete exact keys.
// The caller must supply TextureCache.Update() == false for this exact frame.
// Any texture/palette write, including identical data, prevents all row hits.
// Only raster-consumed vertex fields enter
// the key; original clip-space fields and hires coordinates are unused here.
// Hashes select candidates; exact comparison
// decides equality. Capacity overflow, shadows and neighbor-dependent effects
// fall back to ordinary rasterization. No geometry, guest timing or pixels
// are dropped, and no extra frame buffer is copied.
#pragma once
#include "GPU3D.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <memory>
namespace melonDS {
class NDS4MiSTerBackgroundRowCache {
    static constexpr unsigned Max=256, Buckets=1024;
    struct Key {
        u32* words=nullptr;
        unsigned size=0;
        u32 hash=2166136261u;
        void add(u32 value) { words[size++]=value; }
        template<class T,size_t N> void add(const T(&a)[N]) {for(auto v:a)add(u32(v));}
        void build(const Polygon& p) {
            size=0;hash=2166136261u;
            add(p.NumVertices);add(p.WBuffer);add(p.Attr);add(p.TexParam);add(p.TexPalette);
            add(p.Degenerate);add(p.FacingView);add(p.Translucent);add(p.IsShadowMask);add(p.IsShadow);
            add(p.Type);add(p.VTop);add(p.VBottom);add(p.YTop);add(p.YBottom);add(p.XTop);add(p.XBottom);add(p.SortKey);
            for(unsigned i=0;i<p.NumVertices;++i) {
                add(p.FinalZ[i]);add(p.FinalW[i]);auto& v=*p.Vertices[i];
                add(v.FinalPosition);add(v.FinalColor);add(v.TexCoords);
            }
            // Small lookup hash; the complete key is always compared below.
            for(unsigned i=0;i<std::min(size,30u);++i)hash=(hash^words[i])*16777619u;
        }
        bool equal(const Key& other)const {return size==other.size&&!std::memcmp(words,other.words,size*sizeof(u32));}
    };
    std::array<Key,Max> keys[2];
    std::array<u32,Max*54> storage[2];
    std::array<u16,Buckets> buckets{};
    std::array<u16,Max> next{};
    std::array<std::array<u16,Max>,192> rowIds;
    std::array<u16,192> rowCounts{};
    std::array<bool,192> previousVolatile{};
    std::array<u32,83> regs{};
    unsigned previousCount=0,previousBank=0;
    bool valid=false,pendingValid=false;
    static std::array<u32,83> registers(const GPU3D& g,u32 effectiveDispCnt) {
        std::array<u32,83> r{};unsigned i=0;r[i++]=effectiveDispCnt;
        for(auto v:{g.RenderDispCnt,u32(g.RenderAlphaRef),g.RenderFogColor,g.RenderFogOffset,g.RenderFogShift,g.RenderClearAttr1,g.RenderClearAttr2,u32(g.RenderXPos)})r[i++]=v;
        for(auto v:g.RenderToonTable)r[i++]=v;
        for(auto v:g.RenderEdgeTable)r[i++]=v;
        for(auto v:g.RenderFogDensityTable)r[i++]=v;
        return r;
    }
public:
    std::array<bool,192> reusable{};
    unsigned matchedPolygons=0,compares=0,hitRows=0;
    void invalidate(){valid=pendingValid=false;reusable.fill(false);}
    void commit(){valid=pendingValid;}
    void prepare(const GPU3D& g,u32 effectiveDispCnt,bool textureUnchanged,bool allowed=true) {
        pendingValid=false;reusable.fill(false);matchedPolygons=compares=hitRows=0;
        if(!allowed || (effectiveDispCnt&((1u<<4)|(1u<<5)|(1u<<7)|(1u<<14))) || g.RenderNumPolygons>2048) {valid=false;return;}
        for(unsigned i=0;i<g.RenderNumPolygons;++i) {
            auto* p=g.RenderPolygonRAM[i];
            if(!p || p->NumVertices>10 || p->IsShadow || p->IsShadowMask){valid=false;return;}
        }
        const auto currentRegs=registers(g,effectiveDispCnt);
        bool shared=valid && textureUnchanged && regs==currentRegs;
        regs=currentRegs;
        buckets.fill(0);
        auto& previous=keys[previousBank];auto& current=keys[previousBank^1];
        if(shared)for(unsigned i=0;i<previousCount;++i) {
            auto bucket=previous[i].hash&(Buckets-1);next[i]=buckets[bucket];buckets[bucket]=u16(i+1);
        }
        reusable.fill(shared);std::array<u16,192> counts{};unsigned count=0,wordOffset=0;std::array<bool,192> currentVolatile{};
        for(unsigned i=0;i<g.RenderNumPolygons;++i) {
            auto& p=*g.RenderPolygonRAM[i];if(p.Degenerate)continue;
            bool background=p.NumVertices==4;
            if(background)for(unsigned v=1;v<4;++v)background=background&&p.FinalW[v]==p.FinalW[0]&&p.FinalZ[v]==p.FinalZ[0];
            if(!background) {
                for(int y=std::max(0,p.YTop);y<std::min(192,std::max(p.YTop+1,p.YBottom));++y)currentVolatile[y]=true;
                continue;
            }
            if(count==Max){invalidate();return;}
            auto& key=current[count];key.words=storage[previousBank^1].data()+wordOffset;key.build(p);wordOffset+=key.size;unsigned match=0;
            if(shared)for(unsigned id=buckets[key.hash&(Buckets-1)];id;id=next[id-1]) {
                ++compares;if(key.equal(previous[id-1])){match=id;++matchedPolygons;break;}
            }
            for(int y=std::max(0,p.YTop);y<std::min(192,std::max(p.YTop+1,p.YBottom));++y) {
                unsigned pos=counts[y]++;
                if(!match || pos>=rowCounts[y] || rowIds[y][pos]!=match)reusable[y]=false;
                rowIds[y][pos]=u16(count+1);
            }
            ++count;
        }
        for(unsigned y=0;y<192;++y) {reusable[y]=reusable[y]&&counts[y]==rowCounts[y]&&!currentVolatile[y]&&!previousVolatile[y];hitRows+=reusable[y];}
        previousVolatile=currentVolatile;rowCounts=counts;previousCount=count;previousBank^=1;
        // Caller must commit only after all raster workers finish successfully.
        valid=false;pendingValid=true;
    }
};
}
