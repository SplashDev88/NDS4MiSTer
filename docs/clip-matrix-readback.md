# On-demand clip-matrix readback candidate

## September 23: experimental matrix owner at input

The first CLIP1 hardware build restored FFTA2's missing title/menu graphics,
but the user rejected its speed. Profiling separated reply calculation from
waiting for the ordered renderer: 1,956 replies averaged 14.1 microseconds of
calculation/publication and 39.8 milliseconds waiting in the replay queue.

`NDS4MISTER_GX_MATRIX_PREFIX=verify` maintains a private matrix/stack model on
the input thread and compares its snapshots with the original renderer's
answers. `fast` additionally publishes those snapshots as soon as validated
input is acknowledged. Both require asynchronous replay and matched display;
the default is disabled. Drawing, textures and geometry remain renderer-owned.
Old renderer verification replies never overwrite newer committed replies.

The model uses melonDS's fixed-point matrix arithmetic, preserves partial
commands, queues commands blocked by SWAP until architectural VBlank, and
tracks matrix stacks, power and relevant GXSTAT writes. Unsupported mixed
partial commands or an over-budget deferred burst disable it for the session
and retain the original ordered reply path. Every fast reply is later checked
against all 16 clip and nine vector words; disagreement faults the test helper.
This remains a CLIPMTX-only FPGA contract. Private BOX_TEST result bits are not
implemented by the fast model and are not exposed to the guest.

Validation on the first fast helper (`d140407d`, source `dcd0d46`):

- 73,383 comparisons against the actual vendored melonDS geometry engine on
  host and emulated ARM, including partial commands, stacks, SWAP and power.
- Full helper self-test on both targets with the normal ARM stack limit.
- 256 queries answered with the renderer stopped, then verified after replay
  resumes, without an older reply overwriting the latest result.
- MiSTer verification run: 1,323 matching snapshots, no faults or fallback.
- MiSTer fast run: 21,637 matching/published snapshots, no faults or fallback.
  Maximum replay queue occupancy 35 of 512; zero queue-full polls.
- Timed cold-start FFTA2 runs submitted 944 SWAPs in 66.506 seconds versus
  2,728 in 65.439 seconds with fast replies (about 2.94 times the rate).
  These are game 3D submissions, **not gameplay FPS**. The captured fast title
  screen retains its graphics. User playability testing is still required.

Both runs used CLIP1 FPGA, stock 1 GHz, write-combining and the disconnected
Wi-Fi guard. The accepted public core/helper remain the rollback pair. This
candidate is private and must not replace the accepted release solely on the
basis of the title-screen measurement.

The separate `NDS4MISTER_GX_QUERY_FAST_POLL=1` experiment reduces input's idle
sleep from 500 to 100 microseconds only after a fast query has been answered.
It is disabled by default and **not selected for the morning candidate**:
NSMB submissions rose from 1,281/50.635 s to 1,462/51.914 s, but rendered pairs
fell from 1,024 to 732. More frequent wakeups competed with rendering. The
ordinary polling interval is retained.

Repeated boots found that the original 512-word bound could disable the model
before FFTA2's first query. Matrix-stack initialization has many parameter words
but relatively little geometry work. The corrected bound holds at most 4,096
words and estimates a conservative 30,000-cycle maximum: 128 per ordinary
command, 256 per multiword matrix command, 512 per SWAP or BOX_TEST, divided
upward across parameter words. This stays below the NDS replay query's 32,768
geometry-clock advance, including headroom for SWAP and incomplete commands.
An additional 680-word matrix-stack burst is compared with actual melonDS
before VBlank and after one query clock step. Host and emulated ARM now pass
73,389 oracle comparisons, including near-budget BOX_TEST and single-word
command bursts that must reach the same matrix after one query clock step.

The corrected helper is `9d409749`, source `9fadc62`. Two FFTA2 hardware runs
(separated by an NSMB load) verified 8,425 and 7,936 replies without fallback
or faults. The latter averaged 40 microseconds from packet intake to reply
publication; this excludes time before the input thread acquires the packet.
All raster work and display ownership remain unchanged.

Accepted-pair comparisons also limit promotion: NSMB submitted 1,670 frames in
51.426 s on the accepted pair versus 1,281 in 50.635 s on the fast CLIP1 pair.
The latter rendered more completed pairs (1,024 versus 875), illustrating why
neither counter alone proves better playability. Castlevania's movie submitted
1,271 frames in both runs (51.006 versus 51.273 s), with 1,841 versus 1,860
rendered pairs. All these runs included the same diagnostic profiling overhead.

Final Fantasy Tactics A2 reads the GPU clip matrix at `0x04000640–0x0400067c`
and uses the results in later matrix commands. The fast FPGA returned zero
for these unclaimed registers. A full-CPU reference reproduces the missing
title/menu graphics when only those reads are forced to zero.

This candidate claims only the clip-matrix range. GXSTAT remains local to
the FPGA; frequent status polling does not create an ARM round trip. Vector,
position and BOX_TEST result support is not enabled by this change.

The first uncached read posts a kind-10 fence through the ordered GPU source
queue. Accepted packed commands, including autonomous zero-parameter
expansion, drain before the fence. A command still awaiting future parameters
does not block the query. The fence closes a continuation packet immediately,
without inventing a frame boundary or SWAP.

The replay owner flushes the preceding geometry and publishes an executed
prefix snapshot at control offset `0x200`. The original H3R1 layout is retained
for its session/request/commit validation, including internal busy status and
vector words; only its clip words are exposed to the guest. This operation
does not explicitly join raster or publication workers. Ordinary ordered
LCD phases still retain their existing renderer ownership fences.

The FPGA fetches the validated reply into a small synchronous RAM. Remaining
words are served locally. Any geometry, power-control or GXSTAT write
invalidates the cache, including a write while a reply is outstanding.
Busy snapshots cannot be reused. Request tokens survive guest reset, stale
replies cannot complete a new read, and the helper clears the commit before
advertising Ready. The unused legacy DDR channel 3 drains old ownership on
cancellation before reuse.

The accepted WC/stock-1-GHz render path, Engine B, TATE, display fixes and WiFi
guard remain in place. This requires a companion core and helper; it is a
separate experiment, not an accepted release. Performance and compatibility
must be measured on hardware before promotion. The absence of extra work in
the no-read path does not guarantee unchanged placement or game frame rate.

Validation commands:

- `bash tools/test_h3d_clip_readback.sh`
- `bash tools/test_nitro_console_vhdl_analyze.sh` (set `ALTERA_MF_COMPONENTS`)
- Source-matched host and ARM `nds_hybrid_3d_service --self-test`
- `nds_gx_overflow_order_test`
- Quartus seed 2, then Tactics title/menu and accepted-build comparison runs

The independent fast-bank overflow ordering fix remains required: new input
must not overtake a command tail that has spilled into the legacy GX FIFO.
