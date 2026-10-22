// SPDX-License-Identifier: GPL-3.0-only
// Exact chroma/pixel memoization overlay at guest 0x01ff9220.
.syntax unified
.arch armv5te
.arm
.text
.global _start
_start:
 mov r0, #0
 str r0, [sp, #8]
 ldr r1, [r7]
 ldr r2, [r8]
 ldr fp, [sb]
 mvn fp, fp
 bl recompute
 b row_start
.org 0x40
green_cb: .word 0x581
green_cr: .word 0xb6c
blue_cb: .word 0x1c59
red_cr: .word 0x166f
row_start:
 // Pixel 0: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_0
 cmp ip, fp
 beq store_0
convert_0:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_0:
 strh r0, [sl, #0]
 // Pixel 1: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_1
 cmp ip, fp
 beq store_1
convert_1:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_1:
 strh r0, [sl, #2]
 // Pixel 2: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_2
 cmp ip, fp
 beq store_2
convert_2:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_2:
 strh r0, [sl, #4]
 // Pixel 3: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_3
 cmp ip, fp
 beq store_3
convert_3:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_3:
 strh r0, [sl, #6]
 // Pixel 4: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_4
 cmp ip, fp
 beq store_4
convert_4:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_4:
 strh r0, [sl, #8]
 // Pixel 5: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_5
 cmp ip, fp
 beq store_5
convert_5:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_5:
 strh r0, [sl, #10]
 // Pixel 6: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_6
 cmp ip, fp
 beq store_6
convert_6:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_6:
 strh r0, [sl, #12]
 // Pixel 7: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_7
 cmp ip, fp
 beq store_7
convert_7:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_7:
 strh r0, [sl, #14]
 // Pixel 8: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_8
 cmp ip, fp
 beq store_8
convert_8:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_8:
 strh r0, [sl, #16]
 // Pixel 9: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_9
 cmp ip, fp
 beq store_9
convert_9:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_9:
 strh r0, [sl, #18]
 // Pixel 10: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_10
 cmp ip, fp
 beq store_10
convert_10:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_10:
 strh r0, [sl, #20]
 // Pixel 11: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_11
 cmp ip, fp
 beq store_11
convert_11:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_11:
 strh r0, [sl, #22]
 // Pixel 12: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_12
 cmp ip, fp
 beq store_12
convert_12:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_12:
 strh r0, [sl, #24]
 // Pixel 13: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_13
 cmp ip, fp
 beq store_13
convert_13:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_13:
 strh r0, [sl, #26]
 // Pixel 14: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_14
 cmp ip, fp
 beq store_14
convert_14:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_14:
 strh r0, [sl, #28]
 // Pixel 15: reuse exact chroma products only on equal inputs.
 ldr lr, [r7], #4
 ldr r3, [r8], #4
 ldr ip, [sb], #4
 cmp lr, r1
 cmpeq r3, r2
 bne new_chroma_15
 cmp ip, fp
 beq store_15
convert_15:
 mov fp, ip
 add ip, ip, #128
 add r0, ip, r4
 sub r3, ip, r5
 add ip, ip, r6
 orr lr, r0, r3
 orr lr, lr, ip
 cmp lr, #255
 blhi clamp
 mov r0, r0, lsr #3
 and r3, r3, #248
 orr r0, r0, r3, lsl #2
 and ip, ip, #248
 orr r0, r0, ip, lsl #7
store_15:
 strh r0, [sl, #30]

 ldr ip, [sp]
 ldr ip, [ip]
 add sl, sl, ip, lsl #1
 ldr ip, [sp, #8]
 add ip, ip, #1
 str ip, [sp, #8]
 cmp ip, #16
 blo row_start
 // Preserve the original volatile register outputs as well as the ABI.
 mov r0, #31
 ldr r1, green_cb
 ldr r2, green_cr
 ldr r3, blue_cb
 add sp, sp, #0x94
 pop {r4,r5,r6,r7,r8,r9,r10,r11,lr}
 bx lr
recompute:
 ldr r3, red_cr
 mul r4, r1, r3
 asr r4, r4, #12
 ldr r3, green_cr
 mul r5, r1, r3
 ldr r3, green_cb
 mla r5, r2, r3, r5
 asr r5, r5, #12
 ldr r3, blue_cb
 mul r6, r2, r3
 asr r6, r6, #12
 bx lr
clamp:
 cmp r0, #255
 movgt r0, #255
 bic r0, r0, r0, asr #31
 cmp r3, #255
 movgt r3, #255
 bic r3, r3, r3, asr #31
 cmp ip, #255
 movgt ip, #255
 bic ip, ip, ip, asr #31
 bx lr
new_chroma_0:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_0
new_chroma_1:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_1
new_chroma_2:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_2
new_chroma_3:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_3
new_chroma_4:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_4
new_chroma_5:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_5
new_chroma_6:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_6
new_chroma_7:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_7
new_chroma_8:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_8
new_chroma_9:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_9
new_chroma_10:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_10
new_chroma_11:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_11
new_chroma_12:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_12
new_chroma_13:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_13
new_chroma_14:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_14
new_chroma_15:
 mov r1, lr
 mov r2, r3
 bl recompute
 b convert_15
.org 0x82c
