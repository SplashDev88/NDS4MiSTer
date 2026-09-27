# FFT A2 startup logos: busy GX reply fallback

## Symptom and isolation

After accepting the restored FFT menu speed, the user reported grey boxes
in the startup logos when selecting FFT again through Load NDS. The title
menu subsequently looks correct. Captures reproduced the issue after both
a ROM reload and a fresh core/helper start. This is not solely stale reload
state. Disabling the decoded texture cache did not correct it.

The ARM framebuffer already contains the corruption. During the Square Enix
logo, the hardware stream builds a fullscreen clipped quad; the full-CPU
melonDS reference builds the expected quad at x=0..255, y=84..116. Vertex
inputs and texture address `0x055f9e80` agree, but the game's submitted
MTX_MULT_4x4 differs:

| Reply path | X/Y scale | XYZ translation | Result |
|---|---|---|---|
| Unrestricted fast prefix | 131072, -174763 | -4096, 4096, -4096 | Clipped grey rectangles |
| Ordered verification mode | 3200, 4266 | 0, -171, -4095 | Correct logo |
| Fast prefix with busy fallback | 3200, 4266 | 0, -171, -4095 | Correct logo |

The middleware logo also returns to its correct x=64..191, y=32..159 bounds.
The ordered verifier reports no matrix mismatch in the bad run: agreement
at individual query fences alone did not validate this early-reply behavior.
The precise guest/FPGA timing interaction is not yet fully characterized.

## Change

Keep geometry/test-busy prefix snapshots on the existing ordered reply path
(`GXSTAT & 0x08000001`). Do not invalidate the prefix or discard its queued
commands. Once a later snapshot is settled, immediate replies resume. This
preserves the accepted queue compaction and inexpensive-command cost bounds,
100-us query polling, write-combining, and normal MiSTer launcher.

No game ID, startup timer, image suppression, or texture substitution is used.
The FPGA image and its resource use are unchanged. ARM remains at 1 GHz.

## Validation

- Complete ARM-emulated helper self-test passes, including ordered
  readbacks, partial matrix/BOX commands, reset/session ownership, rendering,
  and the existing 256-query independent fast-reply burst.
- Extended SWAP test holds replay stopped and verifies that a busy prefix
  does not publish early; after architectural VBlank, a settled query does
  publish immediately without waiting for replay to resume.
- Hardware captures show both startup logos restored with zero fault words.
  A private read-only sample found 4,831 fast publications out of 4,844
  verified replies; only 13 used the ordered path.
- A 25-second FFT title/menu window measured 59.77 source frames/s,
  29.87 paired publications/s and 672.57 queries/s, against 59.85, 29.93
  and 672.81 in the accepted helper's previous same-scene window. These
  are essentially unchanged, but source-frame rate is not unique visual FPS.
- Moving NSMB/Castlevania performance was accepted for the parent helper.
  Those moving scenes have not been re-measured for this narrow change.

External evidence is under
`evidence/fft-reload-startup-20260927/` in the workspace root. Earlier
performance evidence is under `evidence/query-burst-20260927/`.

The accepted parent helper is preserved (`e905ec9f...`). The final test helper
SHA-256 is `91ce15eed06269380b78ba505e6f5cb19eeb99d3845ce21fb176566a390febe3`.
The user confirmed "works great" after testing the final candidate and
requested packaging as the FFT regression fix. This is the accepted
v0.5.2 runtime; packaging preserves these exact tested binaries.
