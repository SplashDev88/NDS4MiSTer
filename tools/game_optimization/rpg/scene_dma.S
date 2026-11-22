.syntax unified
.macro armcall target
1:
    .hword 0xf000 | (((\target-((0x0200a328+(1b-primary)+4)&~3))>>12)&0x7ff)
    .hword 0xe800 | (((\target-((0x0200a328+(1b-primary)+4)&~3))>>1)&0x7fe)
.endm
.section .text
.arm
.global primary
primary:
    push {r1,r2,r3,r4,r5,r6,r7,lr}
    add ip,pc,#1
    bx ip
.thumb
    movs r7,r0
    adds r1,r7,#0
    adds r1,#0x22
    ldrb r0,[r1]
    cmp r0,#0
    beq update
    movs r0,#0
    strb r0,[r1]
    movs r0,r7
    armcall 0x020026f4
    b done
update:
    subs r1,#2
    ldrb r0,[r1]
    movs r6,#1
    cmp r0,#0
    bne alternate
    ldr r2,[r7,#16]
    ldr r0,[r7,#20]
    cmp r0,r2
    bne swap_screen
    movs r6,#0
    b capture_arm
swap_screen:
    str r2,[r7,#20]
    ldr r1,=0x04000304
    ldrh r0,[r1]
    lsls r0,r0,#17
    lsrs r0,r0,#17
    lsls r2,r2,#15
    orrs r0,r2
    strh r0,[r1]
capture_arm:
    ldr r1,[r7,#16]
    ldr r0,[r7,#12]
    cmp r1,r0
    beq primary_dma
    ldr r0,=0x04000006
    ldrh r0,[r0]
    cmp r0,#193
    bhi capture_ready
    movs r0,#0xc4
    lsls r0,r0,#1
    armcall 0x02055a4c
capture_ready:
    ldr r0,=0x04000600
    ldr r0,[r0]
    lsls r0,r0,#4
    bmi primary_dma
    ldr r2,[r7,#12]
    str r2,[r7,#16]
    ldr r1,=0x80330010
    ldr r0,=0x04000064
    str r1,[r0]
primary_dma:
    movs r0,#1
    armcall 0x02052778
    bl title_active
    cmp r0,#0
    beq transmit
    ldr r1,=0x06204000
    adds r0,r1,r0
    str r0,[r1]
    @ The title uses both scratch images only for DMA to the sub display.
    @ The HPS already owns the actual bank-D image and retains both views.
    b done
transmit:
    armcall 0x0204fe8c
    movs r2,r0
    ldr r0,[r7,#20]
    movs r1,#1
    eors r0,r1
    lsls r0,r0,#2
    adds r0,r7,r0
    ldr r1,[r0,#24]
    movs r0,#1
    bl stream_pair
capture:
    cmp r6,#0
    beq done
    movs r0,#1
    str r0,[sp]
    ldr r0,[r7,#20]
    lsls r0,r0,#2
    adds r0,r7,r0
    ldr r2,[r0,#24]
    ldr r1,=0x06860000
    movs r3,#3
    lsls r3,r3,#15
    movs r0,#3
    armcall 0x020523cc
done:
    pop {r1,r2,r3,r4,r5,r6,r7,pc}
.thumb_func
stream_pair:
    push {r3,r4,r5,r6,r7,lr}
    movs r4,r0
    movs r5,r1
    movs r6,r2
    movs r3,#1
    str r3,[sp]
    lsls r3,r3,#9
    armcall 0x020523cc
    movs r0,r4
    movs r3,#2
    lsls r3,r3,#8
    adds r1,r5,r3
    movs r2,r6
    armcall 0x020528e8
    pop {r3,r4,r5,r6,r7,pc}
send:
    pop {r0,r1,r2,r3}
    mov lr,r3
    ldr r3,=send_shape
    bx r3
.ltorg
alternate:
    movs r0,#2
    armcall 0x02052778
    armcall 0x0204ff00
    movs r2,r0
    ldr r1,[r7,#24]
    movs r0,#2
    bl stream_pair
    movs r0,#1
    armcall 0x02052778
    armcall 0x0204fe8c
    movs r2,r0
    ldr r1,[r7,#28]
    movs r0,#1
    bl stream_pair
    b done
.thumb_func
title_active:
    @ Title archive FAT window; the prologue reuses the same VRAM and heap.
    ldr r0,=0x0207f780
    ldr r1,[r0]
    movs r2,#1
    ldr r0,=0x033e9e00
    cmp r1,r0
    beq check_display
    ldr r0,=0x00506400
    cmp r1,r0
    bne inactive
    movs r2,#2
check_display:
    ldr r0,=0x04001000
    ldr r1,[r0]
    ldr r0,=0x10555
    cmp r1,r0
    bne inactive
    movs r0,#4
    lsls r0,r0,#24
    ldr r1,[r0]
    lsls r1,r1,#12
    lsrs r1,r1,#28
    cmp r1,#14
    bne inactive
    movs r0,r2
    bx lr
inactive:
    movs r0,#0
    bx lr
.global can_send_shape
.thumb_func
can_send_shape:
    push {r0,r1,r2,lr}
    bl title_active
    cmp r0,#1
    bne send
    @ Only the tagged title model has an alternate list after its original.
    ldr r0,[sp]
    ldr r1,[sp,#4]
    adds r0,r0,r1
    lsrs r2,r0,#22
    cmp r2,#8
    bne send
    ldr r2,[r0]
    ldr r1,=0x31534347
    cmp r1,r2
    bne send
    ldr r2,[r0,#4]
    lsrs r1,r2,#24
    ldr r3,=0x02083f4c
    ldr r3,[r3]
    cmp r3,#0
    beq send
    ldr r3,[r3,#16]
    cmp r3,#0
    bne landscape_camera
    subs r1,#1
    cmp r1,#2
    bls send
    b omit_shape
landscape_camera:
    @ Latch one decision for the whole landscape pass. The first shape is seven.
    adr r3,landscape_phase
    ldrb r2,[r3]
    cmp r1,#7
    bne use_phase
    movs r1,#1
    eors r2,r1
    strb r2,[r3]
use_phase:
    cmp r2,#0
    beq omit_shape
    ldr r2,[r0,#4]
    lsls r1,r2,#8
    beq omit_shape
    bmi send
    lsrs r1,r1,#8
    adds r0,#8
    str r0,[sp]
    str r1,[sp,#4]
    b send
omit_shape:
    pop {r0,r1,r2,pc}
.align 2
landscape_phase:
    .word 0
.ltorg
