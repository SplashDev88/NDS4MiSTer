# NDS4MiSTer

Experimental Nintendo DS support for the MiSTer FPGA platform.

**v0.4.0-beta.6 — Final Fantasy Tactics A2 and Pokemon Platinum graphics fixes**

The latest beta restores missing graphics in Final Fantasy Tactics A2 and
Pokemon Platinum, with faster ARM rendering and a fix for disconnected Wi-Fi
retries that caused a Lunar Knights movie crash. Earlier game fixes remain.

> **Engine B must be On.** Change it in the core menu, then reset or reload
> your ROM. Older Off settings can produce a blank display. Use this release's
> core, helper and launcher together.

No commercial ROMs, BIOS or firmware dumps, personal saves, compiled release
artifacts, or credentials are included in this source repository.

## What works today

- Faster ARM-to-FPGA pixel transfers through the included WC driver on compatible
  kernels, with automatic Device-memory fallback.

- Some 2D and lighter 3D games boot and run.
- Smoother opening movies in Chrono Trigger and Castlevania, with occasional
  audio hitches still possible.
- Optional 90-degree clockwise or counterclockwise TATE rotation for a
  sideways monitor.
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
- Both screens composed together by the MATCH4 renderer. Engine B On is required.

## Current limitations

- **Strange Journey can still freeze during its intro.** WC does not fix it.
- **WC was tested on MiSTer Linux 5.15.1.** Other kernel builds may reject the
  optional module and use the previous transfer path without the WC gain.

- **Movies and audio can still hitch occasionally.** Playback is smoother, but
  full-speed playback in every game remains work in progress.
- **TATE supports 90 CW and 90 CCW, but not 180 degrees.** The game picture
  and MiSTer menu rotate separately. Both-screen performance depends on the game.
- **Other graphical regressions remain.** Castlevania and Metroid fixes passed
  focused testing; other games and scenes can still expose rendering problems.
- **Engine B must stay On.** Off remains in the menu but is unsupported by this
  build. Set On, then Reset or reload the ROM. The installer preserves your
  configuration, so an older saved Off setting must be changed manually.
- **Pokemon Platinum character and room furniture passed testing.** SoulSilver
  has not been verified with this build; other scenes may still expose problems.
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
   `NDS4MiSTer_Public_Beta_v0.4.0-beta.6_20260924.zip` directly into the root
   of the MiSTer SD card (`/media/fat`). Allow it to merge the `_Console` and
   `Scripts` folders.
2. After every MiSTer reboot, go to **Scripts → NDS_Kickstart** and wait for
   the 3D service to start.
3. Within five minutes, go to **Console → NDS_20260924** and launch the core.
4. Set **Engine B (next Reset) → On**, then choose **Load NDS** and your `.nds`
   file. If already loaded, Reset or reload after changing Engine B.

> **Run NDS_Kickstart once after every MiSTer reboot, before launching the
> core.** The DS 3D renderer is a helper program on the MiSTer's ARM/HPS. The
> launcher verifies that helper, requests the tested 1 GHz HPS clock, and
> starts exactly one non-persistent renderer process. Games will not run
> correctly if the helper is not running. Kickstart also watches for that one
> core launch and moves its replacement MiSTer frontend to CPU0; rerun
> Kickstart before a later NDS re-entry or if five minutes elapsed.

## TATE mode

Select **Video Layout → Top/Bottom** to stack the DS screens. Choose the
picture rotation opposite to your monitor's physical turn:

| Monitor physically turns | Video Rotation |
| --- | --- |
| Clockwise / right | **90 CCW** |
| Counterclockwise / left | **90 CW** |

Rotation starts Off and can be changed without resetting the game. Existing
saved Off and 90 CCW settings retain their meaning. D-pad, right-stick touch,
and mouse controls keep their native DS directions for the physically turned
monitor. Screen order and gap settings remain available.

The MiSTer menu rotates separately. Put `osd_rotate=1` or `osd_rotate=2`
under `[NDS]` in `MiSTer.ini` to match your setup, then save and reboot. If the
menu is upside down, switch between 1 and 2. If an `[NDS]` section already
exists, update it. This affects NDS only; the installer does not edit your INI.
See the [MiSTer INI documentation](https://mister-devel.github.io/MkDocs_MiSTer/advanced/ini/#menu-settings).

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
movement. With Engine B On, it follows the DS touchscreen through the selected
layout and screen order. Engine B Off is unsupported in this build.

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

## What's new in v0.4.0-beta.6

- Final Fantasy Tactics A2 startup/menu graphics restored.
- Pokemon Platinum character and room furniture restored in testing.
- Faster ARM rendering, retaining the recovered graphics and stock 1 GHz clock.
- Disconnected Wi-Fi retries stopped at Kickstart to avoid the observed
  Lunar Knights movie crash. Connected Wi-Fi and saved settings are preserved.

See the [release notes](docs/RELEASE_NOTES_V040_BETA6.md) and
[technical source notes](SOURCE_PACKAGE.txt).

## Retained from v0.4.0-beta

The smoother movie playback and other work from v0.4.0-beta are retained:

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
and boot fixes remain in the source. New graphical regressions are listed
above. Engine B On is required. ARM runs at stock 1 GHz with no overclock.
No new gameplay speed percentage or universal 60 FPS claim is made.

The new ordered matrix and visibility readback restores the tested Pokemon
Platinum player and room furniture. SoulSilver and other scenes still need
validation; see
[issue #16](https://github.com/SplashDev88/NDS4MiSTer/issues/16).

## Verification

The installer contains the exact user-tested PBOX1 FPGA and C22 ARM helper.
Source, binary identities, test coverage and timing limits are in
[SOURCE_PACKAGE.txt](SOURCE_PACKAGE.txt). Source and installer each include
checksums. No runtime binary was rebuilt for packaging. ARM self-tests, exact
pixel comparisons, focused FPGA tests and hardware gameplay checks passed.
These are focused checks, not a guarantee of 60 FPS or all-game accuracy.

## For developers

<details>
<summary>Architecture</summary>

- The **FPGA** runs ARM9/ARM7, timing, DMA, cartridge, memory/VRAM, sound,
  saves, input and MiSTer video output, and transports ordered graphics events.
- The **ARM/HPS service** composes Engine A, Engine B and 3D into complete pairs.
  The FPGA adopts acknowledged complete banks; native FPGA pixel writes are
  disabled in the matched configuration.
- Weighted dual-core raster bands, packed background rows and Engine B
  composition caching reduce rendering work. Full-rate drawing has no mandatory
  alternate-frame skip; backlog admission can still omit obsolete pictures.
- All architectural records replay. Frame-bank ownership, separate WC pixel
  mappings, session checks and reset quiescence remain enforced.
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

Build the optional WC driver using the pinned kernel/configuration and
instructions in [kernel/nds_mem_wc](kernel/nds_mem_wc/README.md). Its separate
GPL-2.0 license and source accompany the release.

Run the full built-in self-test on the host or under ARM emulation. On the
physical MiSTer, use only the focused `--self-test-matched-full-rate` in MENU;
do not run the aggregate native self-test.
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
| `kernel/nds_mem_wc` | Restricted WC module source, license, configuration and build recipe |

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

NDS4MiSTer is distributed under GPLv3; see `LICENSE.txt`. The separate WC
kernel module is GPL-2.0; see `kernel/nds_mem_wc/COPYING`. Vendored components
retain their own licenses and attribution files.
