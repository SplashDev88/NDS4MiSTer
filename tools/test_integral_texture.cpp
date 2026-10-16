#include "GPU3D_Soft.h"
#include <cstdio>
#include <cstdlib>
#include <algorithm>
using namespace melonDS;
using I=SoftRenderer3D::Interpolator<0>;
using S=I::SpanInterpolator;
int main() {
    unsigned random=0x6c731a8f, accepted=0, rejected=0; unsigned long long checks=0;
    auto next=[&](){random^=random<<13;random^=random>>17;random^=random<<5;return random;};
    for(int width: {0,1,2,3,7,16,31,64,127,192,255,256})
    for(bool perspective: {false,true})
    for(bool wbuffer: {false,true})
    for(unsigned trial=0;trial<256;++trial) {
        I parent(13,13+width,2048,perspective?4096:2048,wbuffer);
        int s0=int(next()&65535)-32768,s1=int(next()&65535)-32768;
        int t0=int(next()&65535)-32768,t1=int(next()&65535)-32768;
        if(trial%3==0) {s0=-2048;s1=s0+(int(trial%31)-15)*width;t0=1024;t1=t0+(int(trial%19)-9)*width;}
        if(trial%5==0) {s1=s0;t1=t0;}
        S span(parent,511,511,511,511,511,511,s0,s1,t0,t1);
        parent.SetX(13); int original[5];span.Interpolate(original);
        const int first=width?int(next()%unsigned(width+1)):0;
        int s,t,ds,dt; bool ok=span.PrepareIntegralTextureSpan(first+13,s,t,ds,dt);
        bool expected=!perspective&&width>0&&(s1-s0)%width==0&&(t1-t0)%width==0;
        if(ok!=expected) return std::fprintf(stderr,"guard mismatch\n"),1;
        if(!ok) {++rejected;continue;} ++accepted;
        for(int x=first;x<=width;++x,s+=ds,t+=dt) {
            parent.SetX(x+13);
            if(s!=parent.Interpolate(s0,s1)||t!=parent.Interpolate(t0,t1))
                return std::fprintf(stderr,"coordinate mismatch width=%d x=%d\n",width,x),1;
            checks+=2;
        }
        // Resume the generic edge after the independent span, including
        // reverse jumps and a single-pixel continuation from the old state.
        for(int x: {width,0,1,width/2}) {
            if(x>width)continue;
            parent.SetX(x+13);span.Interpolate(original);
            if(original[3]!=parent.Interpolate(s0,s1)||original[4]!=parent.Interpolate(t0,t1))
                return std::fprintf(stderr,"generic edge resync mismatch\n"),1;
            checks+=2;
        }
    }
    std::printf("PASS integral texture: accepted=%u rejected=%u coordinate checks=%llu\n",accepted,rejected,checks);
}
