// SPDX-License-Identifier: GPL-3.0-or-later
// Check actual linked renderer functions against an independent modulo oracle.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <random>
namespace melonDS {
void MatrixMult4x4(std::int32_t*, std::int32_t*);
void MatrixMult4x3(std::int32_t*, std::int32_t*);
void MatrixMult3x3(std::int32_t*, std::int32_t*);
void MatrixScale(std::int32_t*, std::int32_t*);
void MatrixTranslate(std::int32_t*, std::int32_t*);
}
using Fn = void(*)(std::int32_t*, std::int32_t*);
static std::uint64_t product(std::int32_t a, std::int32_t b) {
    return static_cast<std::uint64_t>(static_cast<std::int64_t>(a)*b);
}
// Independent modulo-64 oracle also models the original sequential alias writes.
static void reference(unsigned kind, std::int32_t* m, std::int32_t* s) {
    std::int32_t old[16]; std::memcpy(old,m,sizeof old);
    if (kind<3) {
        const unsigned rows=kind==2 ? 3 : 4, terms=kind==0 ? 4 : 3;
        for (unsigned r=0;r<rows;++r) for (unsigned c=0;c<4;++c) {
            std::uint64_t sum=0;
            for (unsigned k=0;k<terms;++k) sum+=product(s[r*terms+k],old[k*4+c]);
            if(kind==1 && r==3) sum+=product(4096,old[12+c]);
            m[r*4+c]=static_cast<std::int32_t>(static_cast<std::uint32_t>(sum>>12));
        }
    } else if(kind==3) {
        for(unsigned r=0;r<3;++r) for(unsigned c=0;c<4;++c)
            m[r*4+c]=static_cast<std::int32_t>(static_cast<std::uint32_t>(product(s[r],m[r*4+c])>>12));
    } else {
        for(unsigned c=0;c<4;++c) {
            std::uint64_t sum=0;
            for(unsigned k=0;k<3;++k) sum+=product(s[k],m[k*4+c]);
            m[12+c]=static_cast<std::int32_t>(static_cast<std::uint32_t>(m[12+c])+static_cast<std::uint32_t>(sum>>12));
        }
    }
}
int main() {
    Fn actual[]={melonDS::MatrixMult4x4,melonDS::MatrixMult4x3,melonDS::MatrixMult3x3,melonDS::MatrixScale,melonDS::MatrixTranslate};
    std::mt19937 rng(0x629e13);
    unsigned checks=0;
    for(unsigned sample=0;sample<2048;++sample) {
        std::array<std::int32_t,96> initial{};
        for(auto& v:initial) v=static_cast<std::int32_t>(rng());
        if(sample<8) {
            const std::int32_t edges[]={0,1,-1,4095,-4096,0x7fffffff,static_cast<std::int32_t>(0x80000000),0x40000000};
            for(unsigned j=0;j<initial.size();++j) initial[j]=edges[(j+sample)%8];
        }
        for(unsigned k=0;k<5;++k) for(int delta: {-24,-15,-4,0,4,12,16,24})
            for(unsigned alignment=0;alignment<4;++alignment) {
                auto expect=initial,got=initial;
                const int m=32+alignment,s=m+delta;
                reference(k,expect.data()+m,expect.data()+s);
                actual[k](got.data()+m,got.data()+s);
                if(got!=expect) {
                    std::fprintf(stderr,"GX_MATRIX_ARITHMETIC_FAIL sample=%u kind=%u delta=%d align=%u\n",sample,k,delta,alignment);
                    return 1;
                }
                ++checks;
            }
    }
    std::printf("GX_MATRIX_ARITHMETIC_PASS comparisons=%u overflow_alias_alignment=1\n",checks);
}
