// SPDX-License-Identifier: GPL-3.0-or-later
// NDS4MiSTer movie transport hook; original converter is copied from the caller's ROM at load time.
.syntax unified
.arch armv5te
.arm
.text
.global _start,filter_entry,flush_filter,filter_original
.equ RECORD,0x01fffe00
_start:
 push {r0-r12,lr}
 ldr r4,[r0]
 ldr r5,[r0,#4]
 ldr r6,[r0,#8]
 ldr r7,[r0,#24]
 ldr r8,[r0,#12]
 cmp r8,#512
 bne color_fallback
 ldr r8,[r0,#16]
 cmp r8,#256
 bne color_fallback
 ldr r8,[r0,#20]
 cmp r8,#192
 bne color_fallback
 orr r8,r4,r5
 orr r8,r8,r7
 tst r8,#3
 bne color_fallback
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
 bhi color_fallback
 mov r9,r8,lsl#15
 cmp r9,#0
 bne color_fallback
valid_destination:
 ldr r8,=RECORD
 ldr r10,[r8]
 cmp r10,#0
 beq no_filter
 ldr r10,[r8,#12]
 cmp r10,r4
 ldreq r10,[r8,#16]
 cmpeq r10,r5
 bne flush_mismatch
 ldr r4,[r8,#4]
 ldr r5,[r8,#8]
 ldr r10,=0x334e0002
 b begin
flush_mismatch:
 bl flush_filter
no_filter:
 ldr r10,=0x334e0001
begin:
 ldr r0,[r4]
 ldr r1,=0x44564d46
 cmp r0,r1
 orreq r10,r10,#0x10
 sub r12,r6,r9,lsl#6
 add r12,r12,#0x1f000
 ldr r1,=0x31564d46
 str r1,[r12]
 ldr r1,=0x00c00100
 str r1,[r12,#4]
 orr r10,r10,r9
 str r10,[r12,#8]
 tst r10,#0x10
 strne r4,[r6],#4
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
 sub r7,r7,#16
 mov lr,#25
copy_table:
 ldmia r7!,{r0-r3,r8-r11}
 stmia r6!,{r0-r3,r8-r11}
 subs lr,lr,#1
 bne copy_table
 ldr r4,=RECORD
 ldr r0,[r4]
 cmp r0,#0
 beq commit
 ldr r0,[r4,#40]
 ldr r1,[r4,#36]
 mov r2,#0
 mov r3,#0
 stmia r6!,{r0-r3}
 ldr r5,[r4,#32]
 mov lr,#12
copy_clamp:
 ldmia r5!,{r0-r3,r8-r11}
 stmia r6!,{r0-r3,r8-r11}
 subs lr,lr,#1
 bne copy_clamp
 mov r0,#0
 str r0,[r4]
commit:
 ldr r1,=0x54494d43
 str r1,[r12,#12]
 pop {r0-r12,pc}
color_fallback:
 bl flush_filter
 pop {r0-r12,lr}
 ldr pc,=0x01fff000

filter_entry:
 push {r4-r12,lr}
 mov r4,r0
 bl flush_filter
 ldr r1,[r4,#16]
 cmp r1,#256
 bne filter_fallback
 ldr r1,[r4,#20]
 cmp r1,#192
 bne filter_fallback
 ldr r5,[r4,#24]
 cmp r5,#40
 bhi filter_fallback
 ldr r1,[r4,#32]
 cmp r1,#2
 bhi filter_fallback
 ldmia r4,{r0-r3}
 orr r0,r0,r1
 orr r0,r0,r2
 orr r0,r0,r3
 ldr r1,[r4,#28]
 orr r0,r0,r1
 tst r0,#3
 bne filter_fallback
 ldr r6,=0x0213b404
 ldrb r6,[r6,r5]
 ldr r7,=0x0213b429
 ldrb r7,[r7,r5]
 orr r6,r6,r7,lsl#8
 ldr r12,=RECORD
 str r6,[r12,#40]
 add r12,r12,#4
 ldmia r4,{r0-r8}
 stmia r12,{r0-r8}
 mov r0,#1
 str r0,[r12,#-4]
 pop {r4-r12,pc}
filter_fallback:
 mov r0,r4
 pop {r4-r12,lr}
 b filter_original

flush_filter:
 push {r0-r12,lr}
 ldr r0,=RECORD
 ldr r1,[r0]
 cmp r1,#0
 beq flush_done
 mov r1,#0
 str r1,[r0],#4
 bl filter_original
flush_done:
 pop {r0-r12,pc}
filter_original:
 push {r4-r9,lr}
 ldr pc,=0x0213b330
.ltorg
