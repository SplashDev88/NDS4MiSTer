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

## Missing prerequisites

The MMZX archive explicitly describes its base as beta.5 **with the Kirby and
GTA fixes already applied**, and says none of their source files are included
in its delta. Separate sources for **Kirby Mass Attack, Kirby Super Star Ultra,
and GTA: Chinatown Wars** are therefore still required. Do not infer those
fixes from the supplied prebuilt FPGA or claim this candidate includes them.

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

Existing complete console VHDL analysis, permission/negative-control tests,
VRAM DMA retirement, GX readback transport, host/ARM service self-tests and
new packed-transfer tests pass in this integration. There is no new fitted
FPGA, hardware speed measurement or confirmation that all requested games
work. In particular, DMA main-RAM prefetch and SDRAM burst changes still need
focused memory-model tests and a full FPGA build. The added 4096-entry event
queue consumes FPGA block RAM; resource fit cannot be inferred from RTL alone.

After the missing prerequisites arrive: port them without replacing whole
newer source files, validate their interactions, build a matching pair, and
test the five requested games plus FFT A2, Platinum, NSMB and Castlevania.
Keep the accepted beta.6 package intact as rollback until user acceptance.

## Attribution

Original compatibility and acceleration changes supplied by **InsaneFriend
(GitHub: saneFriend)**. Protocol reconciliation, regression tests and prior
REPU2 review corrections were added while integrating with this project's
newer accepted code. Original copyright and GPL notices remain in source.
