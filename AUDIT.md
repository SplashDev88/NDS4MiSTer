# RC15 source and release audit

Audited **2026-11-14**, before rewriting README.md. Scope: the packaged **v0.9.0-rc.15** selected by the maintainer. This is a source/package audit, not a new hardware qualification or full-game compatibility test.

## Release identity and verification

- Release/tag: **`v0.9.0-rc.15`**, commit **`bf87d812860eeb32d72c78f5563bd39a14defaef`**.
- Checkout: **`3e5f870c3eb8b9fb59785c74d5290b1b97c92f7c`** on `release/rc15-20261114`. Its only differences from the tag are three publication documents: README.md, RC14 release notes and the standalone installation guide. Runtime source is unchanged.
- Packaged FPGA source: `d7a1c1a9a9b1afbb3afc939dc8ae20a5adebd8c7`; renderer source: `e39559cc2f396ef67343b826752dc05d5fa9f559`; host/runtime source: the RC15 tag above.
- RC15 became public during this audit, at **2026-11-14 07:28:13 UTC**. A fresh unauthenticated [GitHub API request](https://api.github.com/repos/SplashDev88/NDS4MiSTer/releases/latest) identified RC15 as latest, with asset digests matching the audited package. An earlier cached web view still showed RC14. See the [RC15 release](https://github.com/SplashDev88/NDS4MiSTer/releases/tag/v0.9.0-rc.15) and [committed release notes](docs/RELEASE_NOTES_V090_RC15.md).

Local evidence was the `releases/v0.9.0-rc.15-20261114` release directory in the development workspace: archives, manifest, `RUNTIME_CONTRACT.json`, `VALIDATION.md`, `PERFORMANCE_SINCE_RC14.json`, build recipes and publication receipts. No consolidated current CHANGELOG was found; numbered release notes and these records supply the release history.

| Artifact | SHA256 |
| --- | --- |
| `NDS4MiSTer_v0.9.0-rc.15_Standalone.zip` | `e5c4dd08a0c6fdcc0c0816e6635ad95bf9d08761784b1c2cfdff676add1c962f` |
| Local `NDS4MiSTer_v0.9.0-rc.15_Sources.zip` | `84deebb0ac6eef4ed73bf2e3b7c5c160c448b6482fb28bec4fcabebf48ff6e4b` |
| `NDS4MiSTer_RetroTINK4K_MrMoro_Profiles.zip` | `ea1ca681eceffae91a1702aaa6e3e53319ce9a82b9aa5d532e00bf731ed6b3ad` |
| `NDS_Standalone.rbf` | `80ab55ba6bcb7fa32d8f5aae3e2348c19eed9b4713fee521b59e0176a5954e92` |
| `nds_standalone_host` | `2a9c824feb41dd0d9c07f1a30b9e874bf84219501589238d30db0b697229f709` |
| `support/nds_hybrid_3d_service` | `3834859ec6550b005d2f98c5e5255154a86aad0354669e30ad4895d09d2f4af9` |
| `support/nds_mem_wc.ko` (5.15.1) | `c3c67f88de36a853db7d4537ddce3202df6329a54b2600fa90b7104c803a7113` |
| `support/modules/6.18.38-MiSTer/nds_mem_wc.ko` | `c613e032ff795422453178d58bc89f5c282f3681ef0c5ecf303cb39807f81fe3` |
| `NDS_speed.cfg` | `3c46da5de7566e009d75baae736e970aae9f1ff75712febd4f5fe8bbe7665f52` |

The install archive contains **no `.mra`/`.mgl`**. Its only supplied user-setting file is `NDS_speed.cfg` (`NDS-SpeedHacks-v1`, value `5`); graphics preferences are generated/read at runtime.

Checks performed: all **584 frozen FPGA inputs** matched the source; all **59 automatic movie manifest entries**, **89 outer checksum entries** and **81 kit checksum entries** passed. Comparing 2,404 archived source files found only the three publication-document differences above. Matching runtime scripts were checked against source. Extracted `auto_movies.py --validate-only` passed; **35** `test_video_target`/`test_public_preflight` unit tests passed. Historical hardware, C++ and RTL results are evidence, not tests rerun by this audit. An additional isolated-package check passed before resetting the speed config to 0 and then reproduced the launcher checksum rejection described below. No core source was changed.

## Complete menu inventory and defaults

The FPGA [CONF_STR](fpga/mister_nitro_console_island/NDS4MiSTer.sv#L29) is not the complete standalone user interface. Raw defaults below mean zero status bits; existing settings override them. The launcher creates first-install status **`0x4420`**: Top/bottom, both engines enabled, independent analog Main. See [initialize_settings](tools/standalone_host/supervisor.py#L400).

| CONF_STR entry | Raw default | Function / standalone treatment |
| --- | --- | --- |
| `FS3,NDS,Load NDS,30000000` | Action | `.nds` loader, file slot 3 and DDR load address; host labels it **Load *.NDS**. |
| Video Layout `[6:5]` | Left/Right | Left/Right, Top/Bottom, Left Only, Right Only. Host relabels Side-by-side, Top/bottom, Main, Touch; single-screen labels follow Screen Order. First install is Top/bottom. |
| Screen Order `[7]` | Main First | Main First / Touch First. Swaps source order and single-panel selection. |
| Screen Gap `[9:8]` | 8 Pixels | 8, None, 16, 24 pixels between combined screens. |
| 3D FPS Counter `[4]` | Off | Off/On diagnostic overlay, still exposed in Display options; deliberately omitted from player README. |
| Video Rotation `[12:11]` | Off | Off, 90 CCW, 90 CW; digital picture and menu rotation. |
| Output Timing `[13]` | Standard | Standard / CRT 240p. Generated host option is CRT Mode Off/On; hidden with the paired independent-output core, which selects analog 240p automatically. |
| Independent Outputs `[14]` | Off | Off/On legacy switch. Paired host/core force independent routing; hidden from their normal menu. |
| Analog Screen `[15]` | Main | Main / Touch. Native analog selection; hidden when `vga_scaler=1`. |
| Reset `T[0]` | Action | Reset DS execution, distinct from System → Reset settings. |
| `J1` | Mapping declaration | A, B, X, Y, L, R, Select, Start, Touch; no fixed physical-controller assignment. |
| `v,1` / `V,...` | Metadata | Config version 1 and legacy `r355 Nitro console island` build-date string; standalone host supplies RC15 branding. |

Host additions come from [menu visibility](tools/standalone_host/host.cpp#L350), [menu rendering](tools/standalone_host/host.cpp#L1570), [settings loading](tools/standalone_host/host.cpp#L2914), [core_menu.h](tools/standalone_host/core_menu.h) and [system_menu.h](tools/standalone_host/system_menu.h#L65).

| Host menu/action | Default | Choices / effect |
| --- | --- | --- |
| Boot DS firmware | Action | Browse a folder containing validated dumps; independent of normal ROM boot. |
| Display options | Submenu | Rotation, Touch Rotation, order, gap, counter, DV target, AA and 3D resolution. |
| Right Stick Range | 100% | 100/125/150/175/200%; absolute stylus gain. |
| Touch Rotation | Normal | Normal, 90 CCW, 90 CW; input transform independent of picture. |
| Direct Video Target | CRT | CRT / Scaler; visible only in DV. CRT limits the selected digital picture to one panel; Scaler permits combined layouts. |
| 3D Anti-aliasing | **On** | Off/On. Enabling restores Native resolution. Manifest's Off default is incorrect for a fresh host. |
| 3D Resolution | Native | Native, Half Rows, 128×96, 64×48; reduced modes disable AA. Also exposes **Off (test)**, a nonpersistent diagnostic omitted from player README. |
| Lid | Open | Toggle closed/open; reopening signals wake. Reset/game load opens it. |
| Main exit / Display back | Action | Close menu / return to main menu. |
| System → Core | Action | Core browser; handoff back through normal MiSTer. |
| Define NDS buttons | Action | Guided mapping; completed maps save automatically, optional steps can be skipped. |
| Reset settings | Confirmation, No selected | Saves frontend defaults immediately; does not reset DS execution. Bug: overwrites bundled speed mode 5 with 0, blocking the next launcher validation; layout becomes Side-by-side. |
| Save settings | Action | Persist display, touch, graphics and speed preferences. |
| Reboot | Action | Clean standalone exit and return to normal MiSTer, not a board reboot. |
| System exit | Action | Return to NDS menu. |
| Lock OSD; Button/Key remap; Reset player assignment; Video processing; Audio filter and filename | Disabled/info | Lock row conditional on INI; filter reflects Main-applied state. No usable NDS volume/filter controls. |
| Recent Files / Clear the List | History; clear defaults No | Recall previous files; confirmation before clearing. |
| Startup F4 options | CRT | CRT/Scaler, save and start/cancel; same saved DV preference. Enter or three-second timeout starts normally. |

Both 2D engines are always enabled; there is no Engine B toggle or Speed hacks menu. Reset defaults are **not** the same as first-install defaults. See [TODO.md](TODO.md).

## ARM loading, paths and configuration

[Launcher](tools/standalone_host/NDS_RC15.sh) → [auto_movies.py](tools/standalone_host/auto_movies.py) → [supervisor.py](tools/standalone_host/supervisor.py) validates the matching kit, selects a kernel module, loads the RBF, starts the renderer and native host, and restores normal Main on exit. [clock_control.py](tools/standalone_host/clock_control.py) requests 1 GHz and restores the previous clock policy. Preflight requires root, Python ≥3.8, `/dev/mem`, `/dev/MiSTer_cmd`, normal Main/menu and matching module vermagic. Packaged kernels are exactly 5.15.1-MiSTer and 6.18.38-MiSTer; no minimum Main version is encoded.

Runtime root: `/media/fat/Scripts/.NDS_RC15`. Default ROM root: `/media/fat/games/NDS`; [host storage browsing](tools/standalone_host/host.cpp#L607) supports already-mounted SD/USB/network locations. Save root: `/media/fat/saves/NDS`, independent of ROM storage. [ROM layout checks](tools/standalone_host/rom_layout.h) accept up to 512 MiB with reserved all-FF tails beyond 252 MiB for ≤256 MiB files, or 464 MiB for larger files; [rom_reader.h](tools/standalone_host/rom_reader.h) validates padding and read-progress timeouts.

| Configuration | Read/write behavior |
| --- | --- |
| Kit `NDS_v1.CFG` | 16-byte status; kit preferred over `/media/fat/config/NDS_v1.CFG`; generated only when neither exists. |
| Kit `NDS_touch.cfg`, `NDS_stick.cfg`, `NDS_video.cfg` | Touch orientation, stick range, CRT/Scaler; stored Scaler token is `retrotink`. |
| Kit `NDS_graphics.cfg`, `NDS_speed.cfg` | AA/resolution and guarded NSMB preset; Save settings writes both. |
| Kit `NDS_rtc.cfg` | Automatic clock offset/offline checkpoint persistence. |
| Kit `inputs/NDS_input_<VID>_<PID>_v3.map` | NDS mapping; shared `config/inputs` and `config` mappings are import/fallback sources. Generic `input_..._v3.map` supplies controller defaults. |
| `/media/fat/config/NDS_storage.cfg` | Browser locations, including firmware folder. |
| `/media/fat/config/NDS_recent_3.cfg`, `NDS_recent_locations.cfg` | Recent ROMs and locations. |
| MiSTer INI / `config/NDS_afilter.cfg` | Main applies video/audio first; host reads browsing, recents and informational filter/lock preferences. Legacy `NDS_osd.cfg`/`osd_rotate` do not control new display rotation. |

RC15 does not automatically import the former private `.NDS_Standalone` directory. No RC15 update_all feed/installer was identified.

## Feature status and source evidence

**Working** means the stated path is implemented and has appropriate existing evidence; it does not certify all games. **Partial** means a known omission or insufficient coverage. **Not supported** means no usable release path. Donor/emulator source alone is not proof: [files.qip](fpga/mister_nitro_console_island/files.qip) and the active top-level instantiations determine what ships.

| Feature | Status | Evidence / qualification |
| --- | --- | --- |
| ARM9/ARM7, memory, DMA/timers | Partial | [Console top](rtl/nds_nitro_console_top.vhd), [island](rtl/nds_nitro_console_island.sv); active FPGA implementation, known timing/compatibility gaps. |
| Dual screens | Working | [Top-level display dimensions/routing](fpga/mister_nitro_console_island/NDS4MiSTer.sv#L100), [scanout](rtl/nds_nitro_video_scanout.sv); both displays composed. |
| 2D A/B; 3D | Partial | [Hybrid3DService.cpp](src/replay/Hybrid3DService.cpp), [GameQueryProfile.h](src/replay/GameQueryProfile.h), active `NDS_ARM_AREA`/`NDS_HYBRID_3D` project configuration. Both 2D engines render on ARM; selected 3D work uses FPGA acceleration. |
| Buttons/touch/hotkeys | Working | [Host input](tools/standalone_host/host.cpp#L2468), [SPI touch ADC](rtl/nds_nitro_spi.vhd). README mapping follows actual evdev/keyboard handlers, not pad labels. |
| Keypad interrupt | Not supported | [Console KEYINPUT/EXTKEYIN reads and IRQ sources](rtl/nds_nitro_console_top.vhd#L2540): button polling exists; KEYCNT/key IRQ path absent. |
| Microphone | Partial | [SPI microphone generator](rtl/nds_nitro_spi.vhd#L390), host F11; clipped synthetic noise or midpoint silence. No physical/USB capture path. Existing host notes record NSMB Balloon Racing. |
| Lid and sleep/wake | Working | [Console sleep/IRQ logic](rtl/nds_nitro_console_top.vhd#L2535), host lid toggle; opening IRQ22 wakes permitted sleep. [RC7 notes](docs/RELEASE_NOTES_V090_RC7.md) record NSMB; other puzzles unqualified. |
| Audio | Partial | Active [nds_sound.vhd](third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd): 16 PCM/ADPCM/PSG/noise channels, stereo mixer. Capture is register-only; some SOUNDCNT selection/channel-hold behavior incomplete. [Island routing](rtl/nds_nitro_console_island.sv#L2188) halves amplitude for headroom. |
| EEPROM / serial Flash | Working | [Save bridge type/size map](rtl/nds_nitro_save_bridge.sv#L107), [cartridge SPI](third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd), [save_profiles.h](tools/standalone_host/save_profiles.h); sizes listed in README. Unknown-code fallback is small EEPROM, not universal autodetection. |
| FRAM | Partial | Shared EEPROM/FRAM-compatible cartridge path; no separate FRAM-specific hardware qualification found. |
| NAND | Partial | [nand_save.h](tools/standalone_host/nand_save.h), [NAND_SAVES.md](docs/NAND_SAVES.md): 16 MiB WarioWare UORE/UORP/UORJ; 8 MiB Jam UXBP. UORE/UXBP limited save/reload checks; other regions unqualified. Band Brothers DX AXBJ's 8 MiB serial Flash is different and unsupported. |
| Automatic raw saves | Working | [Mount/save I/O](tools/standalone_host/host.cpp#L2270), [dirty bridge flush](rtl/nds_nitro_save_bridge.sv#L374): sector writes, synchronous file access, periodic sync and clean-exit drain. Flat basename `.sav`; no power-failure atomicity or container converter. |
| RTC | Partial | [nds_nitro_rtc.vhd](rtl/nds_nitro_rtc.vhd), [host clock](tools/standalone_host/host.cpp#L2107), [GAME_CLOCK.md](docs/GAME_CLOCK.md). Host-local calendar and persistent edits; no alarm IRQ, oscillator trim or battery-backed FPGA state. |
| Normal game BIOS/firmware | Working | [Host boot/load](tools/standalone_host/host.cpp), included FreeBIOS/generated firmware; no user dumps required. |
| Native firmware boot | Partial | [firmware_media.h](tools/standalone_host/firmware_media.h#L333), [host validation](tools/standalone_host/host.cpp#L2010): exact BIOS CRCs/sizes, 256 KiB firmware internal checks, identity touch calibration restriction. Working copy under saves; no cartridge GUI boot. |
| Wi-Fi/local wireless/Download Play | Not supported | [Active ARM7 memory bus](third_party/Nitro_DarkSide/d2dabe/rtl/nds_membus7.vhd) provides compatibility RAM/register handling, not packet/radio connectivity. No host networking bridge to the DS wireless hardware. |
| GBA slot/mode/accessories | Not supported | [ARM9 memory decoder](rtl/nds_nitro_membus9.vhd#L546) and host loaders: no functional slot-cartridge/accessory path. |
| Cartridge IR | Not supported | Cartridge identification/pass-through exists in [nds_card.vhd](third_party/Nitro_DarkSide/d2dabe/rtl/nds_card.vhd); no IR-link transport. |
| DSi mode; save states | Not supported | [Active DS-only core](rtl/nds_nitro_console_top.vhd) and [host loader](tools/standalone_host/host.cpp); no DSi boot path or state UI. CPU boot-state machinery is not a user save-state implementation. RC15 notes agree. |
| HDMI, layouts, both TATE directions | Working | Top-level framebuffer metadata, scanout, [DV1 rotation reader](rtl/nds_dv1_rotate_read.sv), host menu. Native analog remains upright; scaled analog mirrors HDMI. |
| Native analog / CRT DV1 | Partial | [Scanout timing](rtl/nds_nitro_video_scanout.sv#L238), [framework routing](fpga/mister_nitro_console_island/sys/sys_top.v), [nds_dv1_yc.sv](rtl/nds_dv1_yc.sv); RGB and targeted Y/C implemented, adapter coverage limited. Rotation is not clamped to 15 kHz in CRT target. |
| Scaler DV1 | Partial | [Host DV metadata](tools/standalone_host/direct_video.h), rotation reader and release display notes. RT4K evidence exists; no RC15 OSSC/Morph model/firmware qualification. |
| RT4K profile pack | Partial | Four archive files inspected; [contributor notes](docs/release/RETROTINK_MR_MORO.md), [pack record](docs/release/RC14_RETROTINK_PROFILE.json). Two binary `.rt4` profiles, `info.txt`, background BMP; installation/pairing verified from notes, not a new hardware test. |
| PAL 50 Hz | Not supported | Timing logic and RC15 notes; PAL60/PAL-M encoder choices do not create 50 Hz scanout. |
| Automatic per-game optimizations | Partial | [GameQueryProfile.h](src/replay/GameQueryProfile.h), [guest catalog](tools/standalone_host/fmv/guest_catalog.json), [movie profiles](tools/standalone_host/fmv/profiles.json), [NSMB hooks](tools/standalone_host/fmv/nsmb_hooks.json). Identity/content guards limit application; game/revision coverage varies. |

Timing calculations in README follow the active paired-core scanout: 6 MHz/384/262 for single-screen CRT; 10 MHz/640/262 side-by-side; 20 MHz/640/524 stacked. Rotation uses a 60 MHz transport and 640-dot totals with 262/524/786 lines and repetition 6/3/2: 1,006,080 clocks/frame, approximately 59.6374 Hz. A rotated single-screen canvas is 240×320 and **31.25 kHz**, including with CRT target. INI option semantics were cross-checked against [official Main_MiSTer/MiSTer.ini](https://github.com/MiSTer-devel/Main_MiSTer/blob/master/MiSTer.ini); suggested settings do not certify arbitrary converters/scalers.

RT4K archive paths: `NDS4MiSTER/profile/MiSTer/NDS/{NDS Default.rt4,NDS Rotate.rt4,info.txt}` and `NDS4MiSTER/image/MrMoro/NDS.bmp`. Merge the inner folder's contents into the RT4K card root. Default is the ordinary orientation/single-screen analog profile; Rotate requires physical display rotation, core Scaler target and CW/CCW, with RT4K Pro RoTATE off. The contributor does not supply a separate profile per layout or a minimum firmware version. The separate DS Lite manual recipe is not an additional `.rt4` profile in this pack.

## Documentation/code mismatches

1. **Reset settings is inconsistent with release defaults.** [Host reset](tools/standalone_host/host.cpp#L1729) writes speed mode 0, while the package ships 5 (`lookup+bones`), and changes Top/bottom to Side-by-side. Further ROM loads in the same session lose the preset. Worse, `automatic_movie_files` pins this writable file: the next normal launch fails with `Mismatched package file: NDS_speed.cfg` before the host starts. This rejection was reproduced with `auto_movies.py --validate-only` in an isolated extracted package after writing the reset-produced bytes. No menu restores the preset. Recorded as a confirmed bug in [TODO.md](TODO.md); workaround is in README. Already-loaded guest patches are not removed until another load.
2. **AA default:** runtime `manifest.json → graphics_defaults` says Off; [host constructor](tools/standalone_host/host.cpp#L2941), reset and [graphics test](tools/standalone_host/test_host_graphics.cpp#L18) establish On without a graphics config. None ships. The README states actual On and recommends Off for speed.
3. **Old hardware/build descriptions:** [architecture.md](docs/architecture.md) and [DEVELOPMENT.md](docs/DEVELOPMENT.md) include older RC9 assumptions; [BUILD_RC15.md](docs/release/BUILD_RC15.md)/[RC15_BUILD.json](docs/release/RC15_BUILD.json) describe an early RC15 beta and different binary hashes. The final FPGA is not simply byte-identical RC14. `SOURCE_PACKAGE.txt` is also stale.
4. **Old menus/limits:** standalone historical text can describe engine toggles, earlier lid controls, ROM limits or unsupported NAND. Current host has both engines forced on, F10 Screen Peek, menu-only lid, larger guarded ROM layouts and selected NAND support. Read active handlers before following those guides.
5. **Upgrade instructions:** the former `.NDS_Standalone` settings directory is not automatically migrated into `.NDS_RC15`. Shared saves/browser preferences survive; private settings need explicit migration. The new README distinguishes these.
6. **Performance claims need context:** the old README/release notes quote Dawn 30→39, NSMB map 15→30 and Mario Kart pacing improvements. Retained measurements compare different AA/core baselines; AA was On in older runs and Off in newer runs. Renderer pairs are not proof of unique gameplay frames. Mario Kart's pacing correction came from a separate core comparison; its cited rendering rate slightly fell. Final Beta23/RC15 was not comprehensively rebenchmarked. No overall compatibility percentage/full-playthrough claim is supported.
7. **Ultimate Mortal Kombat 3:** the release text names a game-specific speedup, but no corresponding named guard/profile or retained per-game measurement was located. General improvements may help it; the README does not repeat the untraced specific claim.
8. **Source download metadata:** manifest names `NDS4MiSTer_v0.9.0-rc.15_Sources.zip`; that expanded source/reproduction ZIP is local, not a public asset. GitHub supplies the tagged source tree instead. See the build gap below.
9. **CRT selection does not guarantee 15 kHz:** rotation remains enabled in the DV reader; the README explicitly requires Rotation Off for a 15 kHz CRT. This is a code limitation, not a verified safe rotated CRT mode.

The archived old root README is [README.old.md](README.old.md). Runtime limitations were retained even when absent from the short release announcement. Diagnostic menu entries are catalogued here and deliberately excluded from the player README.

## Build provenance

The local source archive contains `source/`, FFmpeg 7.1.1 and 79 PGO files under `dependencies/`, and `reproduction/BUILD.md`, `build-renderer.sh`, `build-fpga.sh`, `FPGA_INPUTS.json` and provenance. Its current recipe specifies Ubuntu 24.04/GCC 13 ARM hard-float, fixed container paths for PGO, and Quartus Lite 17.0.2 Build 602 on Linux/amd64. It is more current than the committed early-beta recipe. Byte-for-byte recompilation was **not** demonstrated by this audit or by release packaging; FPGA static timing remains unresolved.

The public GitHub tag provides the 2,404-file source tree; the publication receipt reports byte verification against the local source archive. The expanded dependency/reproduction material is not in that tree or among the three published assets. README therefore gives the toolchain/project entry points without presenting older scripts as an exact final-binary recipe.

## Open questions

- What external SDRAM module size/speed and alternative boards are actually qualified? The mapped footprint fits 32 MiB; that is not a hardware-tested minimum. What is the oldest supported Main/menu build?
- Should the release's intended default be AA Off, as the manifest says, or On, as the executable implements? Fix the inconsistent declaration/initialization and qualify performance with matching settings.
- Should CRT target reject rotation, or provide a separate verified 15 kHz TATE implementation? Which exact DACs, encoder revisions, RGB/component/Y/C CRTs and OSSC/Morph models/firmware are qualified?
- Which RT4K firmware versions and layouts were tested with each contributed profile? What exact capture/input configuration produced the profile bytes?
- Which FRAM games, lid puzzles, microphone games and save transfers have hardware evidence? Extend NAND region coverage and identify any supported larger serial-Flash cartridges.
- Where is the code/measurement supporting the Ultimate Mortal Kombat 3 claim? Obtain matched final RC14/RC15 benchmarks before advertising general FPS gains. Four Platinum regional ports (Italian, Spanish, Japanese, Korean) remain unqualified per [version coverage](docs/release/VERSION_COVERAGE_RC14.md).
- Will the final reproduction recipe and required dependency/PGO inputs be published alongside the tagged source? Correct the manifest's unavailable source-asset name. Is an RC15 update_all route planned?

The reset-preset issue is now a TODO, not an unresolved factual question. All other unknowns remain explicitly qualified in the README; no support was inferred merely from what a DS emulator normally provides.
