/* Authored test startup, borrowed from the private boundary diagnostic. */
.syntax unified
.cpu arm946e-s
.arm
.section .start,"ax"
.global _start
_start:
    msr cpsr_c, #0xd3
    mov r0, #0
    mcr p15, 0, r0, c7, c5, 0
    mcr p15, 0, r0, c7, c6, 0
    mcr p15, 0, r0, c7, c10, 4
    ldr r0, =0x027c000a
    mcr p15, 0, r0, c9, c1, 0
    ldr r0, =0x00000020
    mcr p15, 0, r0, c9, c1, 1
    ldr r0, =0x04000033
    mcr p15, 0, r0, c6, c0, 0
    ldr r0, =0x0200002b
    mcr p15, 0, r0, c6, c1, 0
    mov r0, #0
    mcr p15, 0, r0, c6, c2, 0
    ldr r0, =0x08000035
    mcr p15, 0, r0, c6, c3, 0
    ldr r0, =0x027c001b
    mcr p15, 0, r0, c6, c4, 0
    mov r0, #0
    mcr p15, 0, r0, c6, c5, 0
    ldr r0, =0xffff001d
    mcr p15, 0, r0, c6, c6, 0
    ldr r0, =0x027ff017
    mcr p15, 0, r0, c6, c7, 0
    mov r0, #0
    mcr p15, 0, r0, c2, c0, 0
    mcr p15, 0, r0, c2, c0, 1
    mov r0, #0
    mcr p15, 0, r0, c3, c0, 0
    ldr r0, =0x15111011
    mcr p15, 0, r0, c5, c0, 2
    ldr r0, =0x05100011
    mcr p15, 0, r0, c5, c0, 3
    ldr r0, =0x0005707d
    mcr p15, 0, r0, c1, c0, 0
    ldr sp, =0x023f0000
    ldr r0, =__bss_start
    ldr r1, =__bss_end
    mov r2, #0
1:  cmp r0, r1
    strlo r2, [r0], #4
    blo 1b
    bl diagnostic_main
.global diagnostic_idle
 diagnostic_idle:
    b diagnostic_idle
.ltorg
