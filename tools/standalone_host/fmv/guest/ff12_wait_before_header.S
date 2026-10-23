// SPDX-License-Identifier: GPL-3.0-or-later
// NDS4MiSTer movie transport hook; original converter is copied from the caller's ROM at load time.
.syntax unified
.arch armv5te
.arm
.text
.global _start
_start:
 push {r0-r3,r12,lr}
 ldr r0,[r5]
 ldr r1,[r0]
 ldr r1,[r1,#0x14]
 blx r1
 pop {r0-r3,r12,lr}
 add r2,r5,r0,lsl#2
 ldr pc,=0x02086140
.ltorg
