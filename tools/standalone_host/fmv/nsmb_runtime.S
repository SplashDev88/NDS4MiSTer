// SPDX-License-Identifier: GPL-3.0-only
.syntax unified
.arm
.cpu arm946e-s
.section .text.getpacket,"ax"
.global getpacket
getpacket:
    ldr r1, =0x020887fc
    ldrb r1, [r1]
    cmp r1, #0
    beq local_packet
    cmp r1, #8
    beq local_packet
    cmp r1, #9
    beq local_packet
    push {r4, lr}
    mov r4, r0
    mov r0, r0, lsl #16
    mov r0, r0, lsr #16
    ldr ip, =0x02046e98
    blx ip
    cmp r0, #0
    popne {r4, pc}
    mov r0, r4
    pop {r4, lr}
local_packet:
    ldr r1, =0x020887f0
    ldrb r1, [r1]
    cmp r0, r1
    ldreq r0, =0x020888e0
    movne r0, #0
    bx lr
    .ltorg

.section .text.skipclients,"ax"
.global skipclients
skipclients:
    ldr r0, =0x020887fc
    ldrb r0, [r0]
    cmp r0, #0
    bne normal_client
    ldr r0, =0x020887f0
    ldrb r0, [r0]
    cmp sl, r0
    beq normal_client
    ldr r0, =0x02088a54
    ldrb r0, [r0, sl]
    cmp r0, #0
    bne normal_client
    ldr r0, =0x02088a84
    mov r1, #0
    str r1, [r0, sl, lsl #2]
    ldr pc, =0x02011564
normal_client:
    mov r0, sl
    ldr pc, =0x020114e0
    .ltorg
