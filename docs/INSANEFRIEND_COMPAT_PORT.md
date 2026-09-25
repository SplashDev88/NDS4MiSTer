# InsaneFriend compatibility port — 2026-09-25

Private integration candidate based on accepted beta.6 source `4f25ede`.
This is not a published release or a hardware-qualified combined core.

## Included source

- **Resident Evil: Deadly Silence:** InsaneFriend's privileged ARM9 store
  permission correction, using the reviewed REPU2 adaptation (`ec437fa`).
  Retains the legacy CP15 permission readback correction and computes store
  permission from the data-request address, avoiding the unrelated PC-fetch
  path that regressed REPU1. Existing GPL/Sarah Aronson attribution is retained.
  REPU2 previously passed NSMB and Castlevania startup smoke checks; Resident
  Evil gameplay through the author's reported freeze has not been verified here.
- **Mega Man ZX:** InsaneFriend's DMA display-register mirroring, main-RAM DMA
  fast lane, VRAM streaming queue/read buffer, SDRAM 64-bit writes, packed VRAM
  transport and bounded late forced-blank recovery. Source supplied in
  `NDS4MiSTer_MMZX.zip`, SHA-256
  `77f7819e7a3a7f511cd4b90cf864c8d997c48fff0745959b37425d138a1fa76e`.
  The author's reported on-board game results are not independent validation
  of this newer combined source. Submitted executables have not been loaded.

- **Kirby Mass Attack:** decode low-register Thumb format-5 ADD/CMP on both
  ARM cores instead of falling into the unsupported/default operation.
- **Kirby Super Star Ultra:** ARM9 STM base-in-list stores the original base;
  ARM7 substitutes the advanced base only with writeback enabled.
- **Grand Theft Auto: Chinatown Wars:** bound every clipping emission to the
  ten-vertex buffers, preventing malformed polygons overwriting the helper's
  stack. The author's remaining stray grey triangles are **not fixed** by this
  overflow guard; the underlying malformed-geometry cause is still separate.

These last three changes come from `NDS4MiSTer_Kirby_GTA.zip`, SHA-256
`520c33fe885fc4ddab33056394496d071b8682be62445de824651b0202611f3d`.
Its three-file delta was applied to the accepted newer sources, retaining the
C22 clipping math, fast paths and renderer caches. Both required archives have
now been received. The author's hardware results are reports about his build,
not proof that this combined candidate has passed gameplay tests.

## Integration corrections

The accepted FFT A2/Pokemon Platinum protocol already uses record kind 10 for
ordered GX readback fences. The submission also used 10 for paired VRAM writes.
This port keeps fences at 10 and assigns VRAM pairs **11** on both FPGA and ARM.
The burst writer closes a continuation packet immediately after a readback
fence and prevents subsequent records entering that burst. Malformed fence
validation and commit-last publication ordering remain intact.

Pair validation requires full byte enables, aligned addresses and the exact
32-bit ARM9 access tag. It rejects byte/halfword/ARM7/reserved tags rather than
reinterpreting a malformed pair as partial writes.

The new burst-aware DDR test model checks each physically accepted beat,
constant burst address/count, individual memory locations and final commit
ordering under independent stalls. A separate packer byte-memory scoreboard
checks merged writes at 128 fences and 16 frame boundaries, including FIFO
backpressure, partial overwrites and reset with buffered records.

The matched-display renderer test sends packed VRAM records to the candidate
and the original individual words to its reference, comparing every output
pixel. This covers the actual new ARM replay path, not just parsing.

Accepted C22 melonDS renderer optimizations, matrix prefix/BOX_TEST fixes,
Kickstart Wi-Fi guard, stock 1 GHz settings and WC module are preserved.
The newly integrated packet ABI requires a matching rebuilt FPGA and helper;
do not install this helper with the old PBOX1 core or the submitted prebuilt.

## Behavioral limits and remaining validation

Resident Evil's correction suppresses denied stores without implementing the
full DataAbort exception or all user/read/fetch protection semantics. See
`resident-evil-pu-store.md` for the reviewed limits and previous evidence.

The late forced-blank policy intentionally draws held early lines using later
register/VRAM state when a VBlank blank clears late. It is a bounded timing
approximation, not cycle-accurate display behavior. Persistent blank falls
back after 64 lines. New game-specific graphics and motion checks are required.

The new DMA transfer regression also exposed an inherited VHDL typing error:
`unsigned_address + integer_step` selects a NATURAL operand and fails on a
negative step. Encode the signed step at the 28-bit address width before adding
it. This makes the intended modulo-address operation explicit without adding
pipeline stages or changing transfer timing. It is an integration correction,
not one of the author's submitted changes.

## Local validation

- Complete console VHDL analysis; Resident Evil PU permission tests and four
  detecting negative controls; existing VRAM DMA retirement and GX readback
  transport tests pass.
- New authored CPU programs check all low-register ADD/CMP pairs, flags and
  aliasing, and STM IA/IB/DA/DB with and without writeback and base first/middle/
  last/absent. Both CPUs pass nine memory/clock-enable timings, with 616 checked
  stores per run. Reverting each of the four fixes independently is detected.
- New actual-production-clipper test: 98,956 unchanged cases and 1,045 bounded
  overflow cases. Host optimized and ASan/UBSan runs pass; removing the guards
  triggers the expected stack-buffer-overflow. The test uses wrapping signed
  arithmetic consistently with the existing clip math. This is a bounds/output
  regression, not a full hardware geometry-accuracy oracle.
- DMA main RAM fast/fallback tests pass 72 transfer combinations at each of
  three latency settings: 16/32-bit units, both pair offsets, increment,
  decrement and fixed addresses. Checks pair data, write byte lanes, ownership
  through posted completion, transfer count and reduced physical reads.
- SDRAM pin scoreboard passes 512 32/64-bit writes (1,536 physical halfword
  writes), all byte masks and refresh delays. Lower request attributes change
  after acceptance to check latching; upper payload stays live through ready
  as required. Simulation initializes three otherwise unspecified request
  flops to the Cyclone V flow's zero power-up value, and models the fixed DDR
  output clock; controller protocol and data expressions are unchanged.
- Full host and rebuilt ARM service self-tests pass, including packed VRAM
  versus individual writes in the matched-display renderer oracle.

Candidate build ID is **260925-IFP3**. IFP2 synthesis passed but its fitter was
stopped to incorporate the explicit DMA decrement arithmetic. IFP3 synthesis,
fit, assembly and timing analysis are running as a separate build. Do not use
an old RBF from another candidate with this helper. Fitted resource/timing
results and a hashed binary-pair receipt will be recorded in the local handoff.

The added 4096-entry event queue consumes FPGA block RAM. There is no combined
hardware speed measurement or confirmation yet that these five games work on
this port. Validate the five requested games plus FFT A2, Platinum, NSMB and
Castlevania before promoting this candidate. Keep the accepted beta.6 package
intact as rollback until user acceptance.

## Attribution

Original compatibility and acceleration changes supplied by **InsaneFriend
(GitHub: saneFriend)**. Protocol reconciliation, regression tests and prior
REPU2 review corrections were added while integrating with this project's
newer accepted code. Original copyright and GPL notices remain in source.
