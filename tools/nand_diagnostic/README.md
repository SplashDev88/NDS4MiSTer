# Authored NAND cartridge diagnostic

This is a destructive test of its own save file, not a retail game. Keep a
unique ROM basename and **never** give it the name of a real game or existing
save. The two generated ROMs intentionally use UORE and UXBP header codes to
select the 16 MiB and 8 MiB NAND profiles. They contain authored code and a blank
logo; no retail ROM, firmware or BIOS bytes are copied.

Run `tools/nand_diagnostic/build.sh OUTPUT_DIRECTORY`. It uses the locally
available `skylyrac/blocksds:slim-latest` Docker toolchain without network access.
The output records the toolchain image identity and SHA-256 hashes.

Use a matching NAND-capable core and host. On a fresh test save:

1. Launch the diagnostic. A green screen at stage 0A/value 0 means both 2 KiB
   pages were programmed and read back correctly.
2. Exit cleanly to the MiSTer menu, then launch the same diagnostic again.
   A blue screen at stage 0A/value 1 means both pages were recovered from the
   saved file without being programmed again.
3. Independently compare the whole save file: it must be the selected capacity,
   filled with FF except for the two patterned pages described in `probe.c`.

The pages start at save offsets 0x100000 and `capacity - 0x20800`, covering a
bank above the old 1 MiB limit and the final writable page. The test also checks
NAND status, cartridge ID, protected-region ID and ROM-mode behavior. It uses
PIO cartridge transfers; retail-game testing is still needed for DMA and game
compatibility. A red screen reports a failure stage. The old rc.9 core is a
negative control: it fails stage 01 with value FFFFFFFF. Yellow means running.

This does not test abrupt power loss, all game save layouts or all commands.
Use the RTL/cache/host tests for broader fault and boundary coverage.
