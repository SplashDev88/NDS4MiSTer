// SPDX-License-Identifier: GPL-3.0-or-later
// NDS4MiSTer movie transport hook; original converter is copied from the caller's ROM at load time.
.syntax unified
.arch armv5te
.arm
.text
#ifndef QUEUE_RESUME
#define QUEUE_RESUME 0x0208e67c
#endif
.global _start
_start:
 ldr r3,=0x02007550
 blx r3
 str r0,[r4,#0x74]
 str r1,[r4,#0x78]
 mov r0,#0
 str r0,[r4,#0x5c]
 str r0,[r4,#0x60]
 mov r0,r6
 // Keep the qualified positive-zero literal encoding across assemblers.
 .word 0xe59ff000
.ltorg
 .word QUEUE_RESUME
