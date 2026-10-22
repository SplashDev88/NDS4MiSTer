// SPDX-License-Identifier: GPL-3.0-only
.syntax unified
.arch armv5te
.arm
.text
.balign 4
.global original_converter
.type original_converter,%function
original_converter:
.incbin "/tmp/original-converter.bin"
.size original_converter,.-original_converter
.balign 4
.global candidate_converter
.type candidate_converter,%function
candidate_converter:
.incbin "/tmp/candidate-converter.bin"
.size candidate_converter,.-candidate_converter
.section .note.GNU-stack,"",%progbits
