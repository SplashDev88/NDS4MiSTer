# NDS4MiSTer standalone frontend

See the [project README](../../README.md), [quick start](../../docs/STANDALONE_QUICK_START.txt), and [release notes](../../docs/RELEASE_NOTES_V090_RC4.md).

Build this frontend using `build.sh`. Its menu options are generated from the included FPGA CONF_STR; the release label comes from `VERSION`. The accepted FPGA and renderer are separate components. `supervisor.py`, `Kickstart.sh` and `NDS4MiSTer.sh` supply the matching launch and recovery behavior. See [THIRD_PARTY.md](THIRD_PARTY.md) for font and MiSTer menu attribution.

Offline checks: `python3 -m unittest discover -s tools/standalone_host -p "test_*.py"` from the repository root, plus the C++ test programs in this directory (including `test_storage.cpp` and `test_host_storage.cpp`). These tests use a fake SPI bus; they do not operate hardware.

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
