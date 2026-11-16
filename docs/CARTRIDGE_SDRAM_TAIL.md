# Full 512 MiB cartridge backing

Private compatibility work. Hardware qualification is pending.

The existing extended layout backs cartridge bytes 0..464 MiB in three DDR
windows. Some 512 MiB cartridges have meaningful data above that boundary.
Appending FF padding cannot make these cartridges fit.

The additional FS3 mode `0x0f03` retains every existing DDR address and stores
cartridge bytes 464..512 MiB at SDRAM byte addresses 16..64 MiB. Main RAM and
VRAM remain below 12 MiB. The host must see firmware capability bit 15 before
selecting this mode. Firmware flag bit 13 reports that the extra backing is
ready; direct game release rejects an incomplete transfer.

The native reader and Python fallback first retain the old padding check.
They request full backing only when meaningful data exists above 464 MiB and
the paired core advertises support. Ordinary padded cartridges retain their
existing DDR-only loading path. No game-specific patch or asset conversion is
needed, and the original ROM and its save identity are preserved.

During a full load the host holds both guest CPUs, copies the existing DDR
windows and sends the upper 48 MiB over FIO. This FIO data counter starts at
zero for the tail; it is not a full-ROM byte offset. Trimmed files receive FF
bytes up to the end of the aperture. Sequential offsets and completed SDRAM
acknowledgements are required before readiness. A failed tail is rejected
before mounting a new save or releasing the CPUs.

The SDRAM bridge owns one request until its physical response crosses back.
Channel 3 optionally uses ordinary 16-bit writes and aligned 64-bit reads,
with a one-line cartridge read cache. Other users of the controller retain
the donor's default channel-3 format. Guest resets drain outstanding reads
without delivering them to the next guest epoch; cartridge replacement also
invalidates the cached tail. Physical SDRAM requests are never canceled by
a guest reset.

Validation entry points:

- `bash tools/test_cart_sdram_tail.sh`: complete-image gating, exact tail
  readback, malformed offsets, delayed responses, replacement, cache behavior,
  and actual SDRAM pins at the 16/32/64 MiB boundaries with both DQ settings.
- `python3 tools/test_nds_cart_large_rom.py`: actual cartridge bridge and DDR
  cache, including full backing boundaries and pending-tail reset/replacement.
- `test_host_full_cartridge.cpp`: old-core rejection, failed tail preserving
  saves, odd trimmed EOF, full FF initialization, and unchanged normal loading.
- `test_full_cartridge_reader.cpp ROM FMV_DIRECTORY`: compare both loading
  paths against every original byte of a supplied full cartridge.
- Existing SDRAM, firmware, host-load and host-save regressions remain required.

This adds cartridge storage, not a rendering speedup. Boot time, gameplay,
audio, saves and any contention with the other SDRAM clients must be qualified
on hardware before promotion.
