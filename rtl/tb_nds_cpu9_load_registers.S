// SPDX-License-Identifier: GPL-3.0-or-later
// ARM extension at 02000200 for the existing scalar-load regression.
// Explicit high-register destinations cover the hardware SP reproducer.
.syntax unified
.arm
.cpu arm946e-s
.section .text
.global _start
_start:
    ldr r0, =0x02001000
    ldr sp, [r0, #32]
    str sp, [r7]
    ldrb sp, [r0, #1]
    str sp, [r7]
    ldrsb sp, [r0]
    str sp, [r7]
    ldrh sp, [r0, #2]
    str sp, [r7]
    ldrsh sp, [r0]
    str sp, [r7]
    ldrsh sp, [r0, #1]
    str sp, [r7]
    ldr lr, [r0, #4]
    str lr, [r7]
    ldr r12, [r0, #8]
    str r12, [r7]
    ldr pc, =0x020000c9
.ltorg
