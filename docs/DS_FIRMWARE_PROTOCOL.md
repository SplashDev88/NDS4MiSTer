# DS firmware protocol — v0.9.0-rc.2

This document describes the firmware interface and personal-settings storage in
the standalone release. DS support remains experimental; compatibility and menu
performance vary. User-supplied BIOS and firmware images are not distributed
with the source or release package.

## Game boot and optional firmware GUI

`Load *.NDS` always boots games with the built-in redistributable FreeBIOS pair
and generated firmware. The built-in default nickname is **MiSTer**. Supplied
BIOS or firmware files are not required for games and are never their boot or
SPI firmware source.

`Boot DS firmware` is the optional native firmware GUI. It uses the user's
supplied BIOS pair and the saved firmware working copy. Its file validation,
calibration guard and durable-save requirements apply to that GUI path.

Games share only four personal settings from a valid saved GUI user copy:
nickname, birthday, favorite color and language. These fields are projected
onto the generated defaults in both user pages, with new CRCs. The direct-boot
RAM profile uses the same first 112 bytes. Calibration, clock settings, alarm,
message, other settings flags, firmware code and Wi-Fi data are not imported.
Games retain the built-in virtual-touch calibration.

Reading personal settings does not import native media or require the original
images. If the optional working copy is absent, unreadable or has no usable
personal data, games use built-in settings and a nonblocking menu notice. This
fallback never repairs or overwrites the saved file. Leaving an active GUI
session still requires its pending writes to reach durable storage; a real
persistence failure blocks that transition rather than discarding settings.

## Asset and control interface

Existing cartridge indices 3, 0x103 and 0x303 are unchanged. Firmware FIO indices:

- 4: ARM7 BIOS, exactly 16 KiB, 16-bit little-endian words.
- 5: ARM9 BIOS, exactly 4 KiB.
- 6: native GUI profile, exactly 120 bytes: 32-bit user-settings offset,
  32-bit firmware checksums (data CRC low, GUI CRC high), then the selected
  0x70-byte user block from the supplied working image.
- 7: direct-game profile, exactly 512 bytes: two generated 256-byte user pages,
  including their counters and CRCs, with only the four shared fields applied.
  The loader receives the first 112 bytes. Its generated-image metadata is
  user offset 0x0001FE00 and firmware checksums 0x00000000.

Asset downloads are only valid while the firmware controller holds the console.
Each transferred halfword crosses to the owning clock through an acknowledged
mailbox; `ioctl_wait` applies until accepted. For index 7, acknowledgement also
waits through the generated store's registered write stage. Readiness must not
precede the last actual RAM commit. A completed exact-length download marks
that asset ready. Partial or oversized downloads do not mark it ready. Index 6
and index 7 readiness are distinct; starting either clears stale profile state.

IO command 0x45 is the firmware control/status extension. The command
word returns 0x4657. Three following words return flags, pending persistence
sequence, and error code. The first transmitted data word selects an operation;
the second carries its argument. Query transmits all zeros.

- 0: query only.
- 1: hold console for a boot transition.
- 2: commit native firmware boot; requires BIOS7, BIOS9, profile and mounted
  firmware. Native mode runs with no cartridge.
- 3: commit direct boot after the cartridge transfer, built-in BIOS restoration
  and a completed index 7 upload. It cannot consume a native index 6 profile.
- 4: request a complete firmware-cache flush.
- 5: acknowledge a firmware write durably committed by the host; argument is
  the pending sequence. Stale acknowledgements must have no effect.
- 6: report host storage failure; hold the console and preserve dirty cache.

Flags: bit0 held, bit1 native mode, bit2 BIOS7 ready, bit3 BIOS9 ready,
bit4 profile ready, bit5 firmware clean/idle, bit6 firmware mounted,
bit7 error, bit8 persistence acknowledgement pending, bit 9 direct-game profile
ready. The host requires bit 9 before releasing a game, so an older core that
ignores index 7 cannot silently launch with stale profile data.

## Firmware storage

Slot 0 retains cartridge saves. Slot 1 supplies the 256 KiB native firmware
working image using normal 512-byte hps_io sectors. The FPGA keeps a small
sector cache, rather than consuming hundreds of M10Ks for a complete image or
allocating a new unreviewed DDR bank. Cache hits complete within the existing
SPI-byte busy interval; cache misses extend busy until the data arrives.

The slot-1 write transaction only transfers bytes. It does NOT mean durable
storage. The cache stays dirty until the host atomically commits the sector to
its working image and sends operation 5 with the matching sequence. Firmware
status polling and reset/switch flush checks wait for this acknowledgement.
Original dumps are read-only; the working image has a recoverable prior copy.

The initial working-copy seed never replaces an existing destination. On
filesystems that support it, it uses an exclusive rename. MiSTer's tested
exFAT filesystem rejects `renameat2(RENAME_NOREPLACE)`, so unsupported-flag
errors fall back to creating the destination with `O_EXCL`, copying from the
already-synced recovery file, and syncing the destination and its directory.
An interrupted or failed first copy retains the complete recovery file and
does not silently reseed an existing partial destination. This fallback only
applies to initial creation; later durable firmware commits retain their
atomic replacement path. An exclusive media lock prevents two hosts from
owning the same working image.

The two slots have separate LBA and payload sources. Refill writes carry the
slot ownership delayed to match hps_io's data strobe; they are not broadcast
to both caches. The native cache uses an explicit Cyclone V dual-port RAM:
Quartus 17 did not infer the required read-during-write behavior from arrays.

SPI selects the mounted working image only in native GUI mode. A mounted but
inactive image cannot become a game's SPI source. Direct games use the writable
generated store; game writes do not persist into the native working image.
Each game load/reset restores both generated user pages and the built-in BIOS
pair while held. Returning to the GUI restores the supplied BIOS/native profile.

The default generator emits SPI initial data, the host's generated profile
header and the loader's fallback words from the same pinned synthetic image.
It applies the project nickname locally without editing vendored melonDS.
Both CRCs are recomputed. The previous loader's empty nickname and legacy
0x0007FE00/0x0000FFFF metadata have been replaced with the generated image's
actual defaults and metadata. Public FreeBIOS initialization and restore
assets contain no personal profile and remain unchanged.

## Native menu and clock

`Boot DS firmware` starts the native BIOS with no cartridge present. Both
graphics engines are always enabled for native firmware and games. The former
Engine B menu option is removed, and its legacy saved setting is ignored.

The host seeds the clock once per standalone session through IO 0x22, using
four little-endian halfwords containing BCD bytes: year, month, day, weekday
(Sunday zero), hour (24-hour), minute, second, zero. The existing hps_io RTC
toggle commits the bundle. A seed clears RTC power-loss bit 7, following
melonDS. Keeping that bit set was verified to force first-time setup and
discard the host date. Subsequent guest resets preserve the seeded clock.

RTC date changes survive guest reset, but are not retained across standalone
relaunch. Alarm interrupt generation and arbitrary physical touch-calibration
curves are not implemented in this release. The GUI guard requires the
supported ADC=pixel*16 calibration and preserves unsupported input unchanged.
This restriction does not apply to game loading: games use generated calibration.
The GUI RTC is selected only in native mode; its date/settings are not among
the four fields shared into games.

## Optional user-supplied assets

Originals are read from the folder selected in the `Boot DS firmware` browser.
When a remembered location contains all three original files, the menu action
boots it directly. Otherwise it opens the browser; unavailable devices open
the device list. File availability is checked in the cancellable reader before
any CPU hold or firmware writes. Original validation still precedes boot.
The user selects `firmware.bin`; `bios7.bin` and `bios9.bin` must be beside it.
The browser supports parent navigation across mounted SD, USB and network
storage and remembers its own folder. That location is independent of the
remembered game folder. Read-only discovery and original-file reads happen in
a cancellable child, leaving SPI and heartbeat ownership in the main host.
Neither browsing nor validation writes to those original files.

These three files are optional and used only by `Boot DS firmware`; missing
or invalid originals produce a visible error for that action and do not make
them prerequisites for `Load *.NDS`. The supported inputs are the standard
16 KiB/4 KiB BIOS pair and bootable 256 KiB DS/DS Lite firmware. The working
copy lives alongside game saves at `/media/fat/saves/NDS/firmware.bin`, with a
recoverable `firmware.bin.previous` copy and a `firmware.bin.lock` ownership
file in the same directory. Temporary commit files also stay in that save
directory. No firmware subdirectory is created under either `games/NDS` or
`saves/NDS`. An existing working copy stays authoritative and is not reseeded
when original input files change. Legacy nested working-copy paths are not
imported automatically.

The three original input files stay read-only. None of these personal files
belongs in the source or release archive. The public FreeBIOS initialization
and restore assets remain generated from the existing audited source.

## Validation and limits

The accepted FW1 baseline underlying this release has completed bounded hardware
checks of native health/menu/touch operation, personal-settings persistence,
native-to-game transitions, and direct Castlevania and White2 boot. A dedicated
guest inspector also checked the complete 112-byte generated profile handoff.
These checks establish the tested paths, not compatibility with every game or
complete native firmware functionality. Menu transitions can still be slow.

Local checks cover generated MiSTer defaults and both CRCs, all 28 loader words
and metadata, four-field-only projection, missing or invalid optional input,
original-data preservation, native persistence failure, built-in restore and
direct-ready rejection. Store/SPI and control/CDC checks cover configuration
capture and commit, byte masks, both pages, subsequent guest writes, and native
versus direct mode selection. RAM mapping and selected hardware behavior were
checked separately; behavioral simulation alone is not proof of physical timing.

This release changes frontend storage browsing and remembered locations;
the firmware protocol, FPGA and renderer are unchanged. Successful compilation is not timing
closure, and a short display-publication comparison is not a measurement of
guest frame rate or overall game speed. RTC alarm interrupts and arbitrary
physical touch calibration remain outside the supported implementation.

Private dumps, saved profiles and oracle inputs are excluded from public source
and release packages.
