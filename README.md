# NDS4MiSTer — v1.0.1

Experimental Nintendo DS core for the MiSTer FPGA.

[**Download 1.0.1**](https://github.com/SplashDev88/NDS4MiSTer/releases/download/v1.0.1/NDS4MiSTer_v1.0.1_Standalone.zip) · [Compatibility list](https://docs.google.com/spreadsheets/d/1HNx41BC4jj3XQ-pzT3D9oJNnD20f9ZzkurHLMI3L-Is/htmlview) · [All releases](https://github.com/SplashDev88/NDS4MiSTer/releases)

Compatibility, speed and sound vary by game. Full speed is not guaranteed, and graphics-heavy scenes can slow down even in games that otherwise run well.

**How it differs from other cores:** NDS4MiSTer is a hybrid core, similar to [DreamSTer](https://github.com/skmp/DreamSTer), and is launched from **Scripts** rather than a typical `.rbf` in the `_Console` directory. While you play, it temporarily takes over from the normal MiSTer menu, and it hands control back when you exit.

## What's new in 1.0.1

- Improved FMV playback, including native-speed openings in Castlevania: Dawn of Sorrow and Portrait of Ruin.
- Switching games stays in NDS, without returning to the MiSTer menu or reloading the core.
- Updated menu fonts and spacing for better readability.
- Fixed Dawn of Sorrow's "Save failed" error with certain existing save files.

---

## What you need

- MiSTer (DE10-Nano) with **128 MB SDRAM**. Other sizes may work but are untested at this time.
- **Uncompressed `.nds`** files. ZIPs are not supported.
- A controller or keyboard.
- A mouse or a controller with a right analog stick for touchscreen input. PS5 DualSense controllers work quite well.

**No BIOS or firmware files are needed** to play games.

---

## Install

1. Download the [1.0.1 ZIP](https://github.com/SplashDev88/NDS4MiSTer/releases/download/v1.0.1/NDS4MiSTer_v1.0.1_Standalone.zip).
2. Extract **everything** to the SD card root, merging folders. Include the hidden `Scripts/.NDS/` folder, because the core won't start without it.
3. Put your games in `games/NDS/`.
4. For CRTs or scalers, add an `[NDS]` section to `MiSTer.ini` at the **SD card root** (see [Video setup](#video-setup)). HDMI usually needs no changes; use the HDMI block below if you need to override global settings.
5. Run **Scripts → NDS.sh**.

**Mac users:** Finder hides dot-folders. Press **Command + Shift + .** to show them before copying, and check that `Scripts/.NDS/` reaches the SD card.

Do not move the `.rbf` to `_Console`.

**Upgrading:** exit via **System → Reboot**, then back up `saves/NDS/` and your existing NDS settings folder. Extract the complete **1.0.1 ZIP** to the SD card root, including hidden files, merging folders and replacing package files. Run **Scripts → NDS.sh**.

On first launch, settings, controller mappings and the clock are imported automatically into **`Scripts/.NDS/`**, checking `.NDS_RC15` first, then `.NDS_Standalone`. Existing `.NDS` settings take priority; no manual copying is needed. Saves stay in `saves/NDS/`. Recognized old public launchers are backed up under `.NDS/legacy-launchers/` and removed from the Scripts menu; original settings folders are kept. Future updates use the same `NDS.sh` and `.NDS/` paths and preserve your saved preferences.

---

## First run

1. Launch **Scripts → NDS.sh** and wait for the **three-second countdown** to finish. It starts automatically; no keyboard or button press is needed. Enter skips the wait if you have a keyboard.
2. In the NDS menu, press **D-pad Right** to open **System**, then choose **Define NDS buttons**. Follow the prompts, including **Screen Peek** and **Blow into Mic**.
3. Choose **Load \*.NDS** and pick a game. Some games take longer the first time they load while a cache is built.
4. **3D Anti-aliasing defaults to Off** on a fresh install. Imported settings are preserved; for better speed, set **Display options → 3D Anti-aliasing → Off**, then **System → Save settings**.
5. When you're done, choose **System → Reboot** to return to MiSTer. Do this before powering off.

---

## Controls

**In the NDS menus:** use the D-pad to navigate and your MiSTer menu-confirm button to select. Without a custom MiSTer mapping, the **East face button confirms** and the **South face button goes back**. Press D-pad Right from the main NDS menu to open System.

| DS | Keyboard | Controller |
|---|---|---|
| D-pad | Arrows | D-pad / left stick |
| A / B | X / Z | East / South |
| X / Y | S / A | North / West |
| L / R | Q / W | Shoulders |
| Start / Select | Enter / Right Shift | Start / Select |
| Touch | Space | Right-stick click |

**Touchscreen:** the right stick moves the stylus, with stick center = screen center. Hold Touch to tap or drag. If the stick can't reach the corners, raise **Right Stick Range** (up to 200%). A mouse also works: left-click taps the screen.

| Shortcut | Action |
|---|---|
| Controller menu shortcut (default **Select + Start**) or F12 | Menu |
| Hold mapped **Screen Peek** or F10 | Peek at the other screen (single-screen layouts) |
| Hold mapped **Blow into Mic** or F11 | Blow into mic |
| USER button | Reset game |

Go to **System → Define NDS buttons** to assign **Screen Peek**, **Blow into Mic** and **Cycle Video Layout** to controller buttons. Press and release your chosen button at each prompt; completing the mapping saves it automatically. The MiSTer's physical **USER** button skips a prompt if you don't want to assign it. Hold your mapped Peek or Mic button during play; no keyboard is needed. To close the DS lid, open the menu and select **Lid**.

---

## What works

| Feature | Status |
|---|---|
| Both screens, 2D and 3D | ✅ Works (accuracy and speed vary by game) |
| Buttons, touch via stick or mouse | ✅ |
| Sound | ✅ Mostly (some effects incomplete, hitches during slowdown) |
| Cartridge saves (EEPROM, Flash, FRAM) | ✅ |
| Microphone | ⚠️ Blowing only: no real mic, no voice |
| Lid close / sleep | ⚠️ Works, tested mainly in NSMB |
| Clock (RTC) | ⚠️ Works, no alarms |
| Wi-Fi, local wireless, Download Play | ❌ |
| GBA slot and accessories | ❌ |
| DSi mode | ❌ |
| Save states | ❌ Use in-game saves |

### Game-specific speed optimizations

These games have targeted speed optimizations:

- New Super Mario Bros.
- Castlevania: Dawn of Sorrow, Portrait of Ruin and Order of Ecclesia
- Final Fantasy Tactics A2
- Mario Kart DS
- Pokémon Platinum, HeartGold and SoulSilver

The speedups only work with unmodified retail ROMs. ROM hacks may run without them.

---

## Video setup

Settings go in the `[NDS]` section of **`MiSTer.ini` at the SD card root** (`/media/fat/MiSTer.ini`). After changing them, return to MiSTer and relaunch.

### HDMI (start here)

HDMI usually needs no extra configuration. Add this block if your global settings enable `direct_video` or `vga_scaler`, or you want a separate output mode for NDS.

```ini
[NDS]
direct_video=0
dvi_mode=0
video_mode=8        ; 1080p60 — delete this line to keep your current mode
vsync_adjust=0
vga_scaler=0
```

### CRT (15 kHz, via Direct Video)

**Direct Video (DV1)** sends the core's native video timing through HDMI. Use this with an HDMI-to-VGA DAC driving an **RGBS (RGB + composite sync)**/SCART CRT:

```ini
[NDS]
direct_video=1
dvi_mode=0
vga_mode=rgb
composite_sync=1
forced_scandoubler=0
vga_scaler=0
```

Then, in the core's menu:

- Set **Direct Video Target → CRT**.
- Set **Video Rotation → Off**.
- Pick **Main** or **Touch** as the layout. Hold your mapped **Screen Peek** button (or F10) to see the other screen.

The output is a 240p signal at ~59.64 Hz. There is no 50 Hz/PAL mode. Dual-screen layouts don't work on a 15 kHz CRT.

- **RGBHV monitor:** use `composite_sync=0`.
- **MiSTer Addons YC Active Encoder:** use `vga_mode=svideo` and `ntsc_mode=0`. Keep `svideo` even if you use the board's composite jack.
- **Analog I/O board instead of Direct Video:** use `direct_video=0` and pick the screen under **Analog Screen**.

### Scalers (RetroTINK-4K and others, via Direct Video)

```ini
[NDS]
direct_video=1
dvi_mode=0
vga_mode=rgb
composite_sync=0
forced_scandoubler=0
vga_scaler=0
```

Set **Direct Video Target → Scaler**. This unlocks both-screen layouts.

- Use **square pixels** on the scaler (on the RetroTINK-4K, **1:1 Sq. Pixel**).
- For **TATE (vertical monitor)** mode, use the core's rotation option in **Display options** and turn off the scaler's rotation function.
- Connect the scaler **directly**: splitters may prevent a scaler from locking onto the DV1 signal properly.

The RetroTINK-4K is tested. Morph is untested over Direct Video but should work fine.

**RetroTINK-4K profiles:** Mr. Moro's [profile pack](https://github.com/SplashDev88/NDS4MiSTer/releases/download/v1.0/NDS4MiSTer_RetroTINK4K_MrMoro_Profiles.zip) includes **NDS Default** and **NDS Rotate**. Copy the contents of its inner `NDS4MiSTER` folder to the root of the RetroTINK-4K's SD card.

### Layouts and rotation

Find these under **Display options**:

| Option | Choices |
|---|---|
| Digital Layout | Top/bottom (default), Side-by-side, Main, Touch |
| Screen Order / Gap | Swap screens; 0–24 px gap |
| Video Rotation | Off, 90 CW, 90 CCW |
| Touch Rotation | Usually leave Normal |
| 3D Anti-aliasing | Off (default) = faster |

**Vertical (TATE) monitor:** start with Top/bottom and rotate the picture opposite to the way you turned the monitor. For a monitor turned clockwise, use **90 CCW**. Leave Touch Rotation on Normal.

Save your choices with **System → Save settings**.

---

## Audio

Set volume in the normal MiSTer menu **before** launching. The core otherwise has no audio settings of its own. HDMI audio needs `dvi_mode=0`.

---

## Saves

Saves are written automatically to `saves/NDS/<ROM name>.sav`. They are standard raw `.sav` files.

- **Import a save:** use a raw `.sav` of the correct size, renamed to match your ROM's filename. `.dsv` and save-state files won't work.
- Oversized saves with verified empty padding are supported without trimming the original file. Incompatible extra data produces an error before the game starts.
- **Before powering off:** wait for the game to finish saving, then choose **System → Reboot**.
- Two ROMs with the same filename share one save, even if they're in different folders.
- **Back up** `saves/NDS/` and `Scripts/.NDS/NDS_rtc.cfg` (your in-game clock).

---

## Known issues

- New Super Mario Bros. can show background tearing near level endings, including World 1-2.
- Slowdown, stutter, graphics glitches and audio hitches still happen.

See [GitHub issues](https://github.com/SplashDev88/NDS4MiSTer/issues) for reported problems and updates.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Black screen or nothing starts | Re-extract the full ZIP, including `.NDS`. Launch **Scripts → NDS.sh**. |
| BIOS error | Use **Load \*.NDS**, not Boot DS firmware. |
| A game won't boot | Use an unmodified, uncompressed ROM on the SD card. Check the compatibility list. |
| Stuck loading | The first load can take minutes in certain instances. Network or USB storage is often slower than SD. |
| No CRT sync or squeezed picture | Check: CRT target, Main/Touch layout, rotation Off, `vga_scaler=0`, `forced_scandoubler=0`. |
| Only one screen on scaler | Set **Direct Video Target → Scaler** and a two-screen layout. |
| No audio | Check MiSTer volume and mute, and `dvi_mode=0`. |
| Settings lost | Use **System → Save settings**. |
| How do I exit? | **System → Reboot**. Escape only closes menus. |

**Report a bug:** open a [GitHub issue](https://github.com/SplashDev88/NDS4MiSTer/issues) or post in the [NDS4MiSTer Discord thread](https://discord.com/channels/647909397477195803/1315734482317344860). Include your **core version, game name and region, ROM serial/game code, video output and layout**, plus what happened and how to reproduce it.

[Join the MiSTer FPGA Discord](https://discord.gg/misterfpga).

---

## Optional: real DS firmware boot

This is experimental, and you don't need it for games. **Boot DS firmware** starts the actual DS menu, using your own dumps placed in `games/NDS/`:

| File | Size | CRC32 |
|---|---|---|
| `bios7.bin` | 16,384 bytes | `1280F0D5` |
| `bios9.bin` | 4,096 bytes | `2AB23573` |
| `firmware.bin` | 262,144 bytes | Structure is checked instead |

Most real firmware dumps fail the touch-calibration check. Games can't be launched from the firmware menu.

---

## Credits & license

GPLv3 — see [LICENSE.txt](LICENSE.txt).

Thanks to **FPGAzumSpass**, **srg320**, **ElectronAsh**, **Corn**, **skmp**, **heni**, **Nitro_DarkSide**, the **melonDS team**, **InsaneFriend**, **apeekaboo**, **Mr. Moro** (RetroTINK-4K profiles), **Gilead Kutnick** (FreeBIOS), and every tester. Full third-party credits are in [THIRD_PARTY.md](tools/standalone_host/THIRD_PARTY.md).

Developers: build instructions, source audit and open questions are in [AUDIT.md](AUDIT.md).
