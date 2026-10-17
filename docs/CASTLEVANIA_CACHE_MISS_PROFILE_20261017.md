# Second-screen cache misses — 17 October 2026

A private diagnostic helper found no paired Engine-B composition-cache hits in the focused Castlevania cave and combat windows. This explains why the earlier whole-session hit rate did not describe these gameplay areas. It does not yet establish which inputs could safely be reused.

The helper retains Beta8 rendering and cache decisions. It adds twelve thread-local reason counters at the original cache decision and writes six counter-pair events per admitted frame to the RAM timeline, alongside the earlier renderer-stage counters. It does not change cache eligibility, output pixels, frame admission or clocks. Full ARM service self-tests passed with the diagnostic gate disabled and enabled. All 851 build inputs were checked and temporary build-source overlays restored.

| Active scene | Complete frames | Lines | Cache hits | Memory revision differs | Sprite key differs | OAM newer | VRAM newer | Palette newer | Register/map differences |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Cave, 22 seconds | 371 | 71,232 | 0 | 71,232 | 71,223 | 71,223 | 71,232 | 0 | 0 |
| Warg combat, 6 seconds | 97 | 18,624 | 0 | 18,624 | 18,003 | 17,999 | 18,622 | 0 | 0 |

All counted lines were eligible and warm. Counts can overlap. “Newer” means that the memory category's globally monotonic revision exceeds the cached line's previous maximum revision; it is not a comparison of the actual bytes used by that line. An entire mapped bank contributes its revision even if a changed region does not affect the current line. The sprite key includes the OAM revision latched at the original sprite phase, which can differ from the revision visible later at composition. This accounts for the distinction between sprite-key and composition-time OAM counts.

Both captures show complete backgrounds and active animation, with zero capture drops, zero protocol fault words, audio present, stock 1 GHz, unchanged measured saves and all 54 protected files unchanged. The cave remains at HP132 and EXP69; combat advances from HP103 to HP63 with EXP69. Enemy phases vary. Audio presence does not certify audio quality.

The diagnostic delivered 16.84 and 16.16 source publication pairs/s, respectively. Its extra instrumentation perturbs timing, so these rates are neither optimization results nor distinct displayed animation FPS. Engine-B draw/composition averaged about 4.86 and 4.96 ms per admitted frame under the probe; B sprite work averaged about 1.98 and 2.02 ms. These wall-time stages overlap other worker activity and cannot be summed into an end-to-end cost.

The next probe separates background, sprite and extended-palette bank revisions. Removing only the OAM dependency would leave almost every line invalidated by mapped VRAM. Any future reuse change must preserve sprite preparation at its original phase, compare the actual required inputs, and retain palette, background, mapping and effect dependencies. A hash match alone is not sufficient proof for accepting cached output.

Private evidence: `castlevania-cache-miss-profile-20261017`. The diagnostic helper is excluded from the user-test package.
