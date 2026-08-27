    .syntax unified
    .arm
    .global _start
_start:
    ldr r0, ipc_addr
    mov r1, #0
    str r1, [r0]
wait_9:
    ldr r2, [r0]
    and r2, r2, #15
    cmp r2, #9
    bne wait_9
    ldr r1, value_a
    str r1, [r0]
wait_b:
    ldr r2, [r0]
    and r2, r2, #15
    cmp r2, #11
    bne wait_b
    ldr r1, value_c
    str r1, [r0]
wait_d:
    ldr r2, [r0]
    and r2, r2, #15
    cmp r2, #13
    bne wait_d
    mov r1, #0
    str r1, [r0]
    ldr r3, done_addr
    mov r4, #1
    str r4, [r3]
hang:
    b hang
ipc_addr: .word 0x04000180
value_a:  .word 0x00000A00
value_c:  .word 0x00000C00
done_addr:.word 0x02001000
