ENTRY(_start)
SECTIONS {
 . = 0x02004000;
 .text : { KEEP(*(.start)) *(.text*) *(.rodata*) }
 .data : { *(.data*) }
 . = ALIGN(4); __bss_start = .;
 .bss (NOLOAD) : { *(.bss*) *(COMMON) }
 . = ALIGN(4); __bss_end = .;
 ASSERT(__bss_end < 0x02300000, "Diagnostic overlaps fixed font source")
 /DISCARD/ : { *(.comment) *(.ARM.attributes) *(.note*) }
}
