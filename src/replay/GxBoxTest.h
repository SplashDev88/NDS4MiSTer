// SPDX-License-Identifier: GPL-3.0-or-later
// Position-only BOX_TEST derived from melonDS GPU3D.cpp.
// Copyright 2016-2026 melonDS team. See third_party/melonDS for its license.
#pragma once
#include "types.h"
#include "NDS4MiSTer_GXClipMath.h"
#include <array>

namespace nds4mister::replay {
namespace box_detail {
using Point = std::array<melonDS::s32, 4>;

template<int Axis, int Sign>
inline Point intersection(const Point& in, const Point& out)
{
    using namespace melonDS;
    const auto f = NDS4MiSTerResolveGXClipFactors<Sign>(
        in[Axis], in[3], out[Axis], out[3]);
    Point result{};
    if (f.Widened) {
        for (unsigned j=0; j<4; ++j)
            if (j!=Axis) result[j]=NDS4MiSTerGXClipInterpolateWide(in[j],out[j],f);
    } else {
        const NDS4MiSTerGXClipDivider divider(static_cast<s32>(f.Denominator));
        for (unsigned j=0; j<4; ++j)
            if (j!=Axis) result[j]=in[j]+divider.divide((s64(out[j])-in[j])*f.Numerator);
    }
    result[Axis]=static_cast<s32>(static_cast<s64>(Sign)*result[3]);
    return result;
}

template<int Axis>
inline unsigned plane(std::array<Point,10>& vertices, unsigned count, bool far_clip)
{
    std::array<Point,10> temp{};
    unsigned n=0;
    for (unsigned i=0; i<count; ++i) {
        const auto& v=vertices[i];
        if (v[Axis]>v[3]) {
            if (Axis==2 && !far_clip) return 0;
            const auto& prev=vertices[i?i-1:count-1];
            const auto& next=vertices[i+1<count?i+1:0];
            if (prev[Axis]<=prev[3]) temp[n++]=intersection<Axis,1>(v,prev);
            if (next[Axis]<=next[3]) temp[n++]=intersection<Axis,1>(v,next);
        } else temp[n++]=v;
    }
    count=n; n=0;
    for (unsigned i=0; i<count; ++i) {
        const auto& v=temp[i];
        if (v[Axis]<-v[3]) {
            const auto& prev=temp[i?i-1:count-1];
            const auto& next=temp[i+1<count?i+1:0];
            if (prev[Axis]>=-prev[3]) vertices[n++]=intersection<Axis,-1>(v,prev);
            if (next[Axis]>=-next[3]) vertices[n++]=intersection<Axis,-1>(v,next);
        } else vertices[n++]=v;
    }
    return n;
}
}

inline bool gx_box_test(const std::array<melonDS::s32,16>& matrix,
    const melonDS::s32* params, bool far_clip)
{
    using namespace melonDS;
    using namespace box_detail;
    const s16 x0=params[0]&0xffff, y0=params[0]>>16, z0=params[1]&0xffff;
    const s16 x1=static_cast<s16>((params[1]>>16)+x0);
    const s16 y1=static_cast<s16>((params[2]&0xffff)+y0);
    const s16 z1=static_cast<s16>((params[2]>>16)+z0);
    std::array<Point,8> cube{{{x0,y0,z0,0},{x1,y0,z0,0},{x1,y1,z0,0},{x0,y1,z0,0},
                             {x0,y1,z1,0},{x0,y0,z1,0},{x1,y0,z1,0},{x1,y1,z1,0}}};
    for (auto& p:cube) {
        const s32 x=p[0],y=p[1],z=p[2];
        for (unsigned j=0;j<4;++j)
            p[j]=static_cast<s32>((s64(x)*matrix[j]+s64(y)*matrix[4+j]+
                s64(z)*matrix[8+j]+s64(4096)*matrix[12+j])>>12);
    }
    constexpr unsigned faces[6][4]={{0,1,2,3},{4,5,6,7},{0,3,4,5},
                                   {1,2,7,6},{0,1,6,5},{2,3,4,7}};
    for (const auto& indices:faces) {
        std::array<Point,10> face{};
        for (unsigned j=0;j<4;++j) face[j]=cube[indices[j]];
        auto n=plane<2>(face,4,far_clip);
        n=plane<1>(face,n,far_clip); n=plane<0>(face,n,far_clip);
        if(n) return true;
    }
    return false;
}
}
