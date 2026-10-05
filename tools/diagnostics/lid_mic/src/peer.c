/* Authored ARM7 register diagnostic. Does not issue cart/save/firmware commands. */
#include <stdint.h>
#define REG32(a) (*(volatile uint32_t *)(a))
#define REG16(a) (*(volatile uint16_t *)(a))
#define REG8(a) (*(volatile uint8_t *)(a))
#define M ((volatile uint32_t *)0x023e0000)
static unsigned transfer(unsigned value) {
 REG16(0x040001c2)=(uint16_t)value;
 while(REG16(0x040001c0)&128){}
 return REG16(0x040001c2)&255;
}
static unsigned adc(unsigned command) {
 transfer(command); unsigned hi=transfer(0),lo=transfer(0);
 return (hi*256+lo)>>3;
}
void peer_main(void) {
 REG32(0x04000208)=0; REG32(0x04000210)=1u<<22; REG32(0x04000214)=0xffffffff;
 for(unsigned i=0;i<16;i++)M[i]=0;
 M[0]=0x4c4d4231;
 REG16(0x040001c0)=0x8a01; // TSC only, held chip select, 1 MHz SPI.
 for(;;) {
  unsigned min=4095,max=0,total=0,energy=0;
  for(unsigned i=0;i<256;i++) {
   unsigned lid=(REG16(0x04000136)>>7)&1;
   M[2]=lid;
   if(lid) {
    REG32(0x04000214)=1u<<22;
    M[3]=1;
    REG8(0x04000301)=0xc0; // Actual guest Sleep: continue only when lid IRQ wakes it.
    // Some emulators complete the current CPU slice after requesting sleep.
    // Publish "awake" only after the actual wake IRQ is visible.
    while(!(REG32(0x04000214)&(1u<<22))){}
    M[3]=0; M[4]++; M[9]=REG32(0x04000214);
    if(!(M[9]&(1u<<22)))M[10]++;
    REG32(0x04000214)=1u<<22;
   }
   unsigned sample=adc(0xe0);
   if(sample<min)min=sample;
   if(sample>max)max=sample;
   total+=sample; energy+=sample>2048?sample-2048:2048-sample;
  }
  M[5]=min;M[6]=max;M[7]=total>>8;M[8]=energy>>8;
  M[11]=adc(0xd0);M[12]=adc(0x90);
  M[13]=(REG16(0x04000136)>>6)&1;
  M[1]++;
 }
}
