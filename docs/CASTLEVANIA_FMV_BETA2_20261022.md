# Castlevania FMV Beta2

22 October 2026. Private experiment on `experiment/castlevania-fmv-20261022`.

Beta2 brings the tested Dawn of Sorrow opening movie close to its intended image
cadence at the stock 1 GHz HPS clock. It removes the repeatable extra 300–500 ms
holds observed in the earlier Color3 beta's action sequence. The original movie
normally changes image about ten times per second; this is not a 60 FPS video.

Run **Scripts → NDS_FMV_Beta**, load **Castlevania: Dawn of Sorrow, USA revision 0
(ACVE)**, and wait at the title screen. The previous Color3 build remains available
as **NDS_FMV_Beta1**. Exit with **System → Reboot** before switching launchers.
Other ROM revisions retain their original code. This is a private beta, not a
public release or a general improvement to every game's movies.

## Changes since Beta1

The host replaces three identified guest-code regions in the staged memory copy
before boot. The source ROM stays read-only. These routines still execute on the
FPGA's emulated DS ARM9; no HPS video decoder, new FPGA build, or overclock is used.

- **Color conversion:** reuse unchanged chroma products and pixels with fewer
  comparisons and branches. Preserve the original wrapping arithmetic, clamp,
  RGB555 output, row strides, and alternate converter's shared literals.
- **Inverse transform:** collect nonzero coefficients once and calculate four
  outputs per traversal. Preserve modulo-32-bit sums and signed shifts. Aliased
  source/output buffers fall back to scalar traversal. A DTCM stack-depth guard
  avoids reserving the 512-byte scratch list below the established stack floor.
- **ADPCM audio:** remove dead stack writes and redundant sign extensions from
  the two-sample loop. Preserve valid-stream PCM samples, saturation, index
  clamping, state updates, and input/output access order.

`NDS_FMV_COLOR_FAST=1` retains its existing name and enables all three substitutions.
The normal host default is off; the private launcher enables it. Identity checks
cover the file size, game/revision/header, entire color-converter range, every
replaced byte, the containing audio routine and its tables. All validation occurs
before any mutation; a mismatch skips the entire optimization. The checked-in
assembly must reproduce the embedded replacement bytes exactly.

The final host adds a stricter audio-routine identity check to the hardware-tested
ADPCM1 host. Its three replacement payloads are byte-identical. This startup-only
guard does not change guest runtime behavior for the verified ROM.

## Measurements and image correctness

The earlier five disabled/baseline captures averaged **6.45 substantial movie
image changes/s**. Color3 averaged **9.38/s**. The Beta2 decoder reached approximately
**9.7/s** in the same fixed 37–89 second recording window. Those values use a
32×24 luminance detector with RMS threshold 2; startup alignment and image content
affect the exact count. They are not whole-game FPS or a direct rc.9 benchmark.

More useful than the small average increase is removal of the additional long
holds. Direct read-only framebuffer sampling bypassed the RetroTINK profile and
capture detector:

- All **6,260 sampled publications** matched a reference sparse RGB555 fingerprint.
- In the ordered first-movie segment, reference frames **1829–4473**, all **442
  image runs** appeared in order, with no omitted source transition.
- No measured hold in that segment exceeded its reference duration by more than
  **40 ms**. Across 440 complete paired holds (excluding the initial partial
  observation), the median was 100.4 ms and the 95th percentile 103.5 ms; the
  largest excess over the paired reference duration was 9.8 ms. Natural still
  frames and long source holds are preserved.
- A suspected missing image at reference frame 2356 was present. A nearby captured
  change fell below the luminance threshold; it was not an actual 200 ms freeze.

The probe hashes 32×24 sample positions, not every pixel. Full image correctness is
also checked separately in the software reference: 7,200 frames with the final
payload preserve all top-screen hashes and the sequence of completed bottom
images. The first partially scanned movie image changes timing/coverage, and the
fixed-duration run ends slightly farther into the movie. These are explicitly
excluded from a claim of frame-for-frame wall-clock identity.

A four-minute native run with the final color/transform pair covered multiple
movie loops. The source-aligned detector found 459–460 changes per loop window
versus 460 in the reference. Independently calibrated loop offsets are necessary:
title/loop gaps differ from the software reference and must not be interpreted as
in-movie audio drift. The final audio-loop variant has separate two-minute and three-minute native
captures. Their fixed-window detector rates are 9.67 and 9.63 changes/s; the
source-aligned counts are 460 and 459 versus 460 reference changes.
All reported captures are checked for transport faults and OBS drops.

## Audio validation

The original ARM audio loop, replacement, and scalar reference agree on
**6,448,284 PCM samples in 50,000 blocks**, covering all valid step indices,
saturation boundaries, random bytes, final state, and destination guards.
This test does not claim equivalence for corrupt ADPCM state outside index 0–88.

Native captured audio is compared with the software reference using 2-second
RMS envelopes and sampled 250 ms waveform windows. Median waveform correlation
is about 0.985. No unexpected silent 10 ms windows were found inside the qualified
soundtrack segments, where multiple high-confidence waveform matches establish a
stable offset. A synthetic 100 ms dropout in an audible section remains detectable
by the analysis; captured media are never modified for that control.

**Fades and title transitions remain outside that qualification.** Amplitude-
independent envelope matching produced a false 560 ms silence flag during the
second fade; the correct soundtrack offset shows the reference fading too. Using
the preceding soundtrack offset across the following title transition also
produces silence flags because the native/reference title start times differ.
Those unmatched transition flags are retained in the evidence, not erased or
reported as verified defects. The source-matched soundtrack intervals are reported
separately. Poorer waveform correlation in fades also means these checks do not
certify every transient or rule out every short click. Universally perfect audio
has not been established.

## Reproducible validation

```sh
bash tools/test_fmv_converter_equivalence.sh /path/to/unmodified-ACVE-rev0.nds
```

The caller supplies the private ROM. Extracted original routines and tables live
only in disposable Docker storage; no ROM, save, or captured media belongs in the
repository. The script checks assembled bytes against the actual staged payload.

- Color routine: **3,072,000 pixels / 12,000 blocks**, including signed extremes,
  overflow, repeated/distinct inputs, strides, and destination guards.
- Transform: **1,024,000 outputs / 16,000 cases**, including sparse/dense data,
  cutoff boundaries, signed coefficients/bases, and overlapping buffers.
- Transform stack: **160 calls** at boundary depths, checking the DTCM floor.
- Audio routine: the PCM/state checks described above.
- Staging contract: exact expected output, all-or-nothing rejection for changed
  code/tables/header/revision, short mappings, wrong file size, null mapping, and
  repeat application.
- Normal static Cortex-A9 host build with warnings treated as errors.

Short gameplay controls use isolated copies of saves. They compare Castlevania's
Warg room, NSMB World 2-5 repeated jumps, and Mario Kart's Figure-8 Circuit. Completed
screen updates and captured image changes are separate metrics; neither establishes
whole-game FPS. Small differences in these short samples are not speed-gain claims.
| Bounded scene | Baseline completed updates/s | Beta2 payload completed updates/s |
| --- | ---: | ---: |
| Castlevania Warg room, 6 seconds | 20.97 | 21.11 |
| NSMB World 2-5 jumps, about 20 seconds | 59.50 | 59.61 |
| Mario Kart steady barrier interval, 20 seconds | 28.04 | 27.94 |

No throughput regression is apparent in these short checks; they do not establish
statistical equivalence. Castlevania's final capture has fewer detector-visible
changes than earlier runs (27.91/s versus 36.94/s), but inspection shows different
player/enemy positions and knockback. That capture is not a matched animation
benchmark and must not be presented as a clean frame-pacing comparison. Mario
Kart's visible-change rate is 58.50 versus 58.87/s, with the same 16.7 ms 95th
percentile but a 50 versus 33 ms maximum. No transport or OBS drops occurred.
NSMB and Mario Kart both logged that the game-specific substitutions were skipped.

The color/transform candidate also passed Castlevania suspend and cold reload in
the same room (HP 85/132, time 1:13 before save and 1:16 after resume/pause).

## Identity, scope, and evidence

Source ROM SHA-256:
`3ddc8b0eac841b6005ff4c38a184b517fa8225ac905aad951b0572850358d8b0`.

Final host SHA-256:
`1520a8590ce85ab2a2ea0dcacf5c74497e73a8c9ca35dade856cb6ad7dfb059b`.

Installed kit: `/media/fat/Scripts/.NDS_FMV_Beta2_20261022`.
The regular release and Conquest launchers, FPGA/renderer, original ROM and saves,
MiSTer settings, and RetroTINK setup are retained. Inherited FPGA static-timing
qualification remains unresolved. Long gameplay sessions and other ROM revisions
are not qualified by this movie test.

Private evidence remains under `evidence/castlevania-fmv-20261022` in the testing
workspace. Key records are `FINAL_ALL_DECODER_EQUIVALENCE.log`,
`FINAL_CONTRACT.log`, `ADPCM1_ORACLE_COMPARISON.json`,
`ADPCM1_ON_A_RAW_ANALYSIS.json`, and the final Beta2 validation/install receipts.
[Earlier baseline and Beta1 measurements](CASTLEVANIA_FMV_20261022.md) remain
available for comparison.
