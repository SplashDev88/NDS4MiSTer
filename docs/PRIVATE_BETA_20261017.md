# Private beta freeze — 17 October 2026

**Castlevania Beta12 (C55 worker range)** is the selected runtime for
`NDS4MiSTer_Private_Beta_20261017.zip`. This is a focused private testing package,
not a new public GitHub Release or a promotion over the general Performance
Beta6 baseline. The optimization series is paused for review.

The final change permits a 40% primary-worker share for the verified Castlevania
profile. It passes both live target gates and the NSMB throughput control.
The earlier native snapshot costs remain disclosed.
[Full final comparison](CASTLEVANIA_LIVE_BALANCE_FOLLOWUP_20261017.md).

## Install and rollback

1. Exit the current core with **System → Reboot**. Back up `saves/NDS` and your
   existing launcher/hidden kit, including settings and `NDS_rtc.cfg`.
2. Verify the supplied ZIP SHA-256 sidecar. Extract the ZIP at the SD root,
   including hidden files. It adds `Scripts/NDS4MiSTer_Private_Beta_20261017.sh`
   and `Scripts/.NDS_Private_Beta_20261017`.
3. Run **Scripts → NDS4MiSTer_Private_Beta_20261017**, then **Load *.NDS**.
   Keep its launcher and matching hidden folder together. The retained host
   version label may still say rc.8; the dated launcher/manifest identify this beta.

This is a new kit with fresh display/controller/RTC defaults. Global MiSTer.ini
and shared storage preferences still apply. If retaining compatible settings,
exit both kits first and copy only the chosen settings/maps; do not mix program
files or manifests. Copy `NDS_rtc.cfg` if you want the same edited DS clock.
Saves remain shared in `saves/NDS`, even for USB/network ROMs. Do not rename ROMs.
No ROMs, BIOS/firmware dumps, user settings, maps, saves or kernel image are bundled.
Publication WC modules for Linux 5.15.1-MiSTer and 6.18.38-MiSTer are included.

To roll back, exit cleanly and run your previous launcher. Preserve current saves.
Prior kits keep their own settings. Public rc.8 cannot read the v2 offline RTC
format: retain its old clock-file backup or move the v2 file aside and set MiSTer
local time before reverting. See [Game clock](GAME_CLOCK.md).

## Included since public rc.8

- **Castlevania rendering work:** exact texture/rectangle/back-facing/gray-overlay
  paths, skipped inactive color composition, unchanged Engine-B background writes,
  exact prepared-sprite composition reuse and profile-specific raster scheduling.
  Other cartridges retain their established paths where changes are scoped.
- **Full-rate NSMB drawing**, with frame skipping off; palette conversion reuse,
  neutral-color raster work and fused conversion into WC output banks.
- **Offline RTC startup:** an unusable MiSTer date starts at January 1, 2000;
  guest edits persist and convert safely when valid host time becomes available.
- **Inherited bug-fix experiment:** flash page wrapping/long save transfers,
  ARM9 VRAM-control and OAM readback, geometry backlog preservation, GX DMA pause-
  edge handling and queue-fault detail. The bitstream retains its recorded opt-in
  SWAP/HBlank/GX-busy build settings. This does not claim the issue backlog solved.
- Separate analog/digital layouts, release-aware controller mapping, touch
  rotation, synthetic blowing input and persistent DS clock behavior are retained.

See [bug-fix evidence](BUGFIX_EXPERIMENT.md), [architecture](architecture.md)
and [developer guide](DEVELOPMENT.md) for scope and inherited limitations.
The freeze retains the existing FPGA and host binaries and clock rates.

## Measured improvements and limits

Selected staged comparisons, all source publication throughput:

| Accepted step | Cave | Warg combat | NSMB control |
| --- | ---: | ---: | ---: |
| Beta10 vs Beta9: prepared-sprite reuse and unchanged BG writes | +10.018% | +15.332% | -0.541% |
| Beta11 vs Beta10: Castlevania adaptive scheduling | +2.386% | +3.935% | +0.762% |
| Final 40% range vs Beta11 | +2.493% | +1.836% | +1.055% |

These comparisons used different run batches and variable enemy phases; do not
add their percentages or present them as a controlled rc.8-to-freeze result.
Publication throughput is not distinct animation FPS. **60 fps has not been
achieved.** Average gains do not guarantee every tail gap, input response or
whole-game scene improves. Audio was present; fidelity is not certified.

The selected binary inherits full ARM-service and exact-output qualification,
profile transitions, delayed-worker controls and source correspondence. The final
package must also pass checksum/archive inspection, fresh installation through
its actual shell launcher and formal/visual restoration before delivery. Its
local delivery receipt records those final gates separately from this source
freeze. No new HDMI/DV1/CRT compatibility sweep is implied by these analog tests.

The packet-input Normal-NC change is excluded after an NSMB regression. Earlier
failed pixel, packet-validation, sprite-row-cache and global scheduling prototypes
are excluded. See the [audit handoff](CLAUDE_AUDIT_HANDOFF_20261017.md) for the
rejected approaches and questions that remain.

Remaining limits include slowdown, uneven animation, audio hitches, graphical
faults and crashes; unresolved FPGA timing closure; incomplete long-session and
multi-board coverage. Native analog is about 59.64 Hz, with no PAL 50 Hz mode.
RTC alarms/interrupts, save states, wireless, physical microphone input, NAND
saves and DSi mode remain unsupported. Offline powered-off time needs usable
system time to be recovered.

## Frozen component identities

The ZIP manifest gives the immutable freeze commit and per-component source
revisions. BUILD_PROVENANCE.json records compiler flags, environment, explicit
FPGA QSF overrides and inherited/new validation. BUILD_SOURCE_INPUTS.json is the
851-entry original renderer input inventory; RENDERER_SOURCE_INPUTS.json describes
the corresponding reviewed tree. Their sole allowed difference is the unlinked
GameQueryProfileTest.cpp test. Documentation changes do not rebuild the helper.

| Component | SHA-256 |
| --- | --- |
| ARM helper | `5510089f11be99c2bf56e80bca4cc784ccbbc418ce951514d78d352140a151a8` |
| Standalone host | `6b63736edbe4b82821edd2dfe460a731281ddfd5ae0d27f51cb88d0a4cdf192f` |
| FPGA core | `3d0516778d0805ddef8da30e3ef01d55d4d6fed5ed677fb16036ca56ef1fdfee` |

Host source: `db09fc5cee49ccca4e9e3b9b71e65ba303836607`.
FPGA source: `32c31cd94b5a5734b6c034e8647d2a4924e990ae`, plus the recorded
`NDS_GX_SWAP_RETIREMENT_EXPERIMENT=1`, `NDS_HBLANK_RUN_QUEUE_EXPERIMENT=1`
and `NDS_GX_BUSY_STATUS_EXPERIMENT=1` QSF overrides. Use the packaged input
manifest; source defaults leave these experiments off. Routing and assembly
passed, but static timing is not clean. ARM helper uses GCC 13.3, Cortex-A9
NEON hard-float, static Release -O3/LTO, JIT off and audio mixing off.

The supervisor is the accepted implementation with exact core/helper pins
substituted by packaging. Kickstart, clock control, video recovery and modules
remain byte-identical to the accepted Beta11 package. The private launcher has
a dedicated kit path. The outer checksum covers documentation and all payloads.

For the next review, paste [the Claude handoff](CLAUDE_AUDIT_HANDOFF_20261017.md)
and provide access to this source revision. No further optimization is queued.

The final public scheduler/range sources were freshly compiled against the
qualified ARM core and passed 768 complete-buffer comparisons, including 192
actual delayed wakeups. PUBLIC_TEST_QUALIFICATION.json records their hashes;
the original full-service and 320 saved-scene checks remain inherited.
