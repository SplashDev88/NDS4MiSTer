# ARM9 standard palette readback

The production ARM9 bus previously acknowledged standard palette reads while
returning literal zero. Writes already reached the GPU/HPS correctly. A game
which reads its palette back to build a fade therefore derived new colors from
zero rather than from the palette it had just uploaded.

## Evidence

SoulSilver's title logo reproduced the failure on the Engine B candidate.
Engine B display/background registers and its entire VRAM bank C matched the
normal melonDS reference, but the palette did not. Incoming HPS palette writes
already contained the bad colors; instrumentation found no mismatch between
the received values and the applied values. The error preceded rendering.

A targeted melonDS experiment changed only ARM9 palette reads to return zero.
That reproduced the dark title-logo silhouette. The normal read path restored
the full-color logo. Both runs performed 512 palette reads. Frame phases were
not aligned between hardware and oracle, so this is not a claim of identical
final framebuffer hashes. Missing in-game text requires a separate hardware
retest and is not claimed fixed solely from the title test.

The isolated RTL regression instantiates the actual production ARM9 bus and
cache. Before the fix, a write/read at `0x05000400` failed:

```text
expected=12345678 actual=00000000
```

The same read passes with the readback store connected. The regression also
checks all 512 words, A/B BG and OBJ regions, halfword write lanes, byte reads,
the 2 KiB address mirror, read rotation, consecutive requests in completion
cycles, DMA reads, engine power gating, and clearing on ROM reload/reset.

## Implementation

`nds_palette_readback` maintains a 512-word by 32-bit standard palette shadow
in block RAM. It captures the existing island-side palette write payload and
uses the same engine-power qualification as the GPU stores. Both banks remain
present when Engine B rendering is disabled. The existing GPU write path and
IO completion handshake are unchanged; reads generate no new HPS events.

On accepting a read, the bus registers the palette address. `W_PAL_READ` gives
the synchronous RAM one clock edge to read that address. `FINISH` then presents
the valid word to the existing read rotator. The bus still accepts the next
request on the completing edge. The shadow clears while reset is held and
boot release waits for its synchronized clear-complete state.

Scope is deliberately limited to standard palette readback. OAM readback,
extended palettes, byte-write semantics, the renderer, and frame pacing are
unchanged. This is shared hardware for Engine B and the single-screen backport,
not an Engine B rendering feature.

Run the focused test with:

```sh
bash tools/test_nds_palette_readback.sh
```

It is also included in `tools/test_nitro_console_island_host.sh`. A passing RTL
regression is not a substitute for checking the resulting RBF on hardware.
