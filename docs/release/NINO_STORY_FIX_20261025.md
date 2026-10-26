# Ni no Kuni Japanese story movie fix

The Japanese retail ROM played audio but showed black video after New Game.
Its story player maps VRAM C/D as main backgrounds (0x89/0x91), unlike the
opening. Original-game instruction tracing found alternating conversion
outputs at 0x06020000 and 0x06040000. The accelerated decoder still sent
packets to unmapped LCDC A, and the conversion hook rejected both outputs.

The qualified Ni no Kuni hook now sends decode packets through mapped C
when it has the observed main-BG mapping. The color hook accepts the two
story buffers, and the existing staged receiver handles main-BG C/D writes.
Visible pixels remain unchanged until the complete conversion commits.
Other games retain their existing profile data. No FPGA or ROM-file change.

Validation: all 581 story frames decoded exactly against the original
Japanese interpreter output. Both Japanese and English v1.0 produced the
same 561 distinct paired-screen framebuffer hashes as their respective
unmodified originals in the tested story window. Execution speed changes
some frame boundaries; this is not a claim of cycle, RAM or audio equality.
The receiver self-test verifies LCDC parity, staging, paired writes and the
disabled gate. All 59 loader tests and the renderer/profile self-tests pass.

On MiSTer at 1 GHz, the entire opening followed by New Game and the story
movie decoded 3,215 frames with zero errors, then returned to controllable
Morton Street. The native probe matched 337 story image transitions; median
interval 83.61 ms, p95 85.35 ms, maximum 100.26 ms. The movie is natively
12 FPS. No transport fault was observed. OBS recorded the sequence without
additional skipped frames. Testing used an isolated save; the user's save
hash remained unchanged.

This is a private RC11-based fix, not a public release. Later movies and a
full playthrough remain unqualified. The inherited PGO build uses compiler
estimates for changed functions; broad gameplay speed has not been measured
again. Exact identities and evidence scope are in the adjacent JSON file.
