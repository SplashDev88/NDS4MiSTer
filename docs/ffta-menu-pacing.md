# Sustained fast graphics queries

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

## Validation

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
