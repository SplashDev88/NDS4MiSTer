# Game clock — rc.9 / Beta12

Games and the DS firmware menu use the same RTC calendar. At the first game
or firmware boot, it starts from the MiSTer's local date and time. Set the
MiSTer clock correctly before launching; supported dates are 2000–2099.
rc.9 / Beta12 falls back to January 1, 2000 at midnight if MiSTer's
clock is unavailable or outside that range. The older rc.8 build instead
reports an error in that case.
No original BIOS or firmware dump is needed for games to read the clock.

The clock continues while loading another game, resetting the guest, using
the menu or closing the lid. It is seeded only once during a standalone
session, so those actions preserve edits made inside DS firmware or a game.

## Keeping clock edits

The host saves completed DS date/time writes automatically to `NDS_rtc.cfg`
inside its kit directory. It stores an offset from MiSTer local time and a
weekday adjustment. Relaunching adds time elapsed while the core was off.
All games in that kit share the clock. No MiSTer system-time setting is changed.
The host does not write this file on each tick, or when no guest edit occurred.
An edited offline clock also gets a checkpoint on clean exit or game switching.

To return to MiSTer local time, exit the core, remove that kit's `NDS_rtc.cfg`,
and relaunch. Keep this file when updating the kit. Resetting display/input
settings does not reset the clock. A malformed file is reported rather than
silently overwriting its saved clock setting.

Normal clock settings retain the `NDS-RTC-v1` format: a signed offset in seconds
and a weekday adjustment from 0 through 6, each on its own line. An edit made
during a fallback session uses `NDS-RTC-v2`, `offline`, and the seven decimal
calendar fields (year 0–99, month, day, weekday, hour, minute, second). This
stores the chosen date itself, avoiding a large offset from the fallback year
being added to a later synchronized MiSTer date. Updates use a temporary file,
file sync, rename and directory sync. A failed save retains the pending edit
for retry and shows an error; clean exit captures once more with the CPUs held.
A sudden power loss before a pending edit reaches disk can still lose that edit.
Changing MiSTer local time or timezone affects the next launch's clock basis;
it does not periodically overwrite the running DS clock.

## Offline time, synchronization and timezone changes

Internet access is not required. The clock uses the local date/time MiSTer
already has; a valid but incorrect system date is accepted as the starting
point. No internet-connectivity test is used. If the system date is unavailable
or outside 2000–2099, games and firmware can still boot: the default basis is
January 1, 2000 at 00:00:00, with any existing v1 offset applied. Without a
guest clock edit, the stored settings are left untouched and each fallback
launch starts from that basis again.

The fallback reference advances from a monotonic clock throughout that session,
even if MiSTer synchronizes later. Exit and relaunch to use the corrected system
clock. If a DS clock edit was saved offline, the next launch restores that date;
the first launch with valid MiSTer time converts it to the normal offset format
while preserving the chosen DS date. Subsequent launches then advance normally.
Elapsed time while powered off cannot be recovered without a usable system
clock. Offline edits resume from their last durable checkpoint; a sudden power
loss can lose time since that checkpoint.

The running DS clock does not jump when the host time or timezone changes.
On the next launch it uses the new MiSTer local time plus any saved offset.
Consequently a timezone or daylight-saving change can shift the next launch's
DS time, even if the core was stopped throughout the change. This is local
civil-clock behavior, not an independent UTC battery-clock model. Games may
apply their own rules or delays after clock changes. In White 2, an existing
save can initially show its previous season; the season refreshed when leaving
a building in the controlled retail-game tests.

Back up `NDS_rtc.cfg` before changing or removing it. rc.8 cannot
read a v2 offline setting: when rolling back, restore your rc.8 clock-file
backup or move the v2 file aside and set MiSTer's time first. A pre-RTC release ignores
this file; keep it for a later return to this beta. The supported workflow is
to exit cleanly before updating, restoring files, or changing clock settings.

## FPGA/host contract

IO `0x22` seeds seven BCD bytes plus zero padding: year, month, day, weekday
(Sunday = 0), canonical 24-hour hour, minute, second. The calendar handles
month lengths, leap years, midnight and the DS's 2099-to-2000 wrap. CPU serial
reads retain the DS's 12/24-hour and PM-bit conventions.

IO `0x47` provides coherent snapshots:

| Transfer | Host sends | FPGA returns |
|---|---|---|
| Command | `0x0047` | Signature `0x5254` |
| Operation | 0: read; 1: request a new capture | `0x0100` plus ready in bit 0 |
| Four words | zero | Seven little-endian BCD bytes plus zero padding |
| Two words | zero | Little-endian 32-bit guest-write sequence |

The immediate response to operation 1 belongs to the previous state. Poll
operation 0 until ready. Requests while busy are ignored. A request/ack mailbox
crosses the RTC/host clock domains; the returned bundle is latched for the
whole SPI transaction. The sequence counts completed guest date/time writes
and RTC software reset, including multiple writes between polls. It does not
count elapsed seconds or host seeds. The host references wall time at the
capture request, not at the later poll. This protocol also prevents an RTC
host from silently running against the old game-zeroing FPGA.

An explicit host SIGUSR1 diagnostic request includes `game_clock` in
`framebuffer-metadata.json`: decoded date fields, write sequence and monotonic
capture timestamps. All SPI operations remain in the standalone owner process.

## Scope and verification

This adds the game calendar and persistence. RTC alarm/periodic interrupts,
oscillator trim effects, DSi RTC commands and save-state clock restoration are
not implemented. Calendar access alone does not establish compatibility with
every time-sensitive game.

Automated checks cover all 36,525 civil days, leap/month/century rollover,
12/24-hour GPIO access, held resets, cross-clock coherent snapshots, multiple
edits per poll, single-session seeding, dates beyond 2038, offline advancement,
old-core rejection, malformed settings and failed-write retry. The host tests
also cover missing/pre-2000/post-2099 wall clocks, fallback ticking, late sync,
unchanged legacy settings, offline edits/checkpoints, failed checkpoint retry
and conversion to normal offsets. Run `tools/test_game_clock.sh` on Linux.
The original
hardware diagnostic is under `tools/diagnostics/game_clock`; its manual write
tests must use an isolated kit. Hardware qualification is recorded separately
from compilation and software test results.
