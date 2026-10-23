# NSMB Speed Beta1 validation

Private test build, stock 1 GHz, retained FPGA. This is bounded evidence,
not full-game qualification. All native comparisons used isolated save aliases;
the normal launcher, user ROMs and original saves were protected by hashes.

## Bone-read option

The new host exposes three independent flags under **Speed hacks**. Defaults
in this separate package are local packet lookup On, inactive-client skipping
Off, and bone-read reduction On. A real RetroTINK capture verified this menu.
All eight saved flag combinations, dispatch, reload behavior, guard failures,
and unrelated status preservation passed the host tests.

The six-omission patch passed 520 ARM instruction guard/register/fallback
cases. Its integrated assembly matches the tested probe byte-for-byte; the
`lookup+bones` virtual cartridge image is identical to the user-tested one.
Two reference routes matched both screen hashes throughout: 9,000 frames of
running/firing and 6,000 frames including jumping, down while airborne and
crouching. This checks screens, not complete machine-state or audio identity.
Other levels, power-ups, carried objects, effects and multiplayer remain open.

The rejected nine-omission version differed visibly after frame 3,307 in the
longer route. It is not included as an available option.

## NSMB native results

World 1 castle, repeated jumps, approximately 20 seconds per scored interval.
The local packet-lookup flag is enabled on both sides. Menus, device discovery
and launch preparation are excluded. Scene position, form and static regions
were checked; the timer phase differs slightly between boots.

| Trial | Geometry submissions/sec | Complete paired-screen updates/sec |
| --- | ---: | ---: |
| Bone option off, original control | 34.78 | 44.11 |
| Bone option off, independent repeat | 34.49 | 44.05 |
| Bone option on, retained renderer | 55.80 | 35.52 |
| Bone option on, same-boot repeat | 56.37 | 36.57 |
| Bone option on, integrated host + retained renderer | 55.03 | 35.88 |
| Bone option on, combined renderer candidate | 58.14 | 35.50 |
| Bone option on, integrated host + combined candidate | 58.01 | 35.26 |

The game progresses faster while fewer complete pictures are published.
Geometry submissions, published game-frame IDs and complete picture counts
are distinct metrics; none establishes whole-game displayed FPS. All these
captures recorded zero transport faults and zero OBS render/encode drops.
The user reported a large improvement and much less rubberbanding, with some
slowdown still visible when new 3D elements appear during jumps.

A fixed red-pixel tracker measured the airborne-region portion of repeated
jumps at a median 0.85 seconds before versus 0.65 seconds after the patch.
This supports faster motion in the physical capture, but is not a complete
jump-time benchmark: equal real-time pulses span different game-frame counts.
Low-threshold visible-change detectors overcount relative to stricter image
comparisons and are deliberately not used as a 52–60 FPS claim.

## Held-out games and selection

The selected helper enables parallel final-image processing, packed affine
rows and the shorter idle intake delay. Parallel clear remains disabled.
These changes add no FPGA logic. The helper SHA-256 is
`7a9962fb8bcde14c905e5fc34649e4d18a40f5856ac4abc059ed6d92394b339a`.

| Scene | Retained renderer, pictures/sec | Selected renderer, pictures/sec |
| --- | ---: | ---: |
| Castlevania: Dawn of Sorrow, bat room left of save room | 21.03 | 21.14 |
| Mario Kart DS, Figure-8 Circuit opening straight and first bend | 27.07 | 28.28 |

Both comparisons used the integrated host, retained FPGA and stock 1 GHz.
Each scored interval was approximately 20 seconds. Castlevania was stationary
on the same platform. Mario Kart used Mario/B Dasher with held acceleration,
ending against the wall at the bend; initial race-timer phase differed slightly.
The physical captures were inspected to confirm the scenes and motion. All
four runs recorded zero transport faults and zero OBS render/encode drops.
These are bounded regression checks, not full-game or complete FMV qualification.
The 0.5% Castlevania difference is effectively unchanged; the 4.5% Mario Kart
picture-rate difference should not be generalized to every race.

The first candidate Mario Kart recording included loading/countdown and was
excluded. The accepted candidate is `B6ALL_KART2_RACE`; the retained control
is `B6STOCK_KART1_RACE`. Castlevania records are `B6ALL_CV1_BAT` and
`B6STOCK_CV1_BAT`. Menu navigation was verified with live recordings before
accepting the second Mario Kart run.

The combined renderer is selected for this private beta: NSMB's repeated
submission rate is about 58/sec, complete-picture throughput stays around
35/sec, and neither held-out comparison showed a slowdown. This does not
remove the bone patch's compatibility tradeoff or establish 60 FPS.

## Package checks

The archive contains the selected helper, new host, retained normal FPGA,
matching program files, licenses and corresponding source. Original ROMs,
saves, controller maps and private firmware dumps are excluded. A fresh
experiment-default file is included in the separate kit.

The packaging tool validates every archived file against its manifest and
checksums. Installation verifies the uploaded archive and extracted files,
then copies this board's local display/input/clock preferences separately.
The final archive launch result is recorded in the external installation
receipt after the immutable ZIP has been produced; it is not a new full
compatibility qualification.

For candidate implementation, individual measurements, correctness oracles,
and remaining bottlenecks see `NSMB_RENDER_DELIVERY_EXPERIMENT_20261023.md`.
For exact game-patch guards and compatibility tradeoffs see
`NSMB_BONE_READBACK_EXPERIMENT_20261023.md`.
