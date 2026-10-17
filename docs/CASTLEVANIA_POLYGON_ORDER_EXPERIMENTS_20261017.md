# Castlevania polygon-order experiments — rejected

Beta8 (`3c71cb55e1b8256f3ccab67ed4e399093482e995`) remains the accepted
Castlevania build. Neither experiment below is integrated into this branch or
packaged as a beta.

The first prototype rendered all visible rows of each polygon together, keeping
polygon order at every pixel. It applied only to full-frame rendering with the
existing exact Castlevania profile, and fell back before any writes when a frame
contained shadow polygons. Pixel routines, frame admission, geometry, FPGA,
clock settings and the four-job scheduler were unchanged. The second prototype
also selected the prepared rectangle row routine once per polygon.

Both prototypes matched Beta8 on 5,900 complete color/depth/attribute-buffer
cases (5,644 also matched the independent uncached reference), 48 sequential
snapshots and 160 serial, split, queued and delayed-worker frames. The first
prototype also passed the complete ARM service self-test. Its helper SHA-256 was
`7afa0a2596efe2683ec509397f161cdc5263b245f1984cb4cfedbe8b10bcc089`.
The second did not advance to a full service build or installation.

## Why the apparently faster renderer was rejected

An isolated single-core test initially showed 1.07% less rendering CPU time in
the saved cave frame and 2.43% less in combat. Live testing through the
RetroTINK-4K then found a repeatable slowdown:

| Cave test, in execution order | Completed publication pairs/s |
| --- | ---: |
| Beta8 | 19.3653 |
| Polygon order | 18.2272 |
| Polygon order repeat | 18.2399 |
| Beta8 repeat | 19.2675 |

The mean declined from 19.3164 to 18.2336 pairs/s, **5.61% slower**. The
95th-percentile publication intervals increased from 60.58–60.97 ms to
63.28–63.52 ms. All four captures showed the same cave platform, complete
background textures, and unchanged HP/experience. There were no OBS encoding
or rendering drops, no reported protocol faults, and audio was present.
The 54 protected files and the original saves remained unchanged during these
windows, at the stock 1 GHz ARM clock.

A short combat capture remained visually correct but used a different enemy
phase, so it is a compatibility observation rather than a comparable speed
measurement. The remaining gameplay control repetitions were cancelled after
the target regression was reproduced. Publication pairs are not distinct
visible animation frames, and these measurements do not establish game FPS.

## Two-core follow-up

A closer rendering-only benchmark enabled the normal two-core, weighted
four-job configuration. The hash-verified MiSTer menu process was temporarily
parked so it could not occupy the second core. A watchdog and final cleanup
restored it, its affinity and the clock settings. Each binary had six samples
of 100 renders per saved scene; all complete output hashes matched.

| Saved scene | Polygon order CPU time | Polygon order elapsed time | With row dispatch CPU time | With row dispatch elapsed time |
| --- | ---: | ---: | ---: | ---: |
| Cave/bat | +10.74% | +10.03% | +11.00% | +8.47% |
| Combat | +7.48% | +5.05% | +6.83% | +1.95% |
| NSMB castle | +0.30% | +0.44% | +0.45% | +0.41% |
| NSMB castle, left | +0.71% | +0.87% | +0.34% | +0.87% |
| Mario Kart heavy | -0.01% | +0.46% | +0.28% | +0.13% |

Positive percentages mean slower than Beta8. This reproduces the direction of
the live regression without gameplay timing variability. It does not by itself
identify a particular cache or scheduling mechanism. Both traversal variants
are rejected; future renderer candidates must pass the two-core test before
advancing to gameplay qualification.

Private receipts and patches are retained in
`castlevania-polygon-order-performance-20261016` and
`castlevania-polygon-dispatch-performance-20261016`. No public release was made.
