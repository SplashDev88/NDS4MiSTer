#include "GPU3D_Soft.h"
#include <cstdio>
#include <algorithm>
using namespace melonDS;
int main(){
 u32 work[192]{};s32 boundaries[5];u64 cases=0;
 auto check=[&]{
  NDS4MiSTerBalancedRasterBands(work,boundaries);++cases;
  if(boundaries[0]!=0||boundaries[4]!=192)return false;
  u64 total=0;u64 prefix[193]{};for(int y=0;y<192;y++)prefix[y+1]=total+=work[y];
  for(int b=1;b<5;b++)if(boundaries[b]<=boundaries[b-1])return false;
  for(int b=1;b<4;b++){
   if(!total){if(boundaries[b]!=48*b)return false;continue;}
   u64 target=(total*b+3)/4;int lo=boundaries[b-1]+1,hi=192-(4-b),expected=hi;
   // Enumerate every valid cut independently to find the earliest quota.
   for(int cut=hi;cut>=lo;--cut)if(prefix[cut]>=target)expected=cut;
   if(boundaries[b]!=expected)return false;
  }
  return true;
 };
 if(!check())return 1;
 std::fill_n(work,192,1);if(!check()||boundaries[1]!=48||boundaries[2]!=96||boundaries[3]!=144)return 2;
 std::fill_n(work,192,0);std::fill_n(work+180,12,10000);
 if(!check()||boundaries[1]!=183||boundaries[2]!=186||boundaries[3]!=189)return 3;
 for(int row=0;row<192;row++){
  std::fill_n(work,192,0);work[row]=0xffffffffu;if(!check())return 4;
 }
 u32 random=0xbc394a7d;for(int n=0;n<50000;n++){
  for(auto&v:work){random^=random<<13;random^=random>>17;random^=random<<5;v=(n&1)?random:((random&7)?0:random);}
  if(!check())return 5;
 }
 u32 tiles[16]{};s32 cuts[5];
 for(int hot=-1;hot<16;hot++){
  std::fill_n(tiles,16,hot<0?1:0);if(hot>=0)tiles[hot]=0xffffffffu;
  NDS4MiSTerBalancedRasterBands(tiles,cuts);
  if(cuts[0]!=0||cuts[4]!=16)return 6;
  for(int b=1;b<=4;b++)if(cuts[b]<=cuts[b-1])return 7;
  if(hot<0&&(cuts[1]!=4||cuts[2]!=8||cuts[3]!=12))return 8;
  ++cases;
 }
 std::printf("WEIGHTED_RASTER_BANDS_PASS cases=%llu rows_per_case=192 jobs=4\n",(unsigned long long)cases);
}
