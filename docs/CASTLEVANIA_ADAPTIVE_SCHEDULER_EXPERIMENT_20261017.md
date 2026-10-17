# Adaptive two-way scheduling experiment, 2026-10-17

Disabling the four-band queue globally was rejected. The existing adaptive two-way path reduced saved-scene elapsed rendering time in Castlevania and NSMB, but increased the Mario Kart control by 5.698%. The result motivates a separately qualified cartridge-specific experiment; it does not establish a new beta or gameplay speed gain.

This experiment uses the exact accepted Beta10 helper and core library. The sole runtime-setting difference is `NDS4MISTER_RASTER_BAND_QUEUE=0`; adaptive splitting and the existing shadow/X-partition logic remain enabled. No runtime source changed. The accepted helper passed its full self-test in Docker with the queue-disabled environment. All 160 serial, split, queued and delayed-worker full-buffer comparisons matched the accepted reference.

A single native benchmark binary selects the queue setting before renderer construction. Six samples per mode and scene were measured in baseline/candidate/candidate/baseline order, three samples per position, with 16 warmup and 100 measured renders. All complete output hashes matched. The MiSTer remained at stock 1 GHz; the verified menu process was temporarily parked with a watchdog and restored afterward.

| Saved scene | Median CPU cost change | Median elapsed cost change |
| --- | ---: | ---: |
| bat-live | -2.691% | -4.336% |
| combat-live | -2.880% | -4.884% |
| nsmb-castle | +0.061% | -10.186% |
| nsmb-castle-left | +0.058% | -10.531% |
| mario-kart-heavy | -0.044% | +5.698% |

Negative means faster. The predeclared native gate required both Castlevania elapsed gains above 1% and no NSMB/Mario Kart control regression above 1%. Mario Kart failed. These are isolated rendering measurements without the live packet-input thread's contention, not game FPS. The test does not prove that live adaptive scheduling is faster.

The benchmark SHA-256 is `489ebecf2563944c3594c87425251d1a2b6448bdb1b899507b9d4badfe21145a`; accepted helper `a0ef8246dbdffd15cc861018f2604a969c0af18cd14ccec93de9d3eba56fd4dd`; core library `cf81566afbb468ec462c6f8a74964db969c02b87bd3408354a7736313e42bf59`.

No gameplay kit or package was installed. The original NSMB runtime and save, 54 protected files, stock clock, menu affinity and OBS settings were restored, and the game-selection menu was visually verified. Private evidence: `castlevania-adaptive-two-way-performance-20261017`.
