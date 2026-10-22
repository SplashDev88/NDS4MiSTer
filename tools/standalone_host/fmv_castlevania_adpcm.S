// SPDX-License-Identifier: GPL-3.0-only
// ACVE rev0 decoder inner loop, relocated within its original 0x150-byte span.
// r4=ADPCM state, r1=input, r5=PCM output, fp=sample count, r0=sample index.
// The original entry establishes r6=88, r7=32767 and r8=-32768.
// Valid streams use index 0..88 and the identity-checked step/index tables.
// Four dead stack stores are removed; their slots are never read by the
// containing routine. Saturation already produces signed 16-bit predictors,
// so the following redundant sign-extension instructions are unnecessary.
// Preserve sample/state memory order and live registers at the continuation;
// r2 is dead there. The new literals occupy unused space in this same span.
.syntax unified
.arch armv5te
.arm
.text
.global _start
_start:
L2059960:
 ldrb r2, [r1]
L2059964:
 ldrb r3, [r4, #2]
L2059968:
 ldrsh sb, [r4]
L205996c:
 and lr, r2, #0xf
L2059970:
 ands r2, lr, #4
L2059974:
 ldr r2,step_pointer
L2059978:
 lsl sl, r3, #1
L205997c:
 ldrsh ip, [r2, sl]
L2059980:
 asr r2, ip, #3
L2059984:
 addne r2, r2, ip
L2059988:
 ands sl, lr, #2
L205998c:
L2059990:
 addne r2, r2, ip, asr #1
L2059994:
 ands sl, lr, #1
L2059998:
L205999c:
 addne r2, r2, ip, asr #2
L20599a0:
 ands sl, lr, #8
L20599a4:
 beq L20599c0
L20599a8:
 sub sb, sb, r2
L20599ac:
L20599b0:
L20599b4:
 cmp sb,r8
L20599b8:
 movlt sb, r8
L20599bc:
 b L20599cc
L20599c0:
 add sb, sb, r2
L20599c4:
 cmp sb, r7
L20599c8:
 movgt sb, r7
L20599cc:
 ldr r2,index_pointer
L20599d0:
 ldrsb r2, [r2, lr]
L20599d4:
 adds r3, r3, r2
L20599d8:
 ldrmi r3, [sp, #0x60]
L20599dc:
 bmi L20599e8
L20599e0:
 cmp r3, #0x58
L20599e4:
 movgt r3, r6
L20599e8:
L20599ec:
L20599f0:
 strh sb,[r4]
L20599f4:
 strb r3, [r4, #2]
L20599f8:
 strh sb,[r5]
L20599fc:
 ldrb r2, [r1]
L2059a00:
 ldrb r3, [r4, #2]
L2059a04:
 ldrsh ip, [r4]
L2059a08:
 asr r2, r2, #4
L2059a0c:
 and sb, r2, #0xf
L2059a10:
 ands r2, sb, #4
L2059a14:
 ldr r2,step_pointer
L2059a18:
 lsl sl, r3, #1
L2059a1c:
 ldrsh lr, [r2, sl]
L2059a20:
 asr r2, lr, #3
L2059a24:
 addne r2, r2, lr
L2059a28:
 ands sl, sb, #2
L2059a2c:
L2059a30:
 addne r2, r2, lr, asr #1
L2059a34:
 ands sl, sb, #1
L2059a38:
L2059a3c:
 addne r2, r2, lr, asr #2
L2059a40:
 ands sl, sb, #8
L2059a44:
 beq L2059a60
L2059a48:
 sub ip, ip, r2
L2059a4c:
L2059a50:
L2059a54:
 cmp ip,r8
L2059a58:
 movlt ip, r8
L2059a5c:
 b L2059a6c
L2059a60:
 add ip, ip, r2
L2059a64:
 cmp ip, r7
L2059a68:
 movgt ip, r7
L2059a6c:
 ldr r2,index_pointer
L2059a70:
 ldrsb r2, [r2, sb]
L2059a74:
 adds r3, r3, r2
L2059a78:
 ldrmi r3, [sp, #0x6c]
L2059a7c:
 bmi L2059a88
L2059a80:
 cmp r3, #0x58
L2059a84:
 movgt r3, r6
L2059a88:
 mov sb,ip
L2059a8c:
L2059a90:
 strh sb, [r4]
L2059a94:
 strb r3, [r4, #2]
L2059a98:
 add r0, r0, #2
L2059a9c:
 strh sb, [r5, #2]
L2059aa0:
 add r5, r5, #4
L2059aa4:
 cmp r0, fp
L2059aa8:
 add r1, r1, #1
L2059aac:
 blt L2059960
 b continuation
.equ continuation,_start+0x150
step_pointer: .word 0x020862e0
index_pointer: .word 0x020862d0
.org 0x150
