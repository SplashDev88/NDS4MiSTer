// SPDX-License-Identifier: GPL-3.0-only
.syntax unified
.arch armv5te
.arm
.text
.global test_decode
.type test_decode,%function
test_decode:
 push {r4-r11,lr}
 sub sp,sp,#128
 str r0,[sp,#0x7c]
 mov r4,r1
 mov r1,r2
 mov r5,r3
 ldr fp,[sp,#164]
 str fp,[sp,#0x30]
 mov r0,#0
 str r0,[sp,#0x60]
 str r0,[sp,#0x6c]
 mov r6,#88
 mov r7,#0x8000
 rsb r8,r7,#0
 sub r7,r7,#1
 ldr pc,[sp,#0x7c]
.global test_decode_exit
.type test_decode_exit,%function
test_decode_exit:
 add sp,sp,#128
 pop {r4-r11,pc}
.section .note.GNU-stack,"",%progbits
