# Castlevania linear-attribute experiment, 2026-10-17

The combined vertical-edge and bounded-attribute prototype was rejected. It improved the two Castlevania target rooms slightly, but its New Super Mario Bros. comparison exceeded the predeclared 1% regression limit. Castlevania Beta10 remains the accepted runtime. No runtime source was integrated and no new package or public release was created.

## Change and correctness

The private prototype combines a rectangle-only vertical-edge step with exact bounded linear interpolation of texture and color attributes. It skips unused horizontal-edge and perspective-factor work, while retaining invalidation and resynchronization when returning to generic interpolation. The attribute shortcut admits positive heights up to 512 and signed 16-bit endpoints, preserving ascending and descending DS rounding. Admission remains tied to the existing cartridge-qualified rectangle path.

Qualification passed 8,437,760 attribute comparisons, 1,262,688 edge checks and 11,328 generic resynchronization checks. Renderer checks passed 512 gray cases, 5,388 raster cases, 48 sequential snapshots and 160 parallel comparisons, including full color, depth and attribute buffers. Of the raster cases, 256 retain the legacy one-pixel compatibility oracle; 5,132 use the independent reference. The complete ARM service self-test passed in Docker. All 851 service source inputs were checked; only the two intended GPU renderer files differ at runtime. Temporary build-source overlays were restored.

The private helper SHA-256 is `2250b74cb24d898da388980d2da257794f2c4ebbc9283018d935308ca5f519b1`. The comparison helper is accepted Beta10, `a0ef8246dbdffd15cc861018f2604a969c0af18cd14ccec93de9d3eba56fd4dd`, runtime revision `f8fdb6948fee428958ff50606a96919025e9b7aa`.

## Measurements

Native renderer controls used six samples per build and scene. Median wall time changed by -3.632% in the cave and -4.201% in combat. NSMB castle, NSMB left and Mario Kart controls changed by -0.331%, +0.051% and +0.432%, respectively. Those results justified live testing but did not predict the live NSMB regression.

Live measurements used isolated saves, stock 1 GHz and baseline/candidate/candidate/baseline ordering. Cave windows last 22 seconds, combat windows 6 seconds, and NSMB windows 26 seconds with repeated jumps. Two valid runs per build and scene contribute to each mean.

| Scene | Beta10 mean publication pairs/s | Candidate mean publication pairs/s | Change |
| --- | ---: | ---: | ---: |
| Cave / bat platform | 21.67809 | 21.94482 | +1.23038% |
| Warg combat | 20.53852 | 21.05046 | +2.49256% |
| NSMB castle | 45.04699 | 44.47392 | -1.27215% |

These are completed source publication pairs, not distinct displayed frames or game animation FPS. The predeclared gates required gains above 1% in both Castlevania scenes and an NSMB loss no greater than 1%. The candidate fails the latter gate. Combat individual runs overlap and enemy phases vary, so its average does not establish a uniform improvement. Analog image-change counts are threshold-sensitive and do not establish smoother animation or exact FPS.

All twelve retained recordings have complete pictures, zero protocol faults, zero OBS render or encoder skips, audio presence, unchanged protected files and saves, and the stock clock. Audio presence is not a fidelity certification. No new HDMI or Direct Video qualification is claimed.

## Capture exclusions and harness corrections

The first NSMB candidate recording had one actual OBS encoder skip and remains excluded. Its replacement is retained despite being slower. Another continuation stopped before recording because the new output preflight treated an unavailable replay buffer as an error; it was retried with a fresh isolated save. A missing local navigation helper also caused an earlier stop before NSMB measurements. These stops and restoration receipts are preserved.

The harness originally subtracted OBS output counters across recording starts. OBS resets those counters when encoding starts, so a prior skip produced an impossible -1 for the otherwise clean replacement. The corrected analysis uses the current recording's absolute skipped-frame count, with a post-stop sample for new recordings, and requires no active stream or replay buffer. OBS's final recording log independently confirms zero skips for the replacement. The actual skipped recording remains excluded. Existing Beta10 acceptance captures were audited and all had zero before and after counts; their result is unaffected. This follows the versioned [OBS video counter implementation](https://github.com/obsproject/obs-studio/blob/32.2.2/libobs/media-io/video-io.c), [WebSocket statistics implementation](https://github.com/obsproject/obs-websocket/blob/5.7.4/src/utils/Obs_ObjectHelper.cpp), and [replay-buffer availability response](https://github.com/obsproject/obs-websocket/blob/5.7.4/src/requesthandler/RequestHandler_Outputs.cpp).

Two NSMB causal-timeline snapshots raced and were excluded from interval analysis. Their independent stable-header publication counts remain valid. No video, publication count, source flag or gameplay measurement was changed to obtain acceptance.

The original NSMB installation and save, all 54 protected files, stock clock, OBS configuration and restored game-selection menu passed final verification. Private reproducibility evidence remains in `castlevania-linear-attributes-performance-20261017`; ROMs, saves, recordings and user settings are not included in this report.
