# FFTA2 guest-code optimization — 27 October 2026

Status: the first guest patch is **rejected** after the full Luso replay.
It remains disabled. No new guest patch is installed or release-qualified;
accepted FFTA2 Beta2 remains unchanged. Platinum is queued, not active.

## Scope and existing mechanisms

The target is USA A6FE revision 0, header CRC32 `8c766dbb` over 352 bytes;
complete identity and original/replacement instructions are in
[`ffta2-a6fe-r0.json`](ffta2-a6fe-r0.json). Exact published rc12 is the historical
control; accepted Beta2 source `70e35668b43a8da4f544324fbe13a42d2fee0ceb` is the
cumulative build. Its earlier gains are renderer changes, not guest patches.

Reuse `tools/standalone_host/fmv/prepare.py:VirtualRom` and `hook_guard.py`.
NSMB and FMV work already demonstrate guarded virtual cartridge loading without
changing the source ROM. The guest ARM9/ARM7 execute in FPGA; ordered graphics
records and readback fences cross shared DDR to the existing HPS renderer.
There is no assumed arbitrary guest-PC HLE trap. No RTL or new HPS service is
authorized by this investigation.

The existing replay oracle supplies both CPU instruction samples, framebuffers,
RAM, audio and saves. Its old FFTA2 correctness runs intentionally disabled
sampling. New diagnostic runs enable it without changing the game code. All
43,400 replay frames retain their screen, audio, save and per-frame RAM hashes;
only diagnostic instruction-counter columns differ. The underlying evidence
is `GUEST_PATCH_PROFILE_UNIT.json` in the private FFTA2 evidence directory.

## Initial hotspot classification

These are shares of software instruction samples within the listed address
ranges, **not native cycle shares or speedups**. Luso covers frames 2600–4399,
Fire 6500–8999, and library 23300–29999. The last includes the settled forest
dialogue after the transition. Ranges may cover part of a larger function.

| ARM9 work | Luso | Fire | Library |
|---|---:|---:|---:|
| Per-vertex setup/emission, `0208ccf4–0208cdb7` | 16.24% | 13.72% | 22.61% |
| ADPCM-like nibble decoder, `02020080–02020147` | 18.67% | 18.67% | 0% |
| Halfword copy, `020093e0–02009413` | 4.17% | 4.18% | 0.24% |
| Cartridge receive loop, `0201016c–02010193` | 4.06% | 5.06% | 1.42% |

The decoder classification is an inference from nibble processing, predictor
updates and clamped table indices; callers and buffer lifetimes remain to be
traced. The cartridge loop consumes data at `04100010` while polling `040001a4`;
it is not an idle loop that can simply be replaced with halt. ARM7 profiles are
also retained, with function/caller classification still open. Full disassembly,
hashes and the ten-pattern screening ledger are in
`GUEST_PATCH_HOTSPOT_REVIEW.json` in private evidence.

## First candidate: compact halfword-copy branches

`copy16-compact-branches` replaces a 52-byte ARM main-code function in place.
It retains the same halfword reads/writes and order, signed length checks and
return state. It uses no scratch memory, trampoline, overlay hook, DMA or HLE.
It must be admitted only for the pinned ROM/ARM9 identity and exact original
bytes. A diagnostic loader now reuses `prepare.VirtualRom` and `hook_guard`;
18 negative identity/target/byte guards fall back to the original image.
The existing replay oracle accepts that virtual image over stdin, retains the
original identity, and writes a separate RAM comparison with only the exact
52 instruction bytes normalized. It checks original/replacement bytes every
frame; unexpected code aborts the run. No patched ROM file is created. The
native host is not wired to this diagnostic candidate.

The generic `check_halfword_copy_patch.py` diagnostic passes 1,276 synthetic
cases comparing R0–R12, SP/LR/PC, CPSR, data memory and ordered data accesses.
Cases include zero/negative/odd/even lengths, overlap, identical pointers,
unaligned inputs in Unicorn and ARM/Thumb return. This does not model native
interrupt/DMA interleavings, MMIO, instruction-cache behavior or code overlap.

| Measurement | Original | Candidate | Interpretation |
|---|---:|---:|---|
| 16-byte copy, synthetic executed instructions | 74 | 44 | 40.5% fewer instructions in this function |
| 64-byte copy, synthetic executed instructions | 266 | 164 | 38.3% fewer instructions in this function |
| 128-byte copy, synthetic executed instructions | 522 | 324 | 37.9% fewer instructions in this function |
| ARM9 instructions, Luso frames 2600–4399 | 391,329,973 | 385,205,747 | 1.565% fewer; rejected output, not a speed result |
| Top-screen frames differing from golden | 0 / 4,400 | 16 / 4,400 | First difference at frame 1513 |
| Bottom-screen frames differing from golden | 0 / 4,400 | 0 / 4,400 | Exact |
| Main-RAM frames differing after code normalization | 0 / 4,400 | 4,268 / 4,400 | First difference at frame 94 |
| Audio stream | Golden | Different | First differing stereo sample at about 12.551 s |
| Final game save | Golden | Equal | Does not override other failures |
| Native game progress, p50/p95/max pacing, HPS load | Existing scene evidence | Not run | Software gate failed; no new speedup claimed |
| Native CPU cycle/DMA/cart-byte counters | Unavailable | Unavailable | Do not substitute instruction counts |

The unpatched virtual-stream control reproduces all 4,400 reference frames,
RAM, audio and save data exactly. The patch changes 20,480 bytes outside its
instruction region in the retained frame-2600 main-RAM dump. DTCM differs in
2,660 frames and ARM7 WRAM in 372. ITCM and shared WRAM remain equal. These
differences are not declared benign or masked. Further Fire/library patched
replays and native qualification are unnecessary for this rejected version.

Unpatched caller traces pass all original output checks across Luso, Fire and
library routes. Their profiled windows contain 7,015, 12,338 and 6,697 copy
calls, respectively. Besides RAM, VRAM and palette writes, the routine copies
64 bytes to `04000380` each frame: the toon-table range, confirmed in the
existing `GPU3D.cpp` write handlers. No odd alignment/length, overlap or writes
over this function were observed in these windows; this is not full-game proof.

Exact input manifests/checksums are preserved beside
`GUEST_COPY16_SYNTHETIC_V1.json` and `GUEST_COPY16_REJECTION_ANALYSIS.json` in
private evidence. The current manifest records rejection with `enabled: false`.

The new generic `scan_guest_patterns.py` structural detector finds the same
branch scaffold in ARM9 and ARM7 autoload code, with no hardcoded game address.
Six positive/negative scanner checks pass. The ARM7 occurrence has no samples
in the Luso window; shared SDK provenance is not established. Its coverage is
explicitly limited to ARM main/autoload sections, not overlays or Thumb.

## Next validation and limits

Investigate the vertex function containing `0208ccf4–0208cdb7`, especially its
repeated shifts and index multiplies. Trace callers and register/memory ranges
before changing its arithmetic. Retain graphics submissions and access order.
For any later candidate, complete replay comparison precedes cold boot,
in-game save/reload, reset, overlay transitions, an unrelated scene and paired
native measurement. Ask before accepting non-bit-exactness.

The retained rc12 runtime's observed diagnostic header words 24/25 were zero,
not the required ARM9 sampler tag. Native guest-PC sampling is therefore not
available through that retained interface. Do not silently rebuild RTL.
Persistent core save states are unsupported; ordinary game saves do not prove
save-state round trips. No original ROM or save was changed by this work.

## Three further ideas, not yet tested

1. Simplify repeated vertex packing/shifts and loop indexing while preserving
   every GX write and required register/stack result; investigate before caching
   or suppressing submissions.
2. Establish callers, source-content recurrence and output dependencies of the
   ADPCM-like decoder, then consider an exact arithmetic or resident-data path.
3. Trace repeated cartridge sectors and filesystem lookups before proposing
   reuse; preserve data-ready, completion, destination and invalidation behavior.
