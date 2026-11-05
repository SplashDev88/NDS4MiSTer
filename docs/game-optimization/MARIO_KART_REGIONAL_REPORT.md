# Mario Kart DS — Regional Beta4

Private regional extension of USA Course Beta3. Europe AMCP, Japan AMCJ and Korea AMCK revision 0 now have independent guarded manifests. The USA manifest and all previous release entries remain intact. Nothing is publicly published by this work.

## Implementation

The existing `guest_byte_patch.py` loader substitutes a virtual cartridge stream and initializes the patched ARM9/ITCM code through the ordinary boot/autoload path. No original ROM is rewritten, no overlay is patched, and no live instruction-cache invalidation mechanism is required for this boot-time delivery. The existing `gx_span_asset.py` transformations and bounded preparation cache are reused.

Each regional bundle contains the same 31 course recipes and two inseparable code patches: an ARM ITCM call-site redirect and a 916-byte replacement of an existing OAM function extent, with an ARM entry and Thumb body. The replacement retains the OAM work and adds the conservative course visibility helper. It uses stack storage; no newly claimed unused RAM or persistent scratch allocation is introduced. Both code patches and the resources must be selected atomically.

The OAM routine, concatenation routine and course bytes match the USA routines/resources. Korea moves the OAM entry by 0x64. OAM table, matrix-concatenation and global-state pointers are relocated from each ROM's actual code/data. Global state is independently anchored by the original ITCM literal at 0x01ff8af8 and its surrounding access sequence, and that literal receives an additional expected-data guard. ARM/Thumb interworking, original bytes, containing section hashes, dependency bytes and full ROM identity are checked before application.

The direct-flow audit compared 1,244 decoded instructions per region and found no changed instruction shapes in the selected routines/dependencies. Six unchanged indirect callback sites remain outside this direct-flow proof. This is a scoped audit, not whole-program equivalence.

FPGA, host and renderer binaries are frozen to the same rc13 baseline used for USA Course Beta3. No new HPS service or save-state format is introduced. The only generic source change permits the private packager to append several independently guarded manifest entries while rejecting duplicate identities and incomplete bundles. There is no title-specific logic added to the generic loader.

## Validation

For each new region:

- 1,800 OAM arithmetic/ABI cases, 4,613 culling cases (41,517 spans) and 500 original regional matrix-concatenation cases passed. These are instruction-model checks, not native speed measurements.
- The existing catalog loader produced the expected full virtual stream. Across all four regions, 24 negative tests (wrong region/revision, altered original bytes/dependency/resource, incomplete bundle) retained the exact original stream.
- Normal Grand Prix control/candidate replays ran 6,000 frames each. A second 9,000-frame pair reopened the saved data, drove in Yoshi Falls, paused, restarted and resumed driving. No menu-unlock or automatic-driver patch was used.
- Saves matched the original seed and each other. No post-boot writes were observed to the watched helper extent or dependency code/tables during either replay. Changed framebuffer, RAM, audio and occasional AI trajectories are explicitly retained under the previously approved functional/perceptual budget. This is not bit-exact qualification; human audiovisual review remains pending.
- Native cold launches and Figure-8 Time Trials use private save/ROM copies, verified cartridge identity and patched-stream bytes, the same runtime, and a 1 GHz HPS clock. Menu-routing failures were stopped and excluded from measurement.

The reference checks cover restart/reopen behavior; they do not establish new-record save-write compatibility, every overlay path, multiplayer, all battle/mission modes or long sessions. Save states remain unsupported. Immutable input hashes and the final protected-file audit are recorded separately.

## Native before/after

| Region | Original publications/s | Patched publications/s | Change | Race-clock change |
|---|---:|---:|---:|---:|
| Europe | 21.48 | 24.15 | +12.42% | +0.25% |
| Japan | 21.51 | 24.05 | +11.82% | +0.07% |
| Korea | 21.44 | 24.01 | +11.97% | -0.06% |

These are completed screen-buffer publications per second in a stationary Figure-8 Time Trials starting view, not unique animation FPS, a complete-race benchmark or a claim of full-speed gameplay. Each admitted window is 20 seconds; race-clock advancement is reviewed from the surrounding paused screenshots. The clock interval includes the input lead-in and is compared like for like, rather than divided by the 20-second publication interval. HPS process load, individual windows, route evidence and the reviewed HUD values are recorded in `REGIONAL_NATIVE_RESULTS_V1.json`.

Europe also has an earlier native pair with different menu retries/history: about -5.8% in publication rate, with preserved race-clock pace. It is retained in the evidence rather than pooled into the matched-route table. This launch-history sensitivity is not resolved by the port and limits any general speed claim.

The USA 31-course evidence remains +2.26% to +26.23% in its own fixed-view campaign. Those figures must not be presented as fresh regional whole-game results. The regional asset identities justify reusing the selected recipes, not replacing regional execution checks.

## Limits and retained decisions

GBA Sky Garden retains original course data. USA checks still found approximately 0.85–4.07% slower native clock advancement from the shared helper in isolated runs, with additional history-dependent results. Regional Beta4 inherits that limitation; no Sky Garden improvement is claimed. Four attempted resource settings and the alternate dispatcher did not solve it reliably, so they remain excluded.

The first preparation of an uncached identity can be lengthy (the USA on-board preparation took about 12 minutes). Subsequent loads use verified local cache data. Derived cache assets, ROMs, BIOS and saves are excluded from the beta ZIP. Loading a normal library ROM uses its normal save; the development demonstration uses a private copy.

Coverage is exact revision-0 USA/Europe/Japan/Korea only. Unknown revisions and demos fall back to the original stream. The public launcher and earlier beta remain available.

## Evidence and reproduction

Private local evidence: `evidence/mario-kart-regional-20261105/` in the development workspace. Principal records:

- `OWNED_REGIONAL_INVENTORY_V1.json`, `REGIONAL_STRUCTURAL_V1.json`, `MANIFEST_PORT_V1.json`, `DIRECT_FLOW_V1.json`.
- `REGIONAL_ABI_V1.json`, `REGIONAL_LOADER_V1.json`.
- `REGIONAL_GP_COMPARISON_V1.json`, `REGIONAL_RUNTIME_GUARDS_V1.json`, `REGIONAL_LIFECYCLE_COMPARISON_V1.json` and reviewed contact sheets.
- `REGIONAL_NATIVE_RESULTS_V1.json` and its individual native measurement/HUD files.
- Final `PACKAGE_VALIDATION.json` / `EXTRACTED_STREAM_VALIDATION.json` live alongside the private ZIP; install, actual-launcher and protected-original receipts remain in the private evidence directory.

The source manifests contain the exact guards and payloads. Rebuild their helpers with the existing generic builder and pinned toolchain, then compare the declared helper SHA-256. Replay and native tools accept regional identities/configuration as data. Six packaging tests cover the multi-entry catalog extension.

## Three remaining research ideas

1. Resolve the shared helper's Sky Garden timing cost with a measured ordinary-list fast path.
2. Extend native measurements to matched moving laps in each region and record new results/save writes.
3. Qualify battle/mission/multiplayer behavior separately before expanding the compatibility claim.
