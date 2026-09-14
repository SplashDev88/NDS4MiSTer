# NDS4MiSTer

Experimental Nintendo DS support for the MiSTer FPGA platform.

**v0.3.0-beta.14 — Smoother FMV playback and TATE mode**

> **Read this first:** This is an early beta, not a finished core. Some games
> boot and play well; others slow down, glitch, fail to boot, or crash. Engine B
> defaults Off for speed. Turn it On and Reset or reload the ROM to display
> the second graphics engine; enabling it costs performance. Treat
> this release as something to experiment with, not as a reliable way to play
> your entire library.

No commercial ROMs, BIOS or firmware dumps, personal saves, compiled release
artifacts, or credentials are included in this source repository.

## What works today

- Some 2D and lighter 3D games boot and run.
- Smoother opening movies in Chrono Trigger and Castlevania, with occasional
  audio hitches still possible.
- Optional 90-degree counterclockwise TATE rotation for a sideways monitor.
- FPGA-generated sound with corrected DS sound-bias initialization.
- Persistent cartridge saves:
  - 512-byte tiny EEPROM.
  - 8 KiB, 64 KiB, and 128 KiB EEPROM/FRAM profiles.
  - 256 KiB, 512 KiB, and 1 MiB Flash profiles.
- Touch input using either the controller's right analog stick or a MiSTer
  mouse.
- Remappable keyboard controls through MiSTer's standard controller mapping,
  hardware-tested with beta.7.
- Four video layouts: Left/Right, Top/Bottom, Left Only, and Right Only.
- Selectable screen order, screen gap, and a changed-plane 3D FPS counter.
- Optional Engine B rendering, with an Off/On setting applied on Reset or ROM
  load. Off retains the fast single-screen path from beta.11.

## Current limitations

- **Movies and audio can still hitch occasionally.** Playback is smoother, but
  full-speed playback in every game remains work in progress.
- **TATE supports 90 CCW only.** The game picture and MiSTer menu rotate
  separately. Both-screen performance still depends on the game.
- **Engine B costs speed.** Off is the default and displays Engine A in both
  screen positions. On restores the second graphics engine using the ARM
  service, but games can slow down and the second screen can lag under load.
  Change **Engine B (next Reset)** in the core menu, then Reset or reload the
  ROM to apply it. Returning to Off restores the fast single-screen path.
- **Pokémon graphics using GX readback can remain missing.** The experimental
  correction is deferred because of slowdown; see issue #16 below.
- **Heavy 3D can stutter, fall behind, show minor blanking, or crash.** This is
  the most active area of development.
- **Cartridge-access latency remains a bottleneck.** Some objects or effects
  may appear late or fail to load.
- **Audio remains experimental.** The incorrect startup bias that caused the
  broadly overdriven output is fixed, but individual games may still expose
  unsupported or inaccurate sound behavior.
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
   `NDS4MiSTer_Public_Beta_v0.3.0-beta.14_20260914.zip` directly into the root
   of the MiSTer SD card (`/media/fat`). Allow it to merge the `_Console` and
   `Scripts` folders.
2. After every MiSTer reboot, go to **Scripts → NDS_Kickstart** and wait for
   the 3D service to start.
3. Within five minutes, go to **Console → NDS_20260914** and launch the core.
4. Open the core menu, choose **Load NDS**, and select your `.nds` file.

> **Run NDS_Kickstart once after every MiSTer reboot, before launching the
> core.** The DS 3D renderer is a helper program on the MiSTer's ARM/HPS. The
> launcher verifies that helper, requests the tested 1 GHz HPS clock, and
> starts exactly one non-persistent renderer process. Games will not run
> correctly if the helper is not running. Kickstart also watches for that one
> core launch and moves its replacement MiSTer frontend to CPU0; rerun
> Kickstart before a later NDS re-entry or if five minutes elapsed.

## TATE mode

For a portrait setup, turn your monitor clockwise. Select **Video Layout →
Top/Bottom**, then **Video Rotation → 90 CCW** in the core menu. Rotation
starts Off and can be changed without resetting the game. D-pad, right-stick
touch, and mouse controls keep their native DS directions for this physical
monitor orientation. Screen order and gap settings remain available.

Rotation applies to the game picture. The MiSTer menu rotates separately; if
needed, set `osd_rotate=2` under `[NDS]` in `MiSTer.ini` to rotate it
counterclockwise. The installer does not modify that file. Clockwise picture
rotation is not exposed by this release.

## Controller and keyboard mapping

Nintendo DS buttons can be mapped to keyboard keys through MiSTer's standard
controller-mapping menu. Keyboard control was verified on real MiSTer hardware
with beta.7.

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
movement. With Engine B Off, the pointer appears over both copies of Engine A.
With Engine B On, it follows the DS touchscreen through the selected layout
and screen order.

Touch input reaches the game in either mode. With Engine B Off, controls drawn
only by the second graphics engine are invisible, making precise taps difficult.

## Saves

Cartridge saves are stored in MiSTer's standard directory:

```text
/media/fat/saves/NDS/
```

This is battery-backed cartridge-save support, not emulator save states. Save
profiles are selected from the vendored melonDS ROM database. NAND save
cartridges and unknown save hardware are not supported.

Back up existing saves before upgrading or troubleshooting. Older experimental
builds could create incorrectly sized or corrupted files; this build does not
automatically repair them. Preserve the original save while checking the game
and save profile instead of replacing progress with an older backup.

## Reading the FPS counter

The overlay reports 3D publication activity; counters may include reused
planes. It does not establish distinct displayed frames, total emulation speed,
input latency, or 2D-engine performance. A displayed value of 60 is not proof of
full-speed gameplay. See [issue #11](https://github.com/SplashDev88/NDS4MiSTer/issues/11).

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

## What's new in beta.14

Smoother FMV playback and optional TATE rotation are the headline changes.
See the [release notes](docs/RELEASE_NOTES_BETA14.md) for installation and
known issues.

- Reduce redundant ARM9 instruction, load, and cached-write return cycles so
  movie decoding and audio-buffer production can make progress sooner.
- Join compatible adjacent LCDC reads and let sound refills interrupt long
  ARM7 DMA transfers at complete transfer-unit boundaries.
- Reuse unchanged Engine B lines and transfer completed snapshots without an
  extra full-image copy in the matched ARM helper.
- Add compact four-row TATE capture through the existing scaler DDR port,
  publishing only complete rotated frames. Normal capture is replaced while
  rotation is active. Off produces no additional rotation traffic.
- Retain the accepted VRAM storage optimization and use equivalent sound
  register readback to make room for TATE. Passive sound/display diagnostic
  payloads are omitted; session/fault handling, the PC heartbeat, and the
  on-screen FPS counter remain.

Earlier Chrono startup and sprite corrections, Kirby graphics, palette fades
and text colors, transparency, processor wake-up, touch, sound, cartridge saves,
and boot fixes remain. Engine B defaults Off; change it and Reset or reload
for both graphics engines. ARM continues to run at 1 GHz with no overclock.
No new gameplay speed percentage or universal 60 FPS claim is made.

The experimental GX readback correction remains deferred because of slowdown.
Pokemon player/furniture graphics can remain missing; see
[issue #16](https://github.com/SplashDev88/NDS4MiSTer/issues/16).

## Verification

| Item | Release identity |
| --- | --- |
| Core file | `_Console/NDS_20260914.rbf` |
| Build identity | `260914-TATE10` |
| FPGA SHA-256 | `4b6b623b129aebeb7ebf222305ec23cbc398b49fa3a62142355eacf04d9ffd3a` |
| Quartus seed | 2 |
| ARM clocks | 1 GHz |
| ARM SHA-256 | `826d5c95bab26d523c5327cb61384fd13abe540d43e3c91ba89630c12a98d937` |
| Kickstart SHA-256 | `4919b202a634c32babb45c4d65dc3421cdff434f61ddfdf804752ba0f3bf38cc` |

This package reuses the exact TATE10 candidate loaded for maintainer testing
and its matched ARM helper. Neither binary was rebuilt for packaging. The
maintainer reported substantially better movie playback on the retained WCR1
movie path, then requested TATE and release packaging. This does not establish
a full game, input, or display compatibility matrix for TATE10.

Focused verification covers CPU/cache returns and collision handling, LCDC
reads, sound refill/DMA ownership, Engine B line/snapshot ownership, VRAM
storage equivalence, sound register and complete sound-unit equivalence,
TATE pixel/color correctness, DDR stalls, complete-frame publication, and Off
pass-through. Final control-path tests preserve the heartbeat and session
policy with passive tracing disabled. Deliberate broken variants check that
key tests detect faults. Finite tests and portable memory/scaler simulation
assumptions do not establish universal hardware compatibility.

All 476 frozen FPGA input files match the compiled candidate. Production ARM
sources and build configuration match the tested helper build. Source/archive
hashes and installer contents are checked separately during packaging.

Map, fit, assembly, and timing analysis completed. Fit: 41,238 ALMs needed,
41,022 placed, 510 M10K blocks, 69 DSP blocks. Worst setup: -13.873 ns; worst
hold: -0.366 ns; worst recovery: -10.925 ns. Timing is not closed. Shared DDR
contention, physical routing, and demanding games still require broader
hardware testing. See SOURCE_PACKAGE.txt for source provenance and limits.

## For developers

<details>
<summary>Architecture</summary>

- The **FPGA** runs the ARM9 and ARM7 CPUs, system timing, DMA, cartridge,
  memory and VRAM mapping, Engine A 2D graphics, sound, saves, and MiSTer
  video/control paths.
- The **ARM/HPS service** replays ordered graphics events into melonDS's 3D
  engine and publishes completed 256×192 3D planes to the FPGA. When Engine B
  is enabled, it also renders Engine B from ordered register/VRAM snapshots and
  publishes paired 3D/Engine B planes.
- The FPGA composes the published 3D plane into Engine A using DS priority,
  window, blending, and brightness rules. The HPS service does not render a
  shadow copy of Engine A. Engine B Off avoids the second-engine rendering and
  snapshot transport work; Engine B On uses separate display storage.
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

Build the ARM hybrid-3D service with the isolated Docker build:

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

Built on the MiSTer framework, Nitro_DarkSide, melonDS, and FPGAzumSpass's GBA
ARM7 CPU implementation, which was used as the basis for the ARM9 work.
Component licenses and source notices remain in their vendored trees.

Special thanks to FPGAzumSpass, srg320, ElectronAsh, Corn, skmp, heni, and the
wider MiSTer community for technical advice, testing, and development guidance;
and to InsaneFriend (GitHub: saneFriend) for the writable SPI firmware, ARM7
Wi-Fi boot-memory, and cartridge-IR compatibility work in beta.7.

## License

NDS4MiSTer is distributed under GPLv3; see `LICENSE.txt`. Vendored components
retain their own licenses and attribution files.
