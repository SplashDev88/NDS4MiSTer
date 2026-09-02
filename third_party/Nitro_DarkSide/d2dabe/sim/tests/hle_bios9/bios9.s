@ SPDX-License-Identifier: GPL-3.0-or-later
@ SPDX-FileCopyrightText: 2026 Sarah Aronson <v@pingas.org>
@ ARM9 HLE BIOS for NDS_MiSTfits — assembled by build.sh into
@ rtl/nds_bios9.vhd (served read-only at 0xFFFF0000 by nds_membus9,
@ the NDS9 high-vector boot ROM window).
@
@ calico/libnds-2.x ds9 binaries self-host their exception vectors in
@ ITCM (CP15 V bit low) shortly after boot, so almost nothing here is
@ exercised in steady state. What IS load-bearing:
@   - SWI 0x0F IsDebugger: calico's ds9 bootstub calls svc 0x0f0000
@     from ARM state before installing its own vectors (melonDS runs
@     its FreeBIOS for this; retail -> r0 = 0).
@   - IRQ dispatch (GBATEK NDS9): user handler pointer lives at
@     DTCM_BASE + 0x3FFC; DTCM base comes from CP15 c9,c1,0 [31:12].
@     Only reachable in the pre-vector-setup window, but must not be
@     garbage if an IRQ sneaks in there.
@ Plus the cheap generic SWIs (WaitByLoop/Div/GetCRC16) in case a
@ libnds-1.x-style ROM calls them on the ARM9. Anything else parks at
@ its vector / swi_bad so a missing call is an obvious stuck PC in the
@ sim, never silent garbage.

        .arm
        .cpu    arm946e-s
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
@ NDS9: handler pointer at DTCM_BASE + 0x3FFC (GBATEK). DTCM base is
@ CP15 c9,c1,0 bits [31:12]; DTCM is 16 KB on the NDS.
irq_handler:
        stmfd   sp!, {r0-r3, r12, lr}
        mrc     p15, 0, r12, c9, c1, 0
        mov     r12, r12, lsr #12
        mov     r12, r12, lsl #12       @ DTCM base
        add     r12, r12, #0x4000
        ldr     r12, [r12, #-4]         @ [DTCM+0x3FFC]
        add     lr, pc, #0              @ return lands on the ldmfd
        bx      r12
        ldmfd   sp!, {r0-r3, r12, lr}
        subs    pc, lr, #4

@ ---------------- SWI dispatch ----------------
@ SVC mode, IRQs masked for the whole call (all our SWIs are short).
@ r0-r3 follow the per-call ABI, r11/r12 are scratch.
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
        cmp     r11, #0x09
        beq     swi_div
        cmp     r11, #0x0E
        beq     swi_getcrc16
        cmp     r11, #0x0F
        beq     swi_isdebugger
swi_bad:
        b       swi_bad

swi_ret:
        ldmfd   sp!, {r11, r12, lr}
        movs    pc, lr

@ WaitByLoop: r0 = loop count (4 cycles per iteration on hardware;
@ only the architectural result matters for the frame diff)
swi_waitbyloop:
        subs    r0, r0, #1
        bgt     swi_waitbyloop
        b       swi_ret

@ Div: r0 = num, r1 = den -> r0 = num/den, r1 = num%den, r3 = |num/den|
swi_div:
        stmfd   sp!, {r2, r4, r5}
        ands    r4, r0, #0x80000000
        rsbmi   r0, r0, #0
        ands    r5, r1, #0x80000000
        rsbmi   r1, r1, #0
        mov     r2, #0
        mov     r12, #1
1:      cmp     r1, r0
        movls   r1, r1, lsl #1
        movls   r12, r12, lsl #1
        bls     1b
2:      movs    r12, r12, lsr #1
        beq     3f
        mov     r1, r1, lsr #1
        cmp     r0, r1
        subcs   r0, r0, r1
        addcs   r2, r2, r12
        b       2b
3:      mov     r3, r2                  @ |quotient|
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
@ CRC-16 poly 0xA001 LSB-first, byte-wise (GBATEK).
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
