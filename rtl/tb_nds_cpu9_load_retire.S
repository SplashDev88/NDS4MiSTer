/* SPDX-License-Identifier: GPL-3.0-or-later
 * Authored scalar-load dependency and fallback regression. Each store to r7
 * reports the next independent expected result in the VHDL scoreboard.
 */
.syntax unified
.arch armv5te
.arm
.global _start
_start:
    msr cpsr_c, #0x1f
    mov r7, #0x04000000
    ldr r0, =0x02001000
    ldr r1, [r0]
    str r1, [r7]
    ldr r1, [r0, #1]
    str r1, [r7]
    ldrb r1, [r0, #1]
    str r1, [r7]
    ldrsb r1, [r0]
    str r1, [r7]
    ldrh r1, [r0]
    str r1, [r7]
    ldrh r1, [r0, #2]
    str r1, [r7]
    ldrsh r1, [r0]
    str r1, [r7]
    ldrsh r1, [r0, #1]
    str r1, [r7]
    ldr r1, [r0, #4]!
    str r1, [r7]
    str r0, [r7]
    ldr r1, [r0], #4
    str r1, [r7]
    str r0, [r7]
    sub r0, r0, #8
    ldrd r2, r3, [r0]
    str r2, [r7]
    str r3, [r7]
    ldmia r0, {r2-r4}
    str r2, [r7]
    str r3, [r7]
    str r4, [r7]
    ldr r4, [r0, #12]
    ldr r4, [r4]
    add r4, r4, #1
    str r4, [r7]
    add r0, r0, #16
    mov r2, #0x55
    swp r1, r2, [r0]
    str r1, [r7]
    ldr r1, [r0]
    str r1, [r7]
    cmp r2, #0x55
    ldrne r1, [r0, #4]
    str r1, [r7]
    ldr pc, thumb_target
    .word 0xe7f000f0
thumb_target:
    .word 0x02000000 + (thumb_code - _start) + 1
    .ltorg
.thumb
thumb_code:
    ldr r0, thumb_data
    ldr r1, [r0]
    str r1, [r7]
    ldrb r1, [r0, #1]
    str r1, [r7]
    ldrh r1, [r0, #2]
    str r1, [r7]
    movs r2, #0
    ldrsb r1, [r0, r2]
    str r1, [r7]
    ldrsh r1, [r0, r2]
    str r1, [r7]
    b .
.align 2
thumb_data:
    .word 0x02001000
