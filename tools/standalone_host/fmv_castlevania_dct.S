// SPDX-License-Identifier: GPL-3.0-only
// ACVE revision 0 inverse transform at guest 0x01ffd1d4.
// State fields: +0x44 signed cutoff, +0x48 64x64 signed-16 basis,
// +0x2f4 64 signed-32 coefficients, +0x2f8 64 signed-32 outputs.
// Preserve modulo-2^32 sums followed by ASR 14. Nonzero coefficients
// are collected once; four independent output sums share each list read.
// Source/destination overlap and limited DTCM stack use scalar traversal.
.syntax unified
.arch armv5te
.arm
.text
.global _start
_start:
 push {r4-r12,lr}
 ldr r10,[r0,#0x44]
 ldr r2,[r0,#0x48]
 ldr r1,[r0,#0x2f4]
 ldr r8,[r0,#0x2f8]
 cmp r10,#0
 movlt r10,#0
 cmp r10,#56
 movge r10,#56
 bic r10,r10,#7
 add r10,r10,#8
 mov r7,#64
 // Overlap uses the original coefficient traversal for each output.
 add r4,r1,#256
 cmp r8,r4
 bhs check_basis
 add r4,r8,#256
 cmp r1,r4
 blo fallback
check_basis:
 add r4,r2,#8192
 cmp r8,r4
 bhs check_stack
 add r4,r8,#256
 cmp r2,r4
 blo fallback
check_stack:
 // The game's DTCM stack must keep the 512-byte coefficient list above
 // 0x027c3800. Deeper calls retain the scalar, scratch-free traversal.
 ldr r4,dtcm_base
 cmp sp,r4
 blo prepare
 add r4,r4,#0x4000
 cmp sp,r4
 bhs prepare
 sub r4,r4,#0x600
 cmp sp,r4
 blo fallback
prepare:
 sub sp,sp,#512
 adr r11,order
 add r12,r11,r10
 mov r6,sp
scan:
 ldrb r4,[r11],#1
 ldr r3,[r1,r4,lsl #2]
 cmp r3,#0
 mov r4,r4,lsl #1
 stmiane r6!,{r3,r4}
 cmp r11,r12
 bne scan
row:
 mov r0,#0
 mov r5,#0
 mov r11,#0
 mov lr,#0
 mov r9,sp
 cmp r9,r6
 beq store
term:
 ldmia r9!,{r3,r4}
 ldrsh r12,[r2,r4]
 mla r0,r3,r12,r0
 add r4,r4,#128
 ldrsh r12,[r2,r4]
 mla r5,r3,r12,r5
 add r4,r4,#128
 ldrsh r12,[r2,r4]
 mla r11,r3,r12,r11
 add r4,r4,#128
 ldrsh r12,[r2,r4]
 mla lr,r3,r12,lr
 cmp r9,r6
 bne term
store:
 mov r0,r0,asr #14
 mov r5,r5,asr #14
 mov r11,r11,asr #14
 mov lr,lr,asr #14
 stmia r8!,{r0,r5,r11,lr}
 add r2,r2,#512
 subs r7,r7,#4
 bne row
 mov r0,lr
 // Match original volatile outputs as well as callee-saved registers.
 adr r3,order
 sub r10,r10,#2
 ldrb r3,[r3,r10]
 ldr r3,[r1,r3,lsl #2]
 b done
fallback:
 mov r0,#0
 adr r11,order
 mov r9,#0
fallback_term:
 ldrb r4,[r11,r9]
 ldr r3,[r1,r4,lsl #2]
 mov r4,r4,lsl #1
 cmp r3,#0
 ldrshne r4,[r2,r4]
 mlane r0,r3,r4,r0
 add r9,r9,#1
 sub r12,r10,#1
 cmp r9,r12
 moveq r5,r3
 cmp r9,r10
 blo fallback_term
 mov r0,r0,asr #14
 str r0,[r8],#4
 add r2,r2,#128
 subs r7,r7,#1
 bne fallback
 mov r3,r5
 b done_no_scratch
done:
 add sp,sp,#512
done_no_scratch:
 pop {r4-r12,lr}
 bx lr
dtcm_base: .word 0x027c0000
order:
.byte 0,1,8,16,9,2,3,10,17,24,32,25,18,11,4,5
.byte 12,19,26,33,40,48,41,34,27,20,13,6,7,14,21,28
.byte 35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51
.byte 58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63
.org 0x47c
