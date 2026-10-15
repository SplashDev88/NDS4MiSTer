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

The old Jackass/King Kong/NFS bundle remains excluded. Any reused change needs
its own regression evidence, including the recorded geometry timing counterexample
and matched NSMB/Castlevania gameplay checks.
