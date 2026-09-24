# PBOX1 ARM raster candidate C4 — 2026-09-23

Built on accepted PBOX1 (helper `61159b76...`). Same FPGA core, clocks, frame policy, WC writes, matrix-readback fix, and Pokémon room visibility fix.

The final changes skip constant RGB interpolation and constant linear depth work on generic/edge pixels, and inline the per-pixel shader dispatch. Generic perspective positioning retains the accepted SetX calculation. C2/C3 incorrectly extended the bounded interior SetXFast path to general edge pixels; a 1,226-polygon Mario Kart demo race exposed changed color and depth hashes, so those candidates are held.

C4 helper SHA-256: `a4c5105a548edf1b95f0ac56a132cc1114273e6b84a92c9ab814c5bd71df3e61`.

Validation: host and ARM service self-tests pass; all 262 synthetic native color/depth/attribute hashes match the accepted baseline independently; six native game samples also match exactly. Private game-derived fixtures remain outside Git.

On MiSTer at its unchanged MENU 800 MHz, three interleaved 100-render runs per variant gave median renderer CPU savings: Castlevania 12.78%, Pokémon room 3.17%, NSMB castle 0.44% / left view 0.48%, Mario Kart heavy -0.10% / light -0.52%. Sub-percent results are effectively unchanged. These are renderer CPU timings, not gameplay FPS. Live Castlevania source-frame window 900..2700, ABBA: baseline 52.5177/52.7728 completed publications/s; candidate 52.8708/52.8665 (+0.42%). This is a small whole-game result, not a 13% FPS gain. Stock game clock remains 1 GHz; diagnostics were off; save/config hashes were unchanged.

Mario Kart live smoke tests progressed on both screens without telemetry faults, including Shroom Ridge and Peach Gardens. Its auto-demo chooses different tracks between launches, so those live publication rates are not a valid matched speed comparison. Use the fixed-state CPU timings above.

Later C5 packing and C6/C7 guarded-fast-interpolation experiments were not selected: they produced small mixed gains or slowed the heavy Mario Kart sample. C7 is preserved on branch `perf/pbox-guarded-edge-trial-20260923` at abf1655, including a ROM-free extrapolated-edge regression test. It is not part of this candidate. The first divergence that caught C2 was pixel109 for span[110,112], W24408/22515: the required wrapped factor is99420, outside the fast divider's <=256 proof. C4 retains the general SetX path for these edges.

Evidence: `evidence/pbox-render-next-20260923` in the outer workspace. Accepted fallback selector remains `NDS_Test_Pokemon_Room_20260923.sh`; candidate selector is `NDS_Test_Pokemon_Speed_20260923.sh`. Neither is a published release.

Final hardware checks: FFT A2 title/menu visible, Pokémon private save loads into the bedroom with character and desk/TV/bed furniture visible; no header faults in captures. Device selector loads C4 without a ROM and retains accepted PBOX1 as a separate fallback.
