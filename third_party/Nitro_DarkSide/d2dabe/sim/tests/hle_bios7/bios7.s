@ SPDX-License-Identifier: GPL-3.0-or-later
@ SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
@ ARM7 HLE BIOS for NDS_MiSTfits — assembled by build.sh into
@ rtl/nds_bios7.vhd (served read-only at 0x00000000 by nds_membus7).
@
@ Provides exactly the BIOS surface a calico/libnds-2.x ARM7 binary
@ uses (surveyed from libcalico_ds7.a, see M7 notes):
@   - IRQ dispatch (GBATEK NDS7): save {r0-r3,r12,lr} on sp_irq, call
@     the user handler from [0x0380FFFC] with lr pointing at the
@     restore, then pop + subs pc,lr,#4. calico's __irq_handler either
@     returns with bx lr or consumes the six stacked words itself when
@     it context-switches, so the exact frame layout is load-bearing.
@   - SWIs: 0x03 WaitByLoop, 0x06 Halt (via HALTCNT), 0x07 Sleep
@     (aliased to Halt: no lid/POWCNT2 yet), 0x08 SoundBias (no-op:
@     no sound hardware), 0x09 Div, 0x0E GetCRC16, 0x0F IsDebugger
@     (retail -> 0), 0x1F CustomHalt. This is the exact set linked into
@     a stock libnds-2.x ARM7 binary (thumb-wrapper + ARM-mode scan of
@     hello_world). The dispatcher decodes both Thumb (imm8) and ARM
@     (imm24) callers: calico wrappers are Thumb, its bootstub issues
@     svc 0x0f0000 and libnds7 svc 0x090000 from ARM state.
@   - anything else parks at its vector / swi_bad so a missing call is
@     an obvious stuck PC in the sim, never silent garbage.

        .arm
        .cpu    arm7tdmi
        .text

vec_reset:  b   vec_reset               @ 0x00 (loader presets PC, never used)
vec_undef:  b   vec_undef               @ 0x04
vec_swi:    b   swi_handler             @ 0x08
vec_pabt:   b   vec_pabt                @ 0x0C
vec_dabt:   b   vec_dabt                @ 0x10
vec_resv:   b   vec_resv                @ 0x14
vec_irq:    b   irq_handler             @ 0x18
vec_fiq:    b   vec_fiq                 @ 0x1C

@ ---------------- IRQ dispatch ----------------
irq_handler:
        stmfd   sp!, {r0-r3, r12, lr}
        ldr     r12, =0x0380FFFC
        add     lr, pc, #0              @ return lands on the ldmfd
        ldr     pc, [r12]
        ldmfd   sp!, {r0-r3, r12, lr}
        subs    pc, lr, #4

@ ---------------- SWI dispatch ----------------
@ SVC mode, IRQs masked for the whole call (all our SWIs are short);
@ sp_svc is the app's (calico sets it before its first SWI). r0-r3
@ follow the per-call ABI, r11/r12 are scratch.
swi_handler:
        stmfd   sp!, {r11, r12, lr}
        mrs     r12, spsr
        tst     r12, #0x20              @ caller Thumb?
        ldrneb  r11, [lr, #-2]          @ thumb: swi imm8
        ldreq   r11, [lr, #-4]          @ arm: number in imm24 [23:16]
        moveq   r11, r11, lsr #16
        and     r11, r11, #0xFF

        cmp     r11, #0x03
        beq     swi_waitbyloop
        cmp     r11, #0x06
        beq     swi_halt
        cmp     r11, #0x07
        beq     swi_halt                @ Sleep
        cmp     r11, #0x08
        beq     swi_ret                 @ SoundBias
        cmp     r11, #0x09
        beq     swi_div
        cmp     r11, #0x0E
        beq     swi_getcrc16
        cmp     r11, #0x0F
        beq     swi_isdebugger
        cmp     r11, #0x1F
        beq     swi_customhalt
swi_bad:
        b       swi_bad                 @ unimplemented SWI: park loudly

swi_ret:
        ldmfd   sp!, {r11, r12, lr}
        movs    pc, lr

swi_waitbyloop:                         @ r0 = count (~4 cycles each)
1:      subs    r0, r0, #1
        bgt     1b
        b       swi_ret

swi_halt:
        mov     r12, #0x04000000
        mov     r11, #0x80
        strb    r11, [r12, #0x301]      @ HALTCNT: halt until IE & IF != 0
        b       swi_ret

swi_customhalt:                         @ r2 = HALTCNT value (pm sleep path)
        mov     r12, #0x04000000
        strb    r2, [r12, #0x301]
        b       swi_ret

@ Div: r0 = num, r1 = den -> r0 = num/den (signed), r1 = num%den
@ (numerator sign), r3 = abs(quotient). den = 0 returns q = 0, rem =
@ num instead of the real BIOS's garbage - nothing sane divides by 0.
swi_div:
        stmfd   sp!, {r2, r4, r5}
        movs    r4, r0                  @ keep signed num
        rsbmi   r0, r0, #0              @ r0 = |num|
        movs    r5, r1                  @ keep signed den
        rsbmi   r1, r1, #0              @ r1 = |den|
        mov     r2, #0                  @ quotient
        cmp     r1, #0
        beq     3f
        mov     r12, #1
1:      cmp     r1, r0, lsr #1          @ align without overflowing
        movls   r1, r1, lsl #1
        movls   r12, r12, lsl #1
        bls     1b
2:      cmp     r0, r1
        subcs   r0, r0, r1
        orrcs   r2, r2, r12
        movs    r12, r12, lsr #1
        movne   r1, r1, lsr #1
        bne     2b
3:      mov     r3, r2                  @ r3 = |quotient|
        teq     r4, r5                  @ N = sign(num) ^ sign(den)
        rsbmi   r2, r2, #0
        movs    r4, r4
        rsbmi   r0, r0, #0              @ remainder takes num's sign
        mov     r1, r0
        mov     r0, r2
        ldmfd   sp!, {r2, r4, r5}
        b       swi_ret

swi_isdebugger:
        mov     r0, #0                  @ retail unit: 4 MB main RAM
        b       swi_ret

@ GetCRC16: r0 = initial, r1 = source, r2 = length in bytes.
@ CRC-16 poly 0xA001 LSB-first, byte-wise (GBATEK; the firmware
@ user-settings checksum).
swi_getcrc16:
        ldr     r12, =0xA001
1:      subs    r2, r2, #1
        blt     swi_ret                 @ r0 = crc
        ldrb    r11, [r1], #1
        eor     r0, r0, r11
        mov     r11, #8
2:      movs    r0, r0, lsr #1
        eorcs   r0, r0, r12
        subs    r11, r11, #1
        bne     2b
        b       1b

        .pool
