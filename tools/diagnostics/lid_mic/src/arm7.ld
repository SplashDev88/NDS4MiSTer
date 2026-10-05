ENTRY(_start)
SECTIONS {
 . = 0x02003000;
 .text : { KEEP(*(.start)) *(.text*) *(.rodata*) }
 .data : { *(.data*) }
 .bss (NOLOAD) : { *(.bss*) *(COMMON) }
 ASSERT(. < 0x02004000, "ARM7 overlaps ARM9")
 /DISCARD/ : { *(.comment) *(.ARM.attributes) *(.note*) }
}
