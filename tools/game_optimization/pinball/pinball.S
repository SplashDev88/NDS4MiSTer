// SPDX-License-Identifier: GPL-3.0-or-later
.syntax unified
.arch armv5te
.arm
.section .divide,"ax"
.global divide_magnitudes
// r1:r0 and r3:r2 contain nonzero, unsigned magnitudes. The original
// prologue handles zero inputs, signs and the 32-bit shortcut.
divide_magnitudes:
    cmp     r1, r3
    cmpeq   r0, r2
    blo     numerator_smaller
    clz     r5, r3
    cmp     r3, #0
    clzeq   r5, r2
    addeq   r5, r5, #32
    clz     r6, r1
    cmp     r1, #0
    clzeq   r6, r0
    addeq   r6, r6, #32
    sub     r6, r5, r6
    subs    ip, r6, #32
    movhs   r3, r2, lsl ip
    movhs   r2, #0
    bhs     aligned
    rsb     ip, r6, #32
    lsl     r3, r3, r6
    orr     r3, r3, r2, lsr ip
    lsl     r2, r2, r6
aligned:
    mov     r5, #0
    mov     fp, #0
next_bit:
    subs    lr, r0, r2
    sbcs    ip, r1, r3
    movcs   r0, lr
    movcs   r1, ip
    adcs    r5, r5, r5
    adc     fp, fp, fp
    movs    r3, r3, lsr #1
    mov     r2, r2, rrx
    subs    r6, r6, #1
    bpl     next_bit
    tst     r4, #1
    moveq   r0, r5
    moveq   r1, fp
    b       apply_sign
numerator_smaller:
    tst     r4, #1
    moveq   r0, #0
    moveq   r1, #0
    b       apply_sign

.section .sound,"ax"
.global decode_pairs
decode_pairs:
    // The original step and index table pointers have the same PC-relative offsets in all three cartridges.
    ldr     ip, [pc, #0x3c4]
    ldr     lr, [pc, #0x3c4]
    // The original loop stores each sample and predictor before it reads the
    // next nibble. Preserve that order, including for overlapping buffers.
.macro decode high, dest_offset
    .if \high
    ldrb    r2, [r1], #1
    .else
    ldrb    r2, [r1]
    .endif
    ldrb    r3, [r4, #2]
    ldrsh   r9, [r4]
    .if \high
    lsr     r2, r2, #4
    .else
    and     r2, r2, #15
    .endif
    lsl     r10, r3, #1
    ldrsh   r10, [ip, r10]
    asr     r6, r10, #3
    tst     r2, #4
    addne   r6, r6, r10
    tst     r2, #2
    addne   r6, r6, r10, asr #1
    tst     r2, #1
    addne   r6, r6, r10, asr #2
    tst     r2, #8
    subne   r9, r9, r6
    addeq   r9, r9, r6
    beq     1f
    cmp     r9, r8
    movlt   r9, r8
    b       2f
1:  cmp     r9, r7
    movgt   r9, r7
2:
    ldrsb   r6, [lr, r2]
    adds    r3, r3, r6
    movmi   r3, #0
    cmp     r3, #88
    movgt   r3, #88
    strh    r9, [r4]
    strb    r3, [r4, #2]
    strh    r9, [r5, #\dest_offset]
.endm
next_byte:
    decode 0, 0
    str     r2, [sp, #0x58]
    decode 1, 2
    add     r0, r0, #2
    add     r5, r5, #4
    cmp     r0, fp
    blo     next_byte
    // Recreate the original live registers and stack locals at the join.
    mov     lr, r10
    ldr     ip, [sp, #0x58]
    and     r10, ip, #1
    str     r10, [sp, #0x5c]
    and     r10, ip, #2
    str     r10, [sp, #0x58]
    and     r10, r2, #1
    str     r10, [sp, #0x68]
    and     r10, r2, #2
    str     r10, [sp, #0x64]
    and     r10, r2, #8
    mov     ip, r9
    lsl     r2, r9, #16
    asr     r9, r2, #16
    mov     r6, #88
    b       remaining_samples
