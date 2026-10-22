// SPDX-License-Identifier: GPL-3.0-only
.syntax unified
.arch armv5te
.arm
.text
.align 2
.global original_dct
.type original_dct,%function
original_dct:
.incbin "/tmp/original-dct.bin"
.align 2
.global candidate_dct
.type candidate_dct,%function
candidate_dct:
.incbin "/tmp/candidate-dct.bin"
.align 2
.global candidate_dct_stack
.type candidate_dct_stack,%function
candidate_dct_stack:
 push {r4,r5,lr}
 mov r4,sp
 mov sp,r1
 bl candidate_dct
 mov sp,r4
 pop {r4,r5,pc}
.section .note.GNU-stack,"",%progbits
