#include <cstdint>
#include <cstdio>
#include <algorithm>
#include <array>
#include <climits>
#include <cstdlib>
extern "C" unsigned old_clamp(int,int,int),new_clamp(int,int,int);
unsigned reference(int r,int g,int b) {
 auto c=[](int v){return unsigned(std::clamp(v,0,255))>>3;};
 return c(r)|(c(g)<<5)|(c(b)<<10);
}
int main(){
 uint64_t count=0;
 auto test=[&](int r,int g,int b){
  auto a=old_clamp(r,g,b),n=new_clamp(r,g,b),e=reference(r,g,b);
  if(a!=e||n!=e){std::printf("FAIL %d %d %d %u %u %u\n",r,g,b,a,n,e);std::exit(1);}++count;
 };
 const std::array<int,15> edges {INT_MIN,INT_MIN+1,-65536,-256,-1,0,1,7,8,247,248,255,256,65536,INT_MAX};
 for(int a:edges)for(int b:edges)for(int c:edges)test(a,b,c);
 for(int v=-1024;v<=1024;++v)for(int a:edges)for(int b:edges){test(v,a,b);test(a,v,b);test(a,b,v);}
 uint32_t state=0x619cb847;
 auto next=[&](){state^=state<<13;state^=state>>17;state^=state<<5;return int32_t(state);};
 for(unsigned i=0;i<1000000;++i){int a=next(),b=next(),c=next();test(a,b,c);}
 for(int r=0;r<256;++r)for(int g=0;g<256;++g)for(int b=0;b<256;++b)test(r,g,b);
 std::printf("PASS ARMv5 clamp equivalence cases=%llu including every RGB888 value and signed-boundary fallbacks\n",(unsigned long long)count);
}
