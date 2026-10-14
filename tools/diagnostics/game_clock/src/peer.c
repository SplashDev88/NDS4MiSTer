/* Original DS ARM7 GPIO diagnostic. No cart/save/firmware-flash writes. */
#include <stdint.h>
#define R16(a) (*(volatile uint16_t *)(a))
#define R32(a) (*(volatile uint32_t *)(a))
#define M ((volatile uint32_t *)0x023e0000)
static void gpio(unsigned value) {
 R16(0x04000138)=(uint16_t)value;
 for(volatile unsigned i=0;i<32;i++){}
}
static void send(unsigned value) {
 for(unsigned i=0;i<8;i++){unsigned bit=(value>>i)&1;gpio(0x16|bit);gpio(0x14|bit);}
}
static unsigned receive(void) {
 unsigned value=0;
 for(unsigned i=0;i<8;i++){gpio(6);gpio(4);value|=(R16(0x04000138)&1)<<i;}
 return value;
}
static void begin(unsigned command){gpio(0x10);gpio(0x16);send(command);}
static void read(unsigned command,unsigned *out,unsigned count) {
 begin(command);for(unsigned i=0;i<count;i++)out[i]=receive();gpio(0x10);
}
static void write(unsigned command,const unsigned *in,unsigned count) {
 begin(command);for(unsigned i=0;i<count;i++)send(in[i]);gpio(0x10);
}
void peer_main(void) {
 R32(0x04000208)=0;
 for(unsigned i=0;i<32;i++)M[i]=0;
 M[0]=0x52544331;
 unsigned oldkeys=0,previous_second=0xffffffff;
 for(;;) {
  unsigned date[7],status[1];
  read(0x86,status,1);read(0xa6,date,7);
  const unsigned keys=(~R16(0x04000130))&1023;
  const unsigned pressed=keys&~oldkeys;oldkeys=keys;
  // A: known leap-day edge. B: known 2099 -> 2000 edge. No automatic writes.
  // A zero-return old core can never trigger a write through this diagnostic.
  if(date[1] && date[2] && (pressed&3)) {
   const unsigned mode[1]={2};write(0x06,mode,1);
   const unsigned leap[7]={0x24,0x02,0x28,0x03,0x63,0x59,0x58};
   const unsigned wrap[7]={0x99,0x12,0x31,0x04,0x63,0x59,0x58};
   write(0x26,(pressed&1)?leap:wrap,7);M[12]++;
  }
  if(date[6]!=previous_second){previous_second=date[6];M[11]++;}
  M[1]++; // seqlock protects the cross-CPU report
  for(unsigned i=0;i<7;i++)M[2+i]=date[i];
  M[9]=status[0];M[10]=keys;
  M[1]++;
 }
}
