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

Run these focused checks from the repository root:

```sh
bash tools/test_nds_cache_line_stream.sh
bash tools/test_nds_cache_instruction_return.sh
bash tools/test_nds_cache_swp_lock.sh
bash tools/test_nds_cache_data_return.sh
bash tools/test_nds_cache_write_return.sh
bash tools/test_nds_dma9_mainram_fast.sh
bash tools/test_nitro_console_vhdl_analyze.sh
```

The instruction and swap regressions now exercise both stream settings.
The line-stream suite checks 128 matched misses across both caches, all eight
critical words, two related-clock ratios, and four memory delays. It verifies
the physical pair order, early response, all warm words, ARM7 arbitration,
scheduler stalls, and reset recovery. Wrong-wrap and truncated-line mutations
must fail. Simulation latency is not a game-speed measurement.

The frozen RC15 source also requires its matching scalar GX readback test
runner. The runner restored here removes newer burst-only parameter overrides
that the frozen testbench does not define; it does not change hardware.

Physical compilation, timing-path reports, test logs, and any admitted hardware
results are recorded in the workspace's
`evidence/cache-stream-rc15-20261109` directory. This source port alone does not
establish timing closure, an RC15 game-speed gain, or release qualification.
