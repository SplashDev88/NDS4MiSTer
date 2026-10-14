# NDS4MiSTer v0.9.0-rc.7-split.8.6 beta

Controller mapping now waits for a complete press/release before moving to the
next prompt. Held analog triggers, jitter and overlapping digital/axis inputs
cannot advance successive prompts or save an unfinished map. Cancel and
disconnect retain the previous map; the saved map format is unchanged.

Games and native DS firmware now share a working RTC calendar. It starts from
MiSTer local time, survives game reset and loading, and automatically persists
completed DS clock edits. Relaunch includes elapsed time while the core was off.
All games in an installation share that clock. MiSTer's system clock is unchanged.

Native analog output automatically shows an independent Main or Touch screen at
240p. HDMI/DV1 has its own layout. DV1's CRT target uses a single screen; the
Scaler target enables combined layouts. Existing settings are retained, with
automatic output normalization for older configurations. Normal HDMI and
explicit scaled VGA remain available.

The package uses the normal `NDS4MiSTer` launcher and hidden `.NDS_Standalone`
folder. Follow the included README for backup, upgrade and rollback. This beta
contains a matched FPGA and ARM host; the renderer and 1 GHz ARM setting are
retained. The manifest identifies the binary source revision separately from
the release-documentation and packaging revision.

## Verified behavior

Software checks cover calendar dates, BCD and hour modes, leap/month/year
rollover, reset, coherent clock-domain snapshots, guest writes, durable offsets,
failed-write retry, malformed settings and the mapping release rules.

Actual MiSTer checks on these runtime binaries include native firmware clock
edits, clean restart persistence, leap day and century wrap. Animal Crossing
showed the correct time and the new date after midnight; White 2 changed from
its saved season to Summer in October and Autumn in November after leaving
a building. These are bounded checks, not full timed-event or playthrough tests.

Native analog, HDMI and DV1 CRT paths have been observed through RetroTINK-4K.
See the accompanying qualification report for the exact final-package matrix,
installation results and additional RTC tests; do not infer unlisted hardware
coverage from these examples.

## Known limits

- Static timing has setup/recovery violations and incomplete constraints.
  Routing and bounded hardware tests passed; wider stability is unqualified.
- Physical analog triggers, USER/OSD buttons, CRTs and adapters need coverage
  beyond synthetic input and the connected capture rig.
- Native output is about 59.64 Hz. PAL-TV acceptance requires support for that
  timing; no PAL 50 Hz mode is provided. SS1 composite/S-video has not been
  requalified on this build.
- RTC alarm/periodic interrupts, oscillator trim, DSi RTC commands and
  save-state clock restoration are not implemented. Local-time or timezone
  changes affect the next launch; see GAME_CLOCK.md.
- Slowdown, uneven animation, graphics errors and crashes remain possible.
  Strange Journey can freeze in its intro; GTA: Chinatown Wars can clip near
  the camera. No complete compatibility or unique-frame-rate claim is made.
- USB/HDD behavior has less hardware coverage than SD and the mounted CIFS share.

For a bug report, include the beta version, game, video connection and steps to
reproduce. If the picture is black, first check Main/Touch or Screen Peek.
