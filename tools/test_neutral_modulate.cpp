// Compare the optimized identity path against the existing DS modulate kernel.
#include "GPU3D_Soft.h"
#include <cstdio>
using namespace melonDS;
int main() {
    u64 cases=0;u32 random=0x7c31a598;
    auto check=[&](u32 texel,u32 ref) {
        u32 got=0xdeadbeef,expected=0xdeadbeef;
        bool a=NDS4MiSTerNeutralOpaqueCachedPixel(texel,ref,got);
        bool b=NDS4MiSTerModulateVisibleCachedPixel(texel,0x003f3f3f,31,ref,expected);
        ++cases;
        if(a!=b||got!=expected) {
            std::fprintf(stderr,"FAIL texel=%08x ref=%u got=%08x expected=%08x\n",texel,ref,got,expected);return false;
        }
        return true;
    };
    // Every legal RGB triplet, texture alpha and rejection boundary. Noise in
    // unused RGB bits checks exact output packing as well as visible colors.
    for(u32 r=0;r<64;r++)for(u32 g=0;g<64;g++)for(u32 b=0;b<64;b++)
    for(u32 a=0;a<32;a++) {
        u32 p=r|(g<<8)|(b<<16)|(a<<24);
        if(!check(p,a)||!check(p|0x00c0c0c0,a?a-1:0))return 1;
    }
    // All native alpha/test-reference pairs with independent channel values.
    for(u32 a=0;a<32;a++)for(u32 ref=0;ref<32;ref++)for(u32 n=0;n<1024;n++) {
        random^=random<<13;random^=random>>17;random^=random<<5;
        if(!check((random&0xffffff)|(a<<24),ref))return 1;
    }
    std::printf("NEUTRAL_MODULATE_ORACLE_PASS cases=%llu\n",(unsigned long long)cases);
}
