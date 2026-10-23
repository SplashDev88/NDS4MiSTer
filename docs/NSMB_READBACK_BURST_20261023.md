# Matrix reply burst experiment — 23 October 2026

This is a default-off FPGA experiment targeting the final DDR fetch of an HPS
geometry-query reply. The isolated build and bounded board comparisons are
complete. **Do not promote this candidate:** the observed benefit is too small
and uncertain for its resource and timing cost. The existing beta remains
unchanged. This experiment does not change guest instructions, matrix
arithmetic, graphics commands or DMA completion.

## Why this path

The [native ARM9 profile](NSMB_NATIVE_PC_PROFILE_20261023.md) placed the
clip-matrix register copy first among NSMB's non-halted PCs. That identifies
the whole readback round trip, not the cost of this particular DDR reader.

Two normal-bitstream World 2-5 jump captures each contained about 12,200 fast
query replies in 20.6 seconds, with no ordered fallback replies. Measured
HPS acquisition-to-reply latency averaged 131.4–131.5 microseconds, with
medians of 65–66 microseconds and 95th percentiles of 683–686 microseconds.
These intervals exclude request pickup before HPS acquisition and the FPGA
reply fetch after HPS publication. They are not end-to-end query latency.
The two captures reported 56.6 and 57.0 visible changes per second in the
Mario crop; completed screen updates were about 59.5 per second. Neither
metric establishes whole-game FPS.

The previous reader fetched the 128-byte reply through 16 separate 64-bit
transactions on the legacy DDR channel 3. Each transaction acquired the
channel again and stored two 32-bit cache words. This experiment combines
only that payload into one bounded 16-beat read. It retains the separate
initial session-header read, commit poll and final commit reread.

## Implementation and invariants

`NDS_GX_READBACK_BURST` enables the experiment when defined for the hybrid
product. It is absent from the normal project defaults. Isolated candidate
builds retain the baseline SWAP-retirement, HBlank-queue and GX-busy flags;
the diagnostic PC sampler is disabled. This is a build-time comparison, not
an additional OSD switch or a ROM-address hook.

* `nds_h3d_gx_readback_reply` uses a synchronous 16×64 cache instead of
  32×32. The stored payload remains 1,024 bits. The full read port and half
  selector are registered before selecting the 32-bit output, preserving
  the original synchronous source-read latency and Quartus RAM inference.
* `nds_h3d_readback_legacy_adapter` forwards every returned beat. It retains
  physical ownership through the last beat; cancellation suppresses delivery
  while the old transaction drains. The scalar implementation remains the
  default.
* The legacy `ddram` controller uses its existing exclusive read counter for
  channel 3. Return-data validity remains independent of command waitrequest.
  Other channels retain their request ordering, cache rules and interfaces.
* Session, request ID, magic, reserved fields, status and both commit checks
  remain required. Partial or malformed replies cannot complete the CPU read.
  Reset and session flush discard the logical result without transferring
  old physical ownership to a new request.
* The HPS publisher and its memory barriers are unchanged. There is no stale
  matrix substitution, speculative acknowledgement or graphics-DMA shortcut.

## Reproducible simulation

Run `bash tools/test_h3d_gx_readback_reply.sh`. It covers scalar and burst
readers, direct and actual legacy-DDR paths, at three source/DDR clock ratios.
Cases include delayed acceptance, gapped and consecutive return data, stale
sessions, withdrawn commits, malformed replies, synchronous cache reads,
reset and cancellation during a fill. Every cached word is compared.

The prepublished-reply check asserts **19 DDR commands → 4 commands**, while
both modes still return **19 beats**, including the three validation reads.
Latency printed by this test belongs to its memory model, not the board.
Additional commit polling can increase either command count in real use.

A contention test queues the other five legacy clients behind channel 3 and
checks 24 rounds / 144 commands, including zero, one and 16-beat reply counts,
cartridge bank isolation, framebuffer return data and independent DDR stalls.
Existing cartridge-cache displacement, cartridge read-ahead, large-ROM,
framebuffer/session-clear and non-hybrid input-boundary regressions also pass.

The first synthesis attempt exposed register expansion caused by selecting a
half inside the RAM read expression. That attempt was stopped before hardware
testing. The corrected attempt infers a dual-clock M10K RAM and has the same
total block-memory bits as the baseline. The isolated build completed all four
Quartus stages with the following whole-design results:

| Metric | Retained baseline | Burst candidate |
| --- | ---: | ---: |
| ALMs | 34,475 | 34,651 |
| Registers | 41,223 | 41,148 |
| RAM blocks | 536 / 553 | 537 / 553 |
| RAM bits | 4,130,644 | 4,130,644 |
| DSP blocks | 27 | 27 |
| Worst setup slack | −15.898 ns | −20.154 ns |

The wider RAM costs one additional physical block despite unchanged payload
bits. Neither build closes static timing, and this candidate's setup slack
is worse. Passing the fitter does not qualify it for release.

Baseline RBF SHA-256:
`4e83635200fd64441e0e5055eb707f652e2cb3ea4cdd76807e8706c4b99a5e26`.
Candidate RBF SHA-256:
`6ff0058e7a86219e6fabeec8d9b6815a106b1b5279cb22a7ad52e465840248ac`.

## Board comparisons and decision

Interleaved tests used the same HPS host/helper, 1 GHz clock, US A2DE revision-0
ROM, isolated save seed, display configuration and bounded controller sequence.
Both optional NSMB bookkeeping switches were Off. The diagnostic PC sampler
was disabled. Physical video was captured through the RetroTINK-4K rig.

| NSMB scene / metric | Retained baseline | Burst candidate |
| --- | ---: | ---: |
| World 2-5, repeated jumping: completed updates/sec | 59.50–59.54 (3 runs) | 59.55–59.58 (2 runs) |
| World 2-5: visible Mario-crop changes/sec, clean captures only | 55.60–56.96 (3 runs) | 58.23 (1 run) |
| World 1 castle entrance, repeated jumping: completed updates/sec | 43.89 (1 run) | 42.28 (1 run) |

Completed updates can reuse images; visible-change counts depend on animation
and detector thresholds. These are approximately 20-second scene windows,
not whole-game FPS or extended qualification. The World 2-5 visible-change
detector used a channel threshold of 8 and at least 24 changed pixels. The
clean candidate capture had a 16.7 ms 95th-percentile change interval versus
33.3 ms for the baselines; their longest interval was 50 ms. That is a possible
small smoothness benefit in this scene, not evidence of an overall speed gain.

The second candidate jump capture recorded one OBS render drop. Its raw
visible-change result was 58.35/sec, but it is excluded from clean-capture
comparisons. The castle candidate capture also recorded one OBS render drop,
so no castle video-smoothness gain is claimed. Its independent board counter
was approximately 3.7% lower than the baseline. A single pair cannot establish
a repeatable regression, but it does not support promoting the candidate.

The timed scrolling route was excluded entirely from speed comparisons:
one baseline collected the Mega Mushroom and became giant Mario while another
run retained normal-sized Fire Mario. Those are different workloads even
though the input sequence was identical. The in-place jump captures retained
the same Mario form and location.

The five valid World 2-5 jump traces contained only fast matrix replies, with
no ordered fallback replies. HPS acquisition-to-reply means were 131.4–131.9
microseconds on the baseline and 128.6–131.6 on the candidate. These intervals
still exclude request pickup and FPGA result fetch, so they cannot quantify
the full round-trip saving. Read-only flight-record dumps were taken after the
scored windows. Statistics require complete window coverage in every lane and
zero raced records. Late or raced scroll/castle traces were excluded.

All scored sessions reported zero transport faults. Clean exits returned to
MENU, preserved the original ROMs, saves and settings, and retained the NSMB
isolated save hash. The normal launcher and its runtime hashes were rechecked
after testing. Castlevania and Mario Kart control baselines were collected,
but the rejected candidate did not receive corresponding cross-game runs;
there is no claim of cross-game regression qualification.

The implementation remains available behind its default-off build flag for
future investigation. It adds 176 ALMs and one RAM block, and worsens worst
setup slack by 4.256 ns in this fit. Reducing DDR command count alone has not
produced a sufficiently useful player-visible gain to justify those costs.

## Evidence and next target

Local evidence is retained under `evidence/nsmb-runtime-20261023` in the test
workspace. `READBACK_BURST_MEASUREMENTS.json` records per-run metrics, runtime
hashes, capture paths and exclusion flags; `READBACK_BUILD_COMPARISON.json`
records both exact fits. Primary trials are `QBASE1_JUMP`, `QBASE2_JUMP`,
`QBASE3_JUMP`, `QB1_JUMP`, `QB2_JUMP`, `QBCAST_BASE_JUMP` and
`QBCAST_BURST_JUMP`. Raw captures, hardware counters, query timelines, test
logs, frozen build inputs and clean-exit receipts remain alongside them.

The next useful measurement is the complete geometry-query wait: request
generation, HPS pickup, service/publication, and CPU resumption. The existing
host trace misses the pickup and final-fetch intervals. Establish which
interval dominates before changing polling, adding an interrupt path, or
spending more FPGA space. The native profile still gives little support for
prioritizing named fixed-point math stubs or Wi-Fi bookkeeping removal.
