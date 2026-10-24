# Native DV1 menu proportions

The legacy native menu chooses its horizontal pixel size from the number of
transport clocks in an active line. That grid differs from the DS pixel grid.
On a stacked DV1 picture, a font column can occupy one transport clock while
a game pixel occupies three, and menu rows can be doubled independently.
External rotation makes the resulting distorted lettering especially obvious.

The DV1 correction uses the scanout pixel enable to address the existing menu
bitmap. One font pixel occupies one game pixel in each direction. The complete
256-column menu fits a 256-pixel source without clipping its first or last
columns. Normal menus retain 16 rows; loading messages retain 8 rows. Native
video and its menu now follow the core’s Video Rotation selection on DV1.
Leave external scaler rotation Off when using core rotation, to avoid turning
the picture twice.

The correction is enabled only for DV1 (`direct_video=1`, `dvi_mode=0`), when
HDMI uses native timing and analog uses either its independent raster or the
HDMI scaler. DVI, Direct Video 2, ordinary HDMI and the legacy shared analog
raster retain their existing menu implementation. Scaled VGA also retains
the existing HDMI scaler menu. Independent analog keeps its existing menu
implementation even during DV1 operation.
Bitmap storage, the write queue and RGB/sync latency remain unchanged.

The optional fourth response to system command `0x46` is `0x4e50`, with bit 0
set while this raster is active. The host requires the existing `0x4456`
signature, the `0x5350` split-output capability and the exact `0x4e51` response before
removing the DV1 high-resolution OSD flag. The new menu can be decimated like
the game image, so opening it no longer asks the receiver to change sampling.
Older FPGA images retain their original metadata behavior. Two matching
geometry and raster-mode observations are required before updating metadata.

The external scaler still determines the final picture aspect. Use square
pixels for combined DS layouts; an inherited 4:3 pixel-aspect correction
stretches both the game and its menu. On the tested RetroTINK-4K, input timings
have separate scaling settings. For the portrait stacked layout, automatic
decimation, Target Decimate Off and Auto Fill Int replace the earlier manual
720-pixel workaround. The LCD mask remains available. External rotation should be Off when the core
provides the rotation.

## DV1 rotation

The native digital scanout previously bypassed the HDMI rotation framebuffer.
DV1 now reads that same completed framebuffer with a small native scanout.
The original scanout continues feeding the transpose writer and independent
analog output. The ARM renderer and console DDR interface are unchanged.
The added reader uses contiguous bursts on the existing scaler DDR port and
two RGB666 line buffers (18,432 bits). RGB666 expansion roundtrips exactly.
It does not copy another full frame or issue strided column reads.

The transpose writer reserves four 1 MiB slots at `0x24000000..0x24400000`.
The fourth slot was already excluded from cartridge mappings; Linux memory,
ROM capacity and all save mappings remain unchanged. HDMI and DV1 each pin
their displayed slot and independently acknowledge an immutable descriptor.
The writer excludes both readers and the pending descriptor when selecting
a slot. An inactive DV1 reader acknowledges immediately so it cannot delay
normal HDMI publication.

The native consumer changes descriptors only in blanking, after all previous
reads have drained and before fetching the next frame’s first line. Adoption
closes before that prefetch, preventing its completion from releasing the
just-acquired frame. A new completion can be adopted anywhere in this safe
window, avoiding an extra frame of latency when it arrives during blanking.
A missed line is black for the entire line, never a mix
of pixels being overwritten. Geometry changes commit at a frame boundary.
The read arbiter preserves stalled commands and normal write bursts, drains
prior read responses, and routes every response to the client that requested
it. With no native request, the normal scaler interface is a combinational
pass-through.

The native raster retains a 60 MHz transport clock and integer repetitions.
All three timing classes use 1,006,080 clocks/frame (about 59.64 Hz): 640x262
with repetition 6, 640x524 with repetition 3, or 640x786 with repetition 2.
The latter accommodates rotated side-by-side screens and their largest gap.
Images taller than 250 pixels use at least the 524-line class. Vertical sync
leaves blanking both before and after its pulse so MiSTer's reconstructed
HDMI data-enable window retains every game row, including the first two.
MiSTer’s existing video measurement logic measures the selected DV1 output,
so the host sends its actual width, height, repetition and crop offsets.
Opening the menu does not change the raster or its metadata.

The menu applies the inverse of the displayed game rotation when addressing
its existing bitmap, including both 64- and 128-pixel-tall menus. It follows
the applied framebuffer orientation rather than a requested direction that
has not yet finished rendering. Independent analog remains upright. Scaled
analog retains its existing HDMI mirror behavior.

## Validation

`python3 tools/test_dv1_osd.py` checks the complete native menu against an
independent pixel oracle and the non-DV1 and simultaneous analog outputs
against the released implementation. Upright and both rotated directions,
all native layouts, 8/16 rows, hidden menus and transitions passed 23,538,192
samples per output. Both edge columns are checked explicitly.

`python3 tools/test_dv1_osd_gate.py` exhausts the actual mode declarations:
1,572,864 combinations covering DVI, DV2, framebuffer/scaler routing and
both HDMI-only builds. The correction applies only to DV1.

`python3 tools/test_dv1_rotation.py` checks burst arbitration, exact native
pixels, metadata from the actual MiSTer measurement module, delayed reads,
layout transitions, and the complete transpose-to-native-output pipeline.
It also extracts the actual DV1 HDMI transport and verifies that its
data-enable window includes every active game pixel. A timing variant uses
the approximately 59.64 Hz source/native cadence and a 60 Hz HDMI consumer
to reject unintended throttling to half the frame rate.
The measurement harness spells legacy block-static initializers as explicit
initial blocks for Verilator; the production measurement logic is unchanged.
`bash tools/test_nds_tate.sh` also runs the TATE testbench with
`NATIVE_READER=1` to check independent consumer clocks, a paused consumer,
immutable pending frames and recovery, alongside the original four
single-consumer configurations.

The shared-bitmap/write-queue regression, loading-window rotation tests,
actual host display-menu and DV-target tests, dual-output host/RTL trace,
and DV1 metadata tests cover the unchanged paths and protocol fallback.
The older split-output host test still has a stale hard-coded menu-row
assertion; the same assertion fails on the unchanged release source.
The version source and generated menu identify `v0.9.0-rc10`; footer
rendering and scrolling tests passed with that string.

The menu-only candidate was tested on hardware with stacked, single and
side-by-side DV1 layouts, external rotation, independent analog and normal
HDMI in all core rotation directions. These observations do not validate the
new native rotation reader: its FPGA build and hardware checks are pending.

The experimental FPGA build starts from the exact frozen rc10 FPGA inputs
and overlays only the native video/menu changes. Static timing closure
remains unresolved. The release notes and README are unchanged.
