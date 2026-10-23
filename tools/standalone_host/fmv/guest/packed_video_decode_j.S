// SPDX-License-Identifier: GPL-3.0-or-later
// NDS4MiSTer movie transport hook; original converter is copied from the caller's ROM at load time.
.syntax unified
.arch armv5te
.arm
.text
.global _start
_start:
 ldr r2,[r0]
 ldr r3,[r2]
 ldr r12,=0x43424453
 bic r3,r3,#0x8000
 cmp r3,r12
 bxne r1
 push {r4-r11,lr}
 mov r4,r0
 add r5,r2,#16
 ldr r6,[r2,#4]
 ldr r7,[r2,#8]
 ldr r8,[r2,#12]
 ldr r9,[r4,#12]
 str r7,[r4,#0x3b4]
 ldr r0,=0x44564d46
 str r0,[r9]
 ldr r10,=0x06800000
 add r12,r10,#0x1f000
 ldr r0,=0x31564d46
 str r0,[r12]
 add r11,r6,#3
 bic r11,r11,#3
 add r0,r11,#16
 str r0,[r12,#4]
 ldr r0,=0x334e0010
 str r0,[r12,#8]
 str r8,[r10],#4
 str r9,[r10],#4
 str r6,[r10],#4
 mov r0,#0
 str r0,[r10],#4
copy:
 ldr r0,[r5],#4
 str r0,[r10],#4
 subs r11,r11,#4
 bne copy
 ldr r0,=0x54494d43
 str r0,[r12,#12]
 ldr r1,[r4]
 ldr r1,[r1]
 tst r1,#0x8000
 subne r6,r6,#4
 add r0,r6,#16
 pop {r4-r11,pc}
.ltorg
