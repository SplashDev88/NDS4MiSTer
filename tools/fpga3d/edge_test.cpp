// SPDX-License-Identifier: GPL-3.0-only
// Independent full-plane neighbor oracle, including every viewport border.
#define main original_sim_main
#include "sim.cpp"
#undef main
int main()try{
 Sim sim;sim.reset();unsigned comparisons=0,outlined=0;
 uint16_t table[8]={0,1,0x20,0x400,0x1234,0x7fff,0x2a55,0x6b13};
 for(unsigned variant=0;variant<8;variant++){
  const uint32_t borderZ=(variant&1)?0:0xffffff,borderId=(variant&2)?0:63;
  std::vector<Command> commands{edge(borderZ,borderId<<24,table)};
  std::vector<uint32_t> colors(49152),depths(49152),ids(49152);
  for(unsigned y=0;y<192;y++){
   commands.push_back(clear(y,0x1f010203,0xffffff,false,0,32));
   for(unsigned x=0;x<256;x+=8){
    Span s;s.first=s.origin=x;s.end=x+8;s.width=8;s.yEdge=4;
    const auto tile=x/8+y/8;
    const unsigned id=(variant&4)?7:((tile*9)&63);
    s.polyAttr=id<<24;s.z0=s.z1=0x100000+((tile%3)*0x10000);
    s.left=s.right={int((x+y)&63)*8,int((x*3+y)&63)*8,int((x+y*5)&63)*8,0,0};
    commands.push_back(span(s));
    for(unsigned i=x;i<x+8;i++){
     const auto p=y*256+i;ids[p]=id;depths[p]=s.z0;
     colors[p]=0x1f000000|((x+y)&63)|(((x*3+y)&63)<<8)|(((x+y*5)&63)<<16);
    }
   }
   commands.push_back(flush(y));
  }
  auto expected=colors;
  for(int y=0;y<192;y++)for(int x=0;x<256;x++){
   const auto p=y*256+x;bool hit=false;
   for(auto d:{std::pair<int,int>{-1,0},{1,0},{0,-1},{0,1}}){
    const int xx=x+d.first,yy=y+d.second;
    const bool outside=xx<0 || xx>=256 || yy<0 || yy>=192;
    const unsigned id=outside?borderId:ids[yy*256+xx],z=outside?borderZ:depths[yy*256+xx];
    hit|=ids[p]!=id && depths[p]<z;
   }
   if(hit){
    const uint16_t c=table[ids[p]/8];auto expand=[](unsigned v){v&=31;return 2*v+(v!=0);};
    expected[p]=(colors[p]&0xff000000)|expand(c)|(expand(c>>5)<<8)|(expand(c>>10)<<16);outlined++;
   }
  }
  sim.runStreaming(commands,1+variant);
  for(unsigned p=0;p<49152;p++){require(sim.word(Output+4*p)==expected[p],"edge neighbor/border mismatch");comparisons++;}
 }
 require(outlined>10000,"edge fixture did not exercise outlines");
 // An edge-enabled row cannot silently render without its table.
 sim.run({clear(0,0,0xffffff,false,0,32)},100,1);
 // Toon chunks must be unique and complete before a toon span is consumed.
 uint16_t toonTable[32]{};Span s;s.mode=4;
 sim.run({toon(0,toonTable),toon(0,toonTable)},101,1);
 sim.run({toon(0,toonTable),clear(0,0,0xffffff),span(s)},102,1);
 std::cout<<"PASS "<<comparisons<<" four-neighbor edge/border comparisons, "<<outlined<<" outlined pixels, missing/duplicate configuration rejection\n";
 return 0;
}catch(const std::exception& e){std::cerr<<"FAIL "<<e.what()<<std::endl;return 1;}
