.syntax unified
.arm
.section .text.mix, "ax"
.global mix_previous
mix_previous:
    bl blend_direction
    b mix_continue
blend_direction:
    cmn r10, #1
    bxeq lr
    cmp r10, #2048
    beq half_direction
    str lr, [sp, #0x18]
    mov r0, r5
    add r1, sp, #0x64
    add r12, r0, #36
weight_next:
    ldr r2, [r0], #4
    smull r3, lr, r2, r10
    mov r3, r3, lsr #12
    orr r3, r3, lr, lsl #20
    ldr r2, [r1]
    add r2, r2, r3
    str r2, [r1], #4
    cmp r0, r12
    bne weight_next
    ldr pc, [sp, #0x18]
half_direction:
    .irp offset,0,4,8,12,16,20,24,28,32
        ldr r2, [r5, #\offset]
        ldr r3, [sp, #(0x64 + \offset)]
        add r3, r3, r2, asr #1
        str r3, [sp, #(0x64 + \offset)]
    .endr
    bx lr

// The preceding projection result has already synchronized the geometry unit.
// Read its direction matrix before submitting another geometry command.
fuse_direction:
    push {r4-r8, lr}
    sub sp, sp, #40
    ldr r3, [sp, #68]
    mov r1, #84
    mla r4, r1, r4, r3
    add r4, r4, #48
    add r5, r6, #64
    ldr r0, =0x04000680
    mov r1, sp
    bl copy_direction
    ldr r0, =0x04000440
    mov r1, #2
    str r1, [r0]
    mov r0, r4
    bl geometry_mult3
    mov r6, #3
row:
    ldmia r4!, {r0-r2}
    mov r7, sp
    add r8, sp, #12
column:
    ldr r3, [r7]
    smull r12, lr, r0, r3
    ldr r3, [r7, #12]
    smlal r12, lr, r1, r3
    ldr r3, [r7, #24]
    smlal r12, lr, r2, r3
    mov r12, r12, lsr #12
    orr r12, r12, lr, lsl #20
    str r12, [r5], #4
    add r7, r7, #4
    cmp r7, r8
    bne column
    subs r6, r6, #1
    bne row
    add sp, sp, #40
    pop {r4-r8, pc}
.ltorg

.section .text.request, "ax"
    bl fuse_direction
    b mix_position
.section .text.finish, "ax"
    b next_joint
    nop

.section .text.weight, "ax"
    ldrb r1, [r8, #2]
    cmn r10, #1
    beq complete_pair
    cmp r1, #128
    bne scalar_position
    cmp r7, #0
    bne half_position
    ldr r2, [sp, #8]
    cmp r2, #2
    ldrbeq r2, [r8, #5]
    cmpeq r2, #128
    bne half_position
    // Save the first joint until both position and direction are available.
    str r6, [sp, #0x1c]
    mvn r10, #0
    b position_done
scalar_position:
    mov r10, r1, lsl #4
    mov r9, #0
    mov r0, r6
    add r1, sp, #0x34
    mov r4, #4
1:
    .rept 3
        ldr r2, [r0], #4
        smull r3, lr, r2, r10
        mov r3, r3, lsr #12
        orr r3, r3, lr, lsl #20
        ldr r2, [r1]
        add r3, r3, r2
        str r3, [r1], #4
    .endr
    add r0, r0, #4
    subs r4, r4, #1
    bne 1b
    b position_done
complete_pair:
    ldr r4, [sp, #0x1c]
    add r0, sp, #0x34
    // 4 position triples (each padded to four words) and 3 packed normal triples.
    mov r5, #7
pair_triple:
    ldmia r4!, {r1,r2,r3}
    ldmia r6!, {r9,r10,ip}
    mov r1, r1, asr #1
    mov r2, r2, asr #1
    mov r3, r3, asr #1
    add r1, r1, r9, asr #1
    add r2, r2, r10, asr #1
    add r3, r3, ip, asr #1
    stmia r0!, {r1,r2,r3}
    cmp r5, #4
    addge r4, r4, #4
    addge r6, r6, #4
    subs r5, r5, #1
    bne pair_triple
    mov r9, #0
    mvn r10, #0
    b position_done

.section .text.final, "ax"
    bl blend_direction
    add r0, sp, #0x64
    b submit_direction
half_position:
    mov r10, #2048
    mov r9, #0
    .set offset,0
    .irp source,0,4,8,16,20,24,32,36,40,48,52,56
        ldr r2, [r6, #\source]
        ldr r3, [sp, #(0x34 + offset)]
        add r3, r3, r2, asr #1
        str r3, [sp, #(0x34 + offset)]
        .set offset,offset + 4
    .endr
    b position_done
