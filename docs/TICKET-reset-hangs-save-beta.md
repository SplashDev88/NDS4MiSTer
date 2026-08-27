# Reset command hangs after save support

## Status

Backlog. User-reported on the known-good save beta on 2026-08-27. Keep this
separate from ROM loading and save-format support until a trace proves a common
cause.

## Symptom

- A game boots and runs normally when selected from the MiSTer menu.
- Selecting the core's `Reset` command hangs instead of restarting the game.
- Selecting the same ROM again from the MiSTer menu boots it normally.

The currently confirmed reproduction is New Super Mario Bros. running on
`NDS_Save_Beta_20260827.rbf` (SHA-256
`2b135f8fba9168af99108c90781b878fc0901768bd1fbb83384ba85b904cc759`).

## First diagnostic gate

Reproduce reset and menu-ROM reload from the same running state. Capture and
compare the save bridge state, mounted-image state, download/reset pulses,
ARM9 and ARM7 PCs, DMA state, and FPGA/HPS service handshake from the first
divergent cycle. Confirm whether reset incorrectly preserves a pending save
transaction or loses the mounted save image.

Also repeat against the FRAM/Flash CDC-fix beta so the regression can be tied
to a specific save-support revision rather than assumed from one build.

## Acceptance

- The core `Reset` command reliably reboots the selected ROM.
- Existing save data remains mounted and intact across reset.
- Reloading a ROM from the menu continues to work.
- EEPROM, FRAM, and Flash save initialization and persistence do not regress.
