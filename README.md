# NDS4MiSTer

Experimental Nintendo DS support for the MiSTer FPGA platform.

This source snapshot corresponds to Public Touch Beta (2026-08-28). It adds
controller-driven touchscreen input to the LG C-series-compatible video path,
selectable screen layouts, melonDS-derived cartridge-save profiles, 512-byte
through 128 KiB EEPROM/FRAM support, and 256 KiB through 1 MiB Flash support.
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
