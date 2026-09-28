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

A fresh local FPGA build completed from commit
`f01bc87c3f9f51b43c001564bc8132c92f579e52`, using Quartus 17.0.2 and seed 5.
Its SHA-256 is
`8bc0d7d185152a59ab9c8a872a0c03e9e622cf68710b88405667825be885c53d`.
The supplied prebuilt was not used. Every tracked build input was verified
against its recorded pre-build hash. The only changes after the compiled
commit are release documentation and the source checksum manifest.

Resources: 38,938/41,910 ALMs (+36 versus the accepted FPGA), 42,563 registers
(+39), 530/553 M10K and 54/112 DSP (both unchanged). Worst setup slack is
-20.773 ns and worst hold slack is -0.204 ns, versus -21.922/-0.373 ns on the
accepted FPGA. All 12 console-clock hold-summary slacks improve, but timing
is NOT closed. The contributor's all-corner clean-hold result was not reproduced
by this local build; report the measured result rather than assuming equivalence.

GTA1 was loaded on the user's MiSTer with the unchanged v0.5.2 helper at
stock 1 GHz and WC enabled. The user then requested packaging: "ok package
this one up for release. gta fixes by insane friend". No local before/after
GTA event count, new FPS benchmark or full-playthrough result is claimed.

The release preserves that exact core, renamed `_Console/NDS_20260927.rbf`,
and the v0.5.2 helper SHA-256
`91ce15eed06269380b78ba505e6f5cb19eeb99d3845ce21fb176566a390febe3`.
Its on-screen build text still reads `260926-VEC1`; the distinct release
filename and SHA-256 identify the artifact. Rebuilding merely to change this
text would invalidate the tested binary identity. The direct map/fit/asm/sta
build uses tracked `build_id.v`; `sys/build_id.tcl` remains unchanged from the
submission and can regenerate different text in other build flows.

Retest GTA's intro/city and normal gameplay when checking other hardware.
FFT startup/reload/menu, NSMB gameplay and Castlevania remain useful regression
checks. Occasional near-camera clipping remains a separate limitation.
