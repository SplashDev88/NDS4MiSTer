# Castlevania packet-validation experiment, 2026-10-17

The global paired-VRAM validation shortcut was rejected. It reduced native acquisition time for paired and mixed VRAM packets, but increased acquisition time for the non-pair control distributions. Castlevania Beta10 remains the accepted runtime; this experiment was not built into a complete service, installed as a gameplay runtime, or released.

## Hypothesis and implementation

The accepted Beta10 instruction samples put 7.261% of cave leaf samples in `Consumer::begin_into`. Further inspection found 755 of that function's 1,038 cave samples on three principal payload-copy instructions (213 of 306 combat samples). Statistical sample locations can skid: these are not exact instruction-cycle counts. The whole function's sample share must not be interpreted as validation cost.

The private candidate recognizes a valid paired-VRAM record using a compact metadata, alignment and timestamp predicate before the existing validation loop. All other records retain the existing validator. Paired VRAM records are excluded from diagnostic CRC selection; a compile-time assertion and the predicate oracle check that property. Copying, vector lifetime, header snapshots, barriers, session checks, ownership and acknowledgement order are unchanged.

This is distinct from the earlier rejected packet-buffer-reuse experiment. It introduces no buffer reuse or lifetime change.

## Correctness qualification

- Host and ARM predicate tests each passed 47,235,072 cases against the original validator, covering all low metadata words at selected boundary timestamps, all timestamp encodings at selected address boundaries, alignments, and randomized words.
- Original and candidate ARM consumers passed the complete frame-packet protocol suite, including known RTL CRC, torn headers and diagnostics, continuation chains, session changes, direct copies and four-slot ordering.
- Additional integration checks passed 40 accepted mixed packets and 90 malformed-pair rejections, with diagnostics both enabled and disabled. Rejection preserves the output header and prevents acknowledgement.
- Every timed native acquisition was followed by a full payload comparison and acknowledgement check outside the measured interval.

## Native acquisition results

Six samples per build, shape and diagnostic mode, in baseline/candidate/candidate/baseline order with three samples at each position. Each sample times 4,000 acquisitions after 32 warmups. The MiSTer ran at stock 1 GHz; its verified menu process was temporarily parked with a watchdog and restored afterward. No OBS recording ran during this benchmark.

The values below are median acquisition-time changes versus the unchanged Beta10 consumer. Negative is faster.

| Synthetic packet distribution | Diagnostics off | Diagnostics on |
| --- | ---: | ---: |
| pairs_small | -14.761% | -12.314% |
| pairs_untagged | -13.868% | -13.746% |
| pairs_tagged | -16.135% | -15.956% |
| pairs_max | -16.594% | -16.215% |
| mixed_pairs | -9.140% | -7.242% |
| gx_packed | +5.044% | +2.867% |
| gx_commands | +4.442% | +5.181% |
| hblank | +9.386% | +7.279% |
| legacy_vram | +3.917% | +2.354% |

These are cached-RAM protocol fixtures, not uncached FPGA-memory transfers, game frame rates, or live gameplay results. The small paired packet contains 32 records; the large shapes use 1,799 records, with a separate maximum-sized 3,840-record packet. The mixed shape contains paired writes, HBlank markers, GX commands and ordinary VRAM writes. The HBlank control retains the earlier 264-record capture shape.

## Decision and next step

Do not enable this shortcut globally. The additional check makes GX, HBlank and ordinary VRAM workloads slower. A separately qualified cartridge-specific implementation could dispatch once per packet and preserve the original validation loop for other games, but that is a new hypothesis and has no accepted performance claim yet. Any such implementation still needs native controls, full service tests, complete scene output and repeated live gameplay measurements.

The original NSMB installation, save, 54 protected files, stock clock and OBS settings were verified after the benchmark. The restored game-selection menu was also visually checked. No public release or accepted-beta pointer changed.

Private reproducibility receipts are retained under `castlevania-packet-validation-performance-20261017`; no ROM, save, capture or user configuration is included in this report.
