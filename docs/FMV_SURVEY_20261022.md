# Other-game FMV survey — 22 October 2026

Four openings were tested on the MiSTer/RetroTINK-4K rig at **1 GHz**, comparing
FMV Beta2 with the pre-FMV Conquest Beta1 runtime. Revenant Wings, Sonic Chronicles
and Ni no Kuni reached their title menus. Strange Journey reproduced its existing
opening stall on both builds. These checks found no video-speed regression in
the compared sequences; they do not establish intended playback speed or qualify
every audio transient.

No runtime changes were made during this survey. Beta2's Castlevania substitutions
were correctly **skipped for all four ROM identities**. Its optimization remains
specific to the verified Dawn of Sorrow USA revision. See
[the Beta2 notes](CASTLEVANIA_FMV_BETA2_20261022.md).

## Results

| Game / tested ROM | Observed result | Control → Beta2, matched segment |
| --- | --- | --- |
| Final Fantasy XII: Revenant Wings, USA, AXFE rev0 | Automatic opening completed and reached New Game / Continue. | 562 top-screen images: **58.643 → 58.653 s**; **9.566 → 9.565 changes/s**. |
| Sonic Chronicles: The Dark Brotherhood, USA multilingual, YWSE rev0 | Automatic montage completed and reached Touch to Start. Moving montage windows showed roughly 5–6 distinct images/s. | 318 bottom-screen images: **51.163 → 51.154 s**; **6.196 → 6.197 changes/s**. |
| Shin Megami Tensei: Strange Journey, USA, BMTE rev0 | New Game opening stalled on the city image in both builds. | Image remained unchanged for **101.93 s on control** and **122.46 s on Beta2**, through the end of each observation. These are observation lengths, not recovery times. |
| Ni no Kuni: Shikkoku no Madoushi, Japan, B2KJ rev0 | After dismissing the startup notice with A, the animated opening progressed and reached the title menu on both builds. | 681 bottom-screen images: **125.0866 → 125.0871 s**; **5.4362 → 5.4362 changes/s**. |

Rates count changes between matching sparse image fingerprints, **not whole-game
FPS or the encoded movie frame rate**. Selected sequences include their own
stills and transitions. No source/reference-emulator cadence was established for
these four movies. In particular, Ni no Kuni's differing time at its startup
notice must not be included in a speed comparison. The selected movie block
excludes that notice; the longer matching top-screen block does not.

Ni no Kuni's final title-menu state was also confirmed by separate snapshots
after the timed captures. The complete captures and endpoint snapshots are
retained together.

## Strange Journey reproduction

From a fresh isolated save, reach the title menu and choose New Game. The test
pressed A for 0.3 s, released for 3 s, then repeated that press/release. The
opening text progressed to the city image, then stopped changing. On Beta2,
late A and Start presses did not recover it.

Six complete two-screen framebuffer snapshots, across both builds and before
and after the late-input attempt, share SHA-256
`8e4204eedb91f47e9ced684d0750ce35d35888c4fc597e79adcf6eab5ec92374`.
The publication/LCD counters continued and transport fault counters stayed zero.
Captured audio remained active during the hold; continuing audio is not evidence
of movie progress. The root cause is not established. The previously reported
early-skip workaround was not requalified in this survey. This finding does not
change the game's broader compatibility rating.

## Audio scope

Audio stream 2 of each OBS recording contains the game audio. Analysis aligns
control and candidate by matching screen content, then compares 2-second audio
envelopes every 5 seconds and sampled 250 ms waveforms. A coarse 6 kHz search is
refined at the original 48 kHz sample resolution to avoid phase-quantization
errors. Quiet samples remain unqualified.

- Revenant Wings: 12 compared samples; median waveform correlation **0.994**,
  minimum **0.987**.
- Sonic: median **0.971**. One sample near a logo/movie transition has correlation
  **0.463** and remains inconclusive; a quiet sample is also unqualified.
- Ni no Kuni: median **0.994**, minimum **0.828**. The lower early-sequence sample
  remains unqualified for audio fidelity.

These are control-to-candidate checks, not comparisons with original hardware or
a source soundtrack. They support broadly similar sampled audio but do not prove
that every click, hitch, fade or synchronization error is absent. The original
broad audio searches and the later movie-aligned results are both retained.

## Method, controls and evidence

- Nine video/audio recordings, totaling 1,410 seconds of scheduled post-start
  observation, plus ROM loading and setup. The 7,050 transport-header samples
  had no recorded faults; clock assertions required 1,000,000 kHz throughout.
- Read-only framebuffer probe samples coherent publications on both screens,
  using a 32×24 RGB555 fingerprint per screen. Exact contiguous image runs are
  compared, rather than comparing an arbitrary wall-clock window.
- The first Sonic Beta2 probe timed out with CPU1-only/nice19 scheduling. Its
  video/audio recording succeeded, but it supplies no raw-frame comparison.
  Suspected sampler starvation was addressed by allowing CPUs 0–1 at nice10 and
  allowing 30 seconds for exit. Sonic was repeated; control and repeat used the
  same probe scheduling. Game thread scheduling was not changed.
- Sampling gaps were retained: control/Beta2 skipped-publication counts were
  109/211 for Revenant Wings, 9/23 for the successful Sonic pair, 2/3 for Strange
  Journey and 3/7 for Ni no Kuni. Sparse sampling cannot certify every pixel or
  rule out an unseen one-publication image.
- OBS reported zero encoding drops in all nine captures. Each Revenant Wings
  capture had two rendering drops; the other seven had none. Raw framebuffer
  comparisons do not depend on OBS's rendering cadence.
- Each game/build used an isolated ROM alias and test save. The original saves,
  launchers and protected settings passed their hash checks. All nine sessions
  exited cleanly, and the MiSTer was returned to **MENU**. No overclock, display
  setting change, compatibility-list edit, release or public upload was made.

Runtime identities:

| Component | SHA-256 |
| --- | --- |
| Beta2 host | `1520a8590ce85ab2a2ea0dcacf5c74497e73a8c9ca35dade856cb6ad7dfb059b` |
| Conquest Beta1 host | `357add0359781c3e7c3d4a67e01ee4449c881053dc27c4581175c362df1bc545` |
| Shared FPGA | `4e83635200fd64441e0e5055eb707f652e2cb3ea4cdd76807e8706c4b99a5e26` |
| Shared renderer | `5510089f11be99c2bf56e80bca4cc784ccbbc418ce951514d78d352140a151a8` |

Private evidence is in the workspace's `evidence/fmv-survey-20261022` directory:
`SURVEY_RESULTS.json`, `INVENTORY.json`, per-run capture/stop receipts, raw probe
CSVs, paired-image and aligned-audio reports, screenshots and contact sheets.
Capture receipts point to the original recordings. ROMs, extracted movie assets,
saves and captured media are not included in this source-tree report.

## Next work

1. Diagnose Strange Journey's repeatable opening stall, using the preserved
   sequence as a correctness test before attempting speed changes.
2. Establish reference timing and profile Sonic Chronicles and Ni no Kuni's
   decoders. Their measured moving-image cadence makes them useful candidates;
   the Castlevania byte substitutions should not be applied without separate
   identity checks and equivalence validation.
3. Compare Revenant Wings with a source reference before spending time on it.
   Its current matched sequence is close to ten changes per second, but that
   alone cannot establish whether it is already running at the intended speed.

Future changes should repeat these matched scenes and the existing Castlevania,
NSMB and Mario Kart gameplay controls before a new beta is promoted.
