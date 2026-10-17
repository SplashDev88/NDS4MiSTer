# Timing-counter experiment — no promotion

Turning off the optional standalone pacing statistics increased the mean cave publication rate by 0.606%, below the experiment's 1% acceptance threshold. Beta9 keeps its existing diagnostics. This result does not justify a new beta or establish a repeatable gameplay improvement.

The candidate uses the exact Beta9 helper, SHA-256 `2735e074ac8e766cdf2ee7d3ecf290a34b84f120fe4a11981d689d1473ac8ece`. Only `NDS4MISTER_STANDALONE_PACING_TRACE` changes from 1 to 0; the causal RAM timeline remains enabled. Source review found timing/counter work behind this flag, with admission and scheduling decisions outside it. Full ARM service self-tests passed with either flag value. Renderer correctness qualification is inherited from Beta9; the renderer was not recompiled.

| Cave capture | Published pairs/s | Median interval ms | p95 interval ms |
| --- | ---: | ---: | ---: |
| Beta9 first | 19.75874 | 50.435 | 60.036 |
| Counter-off clean | 19.84727 | 50.194 | 58.450 |
| Counter-off repeat | 19.92862 | 50.084 | 59.315 |
| Beta9 repeat | 19.77766 | 50.401 | 59.548 |

The two-run means are 19.76820 and 19.88795 pairs/s. All four accepted 22-second captures show a complete cave/platform at HP 132 and experience 69, zero protocol faults and capture drops, audio presence, unchanged isolated saves and all 54 protected files, and stock 1 GHz. The actual helper executable and both environment flags were verified outside each measured window. Bat phases vary. These are source publication pairs, not distinct animation FPS; audio presence is not a fidelity qualification.

An earlier counter-off capture measured 19.93722 pairs/s but had one OBS rendering drop. Its evidence is preserved and excluded. The replacement used a fresh isolated suspend. Combat and NSMB acceptance captures were not run because the cave gain gate failed. No settings in the accepted Beta9 package were changed.

Private evidence: `castlevania-pacing-counter-performance-20261017`.
