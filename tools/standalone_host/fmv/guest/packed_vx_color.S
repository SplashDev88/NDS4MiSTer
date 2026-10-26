// SPDX-License-Identifier: GPL-3.0-or-later
// NDS4MiSTer movie transport hook; original converter is copied from the caller's ROM at load time.
.syntax unified
.arch armv5te
.arm
.text
.global _start
_start:
 push {r4-r12,lr}
 ldr r4,[r0]
 ldr r5,[r0,#4]
 ldr r6,[r0,#8]
#ifdef OLD_COLOR_TABLE
 ldr r7,=OLD_COLOR_TABLE
#else
 ldr r7,[r0,#24]
#endif
 ldr r8,[r0,#12]
 cmp r8,#512
 bne fallback
 ldr r8,[r0,#16]
 cmp r8,#256
 bne fallback
 ldr r8,[r0,#20]
 cmp r8,#192
 bne fallback
 orr r8,r4,r5
 orr r8,r8,r7
 tst r8,#3
 bne fallback
 mov r9,#0
 ldr r8,=0x06200000
 cmp r6,r8
 beq valid_destination
 add r8,r8,#0x4000
 cmp r6,r8
 moveq r9,#0x100
 beq valid_destination
 ldr r8,=0x06600000
 cmp r6,r8
 beq valid_destination
 ldr r8,=0x06800000
 sub r8,r6,r8
 cmp r8,#0x60000
 bhi fallback
 mov r9,r8,lsl#15
 cmp r9,#0
 bne fallback
valid_destination:
 ldr r0,[r4]
 ldr r1,=0x58564d46
 cmp r0,r1
 moveq r10,#1
 movne r10,#0
 sub r12,r6,r9,lsl#6
 add r12,r12,#0x1f000
 ldr r1,=0x31564d46
 str r1,[r12]
 ldr r1,=0x00c00100
 str r1,[r12,#4]
#ifdef OLD_COLOR_TABLE
 cmp r10,#0
 ldreq r1,=0x314e0001
 ldrne r1,=0x31580021
#else
 ldr r1,=0x334e0001
#endif
 orr r1,r1,r9
 str r1,[r12,#8]
 cmp r10,#0
 strne r4,[r6],#4
 ldrne r0,[r4,#4]
 strne r0,[r6],#4
 bne copy_table_start
 mov lr,#1536
copy_y:
 ldmia r4!,{r0-r3,r8-r11}
 stmia r6!,{r0-r3,r8-r11}
 subs lr,lr,#1
 bne copy_y
 mov lr,#768
copy_uv:
 ldmia r5!,{r0-r3,r8-r11}
 stmia r6!,{r0-r3,r8-r11}
 subs lr,lr,#1
 bne copy_uv
copy_table_start:
#ifdef OLD_COLOR_TABLE
 sub r7,r7,#272
 mov lr,#49
#else
 sub r7,r7,#16
 mov lr,#25
#endif
copy_table:
 ldmia r7!,{r0-r3,r8-r11}
 stmia r6!,{r0-r3,r8-r11}
 subs lr,lr,#1
 bne copy_table
 ldr r1,=0x54494d43
 str r1,[r12,#12]
 pop {r4-r12,pc}
fallback:
 pop {r4-r12,lr}
#ifdef ORIGINAL_CONVERTER
 ldr pc,=ORIGINAL_CONVERTER
#else
 ldr pc,=0x01fff000
#endif
.ltorg
