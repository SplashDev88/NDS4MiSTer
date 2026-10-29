# HeartGold guest-code optimization — 28 October 2026

Status: USA IPKE revision 0 reference seed qualified; gameplay profiling next.
No patch is enabled and no speedup is claimed.
The current user budget permits timing/RNG/hash drift when the game remains
functional and the result is perceptually acceptable. Keep raw comparisons;
reject broken progression, crashes, corrupted saves and perceptible defects.

## Existing implementation and boundaries

Reuse `tools/standalone_host/fmv/prepare.py` (`VirtualRom`, `read_overlay`),
`hook_guard.py` and `guest_byte_patch.py`. Private manifests select CPU,
ARM/Thumb mode, revision/header/full-ROM/code identity and expected bytes.
Overlays are identified by ID, file ID and complete content hash. The existing
worker streams a virtual cartridge while reset is held, then exits; normal
boot and overlay reloads copy the replacement bytes. Source ROMs stay read-only.
There is no assumed arbitrary live-PC HLE service or spare-memory trampoline.

`tools/game_optimization/replay_oracle.cpp` provides fixed-RTC input replays,
ARM9/ARM7 instruction counts and samples, both screen hashes, per-frame RAM
and save hashes, audio, full checkpoints and opt-in memory/geometry traces.
Reuse `validate_replay_inputs.py`, `compare_replays.py`, `scan_guest_patterns.py`
and the configured native session/capture tools. Reference instruction counts
are not FPGA cycles or a native speed claim. Native cycle attribution, DMA/cart
byte totals and missed-VBlank counts are not supplied by this intake run.

Both DS CPUs, memory, DMA, timing and sound remain FPGA-owned. Ordered graphics
and readback records cross the existing shared-DDR packet/mailbox interface;
the HPS helper renders/composes both screens and publishes complete pairs to
four framebuffer banks. The control window starts at HPS physical `3fc00000`;
complete-pair banks occupy `3fe00000..3fffffff`. See `docs/architecture.md` and
`docs/hybrid-3d-abi.md`. Do not add per-call HPS round trips or change RTL.

Prior guest work includes FFTA2 copy/vertex/decoder investigations and Platinum
copy/FIFO/archive/IRQ/ARM7/terrain studies. Platinum's accepted terrain beta is
the cumulative baseline; its addresses and scene-specific benefits do not
transfer to HeartGold. Historical SoulSilver readback experiments proved that
zero clip-matrix or visibility results can remove the player and furniture.
Those are correctness dependencies, not safe opportunities to skip readbacks.

## Owned input and delivery intake

The complete 128 MiB USA image has SHA-256
`65f02a56842b75aa92d775d56d657a56fe3fa993550b04dc20704ab82d760105`;
352-byte header SHA-1 `1b7be2e5079b10c7122aa048656c1d3a6d6bd0c1`.
The owned 512 KiB save contains only `ff`, so it supplies no existing gameplay
progress. Private copies were verified against remote hashes before and after
transfer. No original ROM or save was modified.

The stored ARM9 is compressed (762,644 bytes; initial decoded main section
1,120,352 bytes). Of 129 ARM9 overlays, 127 are compressed; only tiny overlays
35 and 124 are uncompressed. The current same-size byte-patch adapter rejects
a compressed ARM9 before admitting any candidate, including an ARM7 target.
This is a delivery limitation, not an exhausted-game conclusion. If a measured
hotspot warrants it, extend the existing virtual-image reconstruction path used
by NSMB/FMV, with explicit decoded-content and layout guards and no-op delivery
qualification. Do not build a second patch service or bypass existing guards.

## First reusable detector pass

The unchanged structural scanner finds ten leads across main/autoload sections:
three nibble-arithmetic sequences, ARM9 and ARM7 fixed-width mask walks, one
branch-heavy halfword copy, three stack-file-header halfword reads, and one
carry-derived zero multiply. These are static matches only. The scanner does
not cover overlays or all ten optimization families; zero profile weight here
means no profile was supplied, not that a routine never runs.

Private evidence: `OWNED_INPUT_TRANSFER_V1.json`, `OWNED_IDENTITY_V1.json`,
`STATIC_PATTERN_SCAN_V1.json` and the `BOOT_INTAKE_V*` jobs/captures.
The initial input routes are exploratory menu navigation, not qualified
outdoor/transition/battle benchmarks. Establish a real saved checkpoint,
visually verify the route and repeat the control before prioritizing patches.

The oracle now accepts optional validated touch windows through
`NDS_REPLAY_TOUCH_INPUTS`; this extends the same input path and calls the
existing reference-core touch API. No product runtime or FPGA change is
involved. All 29 parser/boundary checks pass. With touch disabled, all 64 files
from the 3,600-frame boot control remain byte-identical. A touch-enabled route
selects No info needed and reaches Oak's introduction; extending it repeats
the first 4,800 frames' screen/RAM/audio output exactly. These are navigation
and harness checks, not a gameplay-performance qualification.

Read-only symbol/navigation reference: [pret/pokeheartgold](https://github.com/pret/pokeheartgold),
pinned at `ce27b413f47f44b16211307426dcf62d8b7031bb`. Its declared USA ROM
SHA-1 matches the owned complete image. No external build or code was run.
Source labels remain leads until checked against the actual disassembly and
trace. The map event and mother script correctly predicted the staircase
transition and Save-button unlock; the 16,800-frame route visually reaches
both. This establishes navigation, not a native performance result.

The first private save route runs 18,000 frames. Frame 16,080 visibly reports
that the game was saved, and the save buffer is stable for the final 2,080
frames. Repeating the entire route from the original blank seed reproduces
all 193 output files exactly. The private generated save has SHA-256
`756f721263a071ea824d64e36d59d0569c1ed8f3d93d84a1f58e8024f0461a05`.
This is a separate disposable save; the user's original remains untouched.
Two separate 3,600-frame cold boots reach the expected downstairs scene with
Save/bag/options retained. All 64 recorded files match on repeat and the save
buffer remains identical to the generated seed. `FIRST_SAVE_SEED_ADMISSION_V1.json`
admits this reference seed. Native save/reset coverage remains pending.

## Initial indoor profile

Frames 1,800–3,599 of the qualified cold load show the idle downstairs room,
without movement or menu inputs. The following are **instruction sample
shares**, not FPGA cycle shares or native speedups. The decoded original bytes
for each span match checkpoint 2,400's actual main RAM or ITCM. Evidence:
`INITIAL_INDOOR_PROFILE_V1.json` and `INDOOR_PATTERN_SCAN_V1.json`.

| ARM9 span | Sample share | Evidence and next check |
| --- | ---: | --- |
| `020d47b8..020d47eb` | 4.469% | Indexed halfword copy; census source/destination/length before choosing a replacement |
| `020d4830..020d4857` | 6.151% | Source increments, destination stays fixed; observe the destination before calling this graphics FIFO work |
| `01ff8000..01ff804f` | 3.677% | IME/IE/IF read, selected interrupt acknowledgement and handler dispatch; necessary synchronization, not a proven idle loop |

The ARM9 mask-walk detector covers 1.173% of samples; the ARM7 zero-multiply
sequence covers 0.533%. Other structural matches have no samples in this
specific idle window. This does not reject them in transitions or battles.
Moving-scene and overlay-identity coverage must precede prioritization.

## Measurement status

| Scope | Control | Patched | Conclusion |
| --- | --- | --- | --- |
| Owned image and save | Verified copies | None | Originals preserved |
| Structural detector leads | 10 | None | Execution/semantics still required |
| Save-creation replay | 18,000 frames | Exact repeat | All 193 files identical |
| Cold-load replay | 3,600 frames | Exact repeat | All 64 files identical; private save admitted |
| Native gameplay speed | Not yet measured | Not run | No speedup claimed |

Top three investigations not completed in this intake:

1. Moving outdoor, transition and battle profiles from the qualified seed,
   including runtime arguments/content for the two transfer loops.
2. Compression-aware guarded delivery through the existing virtual image,
   if a measured candidate justifies extending support.
3. Content-complete graphics-work recurrence and overlay hotspot identity,
   preserving matrix/visibility results, IRQ behavior and moving-scene effects.
