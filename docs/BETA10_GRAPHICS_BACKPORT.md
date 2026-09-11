# Beta.10 graphics-only backport

Base: public beta.10 source `4a12c8c`. Engine B rendering remains disabled.
The ARM service, beta.10 renderer optimizations, launcher, sound, touch,
saves, layouts, and 134 MHz clock family are unchanged. Both display
positions continue showing Engine A. Quartus seed is 2.

## Ported corrections

1. **Extended-palette refill after a VRAM remap.** A temporary LCDC mapping
   during VBlank could replace cached background colors with zero. Keep
   accepted requests intact and repeat the refill after mapping changes.
   This is the correction validated on the dual-screen Kirby intro.
2. **Local VRAM write retirement.** A posted DMA transaction must reach local
   VRAM on the same source-acceptance edge that copies its HPS event. Waiting
   until the event later leaves its queue can sample the DMA's next read/write
   state. Retain pending non-posted pulses under backpressure. Beta.10's
   narrower LCDC-only HPS event filter is deliberately unchanged.
3. **Graphics-control readbacks with Engine B omitted.** Keep DISPCNT and all
   four BGxCNT register values so game-side read/modify/write operations and
   upload-address calculations do not read constant zero. This tiny register
   shadow does not draw Engine B or add ARM-side 2D work.

These are backports of the fixes developed in `226f402`, `30b5de7`, and
`c00ede8`, not a conversion of the Engine B branch into a public baseline.
No Engine B scanline transport, expanded event queues, palette/OAM replay,
display-capture reconstruction, or dual-screen publication is enabled.

## Evidence on this baseline

Before changing production RTL, the extracted beta.10 VRAM wiring failed
the LCDC-DMA test at 175 ns: `HPS event has no preceding local write`.
The original palette process failed a VBlank remap test with 2,130 incorrect
background-palette words. Thus both faults also exist on beta.10, rather than
being assumptions based on the different Engine B integration.

The write-retirement test uses beta.10's actual production mux and event gate
with the real DMA. It covers CPU, posted/non-posted DMA, VRAM-source reads,
sink backpressure, local credit variation, service-off, and local-only BG
writes. The BG-only cases explicitly require no HPS events.

The palette test extracts the actual production refill process and checks
nine mapping cases plus the complete GPU mode/3D-line regression. The register
test verifies masked DISPCNT readbacks, all BG controls, byte enables, reset,
and the resulting Kirby upload addresses.

Run:

```sh
bash tools/test_h3d_vram9_retirement.sh
bash tools/test_nds_extpal_remap.sh
bash tools/test_nds_gpu2d_register_shadow.sh
bash tools/test_nitro_console_island_host.sh
```

To reproduce the two pre-fix failures without reverting production files:

```sh
SOURCE_REVISION=4a12c8c bash tools/test_h3d_vram9_retirement.sh
SOURCE_REVISION=4a12c8c bash tools/test_nds_extpal_remap.sh
```

Build identity: `260907-B10GFXS2`. A successful build still requires its own
TV and gameplay test. Hardware results from the Engine B candidate do not
automatically validate this separately fitted bitstream.
