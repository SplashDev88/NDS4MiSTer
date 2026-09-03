# NDS4MiSTer

Experimental Nintendo DS support for the MiSTer FPGA platform.

**Unreleased HPS Engine B development branch, based on Public Beta
v0.3.0-beta.6 (2026-08-31)**

> **Read this first:** This is an early beta, not a finished core. Some games
> boot and play well; others slow down, glitch, fail to boot, or crash. This
> branch reconstructs Engine B on the HPS and restores independent physical
> top and bottom screen paths. Host regressions cover the path, but it still
> needs a new Quartus build and real-hardware acceptance. Treat it as something
> to develop and test, not as a reliable way to play your entire library.

No commercial ROMs, BIOS or firmware dumps, personal saves, compiled release
artifacts, or credentials are included in this source repository.

## What works today

- Some 2D and lighter 3D games boot and run.
- FPGA-generated sound.
- Experimental HPS-rendered Engine B with independent physical top and bottom
  screen publication.
- Persistent cartridge saves:
  - 512-byte tiny EEPROM.
  - 8 KiB, 64 KiB, and 128 KiB EEPROM/FRAM profiles.
  - 256 KiB, 512 KiB, and 1 MiB Flash profiles.
- Touch input using either the controller's right analog stick or a MiSTer
  mouse.
- Four video layouts: Left/Right, Top/Bottom, Left Only, and Right Only.
- Selectable screen order, screen gap, and a changed-plane 3D FPS counter.

## Current limitations

- **The HPS Engine B path is experimental.** It mirrors ordered GPU registers,
  palette, OAM, VRAM, and LCD phases into melonDS, then publishes Engine B as
  the physical screen selected by the DS power-control swap. Host tests pass;
  hardware stability, performance, and game coverage are not yet established.
- **Dual-screen 3D display capture remains research work.** A focused oracle
  covers the capture modes and screen swap, but production still needs live
  register/VRAM traces and hardware acceptance before this is claimed fixed.
- **Heavy 3D can stutter, fall behind, show minor blanking, or crash.** This is
  the most active area of development.
- **Cartridge-access latency remains a bottleneck.** Some objects or effects
  may appear late or fail to load.
- **Not implemented:** NAND saves, save states, Wi-Fi, and microphone support.
- **Reset is improved, but not universal.** It preserves the current cartridge
  and save mount. If a game does not reset cleanly, reselect its ROM from the
  core menu.
- The first public compatibility target is *New Super Mario Bros.* Broad game
  compatibility is not yet claimed.

## Getting started

You supply your own legally obtained `.nds` files. No games, commercial BIOS
or firmware files, or saves are included, and none should be posted to this
repository.

1. Extract
   `NDS4MiSTer_Public_Beta_v0.3.0-beta.6_20260831.zip` directly into the root
   of the MiSTer SD card (`/media/fat`). Allow it to merge the `_Console` and
   `Scripts` folders.
2. After every MiSTer reboot, go to **Scripts → NDS_Kickstart** and wait for
   the 3D service to start.
3. Go to **Console → NDS_20260831** and launch the core.
4. Open the core menu, choose **Load NDS**, and select your `.nds` file.

These steps install the published beta.6 release. This development branch is
not packaged as a release; developers must build its FPGA and HPS artifacts.

> **Run NDS_Kickstart once after every MiSTer reboot, before launching the
> core.** The DS 3D renderer is a helper program on the MiSTer's ARM/HPS. The
> launcher verifies that helper, requests the tested 1 GHz HPS clock, and
> starts exactly one non-persistent renderer process. Games will not run
> correctly if the helper is not running.

## Touch controls

The most recently active touch input takes control.

### Right analog stick

The right stick uses absolute positioning. Centering it selects approximately
the middle of the 256×192 touchscreen; moving it to an edge selects that edge.
Hold the remappable `Touch` action to press the stylus and release it to lift
the stylus.

### Mouse

Mouse movement is relative, like a desktop cursor, and stops at the touchscreen
edges. Hold the left mouse button to press the stylus.

The on-screen pointer is **white while hovering** and **red while pressed**. It
remains visible while pressed and lingers for about half a second after
movement. The pointer is drawn only over the physical bottom touchscreen; it
follows that screen through screen-order and single-screen layout changes.

## Saves

Cartridge saves are stored in MiSTer's standard directory:

```text
/media/fat/saves/NDS/
```

This is battery-backed cartridge-save support, not emulator save states. Save
profiles are selected from the vendored melonDS ROM database. NAND save
cartridges and unknown save hardware are not supported.

> **If a game reports corrupted save data after an upgrade:** Back up its
> `.sav` file, then delete or move that file out of `/media/fat/saves/NDS/` and
> let the game create a fresh save. Older experimental builds sometimes
> created incorrectly sized or already-corrupted saves; beta.6 does not try to
> repair them.

## Reading the FPS counter

The optional overlay counts changed 3D planes accepted by the FPGA for
display. It does **not** report total emulation speed, HDMI refresh rate,
ARM9/ARM7 speed, or 2D-engine performance. A displayed value of 60 does not by
itself prove that every part of a game is running at full speed.

## Reporting bugs

Use [GitHub Issues](https://github.com/SplashDev88/NDS4MiSTer/issues). A useful
report includes:

- The beta version.
- The SHA-256 values of the FPGA core and ARM/HPS service.
- The game title, region, and revision.
- Exact steps to reproduce the problem.
- Any NDS4MiSTer crash report that was generated.

Never upload or link to commercial ROMs, BIOS or firmware dumps, personal save
files, credentials, or other private data. A ROM filename plus its game code or
revision is enough to identify it.

## What's new in beta.6

Beta.6 focuses on 3D performance, pacing, and FPGA space use while retaining
the saves, reset behavior, touch preview, sound, layouts, and 134 MHz clock
family from beta.5.

- Batches exact perspective texture-coordinate work four pixels at a time.
- Uses a bit-exact Cortex-A9 NEON path for the dominant GX vertex transform.
- Fast-paths COLOR and NORMAL GX commands without bypassing lighting, normal
  matrix, or fixed-point behavior.
- Replaces exact FPGA divide-by-16 and divide-by-32 blend operations with fixed
  shifts, saving 87 ALMs and 26 registers.
- Counts changed 3D planes in the FPS overlay instead of identical plane
  republications.
- Retains direct completed-plane publication, feedback-guided dual-core raster
  splitting, bounded catch-up, and lock-free SPSC/futex handoffs from the
  preceding performance work.
- Fixes first-load save-sector alignment and preserves the verified
  cartridge/save pairing across reset and direct-load transitions.

Focused measurements found about 3.6% lower GX processing cost and 5.6% lower
geometry-flush cost across the retained ARM changes. The conservative summary
is about 5% lower ARM 3D processing cost than beta.5; this is not a whole-game
FPS claim, and visible results remain scene-dependent.

## For developers

<details>
<summary>Architecture</summary>

- The **FPGA** runs the ARM9 and ARM7 CPUs, system timing, DMA, cartridge,
  memory and VRAM mapping, Engine A 2D graphics, sound, saves, and MiSTer
  video/control paths.
- The **ARM/HPS service** replays ordered graphics events into melonDS's 3D
  engine and GPU2D-B. It publishes completed 256×192 3D planes plus the missing
  Engine B physical screen; it does not shadow FPGA Engine A.
- The FPGA composes the published 3D plane into Engine A using DS priority,
  window, blending, and brightness rules, then pairs that output atomically
  with the HPS Engine B screen for scanout.
- The plane-only renderer uses one complete-frame ownership fence, avoiding
  192 unused per-scanline semaphore publications per changed frame without
  changing scanline-capable melonDS frontends.
- Heavy scenes use feedback-guided dual-core raster splitting. If replay falls
  behind, work that can no longer be displayed is discarded only through a
  real GX flush boundary so incomplete polygon buffers are not published.
- A generation-tagged visibility guard keeps the last valid 3D plane when
  catch-up produces an empty intermediate result. Mild load skips only an
  obsolete raster pass; aggressive discard is reserved for a growing backlog.
- Packet and renderer handoffs use cache-separated SPSC indices with private
  Linux futexes, avoiding mutex and kernel transitions on the normal queued
  path.
- Completed immutable ARM planes publish directly, avoiding an extra
  full-frame copy. The four-band raster path admits shadow work only after its
  ordering dependency is satisfied.
- Sound is the GPL-licensed Nitro_DarkSide engine at
  `third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd`, built by the release
  wrapper with `SOUND_ENABLE=1`.
- PSX-core-derived space savings share the ARM7 shifter datapath, compress the
  cartridge-save lookup tables, and pack sound-fetch state and ARM9 cache tags.
  Each retained change has a focused equivalence test.
- Retired private FPGA-sound experiments are excluded and are not release
  dependencies.

</details>

<details>
<summary>Building and testing</summary>

The release FPGA project is built and fitted with Quartus Prime 17.0.2:

```text
fpga/mister_nitro_console_island/NDS4MiSTer.qpf
```

Generated Quartus databases, RBF/SOF files, and other build outputs are
intentionally excluded from the source repository.

Run the production console-island host regression:

```sh
./tools/test_nitro_console_island_host.sh
```

Build the ARM hybrid-3D/Engine-B service with the isolated Docker build:

```sh
./tools/build_hybrid_3d_service_armhf.sh
```

The resulting ARM binary must pass its built-in self-test before deployment.
The installable ZIP, launcher, compiled RBF, ARM payload, and hashes are
distributed separately on the GitHub Releases page.

</details>

<details>
<summary>Repository layout</summary>

| Path | Contents |
| --- | --- |
| `fpga/mister_nitro_console_island` | Production MiSTer Quartus project |
| `rtl` | FPGA integration, video, 3D transport, cartridge-save, and test RTL |
| `src` | ARM/HPS services, melonDS integration, and host utilities |
| `third_party/Nitro_DarkSide` | Vendored GPL Nintendo DS FPGA source |
| `third_party/melonDS` | Vendored melonDS source and license |
| `tools` | Build, test, generation, and service-control scripts |
| `docs` | Architecture, ABI, lifecycle, boot, and publishing contracts |

Contributions and maintainer pushes must follow
[`docs/PUBLIC_PUBLISHING.md`](docs/PUBLIC_PUBLISHING.md). The versioned audit
rejects commercial ROMs, saves, release binaries, credentials, personal paths,
unsafe commit identities, and other private artifacts before publication.

</details>

## Credits

Built on the MiSTer framework, Nitro_DarkSide, melonDS, and Robert Peip's
(FPGAzumSpass) GBA ARM7 CPU implementation, which was used as the basis for the
ARM9 work.
Component licenses and source notices remain in their vendored trees.

The original Nitro_DarkSide work by Heni includes the ARM9 CPU, FPGA 2D
engines, memory/VRAM fabric, DMA, and system integration. SplashDev88's later
NDS4MiSTer work includes the ARM-assisted 3D renderer and its integration,
performance, packaging, and public release line. The histories are joined at
the repository's provenance graft; see [`PROVENANCE.md`](PROVENANCE.md).

Special thanks to FPGAzumSpass, srg320, ElectronAsh, Corn, skmp, heni, and the
wider MiSTer community for technical advice, testing, and development guidance;
and to InsaneFriend (GitHub: saneFriend) for the writable SPI firmware fix.

## License

NDS4MiSTer is distributed under GPLv3; see `LICENSE`. Vendored components
retain their own licenses and attribution files. The history of the root
license files from both parent projects remains available through Git.
