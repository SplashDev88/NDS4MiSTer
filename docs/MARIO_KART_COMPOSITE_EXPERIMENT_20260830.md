# Mario Kart composite ARM 3D experiment (2026-08-30)

This branch applies the Mario Kart profiling recommendations in dependency
order. Each retained stage must preserve the existing 256-command replay
boundary, frame admission/drop policy, save handling, touch/mouse behavior,
audio, FPGA clock, and video output.

## Stages 1-3: retained

1. The kickstart supervisor moves only a single, unambiguous MiSTer frontend
   process from CPU1 to CPU0 while the 3D service is active. The original
   affinity and PID epoch are restored on stop. Worker placement is unchanged.
2. Packed vertex replay batches exactly three commands only when doing so cannot
   cross the established 256-command boundary. Commands 0x22 through 0x28 have
   exact external-replay dispatch paths with the stock melonDS path as fallback.
3. Temporary mode counters measured a bounded Mario Kart demo run. Of
   10,799,561 polygon scanlines, 73.04% were opaque, 0.74% translucent, 13.61%
   shadow-mask, and 12.61% shadow. Texture formats 3 and 5 accounted for 47.17%
   and 23.19%, respectively. Front-facing less-than depth accounted for 86.22%.
   Cached modulate accounted for 7,957,557 scanlines, 99.1% of which were
   opaque. This justified two exact fast paths: direct less-than depth dispatch
   and the mathematically identical opaque-alpha result for cached modulate.

The diagnostic run observed no replay faults and a queue high-water mark of 19.
Normalized geometry flush cost fell from 243.126 to 225.164 microseconds per
flush (7.39%). Packed GX replay cost fell from 1,173.68 to 1,088.29 nanoseconds
per command (7.28%). Other aggregate raster totals came from different demo
segments and are not claimed as stage-specific speedups.

## Stage 4: shadow four-band execution intentionally omitted

The four-band renderer cannot safely run shadow frames without reconstructing
ordered, per-scanline stencil state. Consecutive shadow-mask polygons share a
two-row parity stencil buffer and `PrevIsShadowMask` controls when each row is
cleared. A worker starting a later band therefore cannot derive the correct
state from geometry alone without an ordered prefix pass or duplicated raster
work. Either approach would add substantial work and needs a separate design.

The existing correctness gate remains unchanged: any shadow-mask or shadow
polygon selects the exact adaptive two-worker fallback. A deterministic oracle
test now marks a real polygon fixture as shadow-mask plus shadow, requests the
four-band scheduler, verifies that the fallback counter increments, and compares
the visible plane and complete native color/depth/attribute buffer hashes with
the single-worker melonDS renderer.

## Stage 5: changed-tile copy measured and rejected

An exact 16-pixel changed-tile copy prototype compared the newest safe private
publication buffer, copied only different tiles, and retained a fused alpha
scan. In the bounded Mario Kart run it examined 6,789,120 tiles: 5,669,831
(83.51%) changed and only 1,119,289 (16.49%) could skip a write. The destination
reads and comparisons cost more than they saved.

A controlled follow-up restarted the same demo/core with the same composite
service. The existing fused full-copy path averaged 2.044 ms over 1,214 copies.
An adaptive variant used 43 sparse probes and 1,058 full copies, but still
averaged 2.086 ms over 1,101 copies: 2.04% slower per copy. Scene work outside
the copy loop varied, so the decision uses only normalized copy cost. The
prototype is intentionally not retained. Existing identical-frame republish
already avoids the entire copy when the renderer proves a frame unchanged.

## Validation

- Deterministic packed replay state and vertex-RAM comparison against melonDS.
- Four-band non-shadow plane and native-buffer hash oracle.
- Shadow fallback plane and native-buffer hash oracle.
- Controlled full-copy versus changed-tile-copy live measurement.
- Existing service, save-profile, supervisor, and HPS lifecycle host tests.

## Follow-up: pre-race track-preview flashing

Mario Kart DS otherwise plays well on public beta.6, but the track-preview
sequence immediately before a race shows heavy flashing. Do not classify this
as ordinary renderer slowdown until the display behavior is measured. The
sequence may use alternating screen ownership or display capture at an
effective 30 FPS, or it may expose genuine missing/blank 3D publications.

Reproduce the preview in both this core and melonDS, then correlate each flash
with `POWCNT1`, `DISPCAPCNT`, VRAM capture-bank routing, GX flush completion,
produced and accepted 3D-plane generations, and the final plane selected for
display. Verify whether the two native DS screens intentionally alternate and
whether enabling real Engine B changes the symptom before adjusting frame-drop
or pacing policy.

No ROM, save, private path, or captured binary is stored in this branch.
