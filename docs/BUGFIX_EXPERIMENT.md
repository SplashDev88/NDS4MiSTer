# rc.8 bug-fix experiment

This branch starts from rc.8 plus its README formatting correction. The approved
backlog excludes issue #42 (SS1 launcher detection). Save integrity comes first,
followed by progression, graphics correctness, frame measurement and performance.
Reported game failures must be reproduced and checked individually before closure.

## Save transaction boundaries

Two failures are reproducible through the actual cartridge register interface:

- Flash program (`02h`) and page write (`0Ah`) crossed a 256-byte page boundary
  into the next page. They now wrap within the selected page, matching the
  vendored software reference. EEPROM writes and all reads remain linear.
- The 16-bit SPI byte position wrapped during reads larger than 64 KiB and
  interpreted a data byte as a new command. Only prefix positions are meaningful;
  the position now saturates after the command/address/dummy/IR prefix. A new
  transaction still starts at zero.

`bash tools/test_save_transactions.sh` covers both failures, all flash profiles,
regular EEPROM writes, long tiny/regular/flash reads, fast-read dummy bytes,
IR passthrough and a new command after a long transfer. Each case fails against
the rc.8 card implementation and passes with the correction. The existing save
cache, EEPROM/flash, IR and loader suites also pass.

These changes affect cartridge backup SPI. Renderer settings, CPU/cartridge-ROM
timing and clock rates are unchanged. This is not yet a claim of hardware speed
equivalence or resolution of any particular game's save issue. FPGA routing,
hardware comparison and game-specific save/reload tests remain required.

The old combined Jackass/King Kong/NFS bundle remains excluded. Any reused change needs
its own regression evidence, including the recorded geometry timing counterexample
and matched NSMB/Castlevania gameplay checks.

## Geometry commands behind an ordinary FIFO tail

An external replay burst can arrive while the ordinary FIFO still contains work.
That bypasses the existing growable contiguous bank and fills the 16K stall
queue. The previous code then overwrote commands. A 30K-command test reproduces
the loss: command 16644 is replaced by command 30000.

The isolated overflow correction preserves those commands in a bounded deque,
strictly behind the stall queue. The contiguous fast bank remains the usual
external path. Reset clears both queued commands and the diagnostic peak. This
ports InsaneFriend (saneFriend)'s original fix `4c48874`, previously adapted in
`fd437999531df3a909264c240a1cd41ba286d9d8`. It does not include the Jackass geometry
debt/timing changes or the King Kong RTL change from that earlier bundle.

The GX ordering test covers the reproduced ordinary-tail loss, reset, deferred
swaps and bursts through 70K commands. It and the matrix-prefix oracle pass,
as do the complete renderer self-tests and fake-memory lifecycle checks. A
self-test counter now explicitly returns `std::size_t` so Clang's sign-compare
warning does not prevent these checks from compiling.

This is a command-retention correction, not yet a verified fix for issue #38.
ARM build validation, the reported NFS race and matched gameplay speed checks
are still required before accepting it for a release.

## VRAM bank register readback

ARM9 VRAMCNT A-I reads previously returned zero, so software could not save a
bank mapping before a texture upload and restore it afterward. The register
read mux now returns the implemented bits for each bank. The masks match
`GPU::MapVRAM_AB/CD/E/FG/H/I` and the ARM9 byte/halfword/word read handlers in
the vendored melonDS source. Existing mapping outputs and write timing remain
unchanged; this adds no state machine or gameplay pacing rule.

This adapts InsaneFriend (saneFriend)'s King Kong fix `6041052`, previously
ported in `204098d6ca62001a90e65f15d23fe9651d62decd`. Unlike that earlier port,
reserved bits read as zero. `tools/test_nds_syscnt_vram_readback.sh` reproduces
the original zero-read failure and verifies all 256 values for all nine banks,
byte lanes, texture upload/restore sequences, ARM7 status/write protection,
WRAM sharing and reset. The 27-case console sleep/wake suite also passes.
The King Kong issue remains open until a routed build passes gameplay testing.

## Initial rc.8 save triage

Bounded tests on the unmodified release have not reproduced the reported
Mage Knight or Spyro startup warnings (USA revision 0). Mage Knight created a
profile and resumed it into the world map after a cold relaunch. Spyro passed
save initialization and reached its opening gameplay with a fresh save. These
observations do not establish full-game save reliability or validate the
reported original saves; the issues remain open. All tests use separate save
files, with original files checked for changes.

## Identifying source queue failures

Both Mushroom Men and NFS reproduced the generic FPGA source fault `0x100`
on rc.8, while the HPS fault word remained zero. The source has two possible
causes: exhaustion of its 512 HBlank markers or its 256 frame boundaries.
The experiment preserves the aggregate bit and adds sticky detail bits:
`0x00400000` for HBlank overflow, `0x00800000` for frame overflow. The reason
bits cross through two synchronizer stages and are published with the aggregate
bit. Queue sizes, event ordering, CPU clocks and LCD pacing remain unchanged.
The gate regression checks each cause, combined reasons, service stop and reset.
This diagnostic does not itself fix either game's stall.
