// SPDX-License-Identifier: GPL-3.0-only
// Optional NSMB experiment: omit six cached bone updates in the known caller.
// This deliberately changes game memory effects; it is NOT release qualified.
.syntax unified
.arm
.cpu arm946e-s
.section .text,"ax"
.global nsmb_bones
nsmb_bones:
    // Other users of Model::getNodeMatrix retain the original implementation.
    ldr ip, =0x0212c9c0
    cmp lr, ip
    blo original
    ldr ip, =0x0212ca70
    cmp lr, ip
    bhs original
    // Verify the live overlay entry, after its loader has installed it.
    // The loader separately verifies cartridge identity and the main-RAM hook.
    ldr ip, =0x0212c98c
    ldr r3, [ip]
    ldr ip, =0xe92d4030
    cmp r3, ip
    bne original
    ldr ip, =0x0212c990
    ldr r3, [ip]
    ldr ip, =0xe24dd004
    cmp r3, ip
    bne original
    ldr ip, =0x0212c994
    ldr r3, [ip]
    ldr ip, =0xe1a05000
    cmp r3, ip
    bne original
    ldr ip, =0x0212c998
    ldr r3, [ip]
    ldr ip, =0xe2850c03
    cmp r3, ip
    bne original
    // Exact return-address membership; the final node call is never skipped.
    adr ip, returns
    mov r3, #6
1:  push {r3}
    ldr r3, [ip], #4
    cmp lr, r3
    pop {r3}
    beq omit
    subs r3, r3, #1
    bne 1b
original:
    ldr r0, [r0, #0x58]
    add r0, r0, #0x40
    ldr pc, =0x02019740
omit:
    mov r0, #1
    bx lr
returns:
    .word 0x0212c9e4,0x0212c9f8,0x0212ca0c
    .word 0x0212ca34,0x0212ca48,0x0212ca5c
    .ltorg
