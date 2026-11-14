# Sustained fast graphics queries

**Status:** on 2026-09-27 the user confirmed the cost-bound correction:
“yes its fast again”, in response to the FFT menu animation and button-response
comparison. When asked to check NSMB gameplay and Castlevania movement, the
user then confirmed “yes speed holds up.” This beta is the accepted performance
baseline for these tested games. The earlier compaction-only helper was
rejected because it did not cover a second fallback observed in the user’s
startup sequence.

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
valid beyond 110,000 verified replies. The user then confirmed the menu feels
fast again. Reply counts are not measurements of animation FPS or input
latency. NSMB and Castlevania speed retention is user-confirmed, rather than
a new measured FPS comparison.

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

## Battle vertex-cost candidate (2026-11-13)

An isolated Beta22 timing diagnostic reached the forest battle, moved Pina,
and completed Kevyn's Fire action. The prefix became invalid with reason 3
(cost), command 0x23 (VTX_16), and peak 597 pending words. It supplied 6,530
fast replies before fallback; 200,114 ordered replies accumulated a mean
4.96 ms of queue time. These whole-session counters include startup and idle
menus and are not a gameplay-speed or FPS measurement.

This candidate lowers the conservative total vertex allowance from 128 to
64 modeled cycles. It does not change the renderer's command execution,
geometry timing, storage limit, matrix/BOX bounds, or partial-command ordering.
The two VTX_16 words share that total; incomplete commands remain busy and
cannot publish fast query snapshots.

The timing oracle covers 4,362,240 pipeline/slot combinations and observes a
maximum of 47 cycles for a complete vertex. Twenty-four new vertex-heavy
SWAP-tail streams cover all six vertex formats and four primitive modes;
the old bound rejects them, while the candidate's resulting matrices and
status agree with ordered replay after one ordinary query clock step.
Near-boundary VTX_16 partial-busy and genuine cost-overflow rejection are
also tested. Existing matrix, stack, power, BOX and deferred-storage checks
remain in the test suite. Hardware validation and battle-speed qualification
are still pending; this is not yet a released or qualified improvement.


## Battle matrix-cost candidate (2026-11-13)

The vertex64 candidate still disabled fast queries in a distinct battle
session: peak pending depth increased from 597 to 896 words, but the same
cost rejection remained. It is not selected as a standalone speed improvement.
A subsequent diagnostic captured the first rejected tail during battle loading.
Stored and recomputed cost both equal 29,980, so this rejection is not caused
by stale accounting. The 896-word tail includes matrix/stack work and has no
additional SWAP inside it. The next VTX_16 word would exceed 30,000.

This candidate retains vertex64 and reduces the allowance for single-word
matrix/stack operations from 128 to 64, and complete matrix transforms from
256 to 80. The actual replay engine's 1,934,336-case audit covers every matrix
mode, all vertex/normal and polygon delays, stack boundary states, and all
stack pointers and signed six-bit pop offsets at maximum pipeline delay.
Observed maxima are 43 cycles for stack/identity and 72 for transforms.
The 30,000 total cap, 4,096-word storage cap, other command costs, ordering,
and incomplete-command busy protections are unchanged.

Four matrix-heavy streams (all matrix modes, 420 operations each) reproduce
fallback under the old costs and settle with matching matrices/status under
the candidate after one ordinary query step. Near-cap partial translations
remain busy, and genuine over-budget work still rejects. The captured tail,
plus the rejected word and a synthetic closing VTX_16 parameter, also passes
from synthetic identity matrices. This fixture verifies that command sequence,
not the unrecorded preceding game state or the remainder of the game's burst.

Native validation passes, including the earlier vertex, matrix, stack, BOX,
power, storage and ordering regressions. ARM production validation and actual
battle-speed qualification remain pending. These bounds are query eligibility
estimates, not changes to game timing, and are not evidence of full-speed play.
