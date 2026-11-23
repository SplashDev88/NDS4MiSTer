@ USA revision 0, overlay 6 at 0x02122b34. Assemble for ARMv5TE.
@ Link .trial at that address and extract .trial as the catalog replacement.
.syntax unified
.arch armv5te
.section .trial,"ax"
.arm
.global entry
entry:
    add ip, pc, #1
    bx ip
.thumb
.macro arm_call target
    .set displacement\@, \target - ((0x02122b34 + (. - entry) + 4) & ~3)
    .hword 0xf000 | ((displacement\@ >> 12) & 0x7ff)
    .hword 0xe800 | ((displacement\@ >> 1) & 0x7fe)
.endm
.thumb_func
body:
    push {r4-r7,lr}
    sub sp,#12
    movs r7,r0
    movs r6,r1
    movs r5,r2
    movs r3,#10
    lsls r3,r3,#8
    adds r3,r7,r3
    str r3,[sp,#4]
    ldr r4,[r3,#8]
clear_next:
    ldr r3,[sp,#4]
    ldr r0,[r3,#4]
    cmp r4,r0
    bhs cleared
    ldrh r0,[r4]
    adds r4,#2
    lsls r1,r0,#4
    subs r0,r1,r0
    lsls r0,r0,#2
    ldr r1,[r7]
    adds r0,r0,r1
    movs r1,#0
    movs r2,#60
    arm_call 0x01ff8228
    b clear_next
cleared:
    subs r0,r6,#1
    cmp r0,#2
    bhi finished
    str r7,[sp]
    ldr r4,fixed_size
    cmp r6,#1
    beq flush
    movs r1,#1
    strh r1,[r3,#12]
    cmp r6,#3
    bne flush
    ldr r0,[r7]
    adds r2,r0,r4
    subs r2,#12
    @ Check the fixed three-word trailer before considering a shorter DMA.
    ldr r1,[r2]
    cmp r1,#0x41
    bne flush
    ldr r1,[r2,#4]
    cmp r1,#0x12
    bne flush
    ldr r1,[r2,#8]
    cmp r1,#1
    bne flush
    movs r3,r2
find_word:
    cmp r3,r0
    beq room
    subs r3,#4
    ldr r1,[r3]
    cmp r1,#0
    beq find_word
    adds r3,#4
room:
    @ A packed opcode can consume at most 4 * 32 parameter words. Retain
    @ that prefix intact, including any final zero-valued parameters.
    movs r1,#128
    lsls r1,r1,#2
    adds r3,r3,r1
    subs r2,#16
    cmp r3,r2
    bhi flush
    movs r1,#0x41
    str r1,[r3]
    movs r1,#0x12
    str r1,[r3,#4]
    movs r1,#1
    str r1,[r3,#8]
    str r7,[r3,#12]
    str r3,[sp]
    subs r4,r3,r0
    adds r4,#12
    movs r6,#4
flush:
    ldr r0,[r7]
    movs r1,r4
    arm_call 0x02039488
    movs r0,r5
    ldr r1,[r7]
    movs r2,r4
    cmp r6,#1
    beq mode1
    ldr r3,normal_callback
    cmp r6,#2
    beq mode2
    cmp r6,#4
    bne mode3
    adr r3,after_trim
    adds r3,#1
mode3:
    arm_call 0x0203a79c
    b finished
mode2:
    arm_call 0x0203a598
    b finished
mode1:
    arm_call 0x01ff9328
finished:
    add sp,#12
    pop {r4-r7,pc}
.align 2
after_trim:
    ldr r3,[r0,#12]
    movs r1,#0
    str r1,[r0]
    str r1,[r0,#4]
    str r1,[r0,#8]
    str r1,[r0,#12]
    movs r0,r3
    ldr r3,normal_callback
    bx r3
.align 2
fixed_size: .word 0x12c0c
normal_callback: .word 0x02122b24
