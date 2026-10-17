# Metadata-validation experiment, 2026-10-17

A compact scanline-metadata range check was rejected after native timing. Host and ARM correctness checks passed, but paired/mixed packet acquisition became slower and the regression gate failed. Castlevania Beta10 remains accepted. No full service or gameplay installation was made.

The only runtime change replaces the original high-bit, valid-tag and line-range conditions inside `Consumer::validate_record` with an equivalent unsigned range check. After the existing readback-fence and packed-GX exceptions, the high twelve metadata bits must be zero or fall within 512 through 774 inclusive. This rejects reserved bits and preserves valid lines 0 through 262. There is no new dispatcher, class field, validation loop, buffer-lifetime change or protocol relaxation.

Both host and emulated ARM passed 38,797,312 full-validator comparisons against the original function: every 12-bit stamp and every 8-bit record kind across selected tag, byte-enable, address-alignment and data boundaries, plus randomized records. Both passed the full protocol suite and its additional 40 accepted mixed packets and 90 malformed-pair rejections.

Native cached-RAM measurements used six samples per build/shape/diagnostic mode in baseline/candidate/candidate/baseline order, three samples per position. Each sample had 32 warmups and 1,000 acquisitions. Full payload and acknowledgement checks ran outside each timing interval. The verified MENU process was temporarily parked with a watchdog; the clock remained at stock 1 GHz.

| Shape | Diagnostics | Median acquisition-time change |
| --- | --- | ---: |
| pairs_small | off | +4.701% |
| pairs_untagged | off | +8.509% |
| pairs_tagged | off | +6.871% |
| pairs_max | off | +7.528% |
| mixed_pairs | off | +7.148% |
| gx_packed_small | off | +1.607% |
| gx_commands_small | off | -4.881% |
| hblank_small | off | +2.973% |
| gx_packed | off | +4.093% |
| gx_commands | off | +5.811% |
| hblank | off | +5.781% |
| legacy_vram | off | +8.574% |
| pairs_small | on | +6.381% |
| pairs_untagged | on | +9.475% |
| pairs_tagged | on | +7.541% |
| pairs_max | on | +7.494% |
| mixed_pairs | on | +5.217% |
| gx_packed_small | on | +1.377% |
| gx_commands_small | on | -2.679% |
| hblank_small | on | +2.343% |
| gx_packed | on | +4.862% |
| gx_commands | on | +6.434% |
| hblank | on | +10.894% |
| legacy_vram | on | +3.525% |

Negative means faster. The predeclared gate required paired/mixed gains above 1% and no control regression above 1%; it failed. These synthetic cached-RAM measurements do not establish live game performance or isolate the generated-code reason for the slowdown. A shorter source expression is not sufficient evidence of an optimization.

The original NSMB runtime and save, 54 protected files, stock clock, menu affinity and OBS settings were restored and the game-selection menu visually checked. Private evidence: `castlevania-metadata-validation-performance-20261017`. No accepted-beta pointer or public release changed.
