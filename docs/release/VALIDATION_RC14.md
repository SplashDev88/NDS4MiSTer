# RC14 validation and scope

RC14 packages the accepted Mario Kart Regional + DV1 Y/C Beta5. The game
loader, 26-entry catalog, all four Mario Kart regional recipes, compiled
guest stubs, FPGA and renderer are retained. The normal standalone launcher
path and release labels are updated. The source histories are integrated;
no new analog layout or rotation feature is part of this release.

The accepted host was reproduced byte for byte before a version-only source
rebuild. Compiled host logic is unchanged; the shorter release label changes
binary addresses, so executable byte identity is not claimed.

Release checks include seven host tests covering Direct Video target control,
DV1 menu geometry, RTC/game clock, firmware, the guarded Python ROM reader,
and framed transfer; 48 launcher/recovery/display/clock tests; and 138
guest-loader, ARM9 delivery, course-asset and cache tests. Package audits
check complete hashes, executable permissions, source/runtime agreement,
normal installation paths, frozen source inventories, and absence of personal
data. The final extracted package is checked against all four previously
qualified Mario Kart optimized cartridge streams and a seeded upgrade fixture.

The integrated Beta5 production video test passed 1,024 routing combinations,
six carrier/burst waveforms and independent-picture tests. The shared RTC/Y/C
command test passed and rejected the original command-collision negative
control. These inputs are unchanged in RC14.

Y/C Beta2 passed bounded RT4K checks for game startup, menus, Main/Touch
selection, timing and CRT/Scaler switching. The user subsequently reported
that its Y/C output worked well on the tester setup. Mario Kart qualification
includes the USA course campaign and bounded regional ABI, loader, Grand
Prix, movement/restart/save-reopen and native Figure-8 comparisons. See the
Mario Kart reports in `docs/game-optimization` in the separate source archive.

The final RC14 archive and Mr. Moro's contributed display profiles have not
been relaunched on hardware. No live game session was interrupted to prepare
this release. Component and offline validation do not establish all adapter,
game, firmware, or display combinations.

Existing limitations remain: FPGA timing is not closed; GBA Sky Garden keeps
its original course data and the shared-helper timing cost; the full course
campaign was not repeated in every region; all battle/mission modes, wireless
multiplayer and full playthroughs are not newly qualified. No PAL 50 Hz,
save-state or DSi support is added. The earlier four Platinum gameplay
validation gaps remain documented in `VERSION_COVERAGE.md`.

Installable runtime and corresponding source are separate ZIPs. Mr. Moro's
original profile ZIP is a third, optional asset with its original bytes and
instructions preserved. Each asset has a SHA-256 sidecar. Package-specific
receipts are retained with the prepared release artifacts.
