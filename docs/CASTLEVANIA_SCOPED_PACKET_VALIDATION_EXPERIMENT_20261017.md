# Scoped packet-validation experiment, 2026-10-17

The cartridge-scoped successor to the global packet-validation prototype was rejected before a full service build or gameplay installation. Its paired-VRAM path was faster, but the fallback exceeded the predeclared 1% regression limit on 23 of 24 native packet controls. Castlevania Beta10 remains accepted.

## Implementation and correctness

The private candidate selects one of two validation implementations once per packet. The paired-VRAM shortcut is compiled out of the fallback loop. A constructor flag occupies existing padding; the full service would enable it only under the existing exact Castlevania display profile and integral-texture gate. Header snapshots, payload copying, vector lifetime, barriers, session and ownership checks, CRC semantics and acknowledgement order remain unchanged. No service using that selection was installed.

Host and emulated ARM each passed the complete protocol suite in both modes, including the additional 40 accepted mixed packets and 90 malformed-pair rejections per mode. Both passed the 47,235,072-case predicate oracle. Host and ARM layout checks preserved class size, alignment and all 29 original member offsets. These checks establish correctness of the isolated prototype, not performance or complete service qualification.

## Native result

Stock 1 GHz, verified MENU process temporarily parked with watchdog protection, six samples per build/mode/shape. The order was baseline/fast/fallback/fallback/fast/baseline, three samples per position. Each sample used 32 warmups and 1,000 measured acquisitions; complete payload and acknowledgement checks ran outside each timed interval. The 24 controls include diagnostic off/on modes and short 32-record GX and 8-record HBlank packets.

Median acquisition-time changes versus the unchanged Beta10 consumer are below. Negative means faster.

| Packet shape | Diagnostics | Fast mode | Fallback mode |
| --- | --- | ---: | ---: |
| pairs_small | off | -12.370% | +3.994% |
| pairs_untagged | off | -13.665% | +13.103% |
| pairs_tagged | off | -18.469% | +10.576% |
| pairs_max | off | -16.687% | +12.184% |
| mixed_pairs | off | -7.979% | +11.055% |
| gx_packed_small | off | +14.254% | +1.376% |
| gx_commands_small | off | +11.931% | +0.293% |
| hblank_small | off | +7.863% | +4.066% |
| gx_packed | off | +23.655% | +3.794% |
| gx_commands | off | +24.861% | +10.833% |
| hblank | off | +35.854% | +20.389% |
| legacy_vram | off | +27.659% | +15.307% |
| pairs_small | on | -8.637% | +23.914% |
| pairs_untagged | on | -28.991% | +13.810% |
| pairs_tagged | on | -31.726% | +11.079% |
| pairs_max | on | -33.883% | +8.771% |
| mixed_pairs | on | -8.385% | +16.005% |
| gx_packed_small | on | +24.234% | +22.847% |
| gx_commands_small | on | +25.120% | +18.837% |
| hblank_small | on | +11.360% | +9.600% |
| gx_packed | on | +39.937% | +14.185% |
| gx_commands | on | +48.639% | +17.443% |
| hblank | on | +59.427% | +51.675% |
| legacy_vram | on | +24.650% | +21.861% |

These cached-RAM microbenchmarks do not measure uncached FPGA-memory transfer or game FPS. Identical fallback validation statements did not preserve performance after changing function boundaries and generated code. The observed regressions are sufficient to reject this implementation; the experiment does not isolate their exact instruction-level cause.

The original NSMB runtime and save, 54 protected files, stock clock, menu affinity and OBS settings were restored. The restored game-selection menu was visually checked. No accepted source, package pointer or public release changed.

Private evidence: `castlevania-scoped-packet-validation-performance-20261017`. No ROMs, saves, game snapshots or recordings are included here.
