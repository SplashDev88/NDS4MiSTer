# Full 512 MiB cartridge backing

Private compatibility beta, qualified on a DE10-Nano with 128 MB SDRAM.

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
  actual MiSTer FIO addressing/chunk boundaries and delayed write pulses,
  and actual SDRAM pins at the 16/32/64 MiB boundaries with both DQ settings,
  concurrent channel-1/channel-2 reads and refresh requests.
- `python3 tools/test_nds_cart_large_rom.py`: actual cartridge bridge and DDR
  cache, including full backing boundaries and pending-tail reset/replacement.
- `test_host_full_cartridge.cpp`: old-core rejection, failed tail preserving
  saves, odd trimmed EOF, full FF initialization, and unchanged normal loading.
- `test_full_cartridge_reader.cpp ROM FMV_DIRECTORY`: compare both loading
  paths against every original byte of a supplied full cartridge.
- Existing SDRAM, firmware, host-load and host-save regressions remain required.

This adds cartridge storage, not a rendering speedup. The combined beta core
(2ac8ff1bd9df5fe2bd397604f46ea74075e24057e25f0062e18a2a0b9ef904c2)
passes an authored full-cartridge readback ROM on hardware, including the
464 MiB boundary and the final sector. Both host readers compare every byte
of the supplied 512 MiB cartridge in their regression test.

The original Tokimeki Memorial Girl's Side - 3rd Story Japan B3SJ rev 0 ROM
boots, accepts touch input through new-game setup, plays the prologue and
reaches the daily activity screen. Title and story observations are about
59.6 published FPS with native resolution and AA Off. An in-game slot save
was written to a private 64 KiB file and successfully reloaded after a full
host/core restart using the normal launcher's catalog/fallback environment.
The observed CIFS loading time was 109 seconds in the first native-reader
run and 74 seconds in the later normal-loader run; these are not controlled
throughput comparisons. The additional 48 MiB upload took about 31–33 seconds.

This is not a full playthrough or an all-cartridge certification. Build and
hardware evidence is retained outside the source tree in
evidence/tokimeki-gs3-resume-20261116. Static timing limitations remain in the
Quartus reports; successful fitting is not a timing-closure claim.

Regression smoke checks on this same core include ordinary NSMB gameplay,
Dawn's padded-save loading and gameplay, and a driven Mario Kart Grand Prix
race. Full-cartridge Tokimeki -> small NSMB -> Dawn -> Mario Kart switching
kept the same host PID/epoch, exercising tail invalidation without a core
reload. These checks supplement, rather than replace, the boundary and
all-channel SDRAM contention simulations.
