# NSMB background DMA during an ARM geometry read

NSM3's passive hardware snapshots identified the accepted transaction behind
NSMB's delayed HBlank scroll updates: a read at `0x04000640`. The CPU's
memory bus remained in `W_IO_RESP`, waiting for the ARM geometry reply, while
DMA waited in `GRANT`. All 1,203 sampled grant stalls in the fast-poll run had
this combination. These samples identify the blocker; they are not a cycle
census or a percentage of execution time.

NSM2's address-qualified geometry-cache invalidation already removes needless
queries after ordinary 2D DMA writes. At normal polling it corrects the tested
W1-1 background bands and improves game progression. Faster polling exposes
the remaining arbitration problem. Changing polling alone is not a graphics
fix.

## NSM4's limited overlap

The CPU keeps its accepted read and stays paused. A pending DMA may borrow the
independent main-RAM and IO fast lanes only when all of these conditions hold:

- A real GX read is outstanding and its fence is no longer being posted.
- The main-RAM cache is idle across both existing guard samples, no loader or
  debug peek owns RAM, and the CPU has no memory lock.
- It is a one-unit HBlank DMA from main RAM to an ordinary Engine A or B 2D
  register below the 3D/capture registers.
- A reloaded destination is also in that allowed register range. Unsupported
  source-reload mode is excluded.

After taking ownership, this transfer waits for the existing RAM fast grant.
It cannot fall back to the CPU's occupied memory bus. The ordinary RAM pair
read, lane selection, write backpressure, register event transport and DMA
retirement paths remain in use.

A real geometry reply arriving during this interval is retained by
`nds_h3d_gx_dma_completion`. Its CPU completion is issued only after DMA returns
the IO mux. Without an overlap, completion has no additional clock latency.
Reset discards a pending completion. No fake idle indication, speculative
geometry result or early CPU acknowledgement is introduced.

The change is enabled by the console port connection. Other users of
`nds_dma9` retain the old behavior through the default-zero input.

## Validation

`tools/test_dma9_gx_overlap.sh` uses the real DMA and GX-readback owner. It
checks delayed replies at four transfer stages, word and halfword lanes,
cache/lock guards, delayed RAM grant, IO backpressure, repeated HBlanks during
one outstanding query, unsupported transfers and reset with a retained reply.
It also runs the existing 72-case main-RAM fast/fallback regression.

Negative controls fail when the new grant is disabled and when reply retention
is bypassed. The geometry-cache invalidation, GX owner/reply suites and full
console VHDL analysis also pass. Hardware qualification is recorded separately
with the exact bitstream and helper hashes; passing these tests alone does not
establish that gameplay is fixed or full speed.
