# Beta12 / v0.9.0-rc.9 validation

This release packages the frozen Castlevania Beta12 runtime at **1 GHz**.
The core, ARM renderer, host, modules and runtime settings are unchanged.
Public packaging changes the private kit path to `Scripts/.NDS_Standalone`
and updates the launcher label, metadata and documentation. No binary rebuild,
new optimization or 1.2 GHz clock change is included.

## Performance examples

The release-note examples come from the following recorded development tests.
They are not a direct rc.8-versus-rc.9 benchmark. All use 1 GHz ARM clocks.

| Scene | Earlier measurement | Later measurement | Evidence |
| --- | ---: | ---: | --- |
| Castlevania cave/bat platform | Performance Beta6: 14.773 and 14.459 completed screen pairs/s | Beta12: mean 22.6365 pairs/s, individual runs 22.6172 and 22.6559 | [Initial room measurements](../CASTLEVANIA_ROOM_PERFORMANCE_20261016.md#clean-cave-baseline); [Beta12](../CASTLEVANIA_LIVE_BALANCE_FOLLOWUP_20261017.md#live-observations) |
| Castlevania upper-right Warg combat | Performance Beta6: 12.658 pairs/s | Beta12: mean 21.8774 pairs/s, individual runs 21.7069 and 22.0480 | [Initial combat measurement](../CASTLEVANIA_ROOM_PERFORMANCE_20261016.md#clean-combat-baseline); [Beta12](../CASTLEVANIA_LIVE_BALANCE_FOLLOWUP_20261017.md#live-observations) |
| NSMB World 2-5, repeated jumping | Performance Beta4: 30.09 and 30.14 visible character changes/s | Performance Beta5 full-rate setting: 54.55 and 55.50 visible changes/s | [Full-rate drawing comparison](../GAMEPLAY_PACING_PROFILE_20261016.md#nsmb-full-rate-candidate) |

The Castlevania figures span separate test batches. The same named rooms and
source counter are used, but enemy phases, damage and attacks vary; especially
the short combat measurements are not identical workloads. The release rounds
these observations to 14.5–14.8 → 22.6 and 12.7 → 21.9 screen updates/s without
asserting a controlled percentage improvement over rc.8.

NSMB's full-rate setting is retained in Beta12. Its outdoor visible-change
comparison was measured when that setting was introduced, not rerun on the
final Beta12 binary. The corresponding source publication rates were 29.91
pairs/s for both controls and 59.82/59.77 for full-rate drawing. The calibrated
analog detector measures changes around Mario, with zero paused false changes
in these trials; it is not a whole-screen unique-frame counter. Later testing
showed that this numerical outdoor motion improvement does not generalize to
the heavier [World 1 castle](../FLAT_COLOR_PERFORMANCE_20261016.md#gameplay-qualification).
Beta12's final castle control delivers 44.8448 completed screen pairs/s on
average, versus 44.3764 for its paired Beta11 controls.

Completed publications may contain reused images. Neither publication rates
nor threshold-dependent visible changes are an exact gameplay FPS or latency
measurement. Different test stages must not be added or compounded into a
release-wide percentage. 60 FPS has not been established across these games.

## Inherited runtime qualification

- The [Beta12 live comparison](../CASTLEVANIA_LIVE_BALANCE_FOLLOWUP_20261017.md)
  used baseline/candidate/candidate/baseline ordering, fresh isolated saves,
  analog RGBS through RetroTINK-4K and an unchanged capture setup. All twelve
  accepted recordings had complete reviewed graphics, audio present, zero
  protocol faults and zero OBS render/encode drops. Audio fidelity and long
  sessions were not fully qualified.
- Cave and combat mean throughput passed the declared live gate. NSMB mean
  throughput also passed, but its p95 and maximum gaps were slightly higher;
  this is not a claim that every frame or game is smoother.
- The exact helper inherits its full ARM-service self-test and 320 complete
  saved-scene buffer comparisons. Scheduler and worker-range tests cover
  another 768 complete buffers and 192 actual delayed wakeups. The final public
  scheduler/range sources were separately compiled and passed those 768-buffer
  checks; [the qualification record](BETA12_PUBLIC_TEST_QUALIFICATION.json)
  distinguishes that run from the inherited full-service check.
- The original private ZIP passed a fresh installation through its actual shell
  launcher, with no previous settings copied. The Castlevania title, Suspend
  selection, Warg room and pause menu were reviewed, with zero protocol faults.
  The previous runtime, saves and display were restored, and 54 protected files
  were unchanged. This was a brief package smoke, not a performance benchmark.

## Public packaging checks

Hardware testing is paused. No device was contacted or reconfigured while
preparing rc.9, and **the final public-path install was not physically retested**.
The checks below are local and do not replace that missing live launch.

- Exact comparison against the frozen private ZIP verifies the core, host,
  renderer, both modules, supervisor, Kickstart, clock control and video recovery
  scripts. Runtime environment and 1 GHz clock match. The launcher's executable
  lines differ only in the kit path; its comment identifies the public release.
- The packager verifies all input pins and writes a deterministic 44-file ZIP.
  The strict archive audit checks exact approved payloads, metadata, paths,
  executable modes, licences, CRCs, inner hashes and the outer SHA-256 sidecar.
  No ROM, BIOS dump, save, user setting, map or kernel image is included.
- Ten archive-audit tests pass, including rehashed component/provenance
  tampering and false release/clock metadata. Twenty-one preflight/recovery
  tests and seven clock-control tests pass. These use local fixtures/mocks.
  Shell syntax and Git whitespace checks pass.
- Local fresh extraction contains all 44 expected files. A merge over the
  actual rc.8 archive preserves six synthetic settings/save/INI sentinels.
  Moving the entire new kit aside and restoring the backed-up launcher and kit
  reproduces the previous program bytes and preserves those user files.
- A local launcher dispatch check substitutes a temporary kit path and stub
  Python executable. Argument forwarding and missing-support-file refusal pass;
  the real supervisor and hardware are not started by this check.

The final asset's outer checksum and packaging commit are supplied with the ZIP.
Install instructions explain hidden-folder merging, the separate private kit's
settings, and rc.8's inability to read an offline `NDS-RTC-v2` file.

## Corresponding source and builds

| Component | Source revision | SHA-256 |
| --- | --- | --- |
| Renderer | `1d3a33361730ca0d2f9123c578378bca40463aad` | `5510089f11be99c2bf56e80bca4cc784ccbbc418ce951514d78d352140a151a8` |
| Host | `db09fc5cee49ccca4e9e3b9b71e65ba303836607` | `6b63736edbe4b82821edd2dfe460a731281ddfd5ae0d27f51cb88d0a4cdf192f` |
| FPGA | `32c31cd94b5a5734b6c034e8647d2a4924e990ae`, with recorded QSF overrides | `3d0516778d0805ddef8da30e3ef01d55d4d6fed5ed677fb16036ca56ef1fdfee` |

The host retains its rc.8 internal label to preserve the tested executable.
The launcher/manifest identify rc.9 / Beta12. Module hashes and the exact runtime
environment are recorded in the package manifest.

All 851 reviewed renderer inputs match the release source. The original build
inventory differs only in the unlinked `src/replay/GameQueryProfileTest.cpp`.
All 552 recorded HDL/configuration entries match after applying the exact QSF
append in [frozen provenance](BETA12_BUILD_PROVENANCE.json). That append enables
the SWAP-retirement, HBlank-run-queue and GX-busy experiments; source defaults
leave them off. The original FPGA inventory contains 1,872 whole-tree entries.
Against its historical source revision, only the noncompiled `SHA256SUMS` and
`docs/BUGFIX_EXPERIMENT.md` differ after applying the QSF append. It is not a
claim that every historical documentation byte equals the release tree.

Quartus 17.0.2 routing and assembly passed with seed 7 and one processor.
Static timing closure is unresolved and was not reassessed for this packaging.
Do not apply another release's slack values to this bitstream. Build recipes,
compiler flags and immutable source inventories accompany the ZIP; the release
source's [source-package guide](../../SOURCE_PACKAGE.txt) explains reproduction.

No new HDMI/DV1/CRT compatibility sweep, long-session or multi-board qualification
is implied. Native analog remains approximately 59.64 Hz, without PAL 50 Hz.
Save states, persistent lid-close resume, RTC alarms, wireless and DSi remain
unsupported. Rejected post-freeze optimizations and the failed 1.2 GHz experiment
are excluded from this release.
