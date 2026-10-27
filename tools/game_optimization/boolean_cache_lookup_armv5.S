/* SPDX-License-Identifier: GPL-3.0-or-later
 * Isolated cost experiment, NOT a guest patch or allocated game memory.
 * R0/R1 point to two eight-byte keys. Return R0=0/1 on hit, -1 on miss,
 * -2 on unsupported alignment. Preserve R3-R11/SP; other flags/temps are
 * clobbered. No miss insertion, caller integration or timing qualification.
 * Synthetic table: 512 slots, 32 bytes each: key[16], bool[4], valid[4], pad[8].
 */
.syntax unified
.arch armv5te
.arm
.text
.global lookup
lookup:
    push {r3, lr}
    orr ip, r0, r1
    tst ip, #3
    bne unaligned
    ldmia r0, {r2, r3}
    ldmia r1, {ip, lr}
    eor r0, r2, r3, ror #7
    eor r0, r0, ip, ror #13
    eor r0, r0, lr, ror #19
    mov r0, r0, lsl #23
    ldr r1, table_base
    add r0, r1, r0, lsr #18
    ldr r1, [r0, #20]
    cmp r1, #1
    bne miss
    ldr r1, [r0]
    cmp r1, r2
    ldreq r1, [r0, #4]
    cmpeq r1, r3
    ldreq r1, [r0, #8]
    cmpeq r1, ip
    ldreq r1, [r0, #12]
    cmpeq r1, lr
    bne miss
    ldr r0, [r0, #16]
    pop {r3, pc}
miss:
    mvn r0, #0
    pop {r3, pc}
unaligned:
    mvn r0, #1
    pop {r3, pc}
table_base:
    .word 0x03010000
