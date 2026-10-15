# rc.8 validation and split.8.6 hardware results

Hardware qualification was completed 2026-10-14 on the split.8.6 candidate,
identified in [RELEASE_SPLIT86.json](RELEASE_SPLIT86.json). The rc.8 package retains
that FPGA, renderer and support modules. Its host was rebuilt only to change
CORE_VERSION to v0.9.0-rc.8; the implementation is unchanged. The launcher and
supervisor release labels and package documentation were also updated.

A control build reproduced the hardware-tested host byte-for-byte. The new host
passed the menu/version-footer tests; all 45 launcher and 10 package-auditor tests
passed. Component hashes and source revisions are in
[RELEASE_V090_RC8.json](RELEASE_V090_RC8.json). Hardware results below apply to the
pre-relabel candidate; no physical rc.8 retest is claimed. The final rc.8 ZIP is
separately checked for integrity, source correspondence, repeatable packaging,
and filesystem upgrade/rollback preservation.

## Installation and preservation

- An empty standalone support folder booted through the normal launcher.
- Upgrade from the published rc.7 package preserved display settings, controller
  mapping and a saved one-hour game-clock offset.
- Rollback restored all 35 pre-upgrade support files and the matching launcher
  exactly; the old frontend booted. A second upgrade also passed.
- Disposable tests covered repeated merges and preservation of settings, maps,
  saves, firmware, storage preferences and INI files.
- Repackaging from the packaging-source archive and qualified binary inputs
  reproduced the install ZIP exactly. FPGA recompilation was not performed.
- Original user saves and settings remained unchanged. Game tests used copies.

## RTC

Three RTC C++ suites, 45 launcher Python tests and 10 package-auditor tests passed.
Coverage includes all 36,525 supported calendar days, rollover, BCD/hour modes,
guest writes, persistence failures and retry, malformed settings, invalid system
time, a valid but incorrect system time, and correction after launch. A running
session keeps its clock; relaunch adopts the corrected system-time basis.

Software tests exercised UTC/Central timezones, both 2026 DST changes and 180
simulated offline days. Actual hardware retained the saved offset through
upgrade/rollback and a process-only timezone change. Adjusted clock progress was
218 seconds against 218.1317 monotonic seconds across a clean stop/relaunch.
This does not establish overnight or abrupt-power-loss behavior.

Earlier tests on the same runtime binaries covered native firmware clock edits,
clean restart, leap day and century wrap. Animal Crossing displayed the expected
time and date after midnight. White 2 refreshed its season after a building exit.
These observations do not qualify every game's timed events.

## Video and audio through RetroTINK-4K

| Output | Observed coverage |
| --- | --- |
| Native analog RGBS | Main/Touch, independent digital layout, 240p at about 59.64 Hz |
| Normal HDMI | All four layouts, CW/CCW rotation and rotated menu; 720p input on this rig |
| DV1 CRT target | Main/Touch, upright menu, 320x240 metadata, about 59.64 Hz |
| DV1 Scaler target | All four layouts; Side 520x192, Top/bottom 256x392, single 320x240 |
| Scaled analog RGBHV | All layouts and CW rotation at 1080p60; follows digital layout |

Native DV1 stays upright when the host's scaled-output rotation changes. Combined
DV1 layouts were inspected with RetroTINK's **1:1 (Sq. Pixel)** aspect correction;
the inherited 4:3 pixel-aspect setting stretched them. Screen Peek switched
screens while held and returned on release. No saved receiver profile was changed.

Approximately 20-second analog, HDMI and DV1 captures each contained active
48 kHz stereo with continuous decoded timestamps and no near-full-scale samples.
These are objective capture checks, not subjective listening or a guarantee that
every game's audio is free of hitches.

## Representative game comparison

Both builds used separate copies of the same original save, the same renderer,
native analog path and 1 GHz ARM setting. Paired samples lasted about 30 seconds.

| Game/scene | Beta frame events/s | Published rc.7 frame events/s |
| --- | ---: | ---: |
| New Super Mario Bros., W2-5 | 59.799 | 59.800 |
| Fire Emblem: Shadow Dragon, Prologue II map | 59.866 | 59.899 |

No crash or protocol fault occurred in these samples. Event counters do not
measure unique visual frames or input latency. NSMB's level timer advanced 37
counts on the beta and 38 on rc.7 over equal 28-second captured intervals. The
starting phases were not locked; this is a bounded pacing check.

Fire Emblem rendered map backgrounds, sprites and text. The beta also wrote a
new suspend point to its isolated save, exited cleanly, relaunched and resumed
the saved map/cursor. The original save remained unchanged.

## Remaining limits

- Static timing is not closed: setup -13.834 ns, recovery -14.351 ns, incomplete
  constraints. Successful routing and these observations do not remove that risk.
- One board and bounded sessions do not establish long-run or broad compatibility.
- Physical controller triggers, USER/OSD buttons, CRTs/adapters, PAL TVs and SS1
  composite/S-video still need current-build hardware coverage.
- F4 startup has software coverage and earlier hardware evidence, but the latest
  synthetic-keyboard hardware retest was inconclusive. Normal launcher boot passed.
- No overnight, power-cut, blank-SD, second-kernel or broad USB/HDD qualification
  is claimed. Native output is about 59.64 Hz; PAL 50 Hz output is not implemented.
- RTC alarms/periodic interrupts and save-state clock restoration are unsupported.

Source and package publication audits are separate from gameplay qualification.
