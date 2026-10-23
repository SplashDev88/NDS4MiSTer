# Private FMV offload experiment — 2026-10-22

Private movie-test build. This is not a public release or a compatibility certification. The
ordinary build leaves `NDS4MISTER_EXPERIMENTAL_FMV_PACKED_COLOR` disabled.

## Scope and constraints

Continue from Castlevania FMV Beta2 on the existing FPGA image at 1 GHz. Test
Strange Journey USA (BMTE rev0), Ni no Kuni Japan (B2KJ rev0), Revenant Wings USA
(AXFE rev0), and Sonic Chronicles USA multilingual (YWSE rev0). Use exact-hash
guarded private copies of owned ROMs and isolated saves. Original ROMs, game
saves, user launchers, settings, and the public release remain protected.

The experiment moves movie color conversion, and subsequently Strange Journey's
postfilter, into the ARM renderer. The guest uploads planar data through the
existing ordered VRAM write transport; a complete header/payload/commit sequence
triggers conversion. This is not normal DS VRAM behavior: physical FPGA VRAM and
the renderer's RGB mirror differ. It must not be generalized to other routines
without dependency, transition, and gameplay checks.

## Findings so far

- Strange Journey's producer waits on an unsigned queue-depth comparison at
  `0208edc0`. Its audio/timer consumer can advance beyond the producer; a negative
  difference then satisfies the unsigned wait condition indefinitely. A signed
  comparison avoids that permanent wait, but the native packed-color B trial
  still held an image for **24.247 seconds**. That trial fails the smoothness goal.
- On the color-offload reference run, the postfilter accounts for **57.3% of
  sampled guest ARM9 instructions**. This is an instruction sample, not native
  wall-clock attribution. Deferring the filter is the next substantial candidate.
- The tested Strange Journey opening made 3,050 filter calls with no observed
  CPU/DMA reads of their surviving output outside the filter and color converter.
- Ni no Kuni made 6,144 VRAM word reads after movie conversion began. Tracking
  intervening writes found **zero reads of surviving converted pixels** in the
  tested opening; these reads followed fresh guest writes. This does not establish
  safety for later scenes or every graphics consumer.
- Revenant Wings C delivered the same 511-image segment in **47.656 seconds**, vs
  **54.814 seconds** on the prior Beta2 survey: 9.30 → 10.70 sparse image changes/s.
  This is about 15% faster for that segment, not whole-game FPS.
- The first Ni no Kuni B experiment offloaded one screen only. A matched
  625-image segment improved from **120.272 to 111.981 seconds**. The C implementation permitted intermediate uploads to become visible. D fixes
  this by retaining the previous RGB image until commit. D completed all three
  other openings without transport faults or OBS drops. Ni no Kuni still has few
  exact movie-hash matches against the baseline; adaptive filtering is a possible
  explanation, so the effect is not yet classified as a regression or a gain.

## Further Strange Journey experiments

- D's exact filter offload completed the intro, but its longest native hold was
  **23.779 seconds**. Instruction-share estimates did not predict the native
  stall well enough to claim a large improvement.
- E rebases the movie clock and zeroes queue counters only when the consumer
  finds the queue empty. Normal software-reference video is identical across
  all 9,000 observed frames. With controlled decoder slowdown, the signed-only
  control entered negative queue depth for 456 frames and held an image for
  8.04 seconds; E had no negative-depth frames or holds over five seconds.
- Native E completed the intro but still held the city image for **12.124 seconds**,
  and another image for 5.751 seconds. It fails the smoothness goal. It made
  2,001 color conversions, 1,426 of which used the deferred filter.
- The E helper now allocates transaction buffers lazily. The D native full
  self-test process was OOM-killed at 321,928 KiB anonymous RSS while at MENU;
  that is a fixture-suite limitation, not a recorded game crash. The E ARM
  binary passed the full suite under Docker/binfmt plus the exact filter/color
  tests. A native E full-suite pass has not been established.
- A clean capture avoids SIGUSR1 diagnostic dumps during playback. Its first
  run missed intro-start input because the startup guard observed a lease before
  its host field appeared; it is not an equivalent scripted intro comparison.
  The guard was corrected and the run repeated with a sparse RGB thumbnail probe.

## PCM audio hypothesis (private asset experiment)

The opening uses SX audio (codec 1), not FastAudio. Its original player also
supports PCM (codec 4). The reference decoder extracted all 70,284 channel
blocks, representing 4,498,176 samples per channel. Every compressed audio
packet was located exactly at the end of its original frame chunk. A private
repack preserves every compressed video byte and every decoded PCM sample,
combining two 128-sample SX blocks into each 256-sample PCM block.

The asset grows from 4,534,860 to 21,312,232 bytes. The software reference
completed all 3,060 movie frames; the entire distinct-image sequences matched
(3,524 top and 390 bottom images, including surrounding UI). Sampled soundtrack
segments correlate above 0.999996 after aligning a constant 1,251-sample earlier
start at 48 kHz. Native PCM-only F completed with 2,686 color conversions and no transport faults or OBS drops, but still held the city image for **9.542 seconds**. It fails the smoothness goal. This is not a distributable ROM
or a production host feature; no owned movie/audio bytes may ship in a package.

## Full MODSN3 decoder offload

FFmpeg 7.1.1's LGPL MobiClip decoder was compared with the original game decoder
before integration. After mapping FFmpeg V/U planes to the DS chroma layout,
**all 225,607,680 YUV bytes across 3,060 frames matched exactly**. A standalone
MiSTer benchmark at the established 1 GHz clock also matched every frame:
mean 1.230 ms, p95 2.269 ms, p99 2.542 ms, maximum 3.951 ms. The benchmark
restored the prior clock policy afterward. This is decode cost, not integrated
playback performance.

The private G protocol sends compressed packets to a bounded ARM decoder cache,
keyed by the guest's existing output-buffer address. The guest's audio decoder,
queue counters, filter selection, and display requests remain in control.
Cached YUV is filtered and converted only when the game asks to display it.
The underlying FPGA VRAM is still synthetic, so the same dependency caveat applies.

The owned private opening has a 16-byte descriptor inserted into each frame;
video and SX audio data remain unchanged. The descriptor supplies original
consumed length, quality, and sequence. All 3,060 lengths and quality indices
were independently reproduced by FFmpeg bit-position/quantizer metadata,
removing any need to ship captured proprietary state. Other movies fall back
to their original decoder because they lack the descriptor signature.

The full integrated software reference decoded and displayed all 3,060 movie
frames with zero protocol errors. All 3,524 baseline top-screen images and 390
bottom-screen images match in order; the faster candidate reaches one additional
briefing animation image at the end of the fixed 9,000-frame observation. An
ARM differential protocol test passed 150,405,120 output pixels, including
postfiltering, six-buffer reuse, and atomic visible-image updates.

G was initially compiled with different LTO/audio-mix options from the existing
helper and failed a geometry-discard self-test. Its hardware run is exploratory,
not a controlled performance comparison. H restores the established LTO=ON and
NO_AUDIO_MIX=ON build options and passes the full helper self-test under
Docker/binfmt. H completed two opening playback checks and a skip-to-briefing check. The
full H run decoded/displayed all 3,060 movie frames, with 3,054 filtered frames,
zero decoder errors, zero transport faults, and zero OBS render/encode drops.
There were no image holds over five seconds. Among 2,794 matched moving-image
transitions, the median interval was 33.799 ms, p95 35.267 ms, p99 37.902 ms,
and maximum 64.940 ms; none were delayed by more than 50 ms relative to the
source interval. These measurements exclude authored still frames.

The fitted movie clock scale was 1.000007354; the audio clock scale was
1.000007908. Across 968 nonquiet 100 ms soundtrack windows, no dropouts were
detected; median normalized waveform correlation was 0.9959. These are bounded
source/capture comparisons, not a whole-game or perceptual perfection guarantee.
The skip test reached the briefing, accepted subsequent input, and exited
cleanly. Neither G nor H is a packaged user beta.

FFmpeg is currently an external, minimal static build under local evidence.
Any distributable integration must include its applicable licenses, source and
build/patch instructions. No movie, soundtrack, or ROM bytes may be distributed.

## Correctness checks

Private tests compare the original ARM instructions extracted from the owned
ROMs against the new C++ output. Those extracted binaries are local evidence,
not redistribution artifacts.

- Three original color routines, five destinations (including Sonic's 16 KiB
  offset), **23,592,960 pixels**: exact output and surrounding VRAM preservation.
- Whole reference intros: 3,060 SJ, 2,622 Ni no Kuni, 1,216 FF12, and 2,012 Sonic
  conversion calls matched expected output and preserved callee-saved registers.
  Some automatic intros repeat during the observation; these are call counts.
- Postfilter, modes 0/1/2 and 41 quality indices, **14,155,776 output bytes**:
  exact horizontal and vertical filtering against the original ARM routine.
- Combined deferred filter/converter, **6,291,456 pixels**: exact results,
  materialization of a previous pending filter, and original-routine fallback
  for unsupported color dimensions. A separate test checks that each staged
  upload leaves visible RGB unchanged until commit.

## Prototype placement and invalidated trials

Early probes placed code in what appeared to be unused secure-area padding.
That area contains BIOS SWI wrappers. **Those trials are invalid** as correctness
or performance evidence. Their files remain only for audit history.

Valid loader probes add an explicit SDK autoload section at `01fff000`, preserve
the secure area's first 0x800 bytes exactly, and relocate the ARM9 ROM image into
verified unused tail space. Ni no Kuni's converter resides in overlay 13, so its
owned overlay copy is patched explicitly. Full original/candidate hashes and
byte-level patch receipts are retained. No original ROM is modified.

## Ni no Kuni dual-stream decoder

The standard MobiClip decoder differed from the original game on a small number
of pixels. Instruction-level tracing located unchecked clamp-table reads in
the original decoder: negative residuals can read neighboring game data rather
than mathematical zero. A private FFmpeg extension accepts a **bounded 4,096-byte
window copied from the guest**, reproducing those reads without embedding any
proprietary table in the helper. Out-of-window accesses return a decoder error.

All 2,634 raw YUV frames now match the original decoder exactly. An interleaved
ARM protocol test passed **129,466,368 output pixels**, including two streams
with deliberately overlapping buffer keys, six-buffer reuse, filtering, and
atomic visibility. The updated SJ protocol test also passes 150,405,120 pixels.
The current helper passes the full self-test under Docker/binfmt with the
established LTO and audio-mix configuration.

Private J descriptors preserve the original keyframe bit and original consumed
byte count. Its complete 12,000-frame software run has 2,634 decodes, 2,622 color
conversions, and zero decoder errors. Every distinct displayed image matches
the prior packed-color reference in order. Relative to the unmodified software
reference, the movie sequences match; surrounding UI timing causes a few extra
or differing animation frames. This is not a claim of cycle-exact execution.

The J hardware capture contains the complete two-screen opening and return to
the title screen. The user reported **“ni no kuni looks perfect.”** The authored
opening rate is **12 FPS**, not 30 or 60 FPS. A 90-second soundtrack comparison
contains 900 nonquiet 100 ms windows, zero detected dropouts, median normalized
correlation 0.9768, and fitted clock scale 1.000012857. Timing residuals range
from -2.026 to +2.168 ms. This audio-only check does not independently establish
lip-sync.

The host exited cleanly just before the timed recording window ended and the
supervisor restored MENU, but subsequent investigation found that recovery was
triggered by a **renderer crash**, not a normal user exit. Native runs J A and
J B both faulted in `_int_free` while unreferencing an FFmpeg packet, at displayed
DS frames 12,776 and 12,802 respectively. Both crash reports have fault address
0x450. The opening's visual and audio results remain useful, but **J is not a
stable user beta**.

A native hardware watchpoint subsequently caught the corrupting write. LCDC
writes to banks E-I entered `GPU::ApplyPackedColor`; `PackedColor::Write`
rejected those unsupported banks, but the caller still indexed the four-entry
`DirtyAll` array. That out-of-bounds access cleared bytes in adjacent transaction
pointers. A later bank snapshot then overwrote the malloc arena header. The
packet free was the victim, not the source of the corruption.

Candidate O rejects banks outside A-D before accessing either the transaction
receiver or its dirty flags. An integration regression allocates all four movie
transactions and performs byte, halfword and word LCDC writes to E-I, checking
both staging pointers and ordinary VRAM data. The unfixed ARM test crashes;
the corrected test and full renderer suite pass under Docker/binfmt. The FPGA,
guest clock and decoder math are unchanged by this correction.

Native O subsequently completed **480 seconds**, with 7,600 decodes, 7,568
cached conversions, zero decoder errors, 2,400 fault-free transport samples,
zero OBS render/encode drops and an ownership-checked clean exit (host code 0).
The recording includes two complete openings and most of a third, passing the
former failure at the next movie start. First-pass matched transition medians
are 83.77 ms on both screens; second-pass medians are 83.75–83.76 ms. Neither
pass has a matched transition delayed more than 50 ms beyond its source
interval. Fit each movie separately: title-screen idle timing shifts the
inter-movie offset and should not be interpreted as decoder slowdown.

The same 90-second soundtrack window contains 900 nonquiet 100 ms windows,
zero detected dropouts, median normalized correlation 0.9788, minimum 0.7029,
and clock scale 1.000004660. This is a bounded stability and playback pass;
skip-to-gameplay and full-game qualification remain separate.

The original collectors lost their in-memory telemetry and thumbnail output
when the renderer disappeared; those runs are not full automated transport or
cadence passes. The OBS recordings are retained. The collectors now preserve
partial output and stop recording on termination. Stale decoder-counter files
are explicitly excluded. A longer 20,000-frame software run completes two movie
passes without errors, and a separate ARM worker-thread test completes four
passes (10,536 exact decoded frames), so those tests alone do not reproduce the
native crash.

## Chrono Trigger and older VX movies

Chrono Trigger USA (YQUE rev0) was added at the user's request. Its opening is
`movie/op_ds.mods`, MODSN3 at about 15 FPS. All 2,345 decoded frames match the
original software decoder exactly. Private K patches overlay 8 and adds the
guarded decoder/converter autoload section while preserving the keyframe bit.
All 3,203 distinct upper-screen images match the software reference in order;
lower-screen differences concern the timing of the blue gears/ellipsis UI.
The tested opening has no surviving CPU/DMA reads of converted VRAM.

Two native K captures each contain 1,150 telemetry samples, zero transport
faults and zero OBS rendering/encoding drops. Each matches 2,174 moving-image
transitions in source frames 960–10,200: median interval 67.01 ms, p99 about
70.5–70.7 ms, and maximum 73.4–74.5 ms. No matched transition is delayed by more
than 50 ms relative to the reference. Authored still frames are excluded.

In the same 115-second soundtrack window, the baseline has 117 low-correlation
100 ms windows that instead match another iteration of the approximately
475.4 ms audio buffer. Both K captures reduce that count to zero. Minimum
normalized correlation rises from 0.0061 to 0.7349 and 0.7945; median correlation
is 0.9792 and 0.9801. No silence dropouts are detected. This is evidence of a
repeatable improvement in streamed audio, not a whole-game perfection claim.
These initial captures did not qualify transitions or longer native sessions.

The final helper O also completed a 230-second capture through the new private
game-selection launcher: 4,444 decodes, 4,428 cached conversions, zero decoder
errors, 1,150 fault-free transport samples, zero OBS drops and clean exit. The
same 2,174 transitions have median 67.02 ms, p99 70.28 ms, maximum 73.35 ms and
zero excess delays over 50 ms. The movie-clock fit is 1.000005859. The soundtrack
check contains 1,150 nonquiet windows, zero detected silence dropouts, median
correlation 0.9795 and minimum 0.5568. The 27 lower-correlation windows produce
zero matches at another audio-buffer iteration, using the same repeat detector
that found 117 in the baseline. Input returned the game to its Touch to Start
screen. This is opening/title coverage, not a full-game test.

Sonic Chronicles and Revenant Wings use the older VX codec. An isolated local
comparison build imports Librempeg's GPL-3.0-or-later VX decoder from commit
`4e9475a2e2f8b64605b77025ff793da26fcf1b3e`. All 608 frames on each Revenant Wings
opening screen, and all 600 frames on each Sonic opening screen, match the
original decoder's YUV bytes and consumed-byte counts in sequence.

The combined helper passes its self-test and the existing MobiClip protocol
tests. The VX receiver test covers 3,632 frames (178,520,064 pixels), repeated
stream resets, overlapping keys, six-buffer reuse, atomic writes to four VRAM
banks, the 16 KiB output offset, and invalid codec/sequence/quantizer/stream
rejection. A fresh dependency build from the repository patch passes the same
tests on both native macOS and a fresh ARM cross-build. Source provenance,
licenses and build tooling are under `third_party/fmv`,
`licenses/fmv` and `tools/build_fmv_ffmpeg.py`.

Sonic private M completes the software opening with 1,200 cached conversions
and no decoder errors. Revenant Wings private N completes 1,216. Neither
tested movie has surviving CPU/DMA reads of converted VRAM.

Revenant Wings N with helper O completed two native opening loops in a
180-second check: 2,432 decodes/conversions, zero decoder errors, 900 fault-free
transport samples, zero OBS drops and clean exit. The authored movie is 12 FPS.
For the same 509 upper and 499 lower matched transitions (source frames
700–3,450), the prior Beta2 median interval was 100.6–100.8 ms and p99 about
135.5 ms. N/O reduces these to 83.8 ms and 88.3 ms. Delays exceeding the source
interval by 50 ms fall from 28 to zero on each screen. Candidate movie-clock
fits are 1.000001 and 0.999994, versus 1.256–1.261 on Beta2; these are this
movie segment's playback timings, not gameplay FPS.

Across 450 nonquiet 100 ms audio windows, N/O has no detected dropouts, minimum
normalized correlation 0.8313, median 0.9665, and fitted audio-clock scale
1.000008134. The later gameplay and skip paths still need native checks.

Sonic M with helper O completed a 210-second native check covering repeated
openings, with 2,422 decodes, 2,414 cached conversions, zero decoder errors,
1,050 fault-free transport samples, zero OBS drops and clean exit. The authored
movie is 15 FPS. In source frames 1,000–3,250, 445 upper and 520 lower matched
transitions have medians near 67.0 ms, p99 69.8–70.1 ms and maxima
71.9–73.5 ms. None exceed the source interval by 50 ms.

Sonic's 32-second audio sample contains 320 nonquiet 100 ms windows and no
detected dropouts. Median normalized correlation is 0.9462, minimum 0.5749,
and audio-clock scale 1.000007278. Searching the 62 lower-correlation windows
within one second of their expected positions found no correlation above 0.90
at a displacement over 20 ms. This does not prove perceptual perfection.
The earlier Sonic survey audio does not pass the stable-alignment gate, and
its movie fingerprints provide too few source matches for a defensible paired
timing comparison; no numeric before/after claim is made from those captures.

The first VX guest stub incorrectly assumed word-aligned compressed input;
Sonic needs halfword-safe descriptor reads and copying. These failed L trials
are excluded. Revenant Wings also examined its next packet header before its
existing asynchronous file-read wait. Faster decoding exposed that ordering
bug, producing a bogus length and memory overwrite. N moves the same wait ahead
of the header read in verified overlay 3; the old later wait is removed. The
failed FF12 L/M trials are not hardware candidates.

## Final helper O controls

The Ni no Kuni corruption fix passed the eight-minute native check above.
Strange Journey O now preserves the original keyframe flag; its software run
matches all 3,525 top and 390 bottom distinct images of G, with 3,060 decodes
and zero errors. The refreshed 180-second native run completes all 3,060
decodes/conversions, including 3,054 filtered frames, with zero decoder or
transport errors, zero OBS drops and clean exit. Its 2,796 matched moving
transitions have median 33.79 ms, p99 37.90 ms and no excess delay over 50 ms
relative to the source. The 960 nonquiet audio windows have no detected
dropouts, minimum correlation 0.8251, median 0.9963 and clock scale 1.000007891.

At 1 GHz, isolated 20-second gameplay checks compare O against the retained
Beta2 helper, with the same host, FPGA, ROM and starting save in each pair:

| Scene | Beta2 completed updates/s | O completed updates/s | Difference |
| --- | ---: | ---: | ---: |
| Castlevania bat room | 21.377 | 21.389 | +0.06% |
| NSMB World 2-5 repeated jumps | 59.591 | 59.575 | -0.03% |
| Mario Kart initial drive | 27.342 | 26.985 | -1.31% |
| Mario Kart at the barrier | 28.380 | 28.189 | -0.67% |

All captures have zero transport faults and OBS drops and clean exits. These
single samples show no material slowdown; they are not statistical equivalence
or whole-game FPS measurements. Completed updates can reuse a picture. Mario
Kart idled longer before O's initial drive (2:29 versus 0:32 on the race clock),
so the subsequent barrier is the closer control. Its captured pixel-change
detector is inflated by display noise and is excluded from FPS claims.

The ordinary ARM build with all FMV experiment options disabled passes the full
self-test and is byte-identical to the retained Beta2 helper
(`5510089f11be99c2bf56e80bca4cc784ccbbc418ce951514d78d352140a151a8`).
This protects the default build separately from O's gameplay controls.

## Private launcher and remaining work

The separate movie-test launcher admits only the complete hash-checked prepared
copies and exact matching runtime components. Its seven synthetic guard tests
cover changed ROM tails, mixed renderers, altered registries, wrong revisions,
unknown games and incomplete component checks. Validation-only mode remains
read-only. It recreates temporary aliases after reboot and keeps separate
test saves. These admission checks do not make this a production ROM patcher.

The final private launcher completed six bounded opening/title checks and the
separate transitions below. All transition sessions exited cleanly with zero
decoder/transport errors and zero OBS drops:

| Game | Observed transition coverage |
| --- | --- |
| Castlevania | Skipped the opening, resumed the isolated save and opened the equipment menu (level 2, HP 132/132). |
| Chrono Trigger | Skipped the movie, tapped Touch to Start and entered Game Settings, including DS/Classic and Active/Wait options. |
| Ni no Kuni | Interrupted the opening and reached the startup warning screen; later gameplay remains untested. |
| Revenant Wings | Completed the prepared opening and advanced to the next intro scene; ordinary planar conversions continued without decoder errors. |
| Sonic Chronicles | Completed the opening and returned to the Touch to Start title screen. |
| Strange Journey | Skipped the movie and advanced to the conference-room briefing dialogue. |

Castlevania's additional 140-second opening check uses the unchanged Beta2 host
fast paths on helper O. It has 700 fault-free transport samples and no OBS
drops. Its 650 matched moving transitions have no excess delay over 50 ms
relative to the source. A 50-second soundtrack window has no detected dropouts,
median correlation 0.9860, minimum 0.9000 and clock scale 1.000008013.
These are bounded movie checks, not new gameplay-FPS claims.

Use [the private movie-test instructions](FMV_MOVIE_TEST_20261022.md) for the
separate launcher. Machine-readable native, transition and gameplay receipts
are included in its kit. Original files and normal saves are hash-checked at
session entry and clean exit; runtime identity, ownership and saves/settings
are also checked around scripted input. Full original-ROM hashes are not
recomputed for every keypress.

Public integration still needs safe automatic
patching of supported original ROMs, more movie/gameplay/save coverage and
qualification on other systems. No claim of perfect playback across all movies
or a public-release-ready beta is supported.

### Expanding support beyond the six private selections

The decoder, bounded frame cache, filter and color-conversion implementations
are shared components. They can serve other games that use compatible decoder
and player routines. The prepared guest hooks and packet descriptors are the
current game-specific boundary; this is not a flag that safely accelerates
every DS game.

Automatic support should identify verified decoder/player variants at ROM and
overlay load, validate their code and memory dependencies, and apply the guest
hooks to staged memory. The current prototypes also prepare movie-packet
metadata. A normal-ROM workflow must generate or cache that metadata privately,
without changing the user's ROM or relying on distributed game data. Preserve
consumed lengths, keyframe flags, stream identities, alignment and file-I/O
ordering, and retain the original path for unsupported variants or movies.

Qualification remains per player and movie family: image/audio equality,
playback cadence, skipping, repeated playback, return to gameplay and saves.
Shared decoder support can reduce duplicated implementation work; it does not
remove those checks. These changes target FMV playback, not arbitrary 3D
gameplay. The next production milestone is automatic support for the already
validated families, followed by broader game/revision coverage.

Local evidence folder: `evidence/fmv-improvements-20261022` in the development
workspace. Key receipts are `NATIVE_QUALIFICATION_O.json`,
`MOVIE_TRANSITIONS_O.json` and `GAMEPLAY_REGRESSION_O.json`.
The preceding survey is documented in [FMV_SURVEY_20261022.md](FMV_SURVEY_20261022.md).
