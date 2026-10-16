# Complete-frame publication experiment — 15 October 2026

This experiment converts complete screen pairs directly into an inactive
write-combined output bank. The native Cortex-A9 benchmark reduces publication
time by about 35%, or 0.47 ms per pair, with exact pixels. This is a reduction
in one pipeline stage, not a 35% increase in game speed.

The baseline is performance revision `1a6d9e0fda1d93eae987fb4e6398eb92057a8572`.
Its palette optimization, bug fixes and offline RTC host remain included. The
FPGA, clocks, per-game drawing cadence and melonDS renderer sources are
unchanged. The tested helper SHA-256 is
`39bde3a55fd2c1ab90dfed5b696eb41bbae10203a230e25b04733e809e6a7e25`.

## Implementation and correctness

`FullFramePublisher` previously converted each screen into a private packed
buffer, then copied it to shared output memory. The WC path now uses a NEON
load/convert/store loop and does not allocate that intermediate buffer. Both
packed melonDS pixels and AARRGGBB framebuffers produce the same BGR666 words.
The Device-memory fallback retains the existing staged conversion and copy.

Bank selection, descriptor acknowledgement, sequence overflow protection,
session/quiesce checks and the post-upload completion barrier are preserved.
Both screens finish before the descriptor becomes visible. No additional
queueing or independent 2D/3D frame publication is introduced.

The dedicated oracle compares 6,291,456 pixels, including exhaustive 18-bit
colors, random discarded/alpha bits, both formats, both paths, unaligned
sources and four-bank rotation. It checks source immutability, padding and
inactive banks, rejection without acknowledgement, invalid ownership and
sequence wrap. Injected resets after pixel upload must prevent descriptor
publication and must not advance the bank selection. Native-host tests,
AddressSanitizer/UndefinedBehaviorSanitizer, ARM-target tests and the full ARM
service self-test pass. The physical Cortex-A9 oracle, including the reset
injections, also passes.

## Native write-combined benchmark

The game was stopped, the normal menu was active and the publication region
was mapped through the existing verified WC module. A private header was
used; no FPGA descriptor or control page was modified. The benchmark ran on
CPU0 at 1 GHz with GCC 13.3, Cortex-A9/NEON, `-O3` and static linking. Four
source pairs avoid a tiny source working set. Each baseline/candidate/
candidate/baseline invocation takes three samples of 512 publications after
64 warm-up publications. Timing includes the completion barrier. Every output
pixel is checked after each sample, outside its timing interval.

| Input format | Baseline median | Fused median | Time reduction |
| --- | ---: | ---: | ---: |
| Packed melonDS RGB | 1.336 ms | 0.870 ms | 34.86% |
| AARRGGBB | 1.303 ms | 0.874 ms | 32.91% |

There are six samples per path and format. Baseline/candidate ranges do not
overlap. Clock state and module state were restored after the benchmark.

## Live NSMB measurements

The first quiet World 2-5 pair advances the HUD timer by 172 units in
129.181 seconds for the baseline and 129.080 seconds for the candidate.
That 0.08% difference is below HUD quantization and does not establish a
whole-game speed increase. Across two runs per binary in baseline/candidate/candidate/baseline order,
both timers advance 391 units: 293.703 seconds for the baseline and 293.385
seconds for the candidate. The aggregate 0.11% difference remains below HUD
quantization. All four isolated-save comparisons are unchanged and all sampled
core/helper fault words are zero.

Existing causal traces correlate records by session and LCD frame. In the
retained quiet-scene overlap, the first baseline/candidate pair contains
509/436 complete chains:

| Same-frame interval, median | Baseline | Candidate |
| --- | ---: | ---: |
| Observed input line zero to replay admission | 0.584 ms | 0.580 ms |
| Admission to completed screen pair | 17.710 ms | 17.739 ms |
| Completed pair to upload start | 0.079 ms | 0.078 ms |
| Upload | 1.345 ms | 0.929 ms |
| Observed input line zero to upload completion | 19.755 ms | 19.326 ms |

Upload p95 falls from 1.506 to 1.017 ms in that overlap. A second candidate
run gives a 0.931 ms median upload. Independent upload begin/end pairs remain
usable even when the corresponding intake records have been overwritten.
Across the four runs, excluding five seconds at each snapshot boundary,
median uploads are 1.347/0.926/0.931/1.394 ms in ABBA order (3,565/3,562/4,615/
4,622 samples). Mean completed-publication spacing stays about 33.43 ms for
all four runs. Publication cadence is not a count of unique displayed images.

The untrimmed first candidate window includes one 18.1 ms upload outlier
0.82 seconds after the starting snapshot. The snapshot tool continues checking
owner/protected-file hashes after its timestamp. The boundary exclusion avoids
including that observer work in steady-scene comparisons; all untrimmed
measurements are retained, and this does not prove the cause of the outlier.
No sustained upload regression appears in the repeat. These results establish
a stage saving, not elimination of every hitch or an increase in displayed FPS.

The recorder overwrites old events. The analyzer explicitly reports retained
ranges and incomplete chains rather than treating them as zero-duration work.
Input timestamps observe records after acquisition; they are not original
FPGA VBlank timestamps. Admission-to-ready includes raster waiting, 2D work
and interleaved replay, so it is not an isolated renderer CPU measurement.
Upload completion also precedes FPGA scanout and is not input-to-photon latency.

## Output checks and limits

The first NSMB control/candidate captures through analog RGB and RetroTINK-4K
contain active audio and no OBS render or encode drops. Both versions complete the repeated-jump check with no capture drops. Their
inspected moving-region cadence is similar (median/p95 change gaps about
33.3 ms); the region also contains animation/landing pauses and capture noise.
No obvious composition fault appears in the inspected frames. Capture input cadence
is still not calibrated: a 60 Hz recording container cannot establish 60
unique displayed frames per second. No whole-game FPS increase is claimed.

Castlevania: Dawn of Sorrow USA revision 0 completes the same bounded
prologue movement/attack script on control and candidate, with the displayed
clock advancing from 31 to 39 seconds. Both isolated saves are unchanged and
sampled core/helper fault words are zero. Both analog/RetroTINK captures have
active audio, no OBS render/encode drops and no obvious composition fault in
the inspected frames. Median upload is 1.465 ms on control and 0.970 ms on the
candidate (125/138 upload samples during their input windows).

Enemy position, damage and experience differ between the Castlevania trials.
Completed-publication spacing also differs (about 60.6 versus 55.8 ms mean),
but this is not a matched workload and does not establish an FPS gain. These
are short compatibility checks, not full playthroughs or broad game coverage.
The retained optimization is supported by exact output tests and repeatable
native publication measurements, with bounded live-game regression checks.

## Reproduction and next work

Build `nds_full_frame_publication_test` and run it on the host and target.
`nds_full_frame_publication_bench` is excluded from the default build. Its
no-argument mode uses cached RAM. `--wc-menu` explicitly requests the physical
WC region and rejects an active standalone core or renderer lease. Run it
only on the isolated, stopped MiSTer rig with the matching module and clock
setup; cached or emulated timings are not WC/Cortex-A9 performance results.

`tools/analyze_frame_timeline.py` reads existing binary causal reports and
accepts `--start-ns`/`--end-ns` to select a known scene window. Its regression
tests cover exact intervals, session separation, incomplete retention,
duplicate/reversed events and malformed reports.

The next measurement work is to distinguish raster waiting from 2D work and
record FPGA-side packet age. Test packet-memory mapping and smaller packet
commits separately once those measurements identify a cost. Existing packet
chunks already cap at 1,024 records; this experiment does not change their ABI.
