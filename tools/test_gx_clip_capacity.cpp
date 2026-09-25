// SPDX-License-Identifier: GPL-3.0-or-later
// Compiles the production clipper extracted by test_gx_clip_capacity.sh.
#include "clip_under_test.h"
#include <random>
#include <cstring>
#include <cstdio>
#include <algorithm>

static unsigned unchangedCases=0, overflowCases=0;
template<bool attribs> bool check(const melonDS::Vertex* input, int count, int start)
{
    melonDS::Vertex candidate[10]{};
    melonDS::Vertex reference[256]{};
    std::copy(input,input+count,candidate);
    std::copy(input,input+count,reference);
    tested::TestGPU gpu{1u<<12};
    unbounded::TestGPU refGpu{1u<<12};
    unbounded::peak=0;
    int a=count,b=count;
#define PLANE(C) \
    a=tested::ClipAgainstPlane<C,attribs>(gpu,candidate,a,start); \
    b=unbounded::ClipAgainstPlane<C,attribs>(refGpu,reference,b,start); \
    if(a<0 || a>10) return false;
    PLANE(2)
    PLANE(1)
    PLANE(0)
#undef PLANE
    if(unbounded::peak>10) { ++overflowCases;return true; }
    if(a!=b) { std::fprintf(stderr,"count mismatch %d %d\n",a,b);return false; }
    for(int i=0;i<a;i++) {
        if(std::memcmp(candidate[i].Position,reference[i].Position,sizeof(candidate[i].Position)) ||
           candidate[i].Clipped!=reference[i].Clipped) return false;
        if constexpr(attribs) {
            if(std::memcmp(candidate[i].Color,reference[i].Color,sizeof(candidate[i].Color)) ||
               std::memcmp(candidate[i].TexCoords,reference[i].TexCoords,sizeof(candidate[i].TexCoords))) return false;
        }
    }
    ++unchangedCases;return true;
}
int main()
{
    melonDS::Vertex input[10]{};
    // A valid ten-entry intermediate with five outside corners emits fifteen
    // vertices in the old unbounded pass: guaranteed negative-control trigger.
    for(int i=0;i<10;i++) {
        input[i].Position[3]=0x1000;
        input[i].Position[2]=(i&1)?0x2000:0;
        for(auto& c:input[i].Color)c=0x123fff;
    }
    if(!check<true>(input,10,0))return 1;
    std::mt19937 rng(0x1F25C11Fu);
    for(unsigned iteration=0;iteration<40000;iteration++) {
        for(auto& v:input) {
            v={};
            for(auto& p:v.Position)p=static_cast<int32_t>(rng());
            if(iteration%3==0) {
                v.Position[3]=1+rng()%0x10000;
                for(int c=0;c<3;c++)v.Position[c]=int32_t(rng()%(2*v.Position[3]+1))-v.Position[3];
            }
            for(auto& c:v.Color)c=int32_t(rng()&0x1fffff);
            for(auto& t:v.TexCoords)t=int16_t(rng());
        }
        const int count=3+iteration%2;
        if(!check<true>(input,count,0) || !check<false>(input,count,0)) return 2;
        if(count==4 && !check<true>(input,count,2))return 3;
    }
    if(!overflowCases || !unchangedCases)return 4;
    std::printf("PASS: actual clipper %u unchanged cases, %u bounded overflow cases\n",unchangedCases,overflowCases);
}
