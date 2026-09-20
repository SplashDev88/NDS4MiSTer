# Engine B master-brightness readback

Separate follow-up to BREG1, which restores Metroid Prime Pinball's missing half-screen through WININ/WINOUT readback.

The disabled Engine B FPGA renderer is replaced by `nds_gpu2d_register_shadow.vhd`. Its readable master-brightness register at offset 0x06C was still omitted. Both the native `reg_nds_display.vhd` / `nds_gpu2d.vhd` and the local melonDS `GPU.cpp` implement readback of factor bits 4:0 and mode bits 15:14. The new shadow retains exactly those seven programmed bits, with independent low/high byte enables, zero reserved/upper bits, and both reset inputs. Factors above 16 remain readable; the unchanged ARM renderer clamps their visual effect.

A fade that reads 0x8010 and subtracts one must write 0x800F, preserving darken mode. The test fails against BREG1 at the master-brightness address decode and passes with this correction. It also checks reserved masks, independent byte writes, ignored upper lanes, no byte-enable writes, adjacent address exclusion, and both reset routes. Full console VHDL analysis is required before compiling.

No CPU cadence, ARM helper, rendering algorithm, cache policy, framebuffer, transfer, clock, reset timing, or control changes. Actual fitted cost and slack must be measured. Build ID 260919-BREG2 distinguishes this candidate from the already hardware-verified BREG1.

Castlevania's intermittent bottom-screen flash is still unproven. This corrects a demonstrable register contract omission; there is no evidence yet that the game reads this register at the reported event or that this change fixes that event. Preserve BREG1 as a separate tested rollback and require actual gameplay comparison.
