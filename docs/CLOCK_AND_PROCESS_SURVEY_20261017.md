# Clock experiment and process survey — 17 October 2026

**Do not promote 1.2 GHz.** A repeated live trial lost both video and network
access. The first trial was faster, but the experiment did not pass stability
qualification. Frozen private Beta12 and its normal 1 GHz setting remain
unchanged. No boot configuration, voltage setting, runtime source or package
was changed by this experiment.

## Clock measurements

The current kernel advertises 1.0 and 1.2 GHz boost operating points. The
experiment used its existing CPU-frequency interface, an independent temporary
restore journal and a watchdog. It did not alter the launcher's normal clock
restore journal. Setup ran at 1 GHz; each timed live trial changed frequency
while the game was paused and requested restoration immediately afterward.

The initial native pilot reused the frozen renderer benchmark, with five saved
scenes, 16 warmup renders and 100 measured renders per sample. Each scene used
1.0 / 1.2 / 1.2 / 1.0 GHz order. All 20 runs completed; the color, depth and
attribute hashes before and after each timing loop matched, including across
clock settings. This was not a separate buffer comparison after every render.

| Saved scene | 1 GHz wall time per render | 1.2 GHz wall time | Render throughput change |
| --- | ---: | ---: | ---: |
| Castlevania cave | 13.62 ms | 11.99 ms | +13.6% |
| Castlevania combat | 12.79 ms | 11.13 ms | +14.9% |
| NSMB castle | 8.44 ms | 7.34 ms | +14.9% |
| NSMB castle-left | 8.40 ms | 7.28 ms | +15.3% |
| Mario Kart heavy scene | 22.77 ms | 19.72 ms | +15.5% |

These are repeated-snapshot renderer timings, not live game FPS. The native
clock and normal MiSTer process were restored and verified afterward.

The planned live comparison used the exact frozen Beta12 helper, fresh isolated
saves and the same 1.0 / 1.2 / 1.2 / 1.0 GHz order in the cave, combat and NSMB.
Only the first cave baseline and first 1.2 GHz sample completed:

| Cave, one 22-second sample per clock | 1 GHz | 1.2 GHz |
| --- | ---: | ---: |
| Completed screen pairs per second | 22.69 | 28.50 |
| Picture-ready gap, 95th percentile | 52.55 ms | 42.81 ms |
| Picture-ready gaps over 50 ms | 48 | 1 |
| Worst picture-ready gap | 61.84 ms | 51.20 ms |

The first observed throughput increase was 25.6%. These counters describe
completed publication pairs, not unique animation FPS. Both timelines were
unraced, both captures had zero reported encoding/render drops, and audio was
present. Reviewed contact sheets showed the expected cave scene without obvious
corruption. Audio presence is not a listening test. Analog pixel-change counts
depend strongly on thresholds and paused-frame noise, so they are not used to
claim exact visible FPS.

Both completed trials restored 1 GHz and verified the protected paths and save.
The **second 1.2 GHz live attempt failed**: the capture went black and the
RetroTINK subsequently reported no signal; SSH and ping stopped responding.
The batch aborted and its software restoration could not reconnect. A physical
power-cycle was requested. Final device restoration and post-failure save checks
remain pending. The independent watchdog cannot guarantee recovery when Linux
or the board is unresponsive.

The exact failure cause is unconfirmed without recovered system evidence.
No temperature sensor was exposed. Do not label this as proven overheating,
claim long-term stability from the native pilot, or discard the failed repeat.
The final cave baseline and all live combat/NSMB comparisons were not run.
The first favorable live sample therefore does not qualify a clock change.

## Background processes and existing pipeline evidence

A read-only process census covered approximately 5.6 and 21.2 seconds at the
restored NSMB selection screen. In the longer interval the helper used about
124.5% of one CPU core, the host 3.6%, and the active supervisor 1.2%. The
temporary measurement process used 1.5% and exited. Network, Bluetooth and
file-serving daemons had no measurable CPU use in these intervals; the resync
process used about 0.05%. This is menu-state evidence, not a gameplay-wide
guarantee that background work never occurs.

No service shutdown was justified or attempted. The standalone launcher already
stops normal MiSTer Main during play and restores it on exit.

Reanalysis of twelve existing frozen-baseline captures found zero replay-queue
full polls and zero publication replacements in the sampled active interiors.
The 10 Hz rows were selected strictly between each same-session active-window
publication counter; this omits the margins and is not exact wall alignment.
These counters do not measure all FPGA guest stalls or prove the transport is
free of latency. Where the complete timeline was unraced, ready-to-upload delay
was small relative to admission-to-picture time. Overlapping stage wall times
must not be added together as CPU cost.

The practical outcome is to stop service-killing experiments and retain 1 GHz.
Investigate the overclock failure only after recovery, with explicit evidence
about board, power and kernel behavior. The stock-clock optimization question
remains rendering/pacing; this batch does not justify another small unmeasured
renderer patch or a new FPGA build.

## Evidence identity

- Frozen source: `1d3a33361730ca0d2f9123c578378bca40463aad`.
- Frozen helper SHA-256: `5510089f11be99c2bf56e80bca4cc784ccbbc418ce951514d78d352140a151a8`.
- Native benchmark SHA-256: `e38314b2f0117ea559f3cb05ffb7d4547a1e45de8b8246daf6d2eab32f7b6986`.
- Private experiment identifier: C60. Plan, all native samples, both completed
  live captures, failed-repeat recording, surveys and restoration failure are
  retained privately. No ROMs, saves, binaries or captures belong in Git history.

The frozen ZIP and selected-beta pointer were hash-verified unchanged after the
failure. OBS recording was stopped and its input/video settings verified
unchanged. Hardware recovery is still required.
