# Developer guide

For installation and everyday use, start with the [README](../README.md) or
the [quick start](STANDALONE_QUICK_START.txt).

## Compatibility and performance details


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


## Architecture

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

## Source and builds

The release tag must contain the source matching every shipped component.
See [SOURCE_PACKAGE.txt](../SOURCE_PACKAGE.txt) for exact source revisions,
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

See [standalone frontend source](../tools/standalone_host/README.md) for menu,
input and recovery tests, and [WC module instructions](../kernel/nds_mem_wc/README.md)
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

Contributions and publication follow [PUBLIC_PUBLISHING.md](PUBLIC_PUBLISHING.md).
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
[THIRD_PARTY.md](../tools/standalone_host/THIRD_PARTY.md).

## License

NDS4MiSTer is distributed under GPLv3; see [LICENSE.txt](../LICENSE.txt). The
separate write-combining kernel module is GPL-2.0; see
[kernel/nds_mem_wc/COPYING](../kernel/nds_mem_wc/COPYING). Vendored components
retain their own licences and notices.
