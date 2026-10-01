# NDS4MiSTer

Experimental Nintendo DS support for MiSTer FPGA.

**v0.6.0-beta — standalone launch, a familiar menu, and improved pacing.**

> Release documentation draft; publication is pending approval.

NDS4MiSTer now launches through **Scripts → NDS Standalone**. A lightweight
NDS frontend handles menus, input, loading and saves while you play, allowing
the ARM processors to spend more time on the Nintendo DS workload. The normal
MiSTer program initializes output before standalone takes over and returns
when you exit.

Standalone is the direction of future development. The installer preserves
your existing normal NDS core, launcher and settings. Your ROM and cartridge
save folders stay the same.

This remains a beta. Not every game runs at full speed, and graphics, audio
and compatibility issues remain. No commercial ROMs, BIOS/firmware dumps,
personal saves or credentials are included in this source repository.

## Install and play

1. Back up the SD card's `saves/NDS` folder.
2. Extract the release install ZIP to the SD card root, merging **Scripts**.
   Include the hidden `Scripts/.NDS_Standalone` support folder.
3. Run **Scripts → NDS Standalone** and wait for the NDS menu.
4. Choose **Load NDS** and a game from `games/NDS`. Fresh installations start
   with both screens On in Top/Bottom layout. Older saved settings take
   priority; check **Engine B (next Reset) → On** for independent screens.
5. Use **System → Save settings** to keep your options.

There is **no separate Kickstart step or five-minute window** for standalone.
Run its script each time you want to launch this release. It contains its own
matching FPGA core and ARM helper; do not mix support files between versions.
The normal MiSTer installation is still required, but installing an older NDS
release first is not required.

ROMs must be uncompressed `.nds` files up to **128 MiB**. After you select a ROM,
delayed network/CIFS reads no longer block the loader's heartbeat and trigger
the 20-second recovery watchdog. Loading stops after **120 seconds without
file progress**, not after 120 seconds of total loading time. The recovery
watchdog itself is unchanged. Network folder browsing and Recent Files checks
can still stall; local SD loading avoids those network delays.

The launcher requires **Python 3.8+**, a kernel compatible with the included
write-combining module, and working **1 GHz** clock control. Hardware testing
used Linux **5.15.1-MiSTer**. Unlike the older normal launcher, this standalone
requires a working write-combining mapping; it will not silently run without
it. It does not install a kernel or change `MiSTer.ini`.

See [release notes](docs/RELEASE_NOTES_V060_BETA.md) and the bundled
[quick start](docs/STANDALONE_QUICK_START.txt) for setup and troubleshooting.

## The standalone menu

Open the menu with F12, the board OSD button, or the configured controller menu
combination. Select + Start and Guide provide fallbacks. **Opening the menu
does not pause the game.** Press Right from the core page for System and Left
to return. A/Enter selects; B/Escape goes back.

- **Define NDS buttons** creates a standalone controller map while preserving
  normal MiSTer maps. Mouse and right-stick touch input remain available.
- **Cycle Video Layout**, the final mapping prompt, can assign a spare button
  to switch between Left/Right, Top/Bottom, Left Only and Right Only while playing.
- **Recent Files** shares the normal NDS history. Press controller Select or
  keyboard backtick at Load NDS or in the ROM picker.
- **Save settings** stores standalone's own options. Existing normal NDS
  settings are read when no private settings exist. With no saved settings,
  Engine B starts On in Top/Bottom layout; rotation and the FPS counter are Off.
- **System → Reboot** closes standalone and returns to normal MiSTer's menu;
  it is not a power cycle. The old normal NDS release continues to use its own
  Kickstart and Console launch steps.

Greyed-out System rows are not implemented. Video/audio filters, advanced
button remapping, player assignment and conditional OSD locking are among the
unavailable actions. Use normal MiSTer for global changes and Bluetooth pairing.
The familiar layout is not a promise of every MiSTer system feature.

## Screens, TATE and saves

**Engine B On** draws both DS screens separately and is recommended for normal
play. **Off** skips the second engine and mirrors the first screen. It may
improve performance in some scenes, but hides second-screen content. Reset or
reload the game after changing it.

TATE supports **90 CW** and **90 CCW**. Choose **Top/Bottom**, then rotate the
picture opposite to the monitor's physical turn. D-pad, mouse and touch follow
the rotated display. The menu rotates separately through `MiSTer.ini`.

For a 1080p-capable portrait display, this optional setup gave small borders
and about 95% portrait width in the tested layout:

```ini
[NDS]
video_mode=8
osd_rotate=2
```

Use `osd_rotate=1` if the menu is upside down. Edit the existing `[NDS]` section
if present, then return to normal MiSTer and relaunch standalone. The installer
does not edit the INI. These NDS overrides also affect an older normal NDS core.
Scaling uses whole pixels; border size depends on layout and screen gap.

Cartridge saves are shared by normal NDS and standalone in:

```text
/media/fat/saves/NDS/
```

Keep the same ROM filename to keep using its matching `.sav`. This is in-game
cartridge saving, not save states. Back up saves before upgrading. Standalone
does not repair older corrupt saves or replace progress with archived test saves.

## Compatibility and performance

The accepted build retains prior graphics and compatibility fixes and the
Super Mario 64 DS fix for first-course graphics collapsing into one line.
It reduces repeated drawing work and includes game-specific pacing choices.
Both ARM cores remain at **1 GHz**, with no 1.2 GHz overclock.

The tested **USA revision 0** of New Super Mario Bros. uses alternate drawing
updates to reduce work; game state and graphics commands still advance. Other
regions/revisions may behave differently. This is not a global FPS cap or a
user-selectable frame-skip setting. The **3D FPS Counter** reports publication
activity, including reused planes; it does not establish unique animation
frames, emulation speed or input latency.

Known limitations include:

- Slowdown, surging, uneven animation, and movie/audio hitches. No universal
  60 FPS or percentage speedup is claimed.
- Strange Journey can still freeze during its intro.
- GTA: Chinatown Wars can still show occasional near-camera clipping.
- Network folder browsing and Recent Files availability checks can still block
  the menu and trigger recovery to normal MiSTer. The loading fix covers reads
  after selecting a ROM; it does not cover every operation on a network share.
- The recent Jackass, King Kong and Need for Speed Carbon fixes are not in this
  accepted build.
- Incomplete controller, alternate-INI and display-hotplug coverage.
- Experimental sound and incomplete game compatibility. NAND cartridge saves,
  save states, DS wireless multiplayer and microphone input are not implemented.

The launcher stops disconnected host Wi-Fi retries for the current boot to
avoid stalls. Saved network settings and an active connection are preserved;
normal Wi-Fi startup returns after reboot. This does not implement DS wireless.

## Reporting bugs

Use [GitHub Issues](https://github.com/SplashDev88/NDS4MiSTer/issues). Include
the release version, game title/region/revision, scene and steps to reproduce,
Engine B setting, SD versus network ROM loading, controller and kernel version.
Include the exact launch error or relevant generated log if available. Check
logs for personal paths or network details before sharing.

Do not post commercial ROMs, BIOS/firmware dumps, personal saves or credentials.
A game code/revision and a description of the scene are enough to identify it.

## For developers

### Architecture

- The **FPGA** runs DS ARM9/ARM7 execution, timing, DMA, cartridge/memory/VRAM
  paths, sound, save/input interfaces and MiSTer video output. It transports
  ordered graphics events to the HPS.
- The **ARM/HPS helper** replays graphics work and composes Engine A, optional
  Engine B and 3D into complete screen pairs. The FPGA adopts completed banks.
  Write-combining is restricted to pixel-publication mappings; ownership,
  session checks and reset quiescence remain enforced.
- The **standalone host** owns menu/input/ROM/save SPI after normal MiSTer
  exits. A separate supervisor and recovery guard manage the handoff. They
  prevent simultaneous frontend ownership and restore normal MiSTer after a
  handled exit/failure; a kernel or FPGA hang may still require reboot.
- Dual-core raster work, cached drawing and unchanged-3D reuse reduce repeated
  work. Per-game query/cadence choices are in `src/replay/GameQueryProfile.h`
  and `Hybrid3DService.cpp`. They are not all global rendering defaults.
- Sound uses the GPL Nitro_DarkSide engine in
  `third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd`, with `SOUND_ENABLE=1`.

### Source and builds

The release tag must contain the source matching every shipped component.
See [SOURCE_PACKAGE.txt](SOURCE_PACKAGE.txt) for exact source revisions,
binary identities, validation and timing limits. Focused tests and user
acceptance do not establish full playthrough coverage or FPGA timing closure.

The Quartus Prime 17.0.2 project is:

```text
fpga/mister_nitro_console_island/NDS4MiSTer.qpf
```

Build/test entry points:

```sh
./tools/test_nitro_console_island_host.sh
./tools/build_hybrid_3d_service_armhf.sh
./tools/standalone_host/build.sh
```

See [standalone frontend source](tools/standalone_host/README.md) for menu,
input and recovery tests, and [WC module instructions](kernel/nds_mem_wc/README.md)
for the pinned kernel/configuration and GPL-2.0 module source. Do not force-load
a module built for a different kernel. Run aggregate helper self-tests on a
host or under ARM emulation, not inside an active hardware game session.

Compiled release files, Quartus databases and private test evidence are not
source dependencies. The install ZIP and checksum are distributed on GitHub
Releases; matching source uses GitHub's automatic source archives without a
duplicate source ZIP asset.

| Path | Contents |
| --- | --- |
| `fpga/mister_nitro_console_island` | MiSTer Quartus project |
| `rtl` | FPGA integration, video, transport, save and test RTL |
| `src` | ARM/HPS services and melonDS integration |
| `tools/standalone_host` | Native menu/input/loader, supervisor and tests |
| `tools` | Build, test, generation and service-control scripts |
| `third_party/Nitro_DarkSide` | Vendored Nintendo DS FPGA source |
| `third_party/melonDS` | Vendored melonDS source |
| `kernel/nds_mem_wc` | Write-combining module, licence and build recipe |
| `docs` | User documentation and technical contracts |

Contributions and publication follow [PUBLIC_PUBLISHING.md](docs/PUBLIC_PUBLISHING.md).
The publication audit excludes commercial ROMs, saves, credentials, personal
paths and other private artifacts.

## Credits

Built on the MiSTer framework, Nitro_DarkSide, melonDS, and FPGAzumSpass's GBA
ARM7 implementation, which formed the basis of the ARM9 work. Thanks to the
MiSTer community, FPGAzumSpass, srg320, ElectronAsh, Corn, skmp and heni.

InsaneFriend (GitHub: saneFriend) contributed Resident Evil: Deadly Silence,
Kirby Mass Attack, Kirby Super Star Ultra, GTA: Chinatown Wars and Mega Man ZX
fixes, plus earlier SPI firmware, ARM7 Wi-Fi boot-memory and cartridge-IR
compatibility work. Thanks to Corn for the standalone suggestion and skmp's
DreamSTer project for the process-handoff reference. The frontend retains the
MiSTer Main font/protocol/OSD attribution in
[THIRD_PARTY.md](tools/standalone_host/THIRD_PARTY.md).

## License

NDS4MiSTer is distributed under GPLv3; see [LICENSE.txt](LICENSE.txt). The
separate write-combining kernel module is GPL-2.0; see
[kernel/nds_mem_wc/COPYING](kernel/nds_mem_wc/COPYING). Vendored components
retain their own licences and notices.
