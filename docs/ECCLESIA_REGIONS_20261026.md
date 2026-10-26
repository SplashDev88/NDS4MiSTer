# Order of Ecclesia regional gameplay and movie coverage

This cumulative private Beta2 extends accepted FMV Beta1 (04c23652) to the
European YR9P0, Japanese YR9J0 and Korean YR9K0 retail dumps. USA YR9E0 support
is retained. All four retail entries in the existing project catalog are now
present, and all are revision 0. Modified dumps and unlisted revisions are not
implicitly qualified.

The three new movie profiles each verify the complete source ROM, the shared
movie asset, original converter, displaced instructions and assembled image.
Their movie-player overlays differ: EU overlay 26, JP/KR overlay 22. Each uses
its own decoder call address. The shared 1,038-frame VX asset, original audio
packets, seek metadata and 14.985 fps timing are unchanged. Existing Ecclesia
hook binaries and safe ITCM extension layout are reused without modification.
All 18 previously accepted movie profiles remain byte-for-byte identical.

The gameplay selector admits the exact original and prepared headers for all
four versions. These identities select the accepted integral-texture and
sprite raster paths, ordered replay, paired worker policy and prepared Engine
B composition reuse. Movie receiver admission remains restricted to prepared
images. Tests reject altered code/header identities and all unlisted revision
bytes. The host dispatches regional rev0 images to the fully hash-guarded worker.

For each new region, a 4,454-frame deterministic Monastery route has identical
full-screen hashes, full RAM/state hashes, PCM audio and final save output with
raster optimizations enabled and disabled. The private cross-region fixture
cold-loads the intended scene in all three games. These software tests do not
alone establish hardware speed or paired-worker correctness.

For each region, all movie screen transitions occur in identical order through
a 6,500-frame boot/opening/title replay, with 1,038 decodes and zero errors.
Japanese and Korean movie PCM is byte-identical. European resampled output
starts 5.19 ms earlier; an independent trace before resampling proves its raw
mixer samples are identical after a constant 170-sample alignment across the
whole movie. There is no missing audio or progressive drift. Faster decoding
changes completion timing; guest-cycle/RAM equality is not claimed for movies.

At 1 GHz on MiSTer, each newly added regional opening/replay passes with zero
decoder errors. Each capture matches 998 movie transitions: median intervals
are about 67 ms and p95 about 69 ms, consistent with the native approximately
15 fps movie. Captured audio has no detected dropouts or progressive drift.

The same private suspend save, cold boot, input route and clock produce these
bounded Monastery combat results:

| Region | Previous beta updates/s | Regional beta updates/s | Gain |
| --- | ---: | ---: | ---: |
| EU | 34.26 | 54.71 | 59.7% |
| JP | 34.43 | 54.57 | 58.5% |
| KR | 34.35 | 54.56 | 58.8% |

These are completed paired-screen updates, not unique animation FPS. Full-game
steady 60 fps, later-game coverage and long-duration stability are not promised.
The exact original/prepared loaded headers and executable hashes were checked;
startup profile logging is empty in this production configuration. Full service
self-tests run in Docker, never on the live MiSTer.

ARM renderer/identity tests, streaming-reader guards and all 60 loader tests
pass. The FPGA image, ARM clock, guest clocks, display/menu code, original user
save and previous installations are preserved. Tests use private ROM/save copies.
The final installed-archive and preservation receipts accompany the beta.

Rebuild generated guest binaries with tools/standalone_host/fmv/build_guest.py.
The package includes source, build commands, frozen input hashes, existing PGO
data, licenses and validation summaries. ROMs, extracted payloads, captures,
RAM dumps and user saves are excluded.
