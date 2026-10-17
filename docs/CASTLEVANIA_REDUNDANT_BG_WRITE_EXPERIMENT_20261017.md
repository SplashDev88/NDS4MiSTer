# Redundant BG write prototype — no promotion

Comparing each mapped physical background bank before writing did not improve the cave's live throughput. Two Beta9 samples average 19.68356 completed publication pairs/s; two candidate samples average 19.68084 (−0.014%). This is effectively flat and below the 1% acceptance threshold. Beta9 remains the accepted private beta; the prototype is not integrated.

The exact Castlevania profile uses the shortcut for ARM9 halfword/word writes and eligible packed word pairs to Engine-B background VRAM. Actual changes still store their bytes, retain existing dirty bits and advance revisions for the changed physical banks. Comparing the OR of overlapping banks would be incorrect; each bank is compared independently. Engine-B-only capture synchronization and other cartridge profiles retain their original paths. Timestamps, replay ordering and all renderer arithmetic are preserved.

Full ARM service tests pass, including the existing 98,304 packed-pair cases. A new oracle covers 3,840 logical writes, including 2,827 no-op cases and 48 with only some mapped banks changing. It checks complete physical VRAM, exact expected dirty bits, per-bank revision changes and coherent flattened background memory against the original write operation. Paired, direct-output and Engine-B cache tests pass. All 851 source inputs were verified and the private build checkout restored.

Native measurements use CPU0 at stock 1 GHz with the verified MENU process stopped on CPU1, then restore clocks and MENU. Six samples per binary and workload use ABBA order. The benchmark calls the actual replay-packet method and makes background VRAM coherent after each packet. All final physical/flat-memory hashes match.

| Fixed replay workload | Beta9 ns/record | Candidate ns/record | Change |
| --- | ---: | ---: | ---: |
| Unchanged BG pairs | 195.965 | 218.380 | +11.44% |
| Changing BG pairs | 194.963 | 239.867 | +23.03% |
| Unchanged BG words | 287.070 | 294.266 | +2.51% |
| Changing BG words | 289.946 | 310.983 | +7.26% |
| Mixed regions, pairs | 222.313 | 177.466 | −20.17% |
| Other profile, BG pairs | 436.498 | 436.081 | −0.10% |
| Unchanged BG pairs, four-byte offset | 199.959 | 228.820 | +14.43% |
| Other profile, BG words | 288.176 | 287.229 | −0.33% |

The mixed native result justified a live check; it did not predict a whole-game improvement. All four 22-second cave recordings show complete scenery and animation at HP132/EXP69, no capture drops or protocol faults, audio presence, stock clock, unchanged isolated saves and all 54 protected files. Source publication pairs are not distinct animation FPS. Combat and NSMB acceptance captures were not run after the cave gate failed.

ARM disassembly shows calls to `__memcmpeq` inside both ordinary and packed replay paths. A separate follow-up replaces the tiny generic comparisons with fixed-width comparisons. It requires fresh qualification and measurements; no gain is claimed for that revision here. Exact empty-sprite line reuse is another independent possibility because suppressing background invalidation still leaves OAM dependencies.

Private candidate helper SHA-256: `db67bbbc2943022dc20d0dee8e8d08a90c770714395dea32d0bb4a8aca02fdca`.

Private evidence: `castlevania-redundant-bg-write-performance-20261017`.
