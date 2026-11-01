# FFT A2 regional renderer ports

The accepted USA renderer optimization now selects the exact owned European
A6FP revision 0 and Japanese A6FJ revision 0 headers. The existing USA selection
remains intact. Only the selector and its test changed in the frozen renderer
build; the renderer algorithms, query/VRAM policy, host and FPGA did not change.
No experimental FFT guest-code patch is enabled.

| Identity | Original screen pairs/s | Regional candidate | Change |
| --- | ---: | ---: | ---: |
| A6FP rev0 | 21.3129 | 23.0647 | +8.2194% |
| A6FJ rev0 | 21.0745 | 23.1164 | +9.6890% |

Each comparison uses one 30-second cold-start window per arm at stock 1 GHz,
the same imported ordinary USA Quick Save and the same Luso forest battle
command menu. These are completed screen publications, not unique animation
FPS or whole-game speed. No repeat or confidence interval is claimed. Four
sampled video frames per arm preserve the corresponding regional scene and
UI. All four recordings pass capture checks; review copies preserve game-audio
packets and timestamps. No human listening or full-motion approval is claimed.

Direct read-only inspection of the exact regional renderer confirms its
raster-only flag is enabled, other raster flags remain off, query mode stays 2,
frame skipping stays off, and both HPS clocks remain 1 GHz. Japanese original
also directly verifies the old profile is off. Exact ROM hashes and stable
loaded headers are pinned separately. The unchanged raster implementation
reuses the accepted 144-frame/172,979,712-byte offline raster proof; this is
shared algorithm evidence, not a new regional framebuffer replay. The rebuilt
ARM renderer self-test and three-region identity/fallback tests pass. Changes
to game code, revision or header fingerprints fall back.

Both regions cold-load the imported checkpoint and write normal 64 KiB Quick
Saves. Japanese fresh-process Continue restores the newly written save; the European
new-save cold load is the actual archive delivery gate, recorded in
INSTALLATION_VALIDATION.json. Quick Save consumption on Continue is expected
game behavior. The Japanese completion screen says power may be turned off.
An attempted same-process title-return sequence left black output; its saved
file stayed unchanged. That speculative warm-return sequence is unqualified
and is not classified as a renderer-caused defect. Imported USA player
name encoding in Japan also appears in the unmodified baseline; this is not
independent Japanese new-game or localization validation. Broader battles,
spells, later areas and full playthroughs remain outside this bounded port.

Evidence: FFTA2_OWNED_IDENTITIES_V1.json,
FFTA2_REGIONS_BUILD_STATUS_V1.json, FFTA2_REGIONS_QUALIFICATION_V1.json,
A6FP_RASTER_NATIVE_IDLE_MEASUREMENTS_V1.json,
A6FJ_RASTER_NATIVE_IDLE_MEASUREMENTS_V1.json,
FFTA2_REGIONS_BEFORE_AFTER_V1.csv. Review videos are
FFT_Europe_Original_V1.mp4, FFT_Europe_Candidate_V1.mp4,
FFT_Japan_Original_V1.mp4 and FFT_Japan_Candidate_V1.mp4.

Regional Beta7 also includes the seven new Platinum identities. Three completed
their bounded reference/native checks; the remaining four explicitly skip
further gameplay validation at the user's direction. Their identity, overlay,
original-byte and data guards remain intact. Unknown revisions and the two
Europe-labelled revision-10 Pokémon images remain outside admitted coverage.
No public release is authorized.
