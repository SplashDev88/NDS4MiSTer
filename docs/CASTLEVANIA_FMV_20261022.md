# Castlevania opening-movie optimization

22 October 2026. Branch `experiment/castlevania-fmv-20261022`.
Baseline: Conquest Beta1 FPGA/host, unchanged rc.9 renderer, stock 1 GHz HPS.
Exemplar: Dawn of Sorrow, USA ACVE revision 0, opening attract movie.

**The third prototype delivers a repeatable movie-cadence improvement on the
RetroTINK-4K rig and passed bounded gameplay controls. It is ready for private
testing, not a public release or a general fix for every game's FMVs.**
The user approved substitution of the movie decoder in staged memory.

## Native result

All image measurements use the same 37–89 second recording window, a 32×24
luminance image, and RMS difference threshold 2. They count substantial movie
image changes, not display refreshes or whole-game FPS. Startup offsets vary
slightly between captures; the results are approximate scene measurements.

| Build | Substantial movie images/s | 95th-percentile hold |
| --- | ---: | ---: |
| Frozen baseline, three captures | 6.37–6.50 | 400 ms |
| First new host, optimization disabled | 6.44 | 400 ms |
| Final Color3 host, optimization disabled | 6.48 | 400 ms |
| Color1: faster clamp/pack, two captures | 7.04–7.08 | 400 ms |
| Color2: exact chroma-product reuse | 8.63 | 200 ms |
| **Color3: chroma and complete-pixel reuse, two captures** | **9.37–9.40** | **117 ms** |
| Software reference at this detector threshold | 9.65 | 100 ms |

The five control runs average 6.45 changes/s; Color3 averages 9.38, about
**45.5% more distinct updates** in this interval. The source normally changes
its movie image once per six DS frames: approximately 10 images/s. It is not a
60 FPS movie. Color3's maximum detected holds are 600–617 ms; the reference also
contains a roughly 602 ms hold. Some additional holds remain, and this is not a
claim that every frame is presented perfectly or that all audio defects are gone.

Screen-buffer publication stays around 59.6 updates/s in both builds; repeated
movie images make that an unsuitable FMV-speed metric. The frozen-baseline and
enabled-candidate captures have no encoding drops. The final disabled-host
control recorded three encoding drops over its complete recording; the earlier
disabled control had none and measured 6.44 changes/s. No capture increased OBS
rendering drops. Sampled transport fault words remain zero. The FPGA, renderer,
HPS clock and display setup are unchanged.

## Audio and visual checks

Both Color3 captures keep a constant audio-reference offset across successive
2-second RMS-envelope windows from recording seconds 41–89, at 10 ms resolution.
Their offsets are 13.65 and 13.83 seconds respectively, reflecting independent
recording/boot starts. Neither has a 10 ms interval below RMS 0.001 in seconds
40–89. No accumulating audio slowdown or silent dropout was detected there.
This does not certify that no short click exists, nor does it qualify all audio
in every game. MP4 audio stream 2 contains the captured game audio; stream 1 is
silent and was not used for this result.

The first Color3 recording includes title return and another movie loop.
The first-image transition was inspected on native capture; the image arrives
without a new persistent corruption. Short Start/A input attempts and subsequent
screenshots are retained; A reached the title menu. The game then reached the
combat room with normal controls. Its isolated suspend save survived a clean
exit and cold relaunch: HP 63/132 and the same room were restored, with the
clock advancing from 1:13 before suspension to 1:16 after resuming and pausing.

## Diagnosis and implementation

The original renderer maintained full publication throughput without replay
backlog or budget omissions. A separately compiled diagnostic sampled the
incoming VRAM and rendered pixels before publication. In LCD frames 1500–3598,
bottom-image hashes changed 6.33/s and physical VRAM bank C hashes 6.22/s.
The long repeats therefore already existed upstream of the HPS renderer.
These were sparse hashes, not exhaustive frame comparisons.

A software-reference instruction profile sampled one in 256 ARM9 instructions
in frames 1400–4499. About 51.7% of the original samples belonged to the movie's
color converter at `0x01ff895c..0x01ff9a4b`. In 83,003 decoded blocks, adjacent
pixels shared both chroma inputs about 86% of the time and all three inputs
about 52% of the time. These are workload observations; correctness does not
assume that the inputs repeat.

The final normal-mode converter:

- Reuses chroma products only when both signed 32-bit chroma inputs match.
- Reuses a completed pixel only when luminance and both chroma inputs match.
- Otherwise computes the original wrapping 32-bit fixed-point formula.
- Uses direct RGB555 packing for in-range results and an equivalent signed
  clamp for out-of-range results.

Caching lasts only within a converter invocation. Pixel destinations, movie
scheduling, audio routines, and the separate larger-stride mode are preserved.
The four literal coefficients shared with that mode remain at their original
addresses. This is guest ARM9 code still executed by the FPGA CPU, not HPS-side
movie decoding or a renderer optimization.

| Sampled ARM9 instructions | Original | Color1 | Color2 | Color3 |
| --- | ---: | ---: | ---: | ---: |
| All execution | 4,955,370 | 4,454,242 | 4,437,475 | 4,067,547 |
| Color converter | 2,563,138 | 2,059,916 | 2,041,872 | 1,670,041 |

Color3 reduces sampled instructions about 17.9% overall and 34.8% inside the
converter. Instruction counts do not measure FPGA cycles: Color2's much larger
native gain than Color1 despite similar counts illustrates that limitation.

## Identity and rollback

The standalone host changes only the staged cartridge-memory copy before guest
boot. Its existing source-file loader opens the ROM read-only. It is opt-in via
`NDS_FMV_COLOR_FAST=1`. The patch requires the expected file size, ACVE game code,
revision, 512-byte header CRC, entire converter CRC and every replaced original
instruction byte. All checks precede the first write. A mismatch does nothing.

Verified source ROM SHA-256:
`3ddc8b0eac841b6005ff4c38a184b517fa8225ac905aad951b0572850358d8b0`.
The original file and protected saves remain unchanged. The optimization is
limited to this verified USA revision; other revisions retain their original
code. Relaunching through the usual Conquest launcher loads the original code.
No ROM patching utility or modified ROM file is needed by the player.

Color3 host SHA-256:
`6f45d89a04cb132cba71a68ebbca5b1ac5467758a6df3d4688add292a0fad203`.
Separate installed kit: `/media/fat/Scripts/.NDS_FMV_Color3_20261022`.
The original Conquest kit and launchers are retained.

On the test MiSTer, run **Scripts → NDS_FMV_Beta**, load the USA revision 0
game, and wait at the title screen for the opening movie. The launcher enables
the guarded optimization automatically. Use **System → Reboot** to exit, then
the usual launcher to return to the previous build. This beta retains the
Conquest Beta1 FPGA and renderer; it does not address inherited static timing
closure or establish full-game compatibility.

Source: `tools/standalone_host/fmv_castlevania.h` and `fmv_castlevania.S`.
The current assembly replaces the whole normal-mode region, including its
private helper routines. The first prototype used smaller patch ranges;
its superseded source and binary remain in private evidence.

## Reproducible checks

- Full ARMv5 routine differential test: **3,072,000 pixels in 12,000 blocks**,
  including arbitrary signed 32-bit values, overflow boundaries, repeated and
  distinct inputs, multiple row strides and untouched destination guards.
  Original routine, candidate and mathematical reference agree.
- Clamp arithmetic test: **19,163,666 cases**, including every RGB888 triple,
  boundary cases and deterministic random triples.
- Host staging contract: exact expected output; wrong header/revision/code,
  short mapping, wrong file size, null mapping and repeat application all reject
  without partial mutation.
- Reassembling the checked-in overlay must exactly match the embedded patch.
- 7,200 software-reference frames per candidate: top hashes match throughout;
  completed movie images match in order. The first partial image changes timing
  and scanout coverage. Color3 first shows it three DS frames earlier and six
  frames earlier on the next loop. A fixed-duration run therefore ends one
  movie image ahead. Audio buffers are not byte-identical because execution
  timing changes; native audio alignment is assessed separately.
- ARM host builds with the normal static Cortex-A9 flags. The diagnostic helper
  passed its service self-test; its trace is excluded from ordinary builds.

Run the full converter check with a private, unmodified matching ROM:

```sh
bash tools/test_fmv_converter_equivalence.sh /path/to/Castlevania.nds
bash tools/test_fmv_color_equivalence.sh
```

The converter test uses disposable Docker storage for extracted code fixtures.
No ROM, save or captured game media is committed to the repository.


## Short gameplay regression checks

Castlevania combat: baseline 20.97 completed updates/s, candidate 22.22. These
short, six-second samples do not establish a gameplay speed gain. The capture
detector's action-region rates were 36.94 and 36.78 changes/s, with the same
50 ms 95th-percentile hold. No slowdown was apparent in that bounded check.
No transport faults or capture drops occurred.

NSMB World 2-5 repeated jumps: baseline 59.50 completed updates/s, candidate
59.62; action-region changes 57.74 vs 57.31/s, with the same 16.7 ms
95th-percentile hold and 50 ms maximum. Its host log confirms the Castlevania
patch was skipped. No transport faults or capture drops occurred. Mario Kart
uses the same identity guard and also logged that the patch was skipped.

Mario Kart DS, Figure-8 Circuit, Mario/default kart, 50cc: the first driving
interval gave 27.34 baseline vs 27.53 candidate completed updates/s. Countdown
position differed at the start, so the second, steady barrier interval is the
better control: 28.04 vs 28.82 completed updates/s. Its action-region detector
gave 58.87 vs 59.46 changes/s, both with a 16.7 ms 95th-percentile hold and
33.3 ms maximum. No transport faults or capture drops occurred. These brief
runs showed no speed regression; the small differences do not establish an
improvement, and image-detector rates are not whole-game FPS.

Original user saves stayed unchanged. Only isolated test saves were writable.
These checks do not replace longer gameplay tests or clear older, unrelated
Ni no Kuni/Conquest performance qualification work.

## Evidence and remaining scope

Private evidence is retained in the testing workspace's
`evidence/castlevania-fmv-20261022` directory.
`MOVIE_RESULTS.json` records every baseline/candidate result, drop counters and
available audio checks. Recordings, profiles, oracle hashes, native traces,
build receipts and guarded rig operations are retained there.

An early recorder included a previous session during startup; those samples
are excluded. The recorder now verifies the newly launched supervisor and a
fresh Ready graphics session. A failed diagnostic startup is retained and
excluded from video measurements. A diagnostic chroma probe initially omitted
DTCM addressing; it produced zero samples and was corrected before use.
Reference thumbnail channels were corrected from BGR to RGB before final
luminance comparison; the reference cadence result did not change. Hardware
image-change rates never depended on that reference color conversion.

No FPGA rebuild, timing-closure improvement, overclock or general game-speed
improvement is claimed. Region coverage, long sessions and other FMV codecs
remain separate work.
