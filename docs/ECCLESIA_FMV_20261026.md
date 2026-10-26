# Order of Ecclesia opening movie acceleration

This private cumulative beta builds on Overnight Beta1 (b25acdf). It retains
the Ecclesia gameplay optimizations, RC11 menus and rotations, Portrait movie
profiles, and Ni no Kuni story-movie changes. The FPGA image and 1 GHz ARM
clock are unchanged.

USA YR9E revision 0 is qualified. The loader verifies the entire 64 MiB ROM's
SHA-256, each movie asset, original converter, and displaced instructions.
Unknown or modified ROMs retain their original movie player. Europe, Japan,
and Korea remain pending owned ROM verification; this does not admit their
separate gameplay profiles.

The single `mv/vamp.vx` asset contains 1,038 frames at 14.985 fps. Existing VX
transport moves decoding and color conversion to the renderer. It preserves
the compressed video payload, audio packets, source clock, and seek table.
There is no interpolation or transcoding, and the source ROM is read-only.
Ecclesia's original ITCM section ends at 0x01fff280, above the default hook
location used by earlier games. Its profile therefore reserves
0x01fff280–0x01fffe40, with the copied original converter followed by the two
hooks. Assembly rejects overlap with autoload data or BSS, including aliases,
and rejects overlapping hooks. Earlier profiles retain their original layout.

Both original and prepared USA headers retain the accepted gameplay policy.
Only the exact prepared header enables this movie receiver. Existing regional
and revision fallback checks remain in force.

Software validation covers all 1,038 decoded YUV frames and consumed lengths,
and an entire opening through title return: all original distinct screen pairs
occur in identical order, the complete movie PCM is byte-identical, and saves
match. Faster completion changes presentation timing by about one VBlank and
avoids a brief larger decode delay. Title music subsequently starts one VBlank
earlier; the entire 6,500-frame audio files are therefore not byte-identical.
No guest RAM or cycle equality is claimed for this transport change. A second
6,500-frame run skips the opening and replays it without receiver errors.

The ARM renderer and cartridge-profile tests, host dispatch/framed-load tests,
and all 60 loader/cache tests pass. Reassembly of the existing Portrait USA,
Ni no Kuni Japanese, Sonic, Strange Journey, and Revenant Wings profiles
produces their previously qualified image hashes unchanged.

At 1 GHz on MiSTer, the same 484 matched movie transitions have median
intervals of 66.99 ms in both builds. The 95th percentile improves from
82.12 ms in Overnight Beta1 to 69.20 ms; the 99th improves from 86.28 ms to
71.70 ms. This is smoother delivery of a roughly 15 fps movie, not a 60 fps
conversion or a full-game speed claim. A full opening plus part of its replay
processed 1,524 frames with zero decoder errors. Captured candidate audio has
no detected dropouts or progressive clock drift in the tested opening.

Skipping, entering the save selection menu, and resuming the Monastery suspend
work. The bounded combat route produces 56.23 completed paired-screen updates
per second, consistent with the accepted gameplay improvement. This metric is
not unique animation FPS. Full playthrough, other cartridge versions, and
long-duration stress remain outside this qualification. Actual archive install
and final preservation results are recorded separately in the private handoff.

Rebuild the guest binaries with `tools/standalone_host/fmv/build_guest.py`
before running the loader tests; generated `.bin` files are not tracked in
source. The package includes the generated hooks, source, exact build command,
input hashes, existing PGO data, and validation reports. ROMs, extracted movie
payloads, RAM dumps, and user saves are excluded.
