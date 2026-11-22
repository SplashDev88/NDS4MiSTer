ENTRY(sdk_seek)
sdk_seek_twin = cart_sdk_seek_twin;
SECTIONS {
  .text cart_seek : { *(.text) }
  ASSERT(SIZEOF(.text) <= 0x6c, "HUD checksum exceeds duplicated function")
}
