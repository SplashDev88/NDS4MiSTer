# NDS FPGA Video RTL

`nds_color_compositor.sv` is the first synthesizable FPGA offload stage. It is
bit-for-bit derived from melonDS `SoftRenderer2D::ColorComposite` and
`GPU_ColorOp.h` and implements:

- ordinary first/second-target alpha blending;
- semi-transparent OBJ alpha rules;
- 3D per-pixel alpha blending;
- window effect enable gating;
- brightness increase/decrease;
- six-bit channel saturation and melonDS rounding biases.

The interface consumes the two already-prioritized 32-bit layer pixels used by
melonDS, `BLDCNT`, EVA/EVB/EVY, and window bit 5. It emits the composited
six-bit-per-channel pixel.

`nds_layer_selector.sv` selects the first and second visible pixels from six
packed candidates. Lowest rank wins and lower candidate index breaks ties,
matching the software ordering. `nds_pixel_pipeline.sv` combines selection and
composition behind a one-entry registered ready/valid interface with
backpressure.

`nds_video_pixel_stream.sv` is the video-facing boundary. It carries an 18-bit
pixel tag through backpressure and exposes both the raw melonDS pixel and
bit-replicated 8-bit RGB channels. The tag is intended for screen/coordinate
or frame/line metadata in the eventual MiSTer shell.

Verification:

```sh
python3 tools/test_color_compositor.py
python3 tools/test_pixel_pipeline.py
python3 tools/test_video_pixel_stream.py
```

The test generates 50,000 deterministic valid DS pixel/effect combinations,
computes the melonDS reference in Python, and checks every RTL result with
Icarus Verilog. Yosys synthesis succeeds. Generic technology mapping reports
4,678 combinational cells (2,358 AND, 169 MUX, 120 NOT, 737 OR, 1,294 XOR), no
memories, and no inferred state.

The pipeline test checks 10,000 deterministic randomized candidate sets,
effect configurations, rank ties, and output stalls. Yosys synthesis of the
complete hierarchy succeeds with 5,892 generic cells: 2,450 AND, 33 enabled
flip-flops, 1,121 MUX, 165 NOT, 799 OR, and 1,324 XOR. It contains no memories
or unintended latches.

The video-stream test checks another 20,000 deterministic pixels, including
tag retention, RGB expansion, and stalls of up to six cycles. Its complete
hierarchy uses a 19-bit raster-safe tag and synthesizes to 5,912 generic cells,
including 52 enabled flip-flops,
with no memories or unintended latches.

`nds_mister_video_test.sv` drives a complete 640x260 timing envelope with a
512x192 side-by-side dual-screen active area through the actual compositor.
Its full-frame simulation verifies 166,400 pixel strobes, 98,304 active
pixels, and exact horizontal/vertical sync widths. The complete raster plus
compositor hierarchy synthesizes generically to 6,205 cells with no memories.

The DDR ingestion path consists of `nds_ddr_layer_reader.sv`,
`nds_layer_record_stream.sv`, and `nds_ddr_record_pipeline.sv`. It reads
bounded multi-record bursts, assembles every five DDR64 beats into one
byte-aligned layer record, then applies the same verified selector/compositor
stream. Tests cover 30,000 valid randomized layer records and 2,000 records
with memory wait states and consumer stalls. A scanline-budget regression
also proves that 32-record bursts reduce one 512-pixel line from 512 commands
and 4,609 clocks to 16 commands and 2,625 clocks. The complete DDR-to-pixel
hierarchy passes Yosys structural checks.

`nds_dual_line_store.sv`, `nds_ddr_line_cache.sv`, and `nds_ddr_video.sv`
complete the raster-paced path. The banks infer as two synchronous RAM cells,
and the 100 MHz system clock gives ten cycles per 10 MHz pixel. Tests cover 200
overlapped producer/consumer lines, 20 lines through the DDR cache, and two
complete frames through cache, compositor, tag validation, RGB, sync, and
blanking with zero underruns.

Published mode adds `nds_frame_publication_reader.sv` and explicit DDR
arbitration. Its adversarial end-to-end test rejects odd and torn header
snapshots, switches between distinct slots only at a frame boundary, and
retains zero underrun/tag errors. Run `tools/test_published_ddr_video.py` for
simulation and `tools/test_ddr_video_synthesis.py` for the complete generic
synthesis/structural gate. The hierarchy retains two inferred 512x320-bit RAMs.

The selector and color arithmetic are combinational inside the registered
wrapper. The minimum sustained workload for two 256x192 screens at 60 fps is
5,898,240 pixels/s; Cyclone V timing analysis will determine whether the
arithmetic needs additional internal pipeline stages.
