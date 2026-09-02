    .syntax unified
    .arm
    .global _start
_start:
    ldr r0, ipc_addr
    ldr r1, value_9
    str r1, [r0]
wait_a:
    ldr r2, [r0]
    and r2, r2, #15
    cmp r2, #10
    bne wait_a
    ldr r1, value_b
    str r1, [r0]
wait_c:
    ldr r2, [r0]
    and r2, r2, #15
    cmp r2, #12
    bne wait_c
    ldr r1, value_d
    str r1, [r0]
wait_0:
    ldr r2, [r0]
    and r2, r2, #15
    cmp r2, #0
    bne wait_0
    ldr r3, done_addr
    mov r4, #1
    str r4, [r3]
hang:
    b hang
ipc_addr: .word 0x04000180
value_9:  .word 0x00000900
value_b:  .word 0x00000B00
value_d:  .word 0x00000D00
done_addr:.word 0x02001004
