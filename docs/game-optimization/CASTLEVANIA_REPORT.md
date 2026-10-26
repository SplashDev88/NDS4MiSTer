# Castlevania: Dawn of Sorrow optimization investigation

Status: private beta for bounded playtesting. Native scene, regression and exact-archive installation checks are complete. This is not a whole-game qualification or a 60 FPS claim.

## Architecture and scope

ARM9 and ARM7 execute in the FPGA. The existing HPS process consumes ordered
DDR graphics packets and performs graphics replay, 2D compositing, 3D rasterization
and frame publication. The FPGA retains the guest CPUs and display scanout;
the current renderer is not a software ARM9 interpreter. An HPS function cannot intercept an arbitrary guest PC without an
existing hardware hook. This investigation changes neither RTL nor the
service protocol and adds no HPS service. It uses the existing qualified
USA revision-0 graphics profile and existing runtime configuration mechanism.

The native ARM9 diagnostic sampler already exists. Its samples are wall-time
observations, including halted and DMA periods, not instruction counts or
cycle shares. The separate software-reference oracle samples both guest CPUs
and records framebuffer, RAM, audio and save checks. These two profiles answer
different questions. See `castlevania-native-pc-top30.json`.

The first native cave profile observed 37.2% halted samples and 6.1% DMA-active
samples. Graphics submission was already approximately 60 per second while
screen publication was approximately 21 per second in that earlier position.
No geometry-query stalls were observed. The two >2% unresolved execution-PC sites were subsequently identified as fixed-stride callback-table traversal/dispatch: 0x110 records of 0x2a0 bytes, with conditional indirect calls. They are not idle loops; an object-update role is inferred rather than symbol-confirmed. Removing guest idle work therefore
was not the first throughput priority. Native per-frame ARM7 cycle, DMA-byte,
cartridge-byte and missed-VBlank accounting is not exposed by this bitstream;
no estimates are presented as measured counters.

## Selected approach

The background alternates between real texture/palette contents. The old
texture cache discarded the decoded image when its source changed and then
decoded the same returning version again. The candidate retains two historical
decoded versions per texture key. Before reuse, it compares every raw source
byte, including palette and auxiliary compressed-texture ranges. Hash equality
alone never admits historical reuse. Restored entries retain their own storage
and derived metadata. Eviction returns storage to the existing allocator.

Raw input snapshots have a 4 MiB budget. Historical decoded-pixel/input
accounting has an 8 MiB budget; allocator granularity and metadata are additional.
Reset clears the derived history. Unsupported game profiles retain the existing
path. Guest instructions, RAM, ROM files, saves and event timing are unchanged.
The private build has no Speed hacks menu.

Texture stress testing also found an existing out-of-bounds dirty-bitset lookup
for wrapped textures. The mask now counts 64-bit words rather than individual
blocks. The invalidation check hashes a dirty range once, rather than repeating
the same complete comparison for subsequent dirty blocks.

## Validation so far

- Two deterministic 3,000-frame reference replays: every screen hash, RAM
  checkpoint, audio stream and final save matches the baseline. The final
  texture-only source passed these checks again after removing lighting reuse.
- 8,400 randomized texture comparisons across all seven formats, alpha modes,
  wrapped input ranges, alternating content, history eviction and reset.
  The test passes in both native macOS and ARM builds.
- An independent dirty-bitset wrap test covers the original indexing error.
- No core save-state feature or format was added. The core still does not
  support persistent save states.

## Native measurements

All native comparisons run at 1 GHz. Completed screen-buffer publication pairs
are called **screen updates**, not unique animation frames or whole-game FPS.
The fixed native cave suspend was visually checked; captures are retained in
private test evidence. The final public-rc.10 cave comparison uses the same native suspend, camera position, host, FPGA image and 1 GHz clock.

| Same-build cave comparison | Updates/second, run 1 | Run 2 |
| --- | ---: | ---: |
| Texture and lighting reuse disabled | 24.97 | 25.09 |
| Exact texture history enabled | 27.78 | 27.69 |
| Lighting reuse only | 25.09 | 25.15 |

Texture history improved this internal comparison by about 10.8%. The lighting
result is too small relative to the observed scatter to justify retaining it.
This table isolates the feature in an earlier same-build comparison. The separately compiled final beta comparison follows.

| Public release versus final PGO beta | Run 1 updates/sec | Run 2 updates/sec | Mean change |
| --- | ---: | ---: | ---: |
| Public rc.10, cave/bat checkpoint | 25.80 | 25.58 | Baseline |
| Final texture-only beta, same checkpoint | 29.90 | 29.83 | **+16.2%** |
| Public rc.10, upper-right Warg combat checkpoint | 20.74 | 21.08 | Baseline |
| Final texture-only beta, same combat checkpoint | 24.24 | 24.53 | **+16.6%** |

Cave intervals are 20 seconds; combat intervals are six seconds to keep the seeded enemy encounter bounded. The two runs per build start from the same suspend and pause between intervals; the second interval follows the first and is not a fresh cold seed. Captures confirm active gameplay in both intervals. Geometry submission stays approximately
59.8/sec in both builds. Helper CPU consumption is approximately 142% versus
144% of one HPS core; host use is 3–4%. The higher publication rate is not a
reduction of geometry work or an overclock. Both runs were visually confirmed
in the cave; source palette animation can differ at wall-clock sample times.
The feature-isolation and final-build gains are separate comparisons and must
not be added together. Native per-frame CPU cycles, publication frame-time
percentiles, dropped-frame counts and end-to-end input latency were not measured.

## Other-game regression checks

| Scripted test | Public rc.10 updates/sec | Candidate updates/sec |
| --- | ---: | ---: |
| NSMB, World 2-5 repeated jumps, two 20-second windows | 59.65 / 59.71 | 59.66 / 59.62 |
| Mario Kart DS, Luigi Circuit straight drive, two 20-second windows | 26.77 / 27.83 | 26.02 / 29.28 |

NSMB is unchanged within noise. Mario Kart has course-position variation:
one candidate window is lower and the other higher. These short checks show
no consistent slowdown, not a precise Mario Kart speed gain or an all-game
regression guarantee. Actual jumping/racing is visible in all included captures.
The new history path is disabled by the existing game-profile guard for both.
OBS reported no output-skipped frames in the retained captures.

## Private beta

Run **Scripts → NDS_Castlevania_Beta**, then load **Castlevania: Dawn of Sorrow
(USA), revision 0**. The private kit is `.NDS_Castlevania_Beta_20261025` and shares
normal game saves; back up saves before playtesting. Exit through **System →
Reboot** and use **NDS4MiSTer** to return to the public build. The beta has no
Speed hacks menu and retains the 1 GHz clock and existing FPGA image.

The final renderer SHA-256 is
`bb13597d032d9d365b9763efa3866594c8562e5476b4c02b93ba55754f9f7570`.
Product source is commit `9cdef9e`; later commits add reusable tools and reports.
The packaged source and PGO counters accompany the binary. Extensive play,
other cartridge regions/revisions and long combat sequences remain unqualified.

## Rejected approaches

- Removing three repeated NORMAL writes from the background-quad routine at
  `0x02004280` preserved 3,000 video frames but changed 1,724 RAM checkpoints
  and the audio stream. It was rejected under the exactness budget and was
  never installed on hardware. Expected bytes and identity are recorded in
  the disabled manifest entry.
- Lighting-result memoization preserved 1,440,000 randomized graphics commands
  and 6,000 reference frames, including timing/state, but native gain was below
  repeatability. Removed from the candidate.
- Mixed four-pixel raster handling increased measured native CPU cost.
- A two-version partial-image/tile cache passed reference checks but matching,
  scheduling and buffer copying cost more than the work it saved in live play.
- Conservative opaque sorting and batched depth rejection passed reference
  and mutated-raster tests but did not improve native CPU time.
- Palette-upload suppression is invalid: the alternating colors are real.
- Arbitrary guest HLE traps, overlay hooks and unused-memory trampolines need
  mechanisms or proofs this core does not currently provide. None was added.

## Measurement exclusions

Early private flags were stripped by the release supervisor, so those A/B
results tested disabled paths and are excluded. The private supervisor now
allowlists experiment flags and the rig checks the actual renderer environment.
Timed navigation produced different camera positions; those comparisons are
also excluded. Several runs selected the regular save or pressed an extra
confirmation after resume and measured the save room. Approximately 47–49
updates/second in those runs are not cave performance. Resume automation now
checks the displayed menu, selected suspend slot and paused gameplay state
before measuring. Short keyboard sequences at title were unreliable; the
validated route repeats Start before selecting the save. `PUBF1` measured the
pause screen because an early pause press occurred during resume; excluded.
Capture scene checks sample within the measured active interval, not at a fixed
eight-second video offset that can still show the pause transition.

## Remaining high-value investigations

1. Batch the proven repeated background work before raster setup, with exact
   full-input identity and an ownership-safe retained representation. The
   unsuccessful tile-cache approach should not be repeated unchanged.
2. Profile the remaining CPU0/CPU1 imbalance after this cache change. The existing
   Castlevania raster controller has a 40% minimum primary work share; first
   establish whether that floor is binding, then test a lower bound if warranted.
   Separate raster time from replay, 2D compositing and publication stalls using
   existing stage counters before proposing hardware hooks.
3. Revisit guest display-list construction only with explicit approval of any
   timing/RAM difference. Video equality alone did not prove the NORMAL patch
   safe. Never patch overlays by address without live overlay identity.

## Artifacts and reproducibility

- [Per-game manifest](castlevania-acve-r0.json): exact cartridge identity, rejected guest bytes, admitted host feature and measured outcomes.
- [Native top-30 PCs](castlevania-native-pc-top30.json): wall-time samples with known mappings and explicit unresolved entries.
- [Pattern library](PATTERN_LIBRARY.md): returning exact texture content, sparse callback-table scans, graphics dependency checks and rejected scheduling ideas.
- [Known issues](KNOWN_ISSUES.md): admission rules and excluded measurements.
- `tools/game_optimization/README.md` in the source tree: private debug oracle and comparison commands.

Commercial ROMs, saves, RAM dumps, GPU fixtures and recorded game footage are
kept outside the repository and installer. Source and compiler training counters
are included in the private package. Native evidence labels are recorded in the
manifest; private captures remain with the test rig. Public README and release
notes were not edited.

## Installed-archive verification

The exact 117,932,983-byte private ZIP was installed beside the public build.
Its SHA-256 is `deb347448ca514a17a8f304e34591098027eb3e8438788975a0fcd9cc2739fe5`;
the packaged source tree is commit `2a27a21`. All 74 package pins and the
launcher hash passed validation. The actual launcher enabled texture history
by default, with cache-stat logging disabled.

Native checks passed: cold launch, in-game suspend resume, cave-to-save-room
transition and return, core Reset, an explicit in-game Yes save, complete
exit and fresh-process reload of that save. The game showed “Data has been
saved”; the isolated save checksum changed and stayed identical after the
cold reload. Only a disposable test save was used. No transport faults were
observed. The root menu retains Right Stick Range and has no Speed hacks page.

The final preservation audit checked 1,163 existing file expectations, including
1,093 pre-existing save files, MiSTer.ini, the normal launcher, storage/recent
configuration, the original Castlevania ROM and the pinned public staging
files. There were zero mismatches. The board was left at MENU. Controller
mapping was copied into the private folder; originals were not modified.

Post-install verification is a separate receipt rather than a change to the
validated ZIP. Broader playtesting and the remaining investigations above are
still needed before considering a general public release.
