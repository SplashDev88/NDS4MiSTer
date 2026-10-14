/* Authored diagnostic ARM7 entry, no BIOS, save or firmware dependencies. */
.syntax unified
.cpu arm7tdmi
.arm
.section .start,"ax"
.global _start
_start:
    msr cpsr_c, #0xd3
    ldr sp, =0x0380ff00
    bl peer_main
1:  b 1b
.ltorg
