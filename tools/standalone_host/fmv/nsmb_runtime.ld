/* SPDX-License-Identifier: GPL-3.0-only */
SECTIONS {
 .getpacket 0x0200eb50 : { *(.text.getpacket) }
 .skipclients 0x02000c00 : { *(.text.skipclients) }
}
