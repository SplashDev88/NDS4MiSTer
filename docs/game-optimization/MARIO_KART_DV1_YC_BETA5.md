# Mario Kart Regional + DV1 Y/C Beta 5

This integration merges Mario Kart Regional Beta 4 (`51bee808`) with the
successful DV1 Y/C Beta 2 (`4554f915`). The user reported on 2026-11-06 that
the Y/C Direct Video build worked well on their setup.

The four exact revision-0 Mario Kart identities (USA, Europe, Japan, Korea),
31-course asset recipes, loader, and existing other-game catalog entries are
unchanged from Regional Beta 4. All FPGA/RTL and compiled host inputs match
Y/C Beta 2. The distributable reuses that exact tested FPGA/host pair, its
matching supervisor, and the unchanged common renderer; no FPGA rebuild or
new performance change is introduced.

The runtime-only ZIP has a separate launcher:
`Scripts/NDS_MarioKart_Regional_YC_Beta5.sh`. Its support directory is
`Scripts/.NDS_MarioKart_RegionalYCBeta5_20261106/`. The reused host still
displays `v0.9.0-rc13-yc-beta2`; the package itself is Beta 5. The manifest
pins the actual combined guest catalog, all required runtime files, and the
correct Y/C binaries. Development sources, tests, build records and personal
data are excluded from the runtime ZIP; license notices are retained.

Use the same working DAC/active Y/C adapter and INI setup as Y/C Beta 2,
with Direct Video Target CRT. Scaler target continues to send RGB. See
[the Y/C setup notes](../DV1_YC_EXPERIMENT.md). No new raw CVBS, PAL 50 Hz,
per-port format settings, or arbitrary CRT rotation support is added.

Validation checks the merged source identities, production video waveform
and routing tests, separate RTC/Y/C command ownership, host target/menu/clock
tests, and the extracted package's four optimized ROM streams against the
previous qualified Beta 4 hashes. The exact tested binaries are retained.
No new hardware session is claimed for this combined package; the testing
rig was left available for the user's existing game session.

Existing qualification limits still apply: static timing is not closed;
GBA Sky Garden retains original course data and the shared-helper timing
cost; regional full-course campaigns, all multiplayer/battle/mission modes,
and full playthroughs are not newly qualified. Original ROM files remain
read-only, while normal library paths continue using their normal shared saves.

Local packaging and validation receipts are kept separately under
`evidence/mario-kart-dv1-yc-20261106` in the shared workspace. This is a
private test package, with no public upload or release performed.
