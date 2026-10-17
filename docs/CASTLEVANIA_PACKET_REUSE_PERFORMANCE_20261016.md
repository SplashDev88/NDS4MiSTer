# Castlevania packet-buffer reuse experiment — rejected

The candidate is not included in a beta. Its repeated cave run lost most textured background graphics; the higher publication rate during that run is invalid as a performance result. Castlevania Beta8 remains the accepted build.

The ARM-side experiment retained initialized packet-vector elements until their complete replacement, removing repeated clear/resize initialization. It changed the packet consumer and replay worker only. Packet validation, ownership counters, barriers, acknowledgements, geometry, rendering, frame admission, clocks and RTC were unchanged.

## Measurements and validation

A stock-1-GHz, cached-RAM protocol microbenchmark measured 10.579% less time for 264-record packets and 7.580% less for 1,799 records. This does not measure uncached FPGA transfer or gameplay. Larger NEON copy batches were rejected because results were inconsistent.

The complete ARM service self-test passed, including asynchronous ring wrap and backlog checks. Focused protocol tests covered grow/shrink/reused buffers, diagnostics, empty and failed acquisition, and all previously tested packet faults. These checks did not expose the live graphics failure.

The first intact cave comparison measured 19.2402 versus 19.3799 completed publication pairs/s (+0.726%), below the predeclared 1% improvement gate. NSMB's first control was 44.1535 versus 44.3309 pairs/s. These are completed source publication pairs, not distinct animation FPS. A short candidate combat capture rendered normally but enemy phases differed, so it does not establish a speed gain.

The second candidate cave run showed missing background textures throughout its active window despite zero reported protocol fault words. Its 21.2135 pairs/s result is excluded because the rendered workload was visibly incorrect. The experiment was rejected immediately; remaining candidate runs and packaging were cancelled. The subsequent Beta8 repeat rendered the complete background normally at 19.4535 pairs/s, close to its first 19.2402 result. This supports rejecting the candidate but does not by itself prove the root cause of the intermittent corruption.

The candidate source and failed visual evidence were preserved locally; its three source/test edits were restored exactly to the Beta8 revision. No public release or new beta package was created.
