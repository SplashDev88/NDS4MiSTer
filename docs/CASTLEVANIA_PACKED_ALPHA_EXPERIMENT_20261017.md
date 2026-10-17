# Packed alpha arithmetic: no promotion

Combining the red and blue channels into one unsigned interpolation multiply did not produce a useful Castlevania speed gain. The private prototype is excluded from Beta10; no full helper was built or installed for it.

The candidate replaced the general alpha blend's three channel multiplications with two. Masked red and blue lanes share a 32-bit unsigned calculation; green is separate. Transparent-destination bypass, disabled blending, output alpha, and unused channel bits retain their original behavior. The existing gray-specific blend is unchanged. Since the general blend serves other games too, native controls include NSMB and Mario Kart.

## Correctness

An independent weighted-sum oracle passes all 536,870,912 packed red/blue input and weight combinations, including inter-lane subtraction borrows. Another 4,456,448 directed and randomized cases call the actual linked alpha-blend method and match the independent reference, covering all destination alpha values, transparent destination bypass, disabled blending and unused bits.

The 512 gray raster cases match full baseline color, depth and attribute buffers. All 5,388 broader raster cases match the unchanged Beta8 3D baseline; 5,132 also match an independent uncached reference. The remaining 256 one-pixel compatibility cases retain existing baseline differences. Forty-eight sequential snapshots also match, including ten non-gameplay combat frames, as do 160 serial, split, banded and delayed-worker full-buffer comparisons.

## Physical Cortex-A9 timing

Each scene has six samples per binary in baseline/candidate/candidate/baseline order, with 16 warmup and 100 measured renders per sample. Both raster workers run at stock 1 GHz, with the verified frontend parked and restored. All complete color/depth/attribute hashes match. The baseline uses the accepted Beta10 library and sources.

| Scene | Renderer CPU time change | Renderer wall time change |
| --- | ---: | ---: |
| Cave / bat platform | −0.143% | −0.336% |
| Warg combat | +0.578% | +0.410% |
| NSMB castle | +0.331% | +0.369% |
| NSMB castle left | +0.324% | +0.431% |
| Mario Kart heavy | −0.570% | −0.532% |

Negative values mean less time. Neither target scene clears the 1% native improvement gate, and combat is slightly slower. These are isolated renderer measurements, not whole-game FPS; no live gameplay comparison was justified. Fewer arithmetic operations did not translate into a useful measured improvement on this processor and workload.

The original NSMB installation, save, 54 protected files, stock clock and OBS settings were restored and checked. The completed game-selection menu was visually verified; an earlier snapshot taken during startup was black and was not accepted as restoration evidence.

Private evidence: `castlevania-packed-alpha-performance-20261017`. The source patch, binaries, exhaustive oracle, hashes and individual timings are retained there. Accepted Beta10 and the general Performance Beta6 package remain unchanged.
