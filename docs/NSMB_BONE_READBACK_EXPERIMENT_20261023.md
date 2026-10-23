# NSMB cached bone readback experiment — 23 October 2026

Status: private experiment with a successful user playtest; broader compatibility
and release qualification remain incomplete.

The user asked whether an in-memory game patch could produce a larger gain.
The owned A2DE revision-0 image is the same identity documented in
`NSMB_SPEED_HACK_AUDIT_20261023.md`. No source cartridge or original save is
modified. The diagnostic uses a virtual load image and isolated test saves.

## Evidence motivating the patch

Native castle profiling puts the clip-matrix readback first among non-halted
ARM9 PCs. A separate passive diagnostic bitstream measured approximately
408 microseconds per uncached readback, occupying 14.2% of wall time in its
20-second window. Of that, approximately 375 microseconds was before reply
commit and 33 microseconds fetched the payload. Precommit includes FPGA setup,
HPS pickup, processing, and polling; it does not isolate any one of these.
The instrumented bitstream and collector have overhead, so this is a latency
diagnostic, not a comparison against the normal beta's gameplay speed.

The game caller is `PlayerModel::saveNodeTransforms` at `0x0212c98c` in overlay
11. It makes ten calls through `Model::getNodeMatrix` at `0x0201972c`. Each
restores a different graphics matrix-stack slot, obtains the current matrix,
converts it using the inverse camera matrix, and stores a body-part transform.
These are distinct requests: a 1,500-frame reference window had no repeated
node/slot in the same frame or model-render interval.

The reference read observer watches ARM9 byte, halfword, word and sequential
word loads. In the initial walking/jumping sequence it observed 127,860,543
loads overall, including 180,000 reads inside the matrix computations, but
no subsequent gameplay reads of the ten cached transforms in frames
1800–3299. This is evidence about that sequence only, not proof that the
transforms are unused throughout the game.

## Nine-update omission: rejected for normal use

A temporary hook skipped nine of the ten cached updates and retained the last
call, including its graphics-state operations and completion fence. It kept
the ordinary path for unrelated callers and checked the live overlay entry.
The original cartridge hash, ARM9 CRC/hash, main-RAM hook prefix and scratch
bytes were checked before assembling the load image. There is no PC trap or
new FPGA logic.

The first 3,300 reference frames matched both screens exactly. In the measured
1,500-frame gameplay section, matrix requests fell from 15,171 to 1,671.
ARM9 instructions fell from 198,326,543 to 194,868,300. Neither number is a
native frame-rate improvement.

A longer 9,000-frame run added running/firing. It exposed reads of the face
and left-hand transforms and produced 3,431 differing screen pairs, starting
at frame 3307. This rejects the broad omission as a correctness-preserving
optimization. The paired reference data and rejected patch are retained.

## Narrowed six-update diagnostic

The next version retains both hands, the face, and the final call. It omits
only six other cached transforms in the exact known caller. Their absence
can still affect other actions, power-ups, effects or modes. Matching one
longer sequence cannot establish full-game compatibility.

Both versions passed 520 instruction-level guard/fallback cases, including
changed live-overlay prefixes, unrelated call sites, register preservation
and stack restoration. The virtual load image was decoded again to verify
the installed branch and payload, and the original cartridge hash was unchanged.

The narrowed version matched both screen hashes on all 9,000 frames of the
longer reference sequence, including running/firing. The observer still saw
the face and left-hand reads, now supplied by retained updates. Comparisons
use hashes over every pixel, with raw frame samples saved every 120 frames;
they do not compare complete machine state or qualify every game action.

A second 6,000-frame reference sequence used alternating directional jumps,
down while airborne, crouching and firing. Both screens matched on every
frame. Sampled frames confirm active World 2-5 gameplay and landing effects;
this adds action coverage without establishing all power-ups or levels.

## Native measurements and user playtest

The six-update omission ran on the MiSTer at 1 GHz with the retained FPGA,
host and renderer. The control enabled the existing packet-lookup option;
the experimental load added only the six-update omission. The isolated save,
castle location, character form and scripted jump inputs were the same.
The castle timer differed slightly at the start, so these are short scene
comparisons, not a whole-game benchmark.

| Metric | Control | Six omissions | Same-boot repeat |
| --- | ---: | ---: | ---: |
| Input geometry submissions/sec | 34.78 | 55.80 | 56.37 |
| Completed paired-screen publications/sec | 44.11 | 35.52 | 36.57 |
| Renderer-reused 3D pictures/sec | 5.63 | 0.48 | 0.59 |
| Mean admitted picture preparation span | 20.34 ms | 24.53 ms | 24.00 ms |
| Mean completed picture upload | 0.96 ms | 0.97 ms | 0.97 ms |

The counters measure different stages. Submissions are not displayed FPS;
preparation spans include replay waits and scheduling, not just raster CPU
time. Reuse flags describe 3D reuse, not identical whole-screen output.
The lower publication rate must remain visible when assessing the tradeoff.
An independent control boot repeated at 34.49 submissions/sec and 44.05
completed pictures/sec, consistent with the first control.
The repeat trace reports two raced records, so some paired timings may be
incomplete. All three windows reported zero transport faults and zero OBS
render/encode drops.

The capture's low-threshold motion detector increased from about 45 to
52–53 changes/sec, but higher thresholds count fewer changes. Those counts
cannot establish 52–56 displayed FPS. Further video analysis is required.

The user playtested the same six-update experiment and reported a huge speed
boost, most rubberbanding gone, and slight remaining slowdown during some
jumps when new 3D elements appear. This is subjective gameplay feedback, not
a numeric FPS measurement or a full compatibility pass. The next measured
target is picture preparation; the trace does not yet attribute the user's
specific stalls to a particular rendering operation.

Neither diagnostic is enabled in the existing normal playable beta. The
user's regular save and original cartridge remain unchanged.

## Independent switch

The source now exposes `Speed hacks → Reduce bone reads` separately from the
two bookkeeping options. All three default off in the host. The existing
`NDS-SpeedHacks-v1` masks 0–3 retain their meanings; bit 2 adds bone reduction.
`lookup+bones` generates the exact same virtual image as the user-tested
diagnostic, verified by whole-image SHA-256. Reload applies pending switches;
Save settings persists them. The menu warns that bone effects may differ.

All seven enabled combinations passed virtual-image checks: the intended
main-RAM edits and recompression metadata are the only changed initial code;
autoload sections and original cartridge assets stay intact. The rebuilt ARM
shim is byte-identical to the tested diagnostic. Host navigation, all eight
saved masks, environment overrides, worker dispatch and failed-identity
fallback tests passed. A native launch with the integrated host confirmed the
independent menu switches through the RetroTINK capture. The integrated
lookup-plus-bones scene reproduced the speed gain; final private-package
scope and renderer selection are recorded in `NSMB_SPEED_BETA_VALIDATION_20261023.md`.

Evidence root on the development machine:
`evidence/nsmb-four-candidates-20261023/` (under the NDS4MISTER workspace).
Key records: `BONE_REFERENCE.json`, `BONE_GUARD_TESTS.json`,
`BONE6_GUARD_TESTS.json`, `matrix-usage-confirm/`, `bone-route-control/`,
`bone-route-probe/`, `BONE_DELIVERY_ANALYSIS.json`,
`BONE_ACTION_REFERENCE.json`, `BONE_INTEGRATED_MODES.json`,
`USER_PLAYTEST_HANDOFF.json`, and the `CBONE*` hardware captures.
