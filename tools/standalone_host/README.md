# NDS4MiSTer standalone frontend

See the [project README](../../README.md), [quick start](../../docs/STANDALONE_QUICK_START.txt), and [release notes](../../docs/RELEASE_NOTES_V090_RC1.md).

Build this frontend using `build.sh`. Its menu options are generated from the included FPGA CONF_STR; the release label comes from `VERSION`. The accepted FPGA and renderer are separate components. `supervisor.py`, `Kickstart.sh` and `NDS4MiSTer.sh` supply the matching launch and recovery behavior. See [THIRD_PARTY.md](THIRD_PARTY.md) for font and MiSTer menu attribution.

Offline checks: `python3 -m unittest discover -s tools/standalone_host -p "test_*.py"` from the repository root, plus the four C++ test programs in this directory. These tests use a fake SPI bus; they do not operate hardware.

## Experimental DS firmware support

In this release, `Load *.NDS` uses the built-in FreeBIOS and
generated firmware, with **MiSTer** as the default nickname. Games do not need
supplied BIOS/firmware files. When a valid saved GUI profile exists, only its
nickname, birthday, favorite color and language are shared into the generated
game profile. Games always keep built-in touch calibration. Missing or invalid
optional settings fall back without modifying the saved copy.

`Boot DS firmware` optionally opens the native GUI using `bios7.bin`,
`bios9.bin` and `firmware.bin` directly in `/media/fat/games/NDS` (or the configured
game root), not in a nested `firmware` directory. Originals stay read-only;
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
