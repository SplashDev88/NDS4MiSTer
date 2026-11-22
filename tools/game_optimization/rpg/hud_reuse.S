.syntax unified
.arm
.text
.global sdk_seek, hud_needs_upload
sdk_seek:
    @ Both SDK seek implementations are byte-identical position-independent leaves.
    b sdk_seek_twin
hud_needs_upload:
    push {r4,r5,r7,lr}
    mov r0,r6
    add ip,r0,#0xc000
    mov r1,#0
    mov r2,#0
1:
    ldmia r0!,{r3,r4,r5,r7}
    add r1,r3,r1,ror #7
    add r2,r4,r2,ror #11
    add r1,r5,r1,ror #7
    add r2,r7,r2,ror #11
    cmp r0,ip
    bne 1b
    adr r3,previous
    ldmia r3,{r4,r5,ip}
    cmp r1,r4
    cmpeq r2,r5
    movne ip,#0
    @ A new image needs a full transfer. Otherwise refresh its six 8 KiB
    @ pages over eight calls, preserving the original refresh period.
    subs r0,ip,#1
    andcs r0,r0,#7
    addcs r6,r6,r0,lsl #13
    add ip,ip,#1
    stmia r3,{r1,r2,ip}
    pop {r4,r5,r7,pc}
previous:
    .word 0,0,0
