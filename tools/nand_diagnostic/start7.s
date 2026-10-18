/* SPDX-License-Identifier: GPL-3.0-only */
/* Authored quiescent peer: code fetches only; no SPI, storage, IPC or data writes. */
.syntax unified
.cpu arm7tdmi
.arm
.section .start,"ax"
.global _start
_start:
    msr cpsr_c, #0xd3
.global peer_idle
peer_idle:
    b peer_idle
