/* Authored display for the ARM7 lid/ADC diagnostic. No game assets or saves. */
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
 unsigned previous=0xffffffff,previous_sleep=0xffffffff;
 for(;;) {
  unsigned seq=M[1],sleeping=M[3];
  if(seq==previous && sleeping==previous_sleep)continue;
  previous=seq;previous_sleep=sleeping;
  for(unsigned i=0;i<256*192;i++)fb[i]=0x8842;
  text(4,4,"LID AND MIC BETA DIAGNOSTIC");
  text(4,20,M[0]==0x4c4d4231?"ARM7 READY":"WAITING FOR ARM7");
  text(4,34,M[2]?"LID CLOSED":"LID OPEN");
  text(4,48,sleeping?"ARM7 SLEEPING":"ARM7 RUNNING");
  text(4,62,"WAKE COUNT");hex(76,62,M[4],4);
  text(4,76,"LAST IRQ");hex(76,76,M[9],8);
  text(4,90,"WAKE ERRORS");hex(76,90,M[10],4);
  text(4,105,"MIC MIN MAX AVG ENERGY");
  hex(4,118,M[5],3);hex(40,118,M[6],3);hex(76,118,M[7],3);hex(112,118,M[8],3);
  text(4,134,"SAMPLES");hex(58,134,seq<<8,8);
  text(4,148,"TOUCH X Y");hex(76,148,M[11],3);hex(106,148,M[12],3);
  text(4,166,"F10 LID - HOLD F11 TO BLOW");
  text(4,179,"NO SAVE OR FIRMWARE WRITES");
  for(unsigned i=0;i<16;i++)((volatile uint32_t*)0x06880000)[i]=M[i];
 }
}
