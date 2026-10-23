// SPDX-License-Identifier: GPL-3.0-or-later
// NDS4MiSTer movie transport hook; original converter is copied from the caller's ROM at load time.
.syntax unified
.arch armv5te
.arm
.text
.global _start
_start:
 ldr r2,[r0]
 ldrh r3,[r2]
 ldrh r12,[r2,#2]
 orr r3,r3,r12,lsl#16
 ldr r12,=0x31585646
 cmp r3,r12
 ldrne pc,=ORIGINAL_DECODER
 push {r4-r11,lr}
 mov r4,r0
 add r5,r2,#16
 ldrh r6,[r2,#4]
 ldrh r12,[r2,#6]
 orr r6,r6,r12,lsl#16
 ldrh r7,[r2,#8]
 ldrh r12,[r2,#10]
 orr r7,r7,r12,lsl#16
 ldrh r8,[r2,#12]
 ldrh r12,[r2,#14]
 orr r8,r8,r12,lsl#16
 ldr r9,[r4,#0x1c]
 ldr r0,=0x58564d46
 str r0,[r9]
 mov r0,r7,lsr#16
 str r0,[r9,#4]
 ldr r10,=0x06800000
 add r12,r10,#0x1f000
 ldr r0,=0x31564d46
 str r0,[r12]
 add r11,r6,#3
 bic r11,r11,#3
 add r0,r11,#20
 str r0,[r12,#4]
 ldr r0,=0x31580010
 str r0,[r12,#8]
 str r8,[r10],#4
 str r9,[r10],#4
 str r6,[r10],#4
 mov r0,r7,lsr#16
 str r0,[r10],#4
 and r0,r7,#255
 str r0,[r10],#4
copy:
 ldrh r0,[r5],#2
 ldrh r1,[r5],#2
 orr r0,r0,r1,lsl#16
 str r0,[r10],#4
 subs r11,r11,#4
 bne copy
 ldr r0,=0x54494d43
 str r0,[r12,#12]
 add r0,r6,#16
 pop {r4-r11,pc}
.ltorg
