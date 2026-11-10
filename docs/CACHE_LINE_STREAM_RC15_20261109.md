# RC15 cache-line streaming trial

This opt-in experiment ports the earlier cache-line stream implementation to
the frozen FPGA inputs shipped with RC15. The control revision is `02edafd`.
The RC15 package's FPGA input manifest, rather than the later checked-in QSF,
defines the hardware control. The accepted RC15 core has SHA-256
`e297b21a877b41128f7762e54907ba460c49e43d294ece5a32e550784651f5da`.

`NDS_CACHE_LINE_STREAM_EXPERIMENT=1` enables one logical request for the four
8-byte pairs in a cache line. Main RAM advances the pair address locally,
starting at the requested pair and wrapping within 32 bytes. Every pair still
uses the existing SDRAM transaction and completion handshake. ARM7 priority
and the external memory scheduler still arbitrate between pairs.

The first requested word returns before the rest of the line completes. The
cache cannot mark the line valid until the last word arrives. Uncached reads,
locked swaps, writebacks, and DMA keep their existing request contracts. The
top-level DMA arbiter waits for the cache refill to finish before taking the
port, even if the CPU has already received its requested word.

The default VHDL generic is false. The experimental QSF enables the feature;
the matched control QSF does not. No clock, timing exception, host executable,
renderer, or graphics-quality setting is changed by this port.

## Second physical candidate: local GPU queue credit

The first port (`6fc8430`) passed the focused functional checks, but worst
setup slack worsened from the exact RC15 control's -15.010 ns to -16.529 ns.
Its streaming address/control paths met setup and hold. The first candidate
was archived and was not loaded on hardware.

The detailed failing path traversed the ordered graphics sink and its ready
feedback into DMA IO acceptance and the ARM9 math unit. The second candidate
also enables `NDS_H3D_GPU_LOCAL_CREDIT_EXPERIMENT=1`. With that independent
switch, the source queue grants credit from its registered occupancy alone.
A full queue can accept a replacement on the clock after a downstream pop,
instead of borrowing that pop combinationally. Empty-queue bypass, capacity,
event payloads, timestamps, and ordering are retained. A blocked CPU pulse
remains in the skid slot; a DMA producer holds valid until acknowledged.

This deliberately adds one acceptance cycle when the queue is full in order
to shorten the ready-feedback path. Any game comparison of this second build
measures streaming plus this timing change. It does not isolate streaming's
contribution. The macro and VHDL generic default to disabled outside this
experimental QSF.

Run these focused checks from the repository root:

```sh
bash tools/test_nds_cache_line_stream.sh
bash tools/test_nds_cache_instruction_return.sh
bash tools/test_nds_cache_swp_lock.sh
bash tools/test_nds_cache_data_return.sh
bash tools/test_nds_cache_write_return.sh
bash tools/test_nds_dma9_mainram_fast.sh
bash tools/test_nitro_console_vhdl_analyze.sh
bash tools/test_h3d_console_event_gate.sh
bash tools/test_hblank_run_queue.sh
```

The instruction and swap regressions now exercise both stream settings.
The line-stream suite checks 128 matched misses across both caches, all eight
critical words, two related-clock ratios, and four memory delays. It verifies
the physical pair order, early response, all warm words, ARM7 arbitration,
scheduler stalls, and reset recovery. Wrong-wrap and truncated-line mutations
must fail. Simulation latency is not a game-speed measurement.

The event-gate suite runs both credit policies, checks the full-queue CPU
completion cycle and the held DMA handshake, and requires a deliberately
restored combinational pop-credit path to fail the local-credit check. The
compressed HBlank regression also runs with both credit policies.

The frozen RC15 source also requires its matching scalar GX readback test
runner. The runner restored here removes newer burst-only parameter overrides
that the frozen testbench does not define; it does not change hardware.

Physical compilation, timing-path reports, test logs, and any admitted hardware
results are recorded in the workspace's
`evidence/cache-stream-rc15-20261109` directory. This source port alone does not
establish timing closure, an RC15 game-speed gain, or release qualification.
