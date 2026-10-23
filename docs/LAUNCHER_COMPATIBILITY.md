# Launcher compatibility — private beta, 2026-10-23

This change supports launching the standalone NDS script while a supported
MiSTer Main variant is running, and restoring Main when NDS exits. Offline
tests cover all nine executable paths below. Alternate-frontends still need
launch, gameplay and return checks on real installations; this is a private
test package. The standalone Python suite passes all 63 tests, including
frontend discovery, preflight and recovery.

Touch Range Beta3 includes these changes alongside Automatic FMV RC1 and the
root-menu **Right Stick Range** setting. Run **Scripts → NDS_Touch_Range_Beta**.
The host, renderer and FPGA binaries are unchanged from Touch Range Beta2.

## Main variants

Paths are relative to `/media/fat`. Discovery reads `/proc/PID/exe`, requires
one live Main, and checks that the installed executable matches that process.
Recovery remembers the original executable even when a core-specific `main=`
setting switches variants during NDS startup. Unknown paths, duplicate owners,
unavailable binaries and symlinks redirecting outside the accepted paths are
rejected. This is an installation-path check, not cryptographic authentication
of third-party binaries.

| Main variant | Accepted executable path | Primary source |
| --- | --- | --- |
| Stock and forks installed as stock Main | `MiSTer` | [MiSTer Main](https://github.com/MiSTer-devel/Main_MiSTer) |
| Physical Disc Support | `MiSTer_Physical-CD` | [Installation](https://github.com/Anime0t4ku/Main_MiSTer_Physical_Disc/releases) |
| Zaparoo Frontend | `zaparoo/MiSTer_Zaparoo` | [Zaparoo Main](https://zaparoo.org/docs/platforms/mister/main/) |
| Degauss | `degauss/MiSTer_Degauss` | [Degauss installation](https://github.com/giancarloerra/Degauss#installation) |
| Degauss with RetroAchievements | `degauss/MiSTer_RA_Degauss` | [Degauss RA integration](https://github.com/giancarloerra/Degauss/blob/8652a4c554d34cedf38999960d53758e755b9978/support/ra-main/README.md) |
| RetroAchievements | `MiSTer_RA` | [RA installer](https://github.com/sage2050/MiSTer_RetroAchievements) |
| mister-disc | `MiSTer-disc`, `MiSTer-disc-RA` | [Disc fork installation](https://github.com/theshaneobrien/mister-disc-drive-support#readme) |
| SuperStation Console Mode | `ConsoleMode/MiSTer_ConsoleMode` | [Official distribution and installer](https://github.com/Retro-Remake/ConsoleMode_Distribution/releases/tag/1.2) |

Console Mode's published installer establishes its path. The Main source URL
in the distribution README returned HTTP 404 during this review, so its internal
shutdown and menu routing have not been source-verified. Its path is included
in the offline discovery/recovery tests; end-to-end support needs a device test.

## Zaparoo use

Run `NDS4MiSTer.sh` from the Scripts browser, or use this ZapScript:

For Touch Range Beta3, substitute `NDS_Touch_Range_Beta.sh` in the examples
below. The public script is unchanged by this private package.

```text
**mister.script:NDS4MiSTer.sh
```

For a specific game, supply the existing standalone launcher's `--rom` argument:

```text
**mister.script:NDS4MiSTer.sh --rom "/media/fat/games/NDS/Your Game.nds"
```

These are examples; substitute a game that exists on your card. Use the normal
visible script mode so launch errors remain available. Zaparoo documents script
arguments and visible execution in its [MiSTer commands](https://zaparoo.org/docs/zapscript/mister/#mister-script).

Zaparoo Core is a separate background service and can run with stock Main.
Its `zaparoo.sh` service and the `zaparoo/frontend` UI are deliberately excluded
from Main discovery. The supervisor does not stop or reconfigure Core.

The researched Zaparoo Core source still routes its built-in `.nds` game entry
through the ordinary FPGA launcher. This patch does not replace that entry or
configure per-system launchers: use the script commands above for standalone
NDS. See [the built-in NDS launcher](https://github.com/ZaparooProject/zaparoo-core/blob/7d75fe5fa4194af478600be1d6c36a90278ffdd3/pkg/platforms/mister/launchers.go#L2279).

## Menu and process lifecycle

Return-to-menu commands now send `load_core menu.rbf`. Zaparoo's stable Main
maps that alias to `zaparoo/menu_zaparoo.rbf`; Degauss maps it to
`degauss/menu.rbf`. An absolute `/media/fat/menu.rbf` load bypasses these initial
path mappings. Recovery also starts Main from the SD root with the menu alias
when the FPGA is already at MENU.

Sources: [Zaparoo stable RBF loader](https://github.com/ZaparooProject/Main_MiSTer/blob/9f8f29e/fpga_io.cpp#L426),
[Zaparoo menu names](https://github.com/ZaparooProject/Main_MiSTer/blob/9f8f29e/support/zaparoo/menu_rbf.cpp),
[Degauss RBF loader](https://github.com/giancarloerra/Degauss-Main/blob/a8f9aa8d1390b5299edc510fa452f77d6cc1dfcf/fpga_io.cpp#L440).

Zaparoo Main stops its frontend before core loads and gives its UI child a
parent-death signal. NDS continues to ask Main to load the NDS core before
taking over SPI; it does not independently manage the Zaparoo UI.
See [the stable frontend lifecycle](https://github.com/ZaparooProject/Main_MiSTer/blob/9f8f29e/support/zaparoo/alt_launcher.cpp).

## Other software to account for

- **Aitor/spark2k06 and Classic Home:** installations that replace the normal
  `MiSTer` binary use the stock executable path. That satisfies discovery;
  it is not evidence that every feature of those forks has been tested.
  [Aitor fork](https://github.com/spark2k06/Main_MiSTer),
  [Classic Home](https://github.com/Dino-fly/Main_MiSTer/releases/tag/classic-home-v1).
- **SAM, remote launch tools and NFC automation:** these coordinate launches
  through Main rather than supplying another Main identity. SAM's usual mode
  starts games when the menu is idle. Automatic launches during an NDS session
  are a separate coexistence concern; this change does not implement a shared
  ownership protocol for those tools. [SAM documentation](https://github.com/mrchrisster/MiSTer_SAM#readme).
- **Renamed or relocated forks:** no broad `MiSTer*` process matching. Add a
  documented path and recovery test when a new installation layout is reported.

## Hardware test still required

For each installed frontend, launch the script, load a game, exit through
**System → Reboot**, and confirm the expected menu, video, input and frontend
features return. Repeat with a menu-only `main=` override and a global override.
Exercise Zaparoo's visible script command and its `--rom` form. Check recovery
after a failed launch and check coexistence with any enabled automatic launcher.
Retain `/tmp/nds-standalone` and `/tmp/nds-standalone-lease.json` on failure.
