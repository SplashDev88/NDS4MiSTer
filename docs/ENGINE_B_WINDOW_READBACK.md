# Engine B window-register readback

Metroid Prime Pinball's title image loses the left 128 pixels of the top
screen with the accepted MATCH1 FPGA plus MATCH4 ARM helper. Read-only paired
framebuffer samples and opt-in ARM source samples both contain the missing
half. The source BG0/3D horizontal offset is zero; this is not rotation,
write-combining, or a shifted 3D image.

At source frame 896, line 96, Engine B has `WININ=0x3f00`, with window 0
covering x=0..127 and window 1 covering x=128..255. Engine A has `0x3f3f`.
The disabled FPGA Engine B renderer is replaced by a small register block.
It preserves DISPCNT and BGxCNT, but previously returned zero for WININ and
WINOUT. The game reads WININ while setting one window and writes the whole
halfword back, unintentionally clearing the other window's layer enables.

A local melonDS run of the user's ROM draws all four 64-pixel bands. A
negative control making only Engine B WININ/WINOUT reads return zero produces
exactly `0, 0, 12288, 12288` nonblack pixels per band at frame 300. The right
half remains pixel-identical to the normal reference. The temporary fault
injection patch and image comparison are retained in local evidence and are
not part of the core or release source.

The fix preserves WININ/WINOUT and the likewise-readable BLDCNT/BLDALPHA
registers in the small FPGA block, using the existing native register-map
masks and byte enables. It keeps write-only registers write-only and preserves
both reset inputs. No renderer, CPU cadence, clock, memory buffer, ARM helper,
or graphics transfer changes. The fixed bits total 48 (24 window + 24 blend),
plus decode/mux logic; actual synthesis and fitted area must be measured.

Validation includes the game's two-window read/modify/write sequence, all
window byte lanes, reserved-bit masking, blend halfword/byte independence,
coefficient readback above 16, write-only/unselected addresses, zero byte
enables, and both resets. The whole console VHDL is analyzed as well.
Hardware title verification and gameplay remain required after compilation.

The missing blend readback is corrected on its architectural merits. This
is not yet evidence that it fixes Castlevania's intermittent black frames.
