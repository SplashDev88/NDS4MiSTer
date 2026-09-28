# GTA: Chinatown Wars matrix-stack status port

Original fix by **InsaneFriend (saneFriend)**, supplied in `NDS4MiSTer_GTA.zip`
(SHA-256 `8702baf489f2feea60e39b6bff11bbc0a2e0cea9cf518aa99aeca94c61ded683`).
The contributor identifies the original change as commit `70c75f9` on
`fix/gta-gxstat-matrix-stack`, based on public v0.5.2 commit `62dbc62`.
The archive contains source and a prebuilt RBF, not Git commit history.

## Behavior and scope

GTA reads GXSTAT's position-matrix stack level and pops that many entries at
frame start. The previous local FPGA status owner always returned zero for
this field. InsaneFriend's hardware and melonDS investigation attributes the
periodic wrong-camera/black 3D frames to the resulting stack-pointer drift.

The port tracks normalized MTX_MODE, MTX_PUSH and MTX_POP commands once on
acceptance, including CPU direct writes and packed DMA input. GXSTAT exposes
position level in bits 8–12, projection level in bit 13, and the tracked
PUSH/POP stack error in bit 15. A bit-15 write acknowledges the error and resets
projection/texture pointers without changing the position pointer.

All seven production source/build files are imported byte-for-byte from the
submission. The existing packet format, command acceptance, CPU/DMA backpressure,
render scheduling, clocks, ARM helper, Kickstart and write-combining are unchanged.
The new acknowledgment and status wires stay in the console `clk1x` domain;
they do not add a new asynchronous crossing or an ARM query round trip.
This retains the v0.5.2 FFT fix and v0.5.1 NSMB/Engine B improvements.

The tracker models submission-order stack state, not geometry execution latency.
Matrix busy and polygon/vertex counts remain as before. STORE/RESTORE of slot 31
are not additional error sources in this patch; it is not a complete replacement
for every GXSTAT hardware behavior. No additional performance claim is made.

## Contributor evidence versus local validation

InsaneFriend reports that a matched two-minute GTA recording fell from 41 bad
frame events to one. The remaining event was a near-camera pole/clipping wedge,
not the periodic whole-scene wrong-camera failure. Those recordings/traces were
not included in this archive, so these are contributor results, not measurements
from this import. Other games were not validated by the contributor.

The imported four SystemVerilog regressions pass locally: GX normalization,
frame-record CDC, delayed scanline tags and sparse Engine B phases. Local added
checks cover 128 repeated GTA-style frame-start read-level/POP sequences,
packed DMA versus direct writes, texture-error acknowledgment and session reset.
The VHDL register test additionally covers stack fields alongside FIFO/test/IRQ
bits, acknowledgment byte enables, word/halfword accesses, unrelated writes,
one-cycle acknowledgment and reset. Existing readback-owner/reply regressions
remain part of validation to protect FFT/NSMB result handling.

## Build and test boundary

The supplied project selects fitter seed **5**. InsaneFriend reports that some
other seeds produced main-RAM hold failures and boot crashes. Retain seed 5 and
inspect the new fitter/STA results rather than assuming the prebuilt's reported
result applies to a rebuild. Existing setup violations are not timing closure.

A fresh local FPGA build is prepared from this source. The contributor's prebuilt
is retained separately as evidence and is not the locally compiled artifact.
Use the unchanged v0.5.2 helper SHA-256
`91ce15eed06269380b78ba505e6f5cb19eeb99d3845ce21fb176566a390febe3` and public
Kickstart. The accepted v0.5.2 installation has not been changed for this port.
Local hardware playtesting and publication are pending. Check GTA's intro/city
and normal gameplay, then FFT startup/reload/menu, NSMB gameplay and Castlevania
before accepting a combined release. Occasional near-camera clipping remains a
separate limitation.
