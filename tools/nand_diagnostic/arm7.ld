/* SPDX-License-Identifier: GPL-3.0-only */
ENTRY(_start)
SECTIONS { . = 0x02003000; .text : { *(.start) } /DISCARD/ : { *(.comment) *(.ARM.attributes) *(.note*) } }
