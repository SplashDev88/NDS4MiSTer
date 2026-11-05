// SPDX-License-Identifier: GPL-3.0-only
// Conservative whole-primitive rejection; rendered coordinates are unchanged.
typedef unsigned int u32;typedef int s32;typedef short s16;
struct Segment {u32 offset,bytes; s16 lo[3],hi[3]; u32 error;};
#ifdef DYNAMIC_MODEL_SCALE
#ifdef DYNAMIC_MATRIX_NORMALIZE
struct List {u32 magic;unsigned short count;unsigned char shift,normalize;struct Segment spans[];};
#define LIST_MAGIC 0x334c5344
#else
struct List {u32 magic;unsigned short count,shift;struct Segment spans[];};
#define LIST_MAGIC 0x324c5344
#endif
#define SCALE_SHIFT list->shift
#else
struct List {u32 magic,count;struct Segment spans[];};
#define LIST_MAGIC 0x434c5344
#define SCALE_SHIFT MODEL_SCALE_SHIFT
#endif
#define SEND ((void(*)(const void*,u32))ORIGINAL_SEND_ADDRESS)
#define CONCAT ((void(*)(const s32*,const s32*,s32*))MATRIX_CONCAT_ADDRESS)
#define GLOBAL ((const s32*)GLOBAL_STATE_ADDRESS)
__attribute__((used,noinline))
void candidate(const struct List *list,u32 bytes){
 if(list->magic!=LIST_MAGIC){SEND(list,bytes);return;}
 s32 pos[16],matrix[16],planes[6][4];
 for(u32 i=0;i<16;++i){
  u32 row=i>>2,col=i&3;
  pos[i]=col==3?(row==3?4096:0):(s32)((u32)GLOBAL[0x4c/4+row*3+col]<<(row==3?0:SCALE_SHIFT));
 }
 CONCAT(pos,GLOBAL+2,matrix);
 u32 bounded=1;
 for(u32 i=0;i<16;++i){
#ifdef DYNAMIC_MATRIX_NORMALIZE
  matrix[i]>>=list->normalize;
#endif
  u32 bound=i<12?0x7ffff:0xffffff;if(((u32)matrix[i]+bound)>2*bound)bounded=0;
 }
 for(u32 plane=0;plane<6;++plane){
  for(u32 row=0;row<4;++row){s32 a=matrix[row*4+3],b=matrix[row*4+(plane>>1)];s32 v=(s32)((plane&1)?(u32)a-(u32)b:(u32)a+(u32)b);planes[plane][row]=row==3?(s32)((u32)v<<4):(v>>8);}
 }
 for(u32 i=0;i<list->count;++i){
  const struct Segment *s=list->spans+i;
  u32 visible=1;
  if(bounded && i+1<list->count)for(u32 p=0;p<6;++p){
   s32 dot=planes[p][3];
   for(u32 j=0;j<3;++j){s32 a=planes[p][j];dot+=a*(a<0?s->lo[j]:s->hi[j]);}
   if(dot < -(s32)s->error){visible=0;break;}
  }
  if(visible)SEND((const char*)list+s->offset,s->bytes);
 }
}
