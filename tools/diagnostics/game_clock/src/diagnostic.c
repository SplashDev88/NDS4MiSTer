/* Original RTC readout: raw BCD is shown as hexadecimal decimal digits. */
#include <stdint.h>
#include "display.h"
#define M ((volatile uint32_t *)0x023e0000)
void diagnostic_main(void) {
 *(volatile uint32_t*)0x04000208=0;
 *(volatile uint16_t*)0x04000304=0x8003;
 *(volatile uint8_t*)0x04000240=0x80;
 *(volatile uint8_t*)0x04000244=0x80;
 *(volatile uint32_t*)0x04000000=0x00020000;
 *(volatile uint16_t*)0x0400006c=0;
 unsigned previous=0xffffffff,previous_magic=0xffffffff,previous_writes=0xffffffff;
 for(;;) {
  uint32_t data[16],seq=M[1];if(seq&1)continue;
  for(unsigned i=0;i<16;i++)data[i]=M[i];
  if(seq!=M[1] || (data[8]==previous && data[0]==previous_magic && data[12]==previous_writes))continue;
  previous=data[8];previous_magic=data[0];previous_writes=data[12];
  for(unsigned i=0;i<256*192;i++)fb[i]=0x8842;
  text(4,4,"RTC GAME CLOCK DIAGNOSTIC");
  text(4,22,data[0]==0x52544331?"ARM7 GPIO READ":"WAITING FOR ARM7");
  text(4,42,"DATE 20");hex(46,42,data[2],2);text(58,42,"-");hex(64,42,data[3],2);
  text(76,42,"-");hex(82,42,data[4],2);
  text(4,60,"TIME");hex(34,60,data[6]&0x3f,2);text(46,60,":");hex(52,60,data[7],2);text(64,60,":");hex(70,60,data[8],2);
  text(4,78,"WEEKDAY");hex(58,78,data[5],2);text(88,78,"STATUS");hex(136,78,data[9],2);
  text(4,96,"SECOND CHANGES");hex(94,96,data[11],8);
  text(4,114,"MANUAL RTC WRITES");hex(112,114,data[12],4);
  text(4,140,"A - SET LEAP DAY TEST");
  text(4,154,"B - SET YEAR WRAP TEST");
  text(4,178,"NO GAME SAVE OR FLASH WRITES");
  for(unsigned i=0;i<16;i++)((volatile uint32_t*)0x06880000)[i]=data[i];
 }
}
