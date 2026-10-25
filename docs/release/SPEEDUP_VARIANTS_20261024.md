# Regional speedup qualification

Private follow-up to rc.10, based on the tested DV1 rotation branch. Public
release notes and README are unchanged. This beta extends the existing speedups
to the twelve supplied cartridges below. It is not a public release.

## Additional exact cartridges

| Game | Region / revision | Header code | Acceleration |
| --- | --- | --- | --- |
| New Super Mario Bros. | Europe, rev 0 | A2DP | Packet lookup and guarded bone reads |
| New Super Mario Bros. | Japan, rev 0 | A2DJ | Packet lookup and guarded bone reads |
| New Super Mario Bros. | Korea, rev 0 | A2DK | Packet lookup and guarded bone reads |
| Castlevania: Dawn of Sorrow | Europe, rev 0 | ACVP | Color conversion, inverse transform, ADPCM loop |
| Akumajou Dracula: Sougetsu no Juujika | Japan, rev 1 | ACVJ | Color conversion, inverse transform, ADPCM loop |
| Chrono Trigger | Europe, rev 0 | YQUP | All 10 indexed MODS movies |
| Chrono Trigger | Japan, rev 0 | YQUJ | All 10 indexed MODS movies |
| Final Fantasy XII: Revenant Wings | Europe, rev 0 | AXFP | All 20 indexed VXDS movies |
| Final Fantasy XII: Revenant Wings | Japan, rev 0 | AXFJ | All 20 indexed VXDS movies |
| Sonic Chronicles | Europe, rev 0 | CSNP | All 59 indexed VXDS movies |
| Sonic Chronicles | Japan, rev 0 | C5RJ | All 59 indexed VXDS movies |
| Shin Megami Tensei: Strange Journey | Japan, rev 0 | BMTJ | All 11 indexed MODS movies |

NSMB China and Wii U releases were not supplied and remain unqualified. Matching
the title or header game code alone never enables a patch. Existing accepted
cartridges retain their original profiles. Original ROMs are opened read-only;
changes exist only in the staged load image. Save identity stays with the
original filename. There is no Speed hacks menu.

## Implementation and guards

- NSMB now selects region-specific addresses through a game-code/revision and
  ARM9 CRC32 table, then verifies full-ROM SHA-256, ARM9 SHA-256, autoload layout,
  hook bytes, and scratch space. The complete packet routine and animation
  caller match the USA routines after accounting for addresses. The bone hook
  still checks the live overlay and exact return addresses before skipping any
  read. This ports the existing visual/compatibility tradeoff; it does not turn
  the bone-read shortcut into a bit-exact optimization.
- Castlevania's three overwritten routines are byte-identical in these regions.
  Header, surrounding converter/audio code, table CRCs and all original patch
  bytes are checked before any mutation. Only the audio table pointers need
  relocation in the replacement code. Existing USA query/raster policy is
  unchanged; this regional extension covers the movie routines.
- Movie profiles retain full-cartridge, converter, hook, reconstructed ARM9,
  overlay and movie hashes. The European and Japanese player addresses are
  separate. Japanese Revenant Wings has a different displaced instruction;
  its wait hook restores registers and executes that load after read completion.
- The renderer's independent exact prepared-header allowlist includes the
  seven new movie profiles. A preliminary hardware test exposed the missing
  receiver entry and displayed encoded transport data instead of the movie;
  that incomplete pairing was rejected. The final tests use the updated paired
  host, loader, supervisor and renderer.
- The receiver table is an include file so unchanged functions keep their
  trained source positions. Renderer compilation retains profile-guided
  optimization and `-Werror=coverage-mismatch`; the final build has no coverage
  mismatch errors. FPGA image and clocks are unchanged from the DV1 beta.

## Offline checks

- All 13 prepared movie cartridges reproduce their qualified image SHA-256;
  the six existing profiles retain their previous image hashes.
- All 189 additional indexed MODS/VXDS assets, 87,563 source frames, were
  reconstructed. Every compressed video/audio payload was preserved, and all
  32,520 indexed cartridge files were audited against the original or their
  specifically approved transform.
- Receiver versus original-packet decoding: 89,075 identical pixel comparisons,
  including complete assets, reused buffers, transitions and eight-frame
  restarts of every asset.
- All seven NSMB diagnostic modes assemble for all four regions. Original
  assets and autoload sections are preserved; all USA virtual images are
  byte-identical to the previous loader's output.
- ARM interpreter checks: 360 packet comparisons and 45 bone-guard cases per
  region (1,440 and 180 total). Unknown callers and each damaged overlay guard
  retain the original path. These checks do not claim visual equivalence for
  deliberately omitted bone updates.
- Three movie-buffer wait hooks pass callback-order, displaced-instruction,
  register and stack checks. All three Castlevania profiles pass exact assembly
  comparison, atomic guard rejection, truncated mapping and idempotence checks.
- Loader Python tests, regional worker dispatch/fallback tests, exact receiver
  identity/reset tests, supervisor recovery tests and renderer self-tests pass.

The standalone developer checks `verify_nsmb_regions.py` and
`verify_wait_hooks.py` use Unicorn. Supplied game data stays outside the source
tree and package. Guest `.bin` files are generated with `fmv/build_guest.py`.

## Hardware qualification

All twelve additional cartridges passed bounded MiSTer checks at 1 GHz through
the RetroTINK-4K rig. The nine movie revisions each ran for 120 seconds after a
fresh graphics session; the new NSMB regions reached World 2-5 and completed two
20-second jump windows. All movie hooks were confirmed active, video and audio
were present, and transport/decode faults were zero. The seven shared-decoder
profiles recorded successful accelerated decodes; Castlevania uses its separate
patched guest routines, so shared-decoder counts are zero by design.

The same isolated save, starting position and input sequence were used for each
USA renderer comparison. Rotation was Off for these measurements. The previous
DV1 renderer is the control; the candidate keeps its optimization settings.

| Scene | Previous renderer | Candidate | Scope |
| --- | ---: | ---: | --- |
| NSMB USA, World 2-5, jumping | 59.67/sec | 59.64/sec | Two 20-second windows each |
| Castlevania USA, snowy room beside save area, jumping | 20.10/sec | 20.13/sec | Two 20-second windows each |
| NSMB Europe, World 2-5, jumping | — | 59.63/sec | Two 20-second windows |
| NSMB Japan, World 2-5, jumping | — | 59.61/sec | Two 20-second windows |
| NSMB Korea, World 2-5, jumping | — | 59.63/sec | Two 20-second windows |

These count completed screen-buffer updates, including reused images, not unique
rendered frames or whole-game FPS. NSMB is near the display cap in this scene;
the uncapped Castlevania comparison provides the more sensitive throughput check.
The small differences do not establish a new performance gain or guarantee the
absence of regressions elsewhere. The initial automated NSMB navigation landed
on the world map; that run was rejected. Accepted runs used a verified gameplay
save and a screenshot check before measurement.

The Japanese Chrono Trigger and Japanese Castlevania recordings had capture-side
render/output drops (47/7 and 40/3 respectively). Other movie captures had zero.
These are recorded separately from the zero MiSTer transport/decode faults.
Audio-presence checks and sampled visual review are not proof of hitch-free
playback. Later movies were decoded and compared offline, not all triggered on
hardware. Long sessions and all levels/power-ups/effects remain unqualified.

[Machine-readable results](SPEEDUP_VARIANTS_RESULTS.json) include the exact
runtime hashes, prepared-image hashes, counters and measurement windows.
Static timing closure remains unresolved in the retained FPGA image.

## Test launcher

Run **Scripts → NDS_Speedup_Variants_Beta** on the test MiSTer. The separate kit
keeps the existing public and DV1 launchers available. Its normal launcher uses
your normal saves; back them up before playtesting. Automated qualification used
isolated copies. No ROMs, saves or personal settings are included in the package.

