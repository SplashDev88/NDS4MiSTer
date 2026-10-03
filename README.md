# NDS4MiSTer

**v0.9.0-rc.1 — standalone launch, larger games, and the original DS firmware menu.**

Experimental Nintendo DS support for MiSTer FPGA. This release candidate
retains the accepted gameplay build, adds supported larger ROM layouts and
an optional way to visit the DS firmware interface. Graphics, sound and
compatibility remain works in progress; not every game reaches full speed.

## Install and play

1. Extract the install ZIP to the SD card root, merging **Scripts**. Include
   the hidden **Scripts/.NDS_Standalone** folder. If copying extracted files
   manually, enable “show hidden files.” Exit standalone before updating it.
2. Run **Scripts → NDS4MiSTer** and wait for the NDS menu.
3. Choose **Load *.NDS** and an uncompressed game from `games/NDS`.
4. Use **System → Save settings** to keep your options.

No separate Kickstart step, Console launch or five-minute window is needed.
Standalone stops the normal MiSTer program while you play and uses its own
lightweight menu. **System → Reboot** returns to normal MiSTer without
power-cycling the board. The normal MiSTer installation is still required;
a previous NDS release is not.

Existing normal NDS/Kickstart installations remain available. The update
replaces standalone program files in its own support folder and preserves
games, saves, settings and `MiSTer.ini`. Future development focuses on standalone.
Use the matching core, host, renderer and scripts; do not mix release files.

Fresh settings use **Top/Bottom**, with rotation and the FPS counter Off.
Both DS graphics engines are always enabled. Existing settings take priority;
the former Engine B switch is gone. Cartridge saves are shared with normal
NDS in `saves/NDS`; keep the same ROM filename to use its matching save.

The launcher requires a compatible kernel with write-combining support and
working **1 GHz** clock control. Testing used **Linux 5.15.1-MiSTer**. It does
not install a kernel or change your INI. See the quick start if a prerequisite
check fails. The ARM processors run at 1 GHz, overclocked from the standard
800 MHz; this clock setting is unchanged from the accepted build.

Read the [release notes](docs/RELEASE_NOTES_V090_RC1.md) and
[quick start](docs/STANDALONE_QUICK_START.txt) for setup, requirements and
troubleshooting. In the install ZIP these are `RELEASE_NOTES.md` and
`QUICK_START.txt` at its root.

## Optional DS firmware menu

Normal games use built-in FreeBIOS and generated firmware; no external BIOS
or firmware is needed. The default nickname is **MiSTer**.

To use **Boot DS firmware**, put your own compatible files directly in:

```text
games/NDS/bios7.bin
games/NDS/bios9.bin
games/NDS/firmware.bin
```

The native GUI requires supported BIOS files and a compatible **256 KiB DS/DS
Lite firmware image**. Some dumps and touch calibrations are unsupported;
see the quick start for exact requirements and reference SHA-256 hashes of
the tested original files. These files are not distributed.
Start games through **Load *.NDS**, not the native firmware cartridge slot.

Your original files stay untouched. Updated firmware is saved directly as
`saves/NDS/firmware.bin`, with a previous copy beside it. There is no firmware
subfolder. Nickname, birthday, favorite color and language are shared with the
built-in game profile; touch calibration is not. Firmware clock changes last
only for the current session, and RTC alarm interrupts are not implemented.

## Menu and screen layout

Open the menu with **F12**, the OSD button or your configured controller menu
combination. Select + Start and Guide provide fallbacks for a new controller.
Press Right for System, Left to return, A/Enter to select and B/Escape to go back.
**The menu does not pause the game.** Greyed-out System rows are not implemented;
use normal MiSTer for global changes and Bluetooth pairing.

**Define NDS buttons** creates a standalone controller map. Its last prompt,
**Cycle Video Layout**, assigns a spare button to cycle screen layouts during
play. **Recent Files** shares the normal NDS history; use controller Select or
keyboard backtick at **Load *.NDS** or in the ROM picker.

For TATE, use Top/Bottom and set rotation opposite to your monitor's physical
turn: **90 CCW** for a clockwise turn, **90 CW** for a counterclockwise turn.
D-pad, mouse and touch follow the rotated picture. The menu rotates separately
in `MiSTer.ini`:

```ini
[NDS]
osd_rotate=2
```

Use `osd_rotate=1` if the menu is upside down. Edit the existing `[NDS]` section
if present. On a display supporting 1080p, optional `video_mode=8` under `[NDS]`
can widen the portrait picture with small borders. Scaling uses whole pixels;
borders depend on the layout. Return to normal MiSTer and relaunch to apply
changes. NDS-specific INI settings also affect an older normal NDS core.

## Compatibility and performance

The accepted standalone pacing, drawing reuse and write-combining work remain.
Super Mario 64 DS's first-course horizontal-line problem is fixed in the tested
version. Supported larger layouts include tested Kingdom Hearts: 358/2 Days
and Pokémon White 2. File size alone is not a compatibility guarantee: files
up to 256 MiB require all-FF padding above 252 MiB; larger files up to 512 MiB
require it above 316 MiB. Unsupported layouts are rejected before upload.

Delayed ROM reads run separately so a slow network transfer can keep loading.
A load stops after **120 seconds without file progress**, not 120 seconds total.
Network folder browsing and Recent Files checks can still stall. Local SD
loading avoids those delays.

Known limitations include slowdown, surging, uneven animation, movie/audio
hitches and incomplete compatibility. Strange Journey can still freeze in its
intro; GTA: Chinatown Wars can show near-camera clipping. The later Jackass,
King Kong and NFS Carbon bundle is not included. NAND cartridge saves, save
states, DS wireless multiplayer and microphone input are not implemented.
DSi-enhanced game compatibility does not add DSi mode.

The tested USA revision 0 of NSMB uses alternate drawing updates to reduce
work while game state and graphics commands advance. This is not a global FPS
cap. The **3D FPS Counter** reports publication activity, including reused
planes, rather than unique animation frames or input latency. No universal
60 FPS or percentage speedup is claimed.

Disconnected host Wi-Fi retries are stopped for the current boot to avoid
stalls. Saved network settings and active connections are preserved; normal
Wi-Fi startup returns after reboot. This does not implement DS wireless.

## Reporting bugs

Use [GitHub Issues](https://github.com/SplashDev88/NDS4MiSTer/issues). Include
release version, game title/region/revision, scene, reproduction steps,
SD versus network loading, controller and kernel version. Include the exact
error or relevant log after checking it for personal paths or network details.
Do not upload commercial ROMs, BIOS/firmware dumps, saves or credentials.

## For developers

### Architecture

- The **FPGA** runs DS ARM9/ARM7 execution, timing, DMA, cartridge/memory/VRAM
  paths, sound, save/input interfaces and MiSTer video output. It transports
  ordered graphics events to the HPS.
- The **ARM/HPS helper** replays graphics work and composes Engine A,
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
