# NDS4MiSTer v0.9.0-rc.1

**Standalone launch, larger games, and the original DS firmware menu.**

## Install and play

1. Exit any running standalone session. Extract this ZIP to the root of your
   SD card, merging **Scripts**. Include the hidden **Scripts/.NDS_Standalone**
   folder; enable “show hidden files” if copying extracted files manually.
2. Run **Scripts → NDS4MiSTer** and wait for the NDS menu.
3. Choose **Load *.NDS** and a game from **games/NDS**.
4. Use **System → Save settings** to keep your options.

There is no separate Kickstart step, Console launch or five-minute window.
**System → Reboot** returns to normal MiSTer without power-cycling the board.
The normal MiSTer installation is still required, but an older NDS release is
not. Existing normal NDS/Kickstart files remain available.

This update replaces standalone's program files. Games, saves, settings and
`MiSTer.ini` stay in place. Use all the support files from this release together.
Fresh settings use Top/Bottom with rotation Off; existing settings take priority.
Both graphics engines are always On. Normal NDS and standalone share cartridge
saves in **saves/NDS**; use the same ROM filename to keep its matching save.

The launcher requires a compatible kernel with write-combining and 1 GHz clock
control. Testing used **Linux 5.15.1-MiSTer**. It does not install a kernel or
change your INI. If it reports a requirement error, read the quick start below.

## Optional DS firmware menu

Normal games use built-in firmware with **MiSTer** as the default nickname.
External BIOS and firmware files are optional and are not included.

For **Boot DS firmware**, put your compatible **bios7.bin**, **bios9.bin** and
**firmware.bin** directly in **games/NDS**. The quick start lists supported
sizes and limitations. Your original files remain untouched; saved firmware
changes go directly into **saves/NDS/firmware.bin**. Nickname, birthday, favorite
color and language are shared with normal games. Touch calibration is not.

## More information

- [Release notes](RELEASE_NOTES.md): changes and known issues.
- [Quick start](QUICK_START.txt): controls, TATE/1080p, firmware requirements,
  slow network loading and troubleshooting.
- [License](LICENSE.txt): component notices are also inside the hidden support
  folder's **licenses** directory.

This is a release candidate. Games may slow down, hitch, glitch or crash.
It is not a promise of 60 FPS. For matching source and issue reporting, use the
[NDS4MiSTer repository](https://github.com/SplashDev88/NDS4MiSTer).
