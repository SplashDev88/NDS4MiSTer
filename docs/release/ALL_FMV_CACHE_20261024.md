# All-FMV prepared-ROM cache private beta — 2026-10-24

Run **Scripts → NDS_FMV_Cache_Beta**. This is a separate private launcher;
the installed regional speedup beta and public installation remain available.

The prepared-ROM cache now covers all 13 supported cartridge profiles:
Chrono Trigger USA/Europe/Japan; Final Fantasy XII: Revenant Wings
USA/Europe/Japan; Sonic Chronicles USA/Europe/Japan; Strange Journey
USA/Japan; and Ni no Kuni Japan/original and the qualified English v1.0 patch.
The two Ni no Kuni profiles retain their existing compacted transfer path.
Castlevania keeps its small native patching path, which does not rebuild movies.

The loading dialog says **Preparing FMV cache...** during a cache build and
**Loading ROM...** on cache hits and ordinary loads, with a separate elapsed
timer. NSMB retains Loading ROM: its in-memory patches do not build a movie
cache. Right Stick Range changes and successful settings saves no longer
display the save-settings footer messages; saving still persists the setting.

## Measured loading time

At 1 GHz, with original ROMs on the CIFS share and the cache on the SD card:

| Game | First cache-building load | Verified cache hit |
| --- | ---: | ---: |
| Chrono Trigger (USA) | 48.5 s | 9.4 s |
| Revenant Wings (USA) | 39.0 s | 8.4 s |
| Sonic Chronicles (USA) | 65.3 s | 17.6 s |
| Strange Journey (USA) | 74.2 s | 17.7 s |
| Revenant Wings (Europe) | 65.5 s | 17.6 s |
| Ni no Kuni (Japan) | 149.9 s | 39.8 s |

These intervals run from the host's `loading` message to `ROM started`.
They exclude launcher/core takeover and the game's own startup sequence.
These are single cold/hit pairs before the final loading-label update, not a
statistical storage benchmark. The final host was separately checked with a
fresh Chrono Trigger preparation, verified replay and an NSMB control load.
Final-host Chrono Trigger loading measured 43.8 seconds to build the cache and
8.6 seconds on the verified replay.
Castlevania's unchanged native load took 6.3 seconds.

The first load still verifies the source and prepares the movies. Later loads
read the verified prepared bytes from local storage. Source metadata changes,
loader changes or cache eviction require another preparation. The cache is
limited to 2 GiB and evicts older entries when necessary; it cannot retain all
13 profiles simultaneously. Entries use about 128–463 MiB each.

## Correctness and scope

- All 13 cold reconstructions and all 13 cache replays match the previously
  qualified image SHA-256 values exactly. Warm checks reject any attempt to
  reread original payloads or rerun the assembler.
- 56 Python checks pass, covering original/hash/hook rejection, expanded
  images, malformed or corrupt caches, source changes, incomplete streams,
  storage failures and bounded cache reservation.
- Hardware checks cover cold and cached startup for the six profiles above,
  plus the unchanged Castlevania path. Each observed 20 seconds after boot at
  1 GHz with no transport errors and a clean exit; screenshots were retained.
  This is a loading check, not a new full-game or full-movie compatibility sweep.
- Host protocol checks cover the optional cache-status message and reject
  malformed variants. Host-rendered UI checks cover both loading labels, the
  elapsed timer, preserved progress bar and Right Stick Range persistence
  without the removed footer messages.
- The final host passed Chrono Trigger cold/hit and NSMB startup checks with
  20 seconds of post-boot observation, no transport errors and clean exits.
  External capture initially reported No Video; the user rebooted RetroTINK
  4K and the picture returned. Physical Chrono Trigger/NSMB screenshots and
  board framebuffer screenshots were retained. The physical capture shows
  Loading ROM and an advancing progress bar on a verified cache hit.
  Audio was not requalified.
- Renderer, FPGA, guest movie routines and profile data are unchanged.
  The host changes are limited to loading status and settings footer messages.
  No new runtime renderer workload, game patches or speed-hacks menu is added.
- Original saves and MiSTer.ini passed preservation checks; storage/recents and
  the private display settings were restored after testing.

## Cache validation

The initial preparation verifies the full original ROM and guarded code/movie
data. A cache key includes canonical source path, file identity/size/timestamps,
profile and paired loader identity. Every cached byte is hashed while staged
under reset. Completion is issued only after successful validation. Corruption
clears provisional cartridge writes and rebuilds from the original. Failed
qualification during recovery never boots the provisional image. Unknown or
modified originals retain their original decoder on an uncached fresh load.

Cache hits trust unchanged original file metadata; they do not rehash the
network source. An external edit that preserves all tracked metadata requires
removing the cache. This retains the existing cache policy.

Cache creation is optional: an unavailable or full cache falls back to loading
the original through the verified preparation path. Game ROMs remain read-only.
The ZIP contains no game ROMs, prepared caches, saves or personal settings.

To roll back, exit the core and run the previous launcher. Existing caches are
keyed to the loader and are safe to leave in place. Public rc.10 release notes
and README are unchanged. Detailed results: `ALL_FMV_CACHE_RESULTS.json`.
