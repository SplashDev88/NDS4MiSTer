# NDS4MiSTer

Experimental Nintendo DS support for the MiSTer FPGA platform.

This source snapshot corresponds to Public Cumulative Beta v0.3.0-beta.4
(2026-08-30).
It combines controller- and mouse-driven touchscreen input with the LG
C-series-compatible video path, selectable screen layouts, melonDS-derived
cartridge-save profiles, 512-byte through 128 KiB EEPROM/FRAM support, 256 KiB
through 1 MiB Flash support, the 134.056 MHz console clock family, bounded
cartridge read-ahead, and the current ARM-assisted 3D performance path with
full-frame renderer-fence batching, adaptive dual-core raster balancing,
generation-safe catch-up visibility, stabilized raster-drop pacing, and
DreamSTer-style lock-free SPSC/futex synchronization. It also fixes first-load
save-sector alignment and preserves the verified cartridge/save epoch across
reset and direct-load transitions.
See `SOURCE_PACKAGE.txt` for the exact binary identities, hardware
verification, exclusions, and current limitations.

No commercial ROMs, BIOS binaries, personal saves, compiled FPGA images, or
credentials are included.

## Quick start

1. Unzip the release package to the root of your MiSTer SD card.
2. Go to **Scripts → NDS_Kickstart** and let the 3D service start.
3. Go to **Console → NDS_20260830** and launch the core.
4. Choose your `.nds` ROM from the core menu.

You must run **NDS_Kickstart** before launching the core after every MiSTer
reboot.

## Architecture

- The FPGA runs the Nintendo DS CPU, timing, cartridge, 2D, sound, save, and
  MiSTer video/control paths.
- The ARM/HPS service handles the current hybrid 3D-rendering path and
  publishes completed 3D data to the FPGA.
- The plane-only MiSTer renderer uses one complete-frame ownership fence and
  suppresses 192 unused per-scanline semaphore publications per changed frame.
  Pixels, frame order, and scanline-capable melonDS frontends remain unchanged.
- Heavy scenes use feedback-guided dual-core raster splitting. When replay
  falls behind, geometry that can no longer be displayed is discarded through
  the next real GX flush boundary so incomplete polygon buffers are never
  mixed into a visible frame.
- A generation-tagged visibility guard retains the last valid 3D plane when a
  catch-up discard produces an empty intermediate result. Mild load preserves
  complete geometry and skips only the raster pass; aggressive discard is
  reserved for a backlog that is actually growing. This removes recurring
  blank-frame flashes while keeping heavy NSMB scenes evenly paced.
- The ARM packet queue and renderer handoff use cache-separated single-
  producer/single-consumer indices with private Linux futexes. Normal queued
  work avoids mutex and kernel transitions without skipping packets, commands,
  frames, or polygons.
- The release sound implementation is the GPL-licensed Nitro_DarkSide engine
  in `third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd`. The release wrapper
  builds it with `SOUND_ENABLE=1`.
- PSX-core-derived space work shares the ARM7 shifter datapath, compresses the
  exact cartridge-save lookup tables, packs sound fetch state, and packs ARM9
  cache-tag storage. Each retained change has a focused equivalence test.
- Retired private FPGA-sound experiments are not included and are not release
  dependencies.

## Building and testing

The release FPGA project is:

```text
fpga/mister_nitro_console_island/NDS4MiSTer.qpf
```

It was built and fitted with Quartus Prime 17.0.2. Generated Quartus databases,
RBF/SOF files, and other build outputs are intentionally excluded from this
source archive.

Run the production console-island host regression with:

```sh
./tools/test_nitro_console_island_host.sh
```

Build the MiSTer ARM hybrid-3D service with the provided isolated Docker build:

```sh
./tools/build_hybrid_3d_service_armhf.sh
```

The produced ARM binary must pass its built-in self-test before deployment.
The installable beta, launcher script, compiled RBF, ARM payload, and hashes are
distributed separately as the public binary package.

## Touch controls

You can control the DS stylus with either input:

- Move the controller's right analog stick to position it, then hold the
  remappable `Touch` action to press the screen.
- Move a MiSTer mouse to position it, then hold the left mouse button to press
  the screen.

The most recently moved input takes control. The pointer is white while
hovering and red while pressed. It remains visible while pressed and lingers
for about half a second after movement. Because both current video positions
show Engine A, the pointer is drawn over every visible screen copy, including
the left copy in the side-by-side layout.

The right stick uses absolute positioning: centered is approximately the
center of the 256x192 touchscreen, and the stick edges select the screen edges.
Mouse movement is relative and saturates at the screen edges. Engine B is not
displayed yet, so games that require precise selection of visible touchscreen
controls remain difficult even though touch input is delivered to the game.

## Current limitations

- Engine B is not enabled; both displayed positions currently show Engine A.
- Heavy 3D scenes can slow down, fall behind, or crash.
- Cartridge-access latency can make objects or effects appear late or fail.
- Reset now preserves the cartridge and save mount used by the running game.
  Reselecting the ROM remains the fallback for titles that do not reset cleanly.
- Touchscreen input supports the controller's right stick plus remappable
  `Touch` action, or relative mouse movement plus the left mouse button.
  Because Engine B is not displayed yet, games that require precise
  interaction with touchscreen graphics remain limited.
- Chrono Trigger has a separate boot failure under investigation.
- NAND saves, save states, Wi-Fi, and microphone support are not implemented.

If a game still reports corrupted save data after upgrading, first back up and
then delete or move that game's existing `.sav` file from
`/media/fat/saves/NDS/`. Older experimental builds may have created an
incorrectly sized or already-corrupted file; this core will not attempt to
repair corrupted legacy data and the game must create a fresh save.

## Issues and bug reports

Use the [GitHub Issues](https://github.com/SplashDev88/NDS4MiSTer/issues) page
for reproducible bugs and tracked development work. Include the beta name,
FPGA-core and HPS-service SHA-256 values, game title/region/revision, exact
reproduction steps, and any generated NDS4MiSTer crash report.

Never upload or link to commercial ROMs, BIOS/firmware dumps, personal save
files, credentials, or other private data. A ROM filename and its game-code or
revision are sufficient for identification.

## Repository layout

- `fpga/mister_nitro_console_island`: production MiSTer Quartus project.
- `rtl`: FPGA integration, video, 3D transport, cartridge-save, and test RTL.
- `src`: ARM/HPS services, melonDS integration, and host utilities.
- `third_party/Nitro_DarkSide`: vendored GPL Nintendo DS FPGA source.
- `third_party/melonDS`: vendored melonDS source and license.
- `tools`: focused build, test, generation, and service-control scripts.
- `docs`: current architecture, ABI, lifecycle, boot, and publishing contracts.

Public contributions and maintainer pushes must follow
[`docs/PUBLIC_PUBLISHING.md`](docs/PUBLIC_PUBLISHING.md). The repository's
versioned audit rejects commercial ROMs, saves, release binaries, credentials,
personal paths, unsafe commit identities, and other private artifacts before
they can be published.

## Credits and special thanks

This work builds on the MiSTer framework, Nitro_DarkSide, melonDS, and
FPGAzumSpass's GBA ARM7 CPU implementation, which was used as the basis for the
ARM9 work. Component licenses and source notices remain in their respective
vendored trees.

Special thanks to FPGAzumSpass, srg320, ElectronAsh, Corn, skmp, and heni for
technical advice, testing, and development guidance.

## License

NDS4MiSTer is distributed under GPLv3; see `LICENSE.txt`. Vendored components
retain their own license and attribution files.
