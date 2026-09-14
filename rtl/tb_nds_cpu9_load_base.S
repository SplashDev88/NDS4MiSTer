/* SPDX-License-Identifier: GPL-3.0-or-later
 * Authored load-base update regression; no game or BIOS data.
 */
.syntax unified
.arch armv5te
.arm
.global _start
_start:
    msr cpsr_c, #0x1f
    mov r7, #0x04000000
    ldr r0, =0x02001020
    ldr r1, [r0, #4]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #4
    ldr r1, [r0, r2]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldr r1, [r0, #-4]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #4
    ldr r1, [r0, -r2]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldr r1, [r0], #4
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #4
    ldr r1, [r0], r2
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldr r1, [r0], #-4
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #4
    ldr r1, [r0], -r2
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrb r1, [r0, #1]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #1
    ldrb r1, [r0, r2]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrb r1, [r0, #-1]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #1
    ldrb r1, [r0, -r2]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrb r1, [r0], #1
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #1
    ldrb r1, [r0], r2
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrb r1, [r0], #-1
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #1
    ldrb r1, [r0], -r2
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrh r1, [r0, #4]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #4
    ldrh r1, [r0, r2]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrh r1, [r0, #-4]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #4
    ldrh r1, [r0, -r2]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrh r1, [r0], #4
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #4
    ldrh r1, [r0], r2
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrh r1, [r0], #-4
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #4
    ldrh r1, [r0], -r2
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrsb r1, [r0, #1]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #1
    ldrsb r1, [r0, r2]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrsb r1, [r0, #-1]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #1
    ldrsb r1, [r0, -r2]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrsb r1, [r0], #1
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #1
    ldrsb r1, [r0], r2
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrsb r1, [r0], #-1
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #1
    ldrsb r1, [r0], -r2
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrsh r1, [r0, #4]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #4
    ldrsh r1, [r0, r2]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrsh r1, [r0, #-4]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #4
    ldrsh r1, [r0, -r2]!
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrsh r1, [r0], #4
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #4
    ldrsh r1, [r0], r2
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    ldrsh r1, [r0], #-4
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #4
    ldrsh r1, [r0], -r2
    str r1, [r7]
    str r0, [r7]
    add r3, r1, #1
    str r3, [r7]
    ldr r0, =0x02001020
    mov r2, #1
    ldr r1, [r0, r2, lsl #2]!
    str r1, [r7]
    str r0, [r7]
    ldr r0, =0x02001020
    mov r2, #16
    ldr r1, [r0, r2, lsr #2]!
    str r1, [r7]
    str r0, [r7]
    ldr r0, =0x02001020
    mov r2, #16
    ldr r1, [r0, r2, asr #2]!
    str r1, [r7]
    str r0, [r7]
    ldr r0, =0x02001020
    mov r2, #8
    ldr r1, [r0, r2, ror #1]!
    str r1, [r7]
    str r0, [r7]
    ldr r0, =0x02001020
    mov r2, #1
    ldr r1, [r0, r2, lsl #0]!
    str r1, [r7]
    str r0, [r7]
    ldr r0, =0x02001020
    mov r2, #1
    ldrb r1, [r0, r2, lsl #1]!
    str r1, [r7]
    str r0, [r7]
    ldr r0, =0x02001020
    ldrh r1, [r0, #1]!
    str r1, [r7]
    str r0, [r7]
    ldr r0, =0x02001020
    ldrsh r1, [r0, #1]!
    str r1, [r7]
    str r0, [r7]
    ldr r0, =0x02001020
    mov r1, #4
    ldr r1, [r0, r1]!
    str r1, [r7]
    str r0, [r7]
    ldr sp, =0x02001020
    ldr r1, [sp], #4
    str r1, [r7]
    str sp, [r7]
    ldr lr, =0x02001020
    ldr r1, [lr], #4
    str r1, [r7]
    str lr, [r7]
    ldr r0, =0x02001020
    mov r1, #0x55
    cmp r1, #0x55
    ldrne r1, [r0, #4]!
    str r1, [r7]
    str r0, [r7]
    ldr r0, =0x02001020
    .word 0xe5b00004
    str r0, [r7]
    ldr r0, =0x02001020
    ldr r1, [r0], #4
    str r1, [r0], #4
    str r0, [r7]
    ldr r0, =0x02001000
    ldrd r2, r3, [r0, #4]!
    str r2, [r7]
    str r3, [r7]
    str r0, [r7]
    adr r0, thumb_target
    ldr pc, [r0], #4
    .word 0xe7f000f0
thumb_target:
    .word 0x02000000 + (thumb_code - _start) + 1
    .ltorg
.thumb
thumb_code:
    ldr r0, thumb_data
    ldr r1, [r0]
    str r1, [r7]
    b .
.align 2
thumb_data:
    .word 0x02001000
