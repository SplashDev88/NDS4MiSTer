# rc.9 game fixes and issue coverage

rc.9 retains the bug-fix core and offline-clock host, with the frozen Beta12
renderer. The release is more than a Castlevania performance update. This
inventory separates included code corrections from successful game checks and
reports that remain unverified. Packaging does not close any GitHub issue.

The game tests below were recorded during the earlier bug-fix work. Later
performance qualification concentrated on Castlevania and NSMB; every game
listed here was not rerun on the final Beta12 renderer. Hardware testing remains
paused for public packaging. The [chronological evidence](../BUGFIX_EXPERIMENT.md)
records intermediate failures, controls, exact game revisions and limitations.

## Included fixes with game evidence

| Game / report | Included change or recorded outcome | Remaining limit |
| --- | --- | --- |
| Wizard of Oz: Beyond the Yellow Brick Road, #34 | ARM9 CPU/DMA sprite-memory reads now return stored attributes instead of zero. New Game and Continue labels match the software reference in the sampled native output. Rotated HDMI label checks, movement and temporary save/reload pass. | Not every physical flicker case, later menu or permanent save is qualified. |
| Mushroom Men: Rise of the Fungi, #31 | Exposing geometry busy during pending SWAP retirement corrects the tested misplaced screen content, duplicated bands and missing menu pixels. FIFO backpressure and compact scanline-event storage address the observed backlog/overflow path. The first checkpoint saves and survives a cold reload. | Later gameplay and the original unspecified save failure need more coverage; ordinary geometry execution latency remains unmodeled. |
| Ninja Reflex, #24 | The combined geometry/backpressure changes keep renderer memory bounded in the tested menus. The extended session lasts 56 minutes, navigates all six categories and Meditation, completes Firefly Catch and retains its checkmark after restart. Analog and rotated HDMI label checks pass. | Some title/profile labels also appeared after waiting on rc.8. These tests do not prove every invisible-menu symptom was newly fixed or qualify every minigame. |
| Jackass the Game, #40 | The corrected FPGA set preserves fast matrix-query handling through the phone transition, tutorial, player control and a further NPC conversation. The old geometry-debt patch is excluded. | rc.8 also eventually progresses; a permanent freeze was not established. Long transitions and mission completion remain unqualified. |
| King Kong, #25 | VRAM bank-control reads now return their implemented bits, allowing software to save and restore texture-bank mappings. The isolated correction adapts the earlier InsaneFriend fix with reserved-bit masking. | The opening boat scene is not the reported failing first-person scene. The original texture report is not verified resolved. |
| Save integrity investigations, #21 / #22 / #23 / #31 | Flash program/page-write operations wrap within the selected 256-byte page. Long save-chip reads no longer wrap their byte counter and reinterpret payload as a command. Both failures reproduce in regression tests against rc.8 and pass with the correction. | These are proven save-interface bugs, not proof that they caused each reporter's warning. Original user save files are not rewritten automatically. |
| Large geometry bursts / NFS lead, #38 | The renderer preserves geometry commands behind a full ordinary stall queue instead of overwriting them. The accepted implementation preserves existing geometry-field offsets after the first version's NSMB slowdown. GX DMA also retains a request arriving on its pause edge. | Command-retention and DMA regressions pass, but neither correction is proven to resolve the original NFS missing-race-view report. |

Evidence: [save transactions](../BUGFIX_EXPERIMENT.md#save-transaction-boundaries),
[geometry command retention](../BUGFIX_EXPERIMENT.md#geometry-commands-behind-an-ordinary-fifo-tail),
[VRAM reads](../BUGFIX_EXPERIMENT.md#vram-bank-register-readback),
[DMA request loss](../BUGFIX_EXPERIMENT.md#gx-dma-pause-edge-request-loss),
[Oz labels](../BUGFIX_EXPERIMENT.md#oam-readback-and-wizard-of-oz-menu-labels),
[Ninja memory controls](../BUGFIX_EXPERIMENT.md#extended-ninja-reflex-investigation),
[Jackass queries](../BUGFIX_EXPERIMENT.md#jackass-and-the-earlier-insanefriend-fix),
[Mushroom Men status correction](../BUGFIX_EXPERIMENT.md#geometry-busy-status-investigation).

## Additional tests, not newly proven game fixes

- **Spyro: Shadow Legacy (#21):** an explicit in-game save and cold reload
  resume playable opening-room content. The original save-write warning was
  not reproduced with the tested isolated save.
- **Lunar Knights (#22):** the candidate loads an existing checkpoint, writes
  a new slot and cold-loads it with matching saved bytes. The original startup
  write-error report was not reproduced.
- **Mage Knight: Destiny's Soldier (#23):** profile creation and cold resume
  work in the rc.8 control; that is baseline triage, not a new rc.9 fix.
- **Final Fantasy Tactics A2:** opening-battle movement, Fire, multiple turns,
  Quick Save and cold reload pass. **Pokémon White 2:** movement, explicit
  saving, valid save-block checksums, saved-clock progression and cold reload
  pass. These are regression checks, not completed playthroughs.
- **NFS Carbon (#38), Shrek Smash n' Crash Racing (#33), Skate It (#37):**
  tested race/tutorial views are also visible on rc.8. Correct inputs start
  the NFS race; the observed introduction was not a proven freeze. Full races
  and the Skate challenge were not completed.
- **Spectral Force Genesis (#36):** the tested New Game/power-selection path
  reaches responsive dialogue on rc.8. The original failing setup is needed
  before claiming a fix.

The [investigation record](../BUGFIX_EXPERIMENT.md) preserves the individual
save, rotation, scene and performance checks, including their finite duration.

## Work not claimed complete in rc.9

The exact Zelda lid puzzle (#17) still needs confirmation. Persistent lid-close
resume is not implemented. The distinct displayed-frame counter (#11) is not
implemented; the existing counter reports publication activity. The Castlevania
performance work (#41) is included with [scene measurements](VALIDATION_BETA12_RC9.md#performance-examples),
not a universal 60 FPS claim.

King Kong's reported first-person texture scene (#25), both Prince of Persia
reports (#29 / #30), Lost in Blue (#26), Linda Hyde (#27), Star Fox Command (#35),
Knights in the Nightmare (#39), GoldenEye (#28) and C.O.R.E. (#32) are not
declared fixed by this package. SS1 launcher detection (#42) was excluded
from the approved implementation scope.

## Inclusion in the frozen package

The FPGA source is `32c31cd94b5a5734b6c034e8647d2a4924e990ae` with the three
recorded SWAP-retirement, HBlank-run-queue and GX-busy overrides enabled.
Those overrides are important: the source defaults alone leave them off.
This source includes the save, VRAM, OAM and DMA corrections described above.
The renderer freeze at `1d3a33361730ca0d2f9123c578378bca40463aad` retains the
command-preservation correction and its geometry-layout regression fix.

rc.9 packaging verifies the 552 recorded HDL/configuration inputs and all 851
reviewed renderer inputs, and keeps the exact tested binaries. Component hashes,
build overrides and qualification records are in the [release validation](VALIDATION_BETA12_RC9.md).
The shared 1 GHz clock is unchanged. The held DMA-prefetch experiment, old
geometry-debt extension and rejected post-freeze optimizations are excluded.
