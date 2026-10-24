# rc10 loading follow-up

This follow-up changes the standalone host's loading dialog, NSMB preparation,
and loading of qualified Ni no Kuni cartridges.
The renderer, FPGA image and movie profiles are unchanged from the original
rc10. Package revision 10 includes the loading changes described here.

## Cause

The optional ROM worker sends preparation heartbeat packets before it announces
the virtual image size. `RomReader::size()` consumes these while keeping the
host responsive, but `Host::updateLoading()` only runs during the later transfer.
Thus real verification and patch preparation appeared as an empty, frozen bar.

The host now displays a bouncing activity marker and elapsed loading time,
then switches to the determinate transfer bar. The activity marker means the
host is responsive; it is not a percentage or evidence that a blocked file read
is progressing. Both stages say **Loading ROM**. Existing no-progress timeouts
and completion checks remain.

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

## Ni no Kuni streaming and local cache

The original path scanned the entire 512 MiB source before transferring its
relocated files. The framed loader hashes that source and copies the file spans
in the same sequential pass. It then prepares the guarded movie/code patches.
The DS remains held until the worker confirms successful completion. Reserved
display and Linux memory are excluded from every write. This path applies only
to the qualified Japanese and English-translation compacted profiles; other
profiles retain their existing loader.

Prepared writes are cached locally in
`/media/fat/.cache/NDS4MiSTer/prepared-roms`. The first preparation still checks
the entire original source, every applicable hook guard, and movie identities.
It publishes a cache entry only after those checks pass, using an atomic
manifest-last write. An interrupted preparation cannot publish a partial entry.

Repeat launches verify the complete cached data while staging it under reset.
They trust the original source's canonical path, device/inode, size, modification
time and change time. They do **not** rescan all original content over the
network. A source metadata change, profile change, or loader code change causes
a cache miss. An external edit that preserves all observed source metadata can
therefore require clearing the cache manually. The original file must remain
available; a cache is not a standalone installation or a save state.

A failed cache check discards the entry, clears all provisional cartridge bytes,
and rebuilds from the original without releasing reset. Insufficient disk space
or an unavailable cache directory falls back to uncached loading. The namespace
is bounded to 2 GiB, with oldest entries removed first and 128 MiB of free-space
headroom reserved when starting a new entry. Each tested Ni no Kuni version uses
about 480 MB. Original ROMs and game saves are never changed by this cache.

Exit the core before deleting that cache directory to reclaim space or force
fresh source verification. `NDS_ROM_CACHE_DIR=off` disables it for diagnostics.
There is no new OSD setting or gameplay worker.

### Additional validation

- At 1 GHz on the same board, Japanese Ni no Kuni took **120.134 s** on the
  previous loader, **80.736 s** with uncached streaming, and **37.973 / 38.079 s**
  on cache hits. Its first cache creation took **142.018 s**. The English v1.0
  profile took **115.298 s** to create its cache and **37.979 s** on a cache hit.
  These intervals run from host `loading` to `ROM started`, excluding core
  startup and game logos. Network and OS file-cache conditions were not forcibly
  reset. Cache creation adds SD writes and is not a first-launch speed win.
- Both versions booted and played their opening movies from cache in bounded
  120-second hardware checks, with no graphics-transport faults. NSMB loaded in
  **10.305 s** and the same short World 2-5 jumping check recorded **59.635**
  completed updates/second, matching the earlier loading-fix host's **59.63**.
  That counter can include reused images and is not a whole-game FPS claim.
- Full 512 MiB image comparisons for both qualified profiles match their
  existing image SHA-256 after uncached streaming, cache creation, a cache hit,
  and deliberate cache corruption followed by recovery.
- Python tests cover source mutation, hook/hash failures, malformed cache
  records, truncated/missing metadata, loader/source invalidation, disk errors,
  interrupted writes and cache eviction.
- C++ tests reject incomplete or malformed framed streams before save mounting
  or cartridge release. Boundary tests cross both reserved cartridge windows
  while preserving sentinel bytes in display/Linux memory.
- ARM host cross-compilation and paired-launcher validation pass. The renderer,
  FPGA, game profiles and approved README/release notes remain unchanged.
