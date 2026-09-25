# Resident Evil: Deadly Silence PU store candidate

InsaneFriend supplied the original three-file fix in
`NDS4MiSTer_RE_DeadlySilence.zip`, described as a patch against
v0.4.0-beta.5. Its source delta is also clean against 7fb4158, which retains
the accepted release and the disconnected-Wi-Fi guard. Existing GPL headers
and Sarah Aronson attribution remain unchanged.

The submission reports null-base stores to 0x00000000–0x3f corrupting the
ITCM mirror of the game's FX_SinIdx/FX_CosIdx literal pool. Its author reports
restored room backgrounds and passing the previous freeze. Those gameplay
claims have not yet been independently verified by this candidate's tests.

The ARM9 already matches PU regions for cache attributes. The patch reuses
that match to deny privileged CPU stores unless the highest matching region
has AP 1, 2 or 3. No match denies when the PU is enabled; disabling it permits
writes. The membus suppresses both immediate/deferred TCM stores and external
requests. DMA explicitly bypasses the CPU permission signal. It adds no new
ARM helper protocol, GX readback, frame pacing, memory buffer or CPU wait state.

Review found and fixed one omission in the submission: legacy c5 MCR writes
were expanded from two to four bits per region, but MRC still returned the
expanded value. A real CPU simulation reproduced 0xE4 reading back as 0x3210.
Legacy reads now repack each region's low two permission bits and clear the
upper 16 bits. Extended reads retain all four bits per region.

## Limits

This is partial protection support, not a complete data-abort implementation.
A denied store completes normally without invoking the abort handler. The CPU
may therefore retain writeback/register effects and continue a multi-transfer
instruction where real hardware would enter an exception. Games relying on
handler side effects, retry/emulation or exact exception timing remain at risk.
Only privileged write permission is enforced; user-mode AP restrictions, read
permission and instruction-fetch permission are not implemented here.

No standalone performance gain is claimed. The added permission priority
logic feeds the store-control path, so routed timing and gameplay need to be
checked. No synthesis/fit resource delta can be inferred from source alone.
Keep this separate from the FFTA2 clip-matrix readback experiment.

## Validation

`bash tools/test_nds_pu_store_permissions.sh` checks nine legacy/extended
CP15 round trips and 25 permission/region probes at three response delays,
two CPU enable rates and with/without DMA overlap (12 CPU scenarios).
A production membus/cache regression checks denied stores to eight target
classes at byte, halfword and word sizes; permitted writes; read preservation;
DMA bypass; denied cache hits; and a pending DTCM write followed immediately by
a denied store. Four negative controls prove the checks detect missing ITCM,
DTCM and external gating and the submitted legacy-readback omission.

Before wider use, build from this source, inspect fit/timing changes, verify
RE gameplay through the reported freeze and compare NSMB/Castlevania speed
and graphics with the accepted core. The submitted prebuilt RBF has not been
loaded and its correspondence to source is not independently established.

## REPU1 hardware regression and REPU2 experiment

REPU1 failed independent NSMB and Castlevania boot smoke tests despite zero
ARM transport faults. It is quarantined, not an accepted compatibility fix.
The rendered captures were blank; advancing frame counters alone did not show
successful gameplay.

A private replay of NSMB's actual ARM9 startup reached 9,910,998 bus requests,
including decompression and ITCM initialization, with no PU-denied stores.
NSMB's initial setup uses extended c5 writes, so the added legacy MRC packing
is not exercised in that phase. This does not establish complete game behavior:
the replay is a CPU/TCM/RAM model with stubbed peripherals, not full-console
simulation.

An existing-netlist timing report found the worst REPU1 store-control path
running from DMA/IO read data through the redirected PC-fetch address and the
new permission lookup to main-RAM request register enables (31.015 ns data
path, -17.076 ns setup slack). This suggests a physical implementation issue;
it does not alone prove the cause of the observed boot failures.

REPU2 computes write permission from the current CPU **data-request address**
before the instruction-fetch/PC-write mux. Saved DMA-deferred requests select
the saved address. Cacheability retains its original complete bus-address
lookup. An assertion verifies the permission address equals the accepted bus
address on every CPU data write. The AP rules, suppressed targets and cycle
latency are unchanged; there is no permission bypass or new wait state.
REPU2 still requires a new fit and real gameplay testing before acceptance.
