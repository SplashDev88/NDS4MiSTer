# NDS4MiSTer standalone frontend

See the [project README](../../README.md), [quick start](../../docs/STANDALONE_QUICK_START.txt), and [release notes](../../docs/RELEASE_NOTES_V090_RC4.md).

Build this frontend using `build.sh`. Its menu options are generated from the included FPGA CONF_STR; the release label comes from `VERSION`. The accepted FPGA and renderer are separate components. `supervisor.py`, `Kickstart.sh` and `NDS4MiSTer.sh` supply the matching launch and recovery behavior. See [THIRD_PARTY.md](THIRD_PARTY.md) for font and MiSTer menu attribution.

Offline checks: `python3 -m unittest discover -s tools/standalone_host -p "test_*.py"` from the repository root, plus the C++ test programs in this directory (including `test_storage.cpp` and `test_host_storage.cpp`). These tests use a fake SPI bus; they do not operate hardware.

## Controller motion sensors

Motion-sensor devices are ignored automatically. This keeps DualSense and
DualShock 4 gyro reports from overwriting the right-stick stylus position,
including small sensor changes while the controller is resting. The regular
gamepad, keyboard and mouse remain available; no motion setting is required.
The filter uses the Linux `INPUT_PROP_ACCELEROMETER` device property, rather
than excluding a controller by name or USB/Bluetooth ID.

## Experimental DS firmware support

In this release, `Load *.NDS` uses the built-in FreeBIOS and
generated firmware, with **MiSTer** as the default nickname. Games do not need
supplied BIOS/firmware files. When a valid saved GUI profile exists, only its
nickname, birthday, favorite color and language are shared into the generated
game profile. Games always keep built-in touch calibration. Missing or invalid
optional settings fall back without modifying the saved copy.

`Boot DS firmware` optionally opens the native GUI using `bios7.bin`,
`bios9.bin` and `firmware.bin` together in the selected games folder, or a
separate folder reached through **Boot DS firmware** and its `..` entries. Originals stay read-only;
saved personal settings use `/media/fat/saves/NDS/firmware.bin`, directly alongside
normal game saves. Its preceding copy is `firmware.bin.previous`; the session
lock is `firmware.bin.lock`. Atomic-write temporary files (`firmware.bin.tmp.*`
and `firmware.bin.previous.tmp.*`) use the same `saves/NDS` directory. The old
`saves/NDS/firmware/firmware-working.bin` path is not read or imported. These old paths were used only in private experiments; no public migration
is needed.
The stock `games/NDS/firmware.bin` remains read-only. The native calibration
guard and durable-save checks remain in force.
An active failed save must be resolved before switching away from the GUI.

Use the matching release host/core pair; the host refuses to release
a game if the core lacks the required direct-profile acknowledgement. See
[the firmware protocol and limitations](../../docs/DS_FIRMWARE_PROTOCOL.md).

## Games and BIOS browsing

**Load *.NDS** starts in the last games folder you browsed. Select `..` at the
top to go up, then enter another folder normally. From the root of a storage
device, `..` opens the mounted-device list, where you can enter SD (`fat`), USB
or network storage. The device list's `..` returns to the NDS menu. There is no
separate Storage menu or folder-selection command.

While a game is running, **Load *.NDS** instead opens that game's folder with
the running ROM highlighted and scrolled into view. Other folders start at
the top. The highlight lasts only for the current session: a fresh core launch
starts at the top of the remembered folder.

**Boot DS firmware** boots directly from its remembered folder when all three
files are available. Otherwise it opens the browser (or the device list if the
drive is unavailable), without holding the running game. Select
`firmware.bin` to boot, with `bios7.bin` and `bios9.bin` alongside it. Its first
use starts in the games folder. Merely browsing never boots the firmware or
modifies originals. Normal games retain the built-in BIOS and generated firmware.

Each browser saves its location automatically, including across restarts;
**Save settings** is not needed. On first game use, a single discovered
`games/NDS` folder on mounted storage opens automatically. Multiple or no matches
open the device list. An unavailable remembered games location offers Retry, Browse
and Back; firmware opens the browser. Neither erases the preference.

Saves and saved personal firmware stay on SD in `/media/fat/saves/NDS`.
Locations use `/media/fat/config/NDS_storage.cfg`; Recent Files share the MiSTer
list plus `NDS_recent_locations.cfg` in that config directory for drive identity.
The previous test candidate's root/last-subfolder preferences remain readable.

Devices must already be mounted. No shares or network configuration are changed.
USB UUIDs under `/dev/disk/by-uuid` let a remembered folder follow its drive if
`usb0`/`usb1` changes; without a UUID it uses the saved mount point. Network
locations also remember the mounted share source. Missing Recent Files remain
listed but cannot be loaded.

Directory and original-firmware reads run in a disposable worker, remain
cancellable and time out after 15 seconds. ROM transfers keep their existing
slow-network reader. FPGA, renderer, clock and gameplay scheduling are unchanged.

## Private lid and microphone beta

The `v0.9.0-rc.4-lidmic-beta.4` package retains beta.3's FPGA and adds **Lid: Open
(Close)** / **Lid: Closed (Open)** to the NDS menu. Select that row to toggle.
Alternatively, press **F10**, or assign **Toggle Lid** in System → Define
NDS buttons. One press closes it; another opens it. Opening the OSD preserves the
lid state so that a closed game can still be reopened from the menu.

Hold **F11**, or the optional **Blow into Mic** controller binding, to produce
synthetic blowing noise. Release it for silence. This is a button-driven input,
not speech recognition or a physical microphone. The two optional assignments
follow Cycle Video Layout in the standalone button wizard; existing mappings
remain usable and the new controller actions begin unassigned.

Fresh launches, new ROMs, firmware boots and resets start with the lid open
and the mic released. Lid state is never written into display settings. The
mic is silent while the menu is open. Lost input events and disconnected
controllers release held inputs.

The FPGA supplies ARM7 EXTKEYIN lid state, the lid-open IRQ22, and touchscreen
ADC channel 6 microphone samples. HALTCNT Sleep also pauses ARM9, the LCD
raster and both CPU timers until an enabled ARM7 interrupt wakes the console.
The memory fabric remains active to finish outstanding transfers and deliver
wake input. Ordinary ARM7 Halt still leaves ARM9 running. Renderer, clock,
performance settings, and the active-ROM browser highlight are unchanged.

Run `tools/test_lid_mic_vhdl.sh` for guest SPI/interrupt checks. The authored
`tools/diagnostics/lid_mic` ROM reports lid state, sleep/wake counts and mic
sample levels on screen without game assets or save/firmware writes.
`tools/test_console_sleep.sh` checks ARM9 pause/resume with delayed memory
responses and includes the previous ARM7-only behavior as a negative control.
