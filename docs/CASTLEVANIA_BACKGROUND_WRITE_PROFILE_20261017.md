# Redundant second-screen background writes — 17 October 2026

A private probe found that every observed Engine-B background write stored the bytes already present in the cave and Warg combat samples. Avoiding those redundant writes and dirty/revision updates is the next bounded experiment. This is diagnostic evidence, not an accepted speed improvement.

| Scene | LCD admission intervals | Physical stores | Bytes written | Changed bytes |
| --- | ---: | ---: | ---: | ---: |
| Cave, 22 seconds | 1,318 | 4,081,951 | 32,391,168 | 0 |
| Warg combat, 6 seconds | 358 | 1,040,488 | 8,257,536 | 0 |

All observed writes target bank H. Both scenes retain `DISPCNT=0x11c00`, `BG2CNT=0xe00`, `BG3CNT=0xf01`, and background bank mask `0x80`: Engine B uses text backgrounds. This probe compares bytes immediately before each physical store in `WriteVRAM_BBG`, counting overlapping targets separately. Its intervals include replay work for omitted pictures; they are not restricted to rendered frames. It does not observe LCDC, ARM7 or display-capture writes to those physical banks.

The preceding bank-specific probe found background revisions newer on every cached line, with no newer OBJ or extended-palette bank revisions. The current probe again finds zero whole-line cache hits across 70,464 cave lines and 17,856 combat lines. OAM/sprite state independently invalidates most lines, so removing redundant background invalidation alone does not promise whole-line reuse.

The diagnostic retains Beta9 pixel rendering, all memory stores and dirty/revision updates, frame admission and clocks. Full ARM service self-tests passed with profiling off and on. A ROM-free counter oracle checked 1,184 logical stores for each gate value, across all eight combinations of banks C/H/I, mirrors, boundary addresses, repeated values and mixed changed bytes. All 851 source inputs were verified and temporary build overlays restored.

Both recordings show complete scenery and animation, zero protocol fault words and OBS drops, audio presence, stock 1 GHz, unchanged measured saves and all 54 protected files. Cave HP132/EXP69 is stable; combat HP99 declines to39 with EXP69. Enemy phases vary. Audio presence is not full audio qualification. Instrumentation reduces performance, so diagnostic publication rates are excluded from optimization acceptance and are not distinct animation FPS.

The proposed shortcut must compare each mapped bank independently, preserve existing dirty bits, timestamps and mapping coherence, and leave writes that change data intact. It will use the existing exact Castlevania profile and retain the capture-synchronized fallback. No diagnostic helper is included in the accepted user-test beta.

Private evidence: `castlevania-cache-bank-profile-20261017` and `castlevania-bg-write-profile-20261017`.
