# FFT A2 menu pacing candidate

This candidate starts from published v0.5.1 and restores the v0.5.0 launch
setting `NDS4MISTER_GX_QUERY_FAST_POLL=0`. Fast matrix-prefix processing,
write-combining, the stock 1 GHz clock and all other rendering settings remain
enabled. The core and ARM helper are the unchanged v0.5.1 binaries.

With fast matrix replies active, this setting restores the original 500 us
idle intake wait instead of shortening it to 100 us. Busy processing, geometry
results, frame ownership and rendering correctness are unchanged. More frequent
idle polling is not necessarily a gameplay improvement on the shared ARM cores.

## Validation and limits

- The existing launcher lifecycle and production-environment regression passes.
  It also checks that a stale parent environment requesting fast polling cannot
  override the selected setting.
- The user confirmed FFT A2's menu was substantially faster on v0.5.0 than on
  v0.5.1 or the standalone frontend.
- After a power cycle and a single core/ROM load, the user confirmed both the
  graphics and the fast menu behavior on this v0.5.1-based candidate.
- The latest core and helper hashes were verified on the board. All 33 existing
  cartridge saves and the user's settings were unchanged during installation.

The first attempt encountered black video with audio. Restoring v0.5.0 by
software reload did not clear it; a power cycle did. The retry used a single
core/ROM load. That startup issue is not claimed fixed by this polling change.

Passive source-frame/publication counters did not establish input latency or
unique animation FPS. No numeric speed improvement is claimed. The newer NSMB,
Star Coin, VRAM mirror, optional Engine B and renderer fixes remain in the
unchanged v0.5.1 binaries, but NSMB and Castlevania gameplay still need a quick
regression comparison before release packaging. This candidate is not published.
