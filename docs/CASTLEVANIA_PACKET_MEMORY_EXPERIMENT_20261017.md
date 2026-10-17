# Packet input memory experiment, 2026-10-17

C54 is not promoted. The optional packet mapping improved the tested cave,
but the complete comparison did not meet the declared gameplay regression
gates. Castlevania Beta11 remains the accepted private build.

| Scene | Beta11 publication pairs/s | Candidate pairs/s | Change |
| --- | ---: | ---: | ---: |
| Castlevania cave | 22.1274 | 22.4615 | +1.510% |
| Castlevania combat | 21.1542 | 21.4171 | +1.243% |
| NSMB castle | 44.8363 | 44.3075 | -1.179% |

These are means of two fresh-save captures per build and scene: 22 seconds
in the cave, six in combat, and 26 in the NSMB castle with repeated jumps.
They measure completed source publication pairs, not distinct animation FPS.
The tests used the same core, host, runtime settings and 1 GHz gameplay clock.
Enemy and animation phases vary, especially in the short combat windows.

The faster combat candidate also had EXP 70 instead of 69 and fewer visible
zombies. The first NSMB baseline began at timer 496 versus 495 in the other
runs; the two baseline rates differed by about 2.4%. These variations limit
precision and do not establish a whole-game slowdown. They are retained in
the comparison, rather than excluding inconvenient samples.

The declared live gates required more than 1% improvement in both Castlevania
scenes and no NSMB decline greater than 1%. All technically valid runs are
retained. No threshold was relaxed after measuring. An additional combat
confirmation was prepared because the candidate combat samples varied; it is
not run after the broader regression gate fails.

The six-run cave sequence also compared the same new helper with its option
disabled, separating the mapping change from rebuilding the executable.
Enabled versus the disabled new helper: +2.017%.
Disabled new helper versus Beta11: -0.497%.

Renderer source was unchanged, but the rebuilt renderer archive was not byte
identical. The NSMB control did not include an option-off run of the new
helper, so this comparison does not isolate the cause of its change to the
mapping alone. It does establish that the tested candidate is not a clear
replacement for Beta11 under the declared gates.

The prototype maps only the four 64 KiB input slots at physical
`0x3fc10000..0x3fc4ffff` as read-only, non-executable ARM Normal Non-Cacheable
memory. It replaces its own Device pages rather than retaining a conflicting
alias. The control header, publication mapping, packet validation, memory
barriers, renderer algorithms, clocks and frame-admission policy are retained.
No FPGA resource or routing change is involved.

Qualification passed: full ARM service self-test in Docker, 851 build-input
correspondence checks, host and ARM mapping tests, and a fresh module build
against Linux 6.18.38-MiSTer. On hardware, aperture boundaries, read-only and
non-executable protection, forbidden mprotect upgrades, root-only opening,
normal unforced load/unload, and refusal to unload while a mapping survives
its descriptor were checked. The rig rejects its Device-memory full fault
trace while any packet-NC mapping exists. Every live candidate was checked
for exact mapping permissions, process ownership and absence of aliases.

All 14 comparison recordings were visually reviewed for complete geometry,
backgrounds, sprites, HUDs and menu transitions. They had zero protocol faults
and OBS capture drops, with audio present. Audio presence does not certify
fidelity. All 54 protected files and original saves were unchanged. The test
module was unloaded normally, the original NSMB setup and 1 GHz gameplay
clock were restored, and its menu was visually checked. OBS settings are
unchanged and recording is stopped.

A future package-lifecycle draft passed 57 offline tests, including owned
module cleanup and shell startup/shutdown cases. It remains unintegrated;
those tests do not make this rejected performance candidate a beta. No new
launcher, beta ZIP, accepted-build pointer or public Release was published.

Private evidence: `castlevania-packet-nc-performance-20261017` and
`castlevania-input-memory-investigation-20261017`. Raw game captures and
fixtures remain outside the source repository.
