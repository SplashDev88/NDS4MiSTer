// SPDX-License-Identifier: GPL-3.0-only
// Authored equivalent SDK-style OAM setup; tables supplied by the manifest.
typedef unsigned int u32; typedef unsigned short u16; typedef signed int s32; typedef long long s64;
struct Source {u16 count,flags;const u16* attrs;};
static s32 add(s32 a,s32 b){return (s32)((u32)a+(u32)b);}
__attribute__((used,noinline))
u32 candidate(u32* out,u32 count,const struct Source* source,const s32* matrix,const s32* pos,u32 index,u32 doubled){
 const u16 *width=(const u16*)OAM_WIDTH_TABLE_ADDRESS,*height=(const u16*)OAM_HEIGHT_TABLE_ADDRESS;
 if(count>=source->count)count=source->count;
 for(u32 i=0;i<count;++i){
  u16 *dst=(u16*)((char*)out+i*8);const u16 *src=source->attrs+i*3;
  dst[0]=src[0];dst[1]=src[1];dst[2]=src[2];
  if(!matrix&&!pos)continue;
  u32 attr=*(u32*)dst;
  s32 x=(s32)(attr<<7)>>23; s32 y=(s32)(attr<<24)>>24;
  x=(s32)((u32)x<<12);y=(s32)((u32)y<<12);
  if(matrix){
   u32 kind=attr&0x300;
   if(kind!=0x100&&kind!=0x300)kind|=attr&0x30000000;
   u32 size=((attr>>14)&3)*4+(attr>>30);
   if(kind==0x300){x=add(x,(s32)((u32)width[size]<<11));y=add(y,(s32)((u32)height[size]<<11));}
   s32 xx=(s32)(((s64)matrix[0]*x+(s64)matrix[2]*y+4096)>>12);
   s32 yy=(s32)(((s64)matrix[1]*x+(s64)matrix[3]*y+4096)>>12);
   attr=(attr&0xc1fffcff)|(doubled?0x300:0x100)|((index&65535)<<25);
   *(u32*)dst=attr;
   size=((attr>>14)&3)*4+(attr>>30);
   s32 hw=width[size]>>1,hh=height[size]>>1;
   x=add(xx,(s32)((u32)matrix[0]*hw+(u32)matrix[2]*hh-((u32)hw<<12)));
   y=add(yy,(s32)((u32)matrix[1]*hw+(u32)matrix[3]*hh-((u32)hh<<12)));
   if(doubled){x=add(x,-(s32)((u32)hw<<12));y=add(y,-(s32)((u32)hh<<12));}
  }
  if(pos){x=add(x,pos[0]);y=add(y,pos[1]);}
  *(u32*)dst=(attr&0xfe00ff00)|(((u32)(add(x,2048)>>12)&511)<<16)|((u32)(add(y,2048)>>12)&255);
 }
 return count;
}
