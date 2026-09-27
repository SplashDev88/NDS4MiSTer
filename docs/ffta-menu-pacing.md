# Sustained fast graphics queries

**Status:** the user rejected the compaction-only helper as slow in FFT
A2’s title menu (both animation and input). Its earlier automated success
did not cover the startup sequence observed in the user’s session.

## Second fallback: overstated command costs

Live inspection of that unchanged slow session found prefix mode 2, valid 0,
reason 3 (work budget), rejected command 0x22 (TEXCOORD), peak 567 pending
words, and only 93 fast replies, all verified. The helper was at stock 1 GHz
with WC and release flags, with profiling disabled.

The new correction charges simple state/attribute commands 16 modeled cycles
instead of 128. The unchanged renderer bounds its vertex and normal pipeline
delays at seven; these commands take at most eight cycles plus up to four for
lighting. They do not wait for polygon completion. Matrix/stack, vertex,
SWAP and BOX_TEST allowances, the 30,000-cycle total eligibility bound, and
the 4,096-word limit remain unchanged. No renderer timing is modified.

An exhaustive oracle check covers 26,624 combinations of command, pipeline
delays and light mask (maximum observed: 12 cycles). A new near-budget mixed
state/vertex burst fails on compaction alone and passes with the cost
correction. Its final matrix matches ordered replay after one ordinary query
clock step, in all four primitive modes. The 1,200-frame stream and 91,880
other comparisons pass, including real overflow rejection for both cheap and expensive commands.
The complete ARM-emulated helper self-test also passes.

On hardware, the first corrected FFT boot/menu run lasted 108 seconds with
70,444 fast replies, all verified against ordered replay, no prefix fallback,
and an empty replay queue at shutdown. A second boot used the user’s normal
SD-card ROM, a longer load delay, and profiling disabled. Its prefix remained
valid beyond 34,000 replies. The current beta is for user comparison; these
checks do not establish input latency, animation FPS, or acceptance.

## First fallback: retired queue entries

FFT A2 could start quickly and then slow down because the matrix-prefix queue
counted retired entries against its 4,096-word limit. Consecutive SWAP commands
can leave a small live tail across VBlanks, preventing the backing vector from
becoming empty. Once its total length hit the cap, fast replies were disabled
for the rest of that ROM session. Queries then waited for ordered rendering.

The candidate reclaims only the already-executed prefix when storage reaches
the cap. Pending commands remain in order, and both the live-word and execution
cost limits still apply. Reported peak depth now counts live pending words.
The published v0.5.1 core and launch settings are retained, including 100 us
query polling, write-combining, optional Engine B and the stock 1 GHz clock.

## Earlier compaction-only validation (before the user rejection)

- A new 1,200-frame SWAP-stream regression reproduced the original fallback.
  With compaction, every frame's matrices and status match the unchanged
  melonDS oracle, with at most eight live pending words.
- The existing randomized matrix/stack/partial-command/SWAP/power cases pass
  91,872 comparisons. Tests retain rejection of a real over-budget backlog
  and now explicitly check the 4,096 live-word cap.
- The complete ARM-emulated helper self-test passes, including raster oracles,
  frame ownership, matched display, session changes and fast-prefix ordering.
- The fixed-path launcher lifecycle/environment test passes.

A 144-second hardware FFT boot/menu run kept the prefix valid for 104,120
replies, all verified against ordered replay. The exact published helper had
disabled the path after 193 replies. Both screens render and menu selection
moves correctly. These query counts are not gameplay FPS. NSMB and Castlevania
checks include successful NSMB startup, map rendering and World 1-1 entry.
The stationary NSMB map retained the release query throughput and CPU load
within measurement variation. Castlevania reached the same saved room with
both screens visible; its packet/publication rates and CPU load also matched
the release within measurement variation. All sampled fault words stayed zero.
These are limited automated scene checks; moving gameplay still needs the
user's visual and responsiveness comparison. Profiling is disabled for the
installed test beta. The earlier global 500 us polling
candidate improved FFT subjectively but slowed Mario and Castlevania. A brief
adaptive-polling trial was also rejected as slow. Neither setting change is
part of this candidate. The separate black-startup problem is not claimed fixed.
