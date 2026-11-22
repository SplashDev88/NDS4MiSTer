ENTRY(sdk_seek)
sdk_seek_twin = 0x0204cab0;
SECTIONS {
  .text 0x02031a0c : { *(.text) }
  ASSERT(SIZEOF(.text) <= 0x6c, "HUD checksum exceeds duplicated function")
}
