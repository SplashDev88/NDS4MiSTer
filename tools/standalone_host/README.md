# NDS4MiSTer standalone frontend

See the [project README](../../README.md), [quick start](../../docs/STANDALONE_QUICK_START.txt), and [release notes](../../docs/RELEASE_NOTES_V090_RC1.md).

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
separate folder selected through **System → Storage → BIOS/firmware folder**. Originals stay read-only;
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

## Games and BIOS storage (experimental candidate)

**Load *.NDS** remembers the selected games folder and the last subfolder you
browsed, across restarts. On first use it checks `games/NDS` on mounted SD, USB
and network storage. One matching folder is selected automatically; when more
than one is found you choose once. If none is found, choose a device and browse
to any folder. You can also select a device's root, such as `/media/usb0`.

Change it later through **System → Storage → Games folder** or **Change location**
at the top of the game browser. Choose a device, enter the desired folder and
select **Use: …**. Choices save automatically; **Save settings** is not needed.

By default, **Boot DS firmware** looks for `bios7.bin`, `bios9.bin` and
`firmware.bin` together in that games folder. **System → Storage → BIOS/firmware
folder** selects a separate location; **Use games folder for BIOS** restores the
default. Normal games continue to use the built-in BIOS and generated firmware.
The originals are read-only.

Cartridge saves and saved personal firmware remain on the SD card in
`/media/fat/saves/NDS`, even when a game or original firmware is on USB/network
storage. No save migration occurs. Locations and the last browsed subfolder
are stored separately in `/media/fat/config/NDS_storage.cfg`. Recent Files keep
the shared MiSTer list and a companion `NDS_recent_locations.cfg` in that same
config directory to remember drive identities.

USB and network devices must already be mounted by MiSTer. This feature does
not mount shares or configure networking. When filesystem UUIDs are available
under `/dev/disk/by-uuid`, the saved location follows a USB disk even if its
`usb0`/`usb1` number changes. Otherwise it uses the saved mount point. Network
locations also remember the mounted share source.

An unavailable saved location offers **Retry**, **Browse…**, and **Back**. It does
not erase the saved preference or silently select another drive. Directory and
original-firmware reads run in a disposable worker so a slow/disconnected share
does not block the menu or heartbeat. Those reads time out after 15 seconds and
can be cancelled; normal ROM transfers keep their existing slow-network reader.
Missing Recent Files stay listed but cannot be loaded. The FPGA, renderer,
clock setting and gameplay scheduling are unchanged in this candidate.
