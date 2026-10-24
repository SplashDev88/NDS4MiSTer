# rc10 loading follow-up

This candidate changes the standalone host's loading dialog and NSMB preparation.
The renderer, FPGA image, movie profiles and released rc10 package are unchanged.

## Cause

The optional ROM worker sends preparation heartbeat packets before it announces
the virtual image size. `RomReader::size()` consumes these while keeping the
host responsive, but `Host::updateLoading()` only runs during the later transfer.
Thus real verification and patch preparation appeared as an empty, frozen bar.

The host now displays a bouncing activity marker and elapsed preparation time,
then switches to the determinate transfer bar. The activity marker means the
host is responsive; it is not a percentage or evidence that a blocked file read
is progressing. Existing no-progress timeouts and completion checks remain.

NSMB also recompressed its patched ARM9 in Python on every launch. The candidate
instead serializes the same sections uncompressed and clears the SDK compressed
end marker. The ARM9 grows from about 389 KB to 582 KB. Original game assets and
the full-cartridge, ARM9, and hook-site checks remain unchanged.

## Validation

- In hardware launches at 1 GHz from the same CIFS ROM and isolated save, the
  interval from host `loading` to `ROM started` was **46.597 s** for rc10 and
  **10.297 / 10.262 s** for the candidate. These exclude launching the core itself
  and subsequent game logos. File-cache conditions were not forcibly reset.
- Candidate preparation was **9.246 / 9.116 s**. A separate idle-board worker
  probe at 800 MHz attributed **46.439 s** to recompression alone; its full
  74.881-second preparation result is not the matched 1 GHz baseline.
- All seven NSMB internal mode combinations preserve the five loaded sections,
  addresses, BSS sizes and original assets, except for the intentional cleared
  compression marker. Reproduce with an owned, qualified ROM:
  `python3 tools/standalone_host/fmv/verify_nsmb_load.py <ROM>`.
- NSMB boot, World 2-5 entry and a short repeated-jumping session passed on the
  physical board. This is a bounded gameplay check, not full-game qualification.
- Host tests exercise animation during delayed metadata, bounded OSD traffic,
  switching back to determinate transfer, cancellation and incomplete-load
  rejection. Menu presentation, ROM reader and Python preparation tests pass.
- The legacy `test_host_display.cpp` navigation test also fails on the unchanged
  rc10 source; its old root-menu order is stale. The current
  `test_host_display_menu.cpp` passes on this candidate.

## Remaining loading work

Ni no Kuni preparation still verifies the whole 512 MiB source and prepares its
movie assets before the transfer rereads the source. The dialog fix makes this
visible but does not remove that cost. A read-once or verified local-cache path
is a separate follow-up; no hash checks have been relaxed and no ROM cache has
been introduced by this candidate.
