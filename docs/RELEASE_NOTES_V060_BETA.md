# NDS4MiSTer v0.6.0-beta

**Standalone launcher, a configurable button to switch screen layouts, and Super Mario 64 DS fixes.**

> Draft for review. This release has not been published.

## What's changing

For this release, you no longer run Kickstart separately or launch a core from Console. Everything starts from **Scripts → NDS4MiSTer**.

Standalone stops the MiSTer process while you play and runs its own lightweight menu in its place, following the familiar MiSTer layout and controls. This frees ARM processor time for rendering and supports the speed and pacing improvements.

**Your existing installation stays intact.** Your MiSTer install, other cores, settings and games stay in place. The swap lasts only while you're playing. **System → Reboot** in the NDS menu returns you to the normal MiSTer menu — it doesn't power-cycle the board. Future NDS4MiSTer development will focus on standalone; your existing normal NDS release remains available.

## What's new

- **Standalone launcher.** One script starts the core and ARM helper and opens a lightweight replacement for the MiSTer binary.
- **A configurable button to switch screen layouts.** The last option in **Define NDS buttons** is **Cycle Video Layout**. Map it to any spare button and cycle through **Left/Right**, **Top/Bottom**, **Left Only** and **Right Only** without leaving the game.
- **Super Mario 64 DS fixes.** The first course no longer collapses into a horizontal line.

## Before you install

- **A kernel supporting the included write-combining module and 1 GHz clock control.** Tested on **Linux 5.15.1-MiSTer**. Standalone won't install a kernel for you.
- Games as uncompressed `.nds` files, up to **128 MiB**.

If the launcher reports a missing requirement, see the bundled **NDS4MiSTer_Standalone_README.txt**.

## Install and play

1. Unzip to the root of your SD card, merging the **Scripts** folder. Include the hidden **Scripts/.NDS_Standalone** support folder. If you're copying extracted files manually, turn on "show hidden files" so it isn't missed. Without it, standalone won't start.
2. Open **Scripts → NDS4MiSTer** and wait for the NDS menu.
3. Choose **Load NDS**. New installs start with both screens On in **Top/Bottom**. Upgrading? Confirm **Engine B (next Reset)** is **On**, or you'll get the same picture on both screens. Reset or reload after changing it.
4. Pick a game from `games/NDS`.

**Saves carry over.** Standalone shares `games/NDS` and `saves/NDS` with the normal core. Controller maps and standalone's own settings stay separate.

## Using the NDS menu

Open it with your usual controller combination, the OSD button, or **F12**. A new controller can use Select + Start or Guide, then **System → Define NDS buttons**.

**The menu doesn't pause the game.** **System → Save settings** keeps your options for next time. Greyed-out options aren't built yet — video and audio filters, Bluetooth pairing and other global settings still live in normal MiSTer.

## TATE setup

Choose **Video Layout → Top/Bottom**. Set **Video Rotation** opposite to the monitor's physical turn: **90 CCW** for clockwise, **90 CW** for counterclockwise. The menu rotates separately, via `osd_rotate` under `[NDS]` in `MiSTer.ini`. Try `osd_rotate=2`; if the menu comes out upside down, use `osd_rotate=1`. Return to normal MiSTer and relaunch standalone after editing.

## Known issues

- **Slowdown and uneven animation remain.** Speed varies by game and scene, and this isn't a promise of 60 FPS.
- **Movies and audio can still hitch.** Some games may also glitch, slow down or crash.
- **The System menu doesn't replace every MiSTer feature yet.** Some controller setups, alternate INIs and display changes need more testing.

## Files

The install ZIP and its SHA-256 checksum are the release assets. Matching source is in GitHub's **Source code (zip)** and **(tar.gz)** links.

## Thanks

Built on work from the MiSTer community, FPGAzumSpass, the Nitro_DarkSide and melonDS contributors, heni, and InsaneFriend (GitHub: saneFriend). Thanks to Corn for the standalone suggestion, and to skmp, the DreamSTer developer. Full credits and licenses are in the source tree.
