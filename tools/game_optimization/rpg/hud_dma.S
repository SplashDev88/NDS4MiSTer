.syntax unified
.section .text
.macro armcall target
1:
    .hword 0xf000 | (((\target-((0x020528e8+(1b-word_entry)+4)&~3))>>12)&0x7ff)
    .hword 0xe800 | (((\target-((0x020528e8+(1b-word_entry)+4)&~3))>>1)&0x7fe)
.endm
.arm
.global word_entry
word_entry:
    push {r2,r3,r4,r5,r6,r7,ip,lr}
    add ip,pc,#1
    bx ip
.thumb
    movs r4,#2
    b setup
hud_check:
    cmp r4,#2
    bne normal
    cmp r5,#2
    bne normal
    ldr r0,[sp,#28]
    ldr r1,=0x021c05c0
    cmp r0,r1
    bne normal
    ldr r0,=0x06200f00
    cmp r7,r0
    bne normal
    movs r0,#1
    lsls r0,r0,#8
    ldr r1,[sp]
    cmp r1,r0
    bne normal
    ldr r0,=0x04000242
    ldrb r0,[r0]
    cmp r0,#0x93
    bne normal
    ldr r0,=0x04001000
    ldr r0,[r0]
    ldr r1,=0x00011b55
    cmp r0,r1
    bne normal
    @ The caller advances the source by its sampled VCOUNT (r7) times 256.
    @ Recover the image base even when it schedules HBlank during visible rows.
    ldr r0,[sp,#20]
    lsls r0,r0,#8
    subs r6,r6,r0
    armcall 0x02031a10
    cmp r0,#0
    beq done
    ldr r7,hud_destination
    ldr r0,hud_marker
    ldr r1,hud_magic
    str r1,[r0]
    ldr r3,hud_flags
    b issue
.ltorg
.org 0x74
.arm
.global half_entry
half_entry:
    push {r2,r3,r4,r5,r6,r7,ip,lr}
    add ip,pc,#1
    bx ip
.thumb
    movs r4,#1
setup:
    movs r5,r0
    movs r6,r1
    movs r7,r2
    str r3,[sp]
    movs r1,#1
    lsls r1,r1,#28
    armcall 0x02052808
    movs r0,r5
    movs r1,r6
    ldr r2,[sp]
    movs r3,#0
    armcall 0x02052894
    ldr r3,[sp]
    cmp r3,#0
    beq done
    movs r0,r5
    armcall 0x0205271c
    b hud_check
normal:
    ldr r3,[sp]
    lsrs r3,r4
    ldr r1,=0x92600000
    cmp r4,#1
    beq flags
    ldr r1,=0x96600000
flags:
    orrs r3,r1
issue:
    movs r0,#0
    str r0,[sp]
    movs r0,r5
    movs r1,r6
    movs r2,r7
    armcall 0x01ffa830
done:
    add sp,#4
    pop {r3,r4,r5,r6,r7}
    add sp,#4
    pop {pc}
.ltorg

.align 2
hud_magic: .word 0x31445548
hud_flags: .word 0x84003000
hud_destination: .word 0x06840000
hud_marker: .word 0x0684c000
