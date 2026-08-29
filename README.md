# NDS4MiSTer

Experimental Nintendo DS support for the MiSTer FPGA platform.

This source snapshot corresponds to the Public Cumulative Beta (2026-08-29).
It combines controller-driven touchscreen input with the LG
C-series-compatible video path, selectable screen layouts, melonDS-derived
cartridge-save profiles, 512-byte through 128 KiB EEPROM/FRAM support, 256 KiB
through 1 MiB Flash support, the 134.056 MHz console clock family, bounded
cartridge read-ahead, and the current ARM-assisted 3D performance path.
See `SOURCE_PACKAGE.txt` for the exact binary identities, hardware
verification, exclusions, and current limitations.

No commercial ROMs, BIOS binaries, personal saves, compiled FPGA images, or
credentials are included.

## Architecture

- The FPGA runs the Nintendo DS CPU, timing, cartridge, 2D, sound, save, and
  MiSTer video/control paths.
- The ARM/HPS service handles the current hybrid 3D-rendering path and
  publishes completed 3D data to the FPGA.
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

1. Move the controller's right analog stick to position the DS stylus.
2. Hold the remappable `Touch` action to press the screen at that position.
3. Release `Touch` to lift the stylus.
4. If `Touch` is not on a convenient button, assign it through MiSTer's normal
   controller-remapping menu.

The right stick uses absolute positioning: centered is approximately the
center of the 256x192 touchscreen, and the stick edges select the screen
edges. Engine B is not displayed yet, so games that require precise selection
of visible touchscreen controls remain difficult even though touch input is
delivered to the game.

## Current limitations

- Engine B is not enabled; both displayed positions currently show Engine A.
- Heavy 3D scenes can slow down, fall behind, or crash.
- Cartridge-access latency can make objects or effects appear late or fail.
- The Reset menu command currently hangs; reselecting the ROM is the restart
  workaround.
- Basic touchscreen input uses the controller's right stick for absolute
  position and the remappable `Touch` action for pen-down. Because Engine B is
  not displayed yet, games that require precise interaction with touchscreen
  graphics remain limited.
- Chrono Trigger has a separate boot failure under investigation.
- NAND saves, save states, Wi-Fi, and microphone support are not implemented.

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
