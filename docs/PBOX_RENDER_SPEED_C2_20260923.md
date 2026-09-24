# HOLD — C2 failed the later Mario Kart race check

Do not use this candidate. The original notes below are historical. C4 restores the general perspective interpolation and passes the added Mario Kart checks. See PBOX_RENDER_SPEED_C4_20260923.md.

# PBOX1 raster speed experiment C2

Based on user-accepted PBOX1 (production 92bc7ec, tests 5525b26). Keep its ordered BOX_TEST and fast matrix-prefix behavior. The FPGA, memory transport, frame admission, screen matching, reset paths, audio and CPU clock are unchanged.

## Change

`GPU3D_Soft.cpp`, `RenderPolygonScanline`:

- When both RGB endpoints are exactly equal, generic/edge pixels interpolate only texture coordinates; constant RGB values remain unchanged. This extends the existing cached-interior optimization to AA edges, shadows and generic interior paths.
- When linear interpolation and equal depth endpoints prove constant depth, use the existing factor-free position update and that exact depth. Linear texture/color attributes do not consume a perspective factor.
- Other generic pixels use the existing exact fast perspective recurrence/resynchronization. Pixel positions remain within the sorted, clipped native span, so the existing 0..256 factor bound applies.

No visibility, alpha, depth-test, stencil, blending or coverage decisions are removed. No frames are reused or skipped by this change.

## Validation

- Host and emulated ARM full helper self-tests pass, including shadow, anti-aliasing, raster cancellation/recovery and screen ownership tests.
- All 262 ROM-free raster scenarios match the accepted baseline's visible color, native color, depth and attribute hashes on host and ARM. This cross-binary comparison is required because the internal generic oracle shares scanline setup.
- Native MiSTer snapshot tests render full private-memory scenes 100 times per sample, three samples per variant in interleaved order. Both variants run at the same normal MENU clock (800 MHz); production gameplay remains stock 1 GHz. Original saves/configuration were hashed before and after and did not change.
- Native scene hashes agree for Castlevania's opening (14 polygons), the Pokémon room (289) and two NSMB castle views (384 each).

Initial median rendering CPU time changes: Castlevania -6.57%, Pokémon -1.55%, NSMB castle views -0.83%/-1.34%. Small gains may be within run-to-run variation; these are isolated renderer measurements, not gameplay FPS improvements. A live Castlevania ABBA comparison at stock 1 GHz (diagnostics off) also passed: baseline 53.08/52.57 publications per second versus C2 54.42/54.63, a 3.21% mean increase. Each window covered published source frames 900..2700, with source pacing about 59.9/s, no reported header faults and unchanged save/configuration hashes. Publications are not unique gameplay FPS.

Private evidence (not a distribution of game data): the local `evidence/pbox-render-20260923` directory. Includes exact binaries, CPU sample traces, independent baseline/candidate output hashes, native results, commands, and the smaller first trial. No ROMs/saves/snapshots should be published.

## Hardware pairing

Unchanged PBOX1 core SHA-256: `063eea5a39d60e3ffe673fc44cb6845b8dcc49d7ae313f4cd16c963812ca7731`.

C2 helper: `3ebc32ac5425766e2a9c8b11bb54f9eea80b738052aa8ba25ace31edb5c9b8d8`.

Accepted fallback helper: `61159b76f8e682a590eb39584b8e07db74edede165d0f20cda1763a38e43729f`.

Private MiSTer selector: `Scripts/NDS_Test_Pokemon_Speed_20260923.sh`. The accepted fallback remains `Scripts/NDS_Test_Pokemon_Room_20260923.sh`. Both select a verified pair without loading a ROM. C2 is a speed experiment awaiting user playtesting, not an accepted release.
