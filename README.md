# NDS4MiSTer — v0.9.0-rc.15 (Beta)

Play Nintendo DS games on MiSTer FPGA.

[**Download RC15**](https://github.com/SplashDev88/NDS4MiSTer/releases/download/v0.9.0-rc.15/NDS4MiSTer_v0.9.0-rc.15_Standalone.zip) · [Compatibility list](https://docs.google.com/spreadsheets/d/1HNx41BC4jj3XQ-pzT3D9oJNnD20f9ZzkurHLMI3L-Is/htmlview) · [All releases](https://github.com/SplashDev88/NDS4MiSTer/releases)

> **Beta:** compatibility, speed and sound vary by game. Full speed is not guaranteed, and graphics-heavy scenes can slow down even in games that otherwise run well.

**How it differs from other cores:** NDS4MiSTer is a hybrid core and full package launched from **Scripts**, not a lone `.rbf` in `_Console`. While you play, it temporarily takes over from the normal MiSTer menu, and it hands control back when you exit.

---

## What you need

- MiSTer (DE10-Nano) with **SDRAM**
- **Uncompressed `.nds`** files. ZIPs are not supported.
- A controller or keyboard. A mouse helps with touch-heavy games.

**No BIOS or firmware files are needed** to play games.

---

## Install

1. Download the [RC15 ZIP](https://github.com/SplashDev88/NDS4MiSTer/releases/download/v0.9.0-rc.15/NDS4MiSTer_v0.9.0-rc.15_Standalone.zip).
2. Extract **everything** to the SD card root, merging folders. Include the hidden `Scripts/.NDS_RC15/` folder, because the core won't start without it.
3. Put your games in `games/NDS/`.
4. Add an `[NDS]` section to `MiSTer.ini` for your display (see [Video setup](#video-setup)). On HDMI you can skip this step.
5. Run **Scripts → NDS_RC15**.

Do not move the `.rbf` to `_Console`. Installing through `update_all` is not supported yet.

**Upgrading from RC14:** first back up `saves/NDS`. Saves carry over to RC15. Settings do not carry over automatically: to keep them, copy the `NDS_*.cfg` files and `inputs/` from `Scripts/.NDS_Standalone/` into `Scripts/.NDS_RC15/`.

---

## First run

1. Launch **Scripts → NDS_RC15** and press Enter.
2. If your controller needs mapping, go to **System → Define NDS buttons**.
3. Choose **Load \*.NDS** and pick a game. Some games take longer the first time they load while a cache is built.
4. **For better speed:** set **Display options → 3D Anti-aliasing → Off**, then **System → Save settings**.
5. When you're done, choose **System → Reboot** to return to MiSTer. Do this before powering off.

---

## Controls

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
| F12 or Select + Start | Menu |
| Hold F10 | Peek at the other screen (single-screen layouts) |
| Hold F11 | Blow into mic |
| USER button | Reset game |

You can also map **Screen Peek**, **Blow into Mic** and **Cycle Video Layout** to controller buttons. To close the DS lid, open the menu and select **Lid**.

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

Settings go in the `[NDS]` section of `MiSTer.ini`. After changing them, return to MiSTer and relaunch.

### HDMI (start here)

```ini
[NDS]
direct_video=0
dvi_mode=0
video_mode=8        ; 1080p60 — or keep your current mode
vsync_adjust=0
vga_scaler=0
```

### CRT (15 kHz, via Direct Video)

Use this with an HDMI-to-VGA DAC driving an RGBS/SCART CRT:

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
- Pick **Main** or **Touch** as the layout. Hold F10 to see the other screen.

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
- For TATE mode, use the core's rotation option in **Display options** and turn off the scaler's rotation function.
- Connect the scaler **directly**: splitters may prevent a scaler from locking onto the DV1 signal properly.

The RetroTINK-4K is tested. Morph is untested over Direct Video but should work fine.

**RetroTINK-4K profiles:** Mr. Moro's [profile pack](https://github.com/SplashDev88/NDS4MiSTer/releases/download/v0.9.0-rc.15/NDS4MiSTer_RetroTINK4K_MrMoro_Profiles.zip) includes **NDS Default** and **NDS Rotate**. Copy the contents of its inner `NDS4MiSTER` folder to the root of the RetroTINK-4K's SD card.

### Layouts and rotation

Find these under **Display options**:

| Option | Choices |
|---|---|
| Digital Layout | Top/bottom (default), Side-by-side, Main, Touch |
| Screen Order / Gap | Swap screens; 0–24 px gap |
| Video Rotation | Off, 90 CW, 90 CCW |
| Touch Rotation | Usually leave Normal |
| 3D Anti-aliasing | Off = faster |

**Vertical (TATE) monitor:** start with Top/bottom and rotate the picture opposite to the way you turned the monitor. For a monitor turned clockwise, use **90 CCW**. Leave Touch Rotation on Normal.

Save your choices with **System → Save settings**.

---

## Audio

Set volume in the normal MiSTer menu **before** launching. The core otherwise has no audio settings of its own. HDMI audio needs `dvi_mode=0`.

---

## Saves

Saves are written automatically to `saves/NDS/<ROM name>.sav`. They are standard raw `.sav` files.

- **Import a save:** use a raw `.sav` of the correct size, renamed to match your ROM's filename. `.dsv` and save-state files won't work.
- **Before powering off:** wait for the game to finish saving, then choose **System → Reboot**.
- Two ROMs with the same filename share one save, even if they're in different folders.
- **Back up** `saves/NDS/` and `Scripts/.NDS_RC15/NDS_rtc.cfg` (your in-game clock).

---

## Known issues

- Slowdown, stutter, graphics glitches and audio hitches still happen.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Black screen or nothing starts | Re-extract the full ZIP, including `.NDS_RC15`. Launch from Scripts. |
| `Mismatched package file: NDS_speed.cfg` | Restore that file from the RC15 ZIP (caused by the Reset settings bug). |
| BIOS error | Use **Load \*.NDS**, not Boot DS firmware. |
| A game won't boot | Use an unmodified, uncompressed ROM on the SD card. Check the compatibility list. |
| Stuck loading | The first load can take minutes. Network or USB storage is slower than SD. |
| No CRT sync or squeezed picture | Check: CRT target, Main/Touch layout, rotation Off, `vga_scaler=0`, `forced_scandoubler=0`. |
| Only one screen on scaler | Set **Direct Video Target → Scaler** and a two-screen layout. |
| No audio | Check MiSTer volume and mute, and `dvi_mode=0`. |
| Settings lost | Use **System → Save settings**. |
| How do I exit? | **System → Reboot**. Escape only closes menus. |

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
