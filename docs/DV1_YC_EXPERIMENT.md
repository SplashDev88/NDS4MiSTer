# Independent Y/C over Direct Video — experimental beta

Based on published v0.9.0-rc.13. The separate analog screen retains its encoder;
a second instance of the same encoder processes the DV1 screen after its OSD.
The new path requires native DV1, an explicit CRT target, applied CRT timing,
independent outputs, and `vga_mode=svideo`. Scaler-targeted DV1 retains RGB
at the FPGA output. Component transmitter setup is unchanged. The existing
non-split Y/C/CVBS fallback is retained; new independent raw CVBS is out of scope.

The standalone host probes UIO command 0x47 for signature 0x5943, then writes
0x5941 for CRT or 0x5940 otherwise. The FPGA defaults to disabled and ignores
other payloads. This session-only control is separate from persistent status
words: old saved CRT/layout flags cannot opt the Scaler target into Y/C.
The host sends a change only after discovering actual Direct Video flags.
Older cores receive no target payload and remain supported.

Both encoders use the same 60 MHz clock and Main-provided carrier/burst settings,
with independent pixels and sync/blanking inputs. Each routes its delayed sync
with its encoded samples. The existing DV transport keeps the back porch inside
its data window, so chroma and burst are transmitted at the transport clock,
not decimated to the DS pixel-enable cadence. No framebuffer or renderer changes.

## Tester setup

Use a compatible Direct Video HDMI-to-VGA DAC and a MiSTer Y/C active adapter.
On the MiSTer Addons adapter select Direct Video (switch toward the VGA input).
For this first test use NTSC, Video Rotation Off, Direct Video Target CRT,
Digital Layout Main, and Analog Screen Touch; then swap Main/Touch.

The effective NDS INI profile needs:

```ini
direct_video=1
dvi_mode=0
vga_scaler=0
forced_scandoubler=0
composite_sync=1
vga_mode=svideo
ntsc_mode=0
```

Keep `svideo` when using the active board's composite socket: the board mixes
Y and C. This beta does not add PAL 50 Hz, arbitrary CRT-compatible rotation,
independent format settings per port, or new raw-CVBS support. Retain the DAC's
known-working range settings. Apply INI changes through normal MiSTer before
launching; the beta must not replace an existing INI or personal configuration.

Check color, stable sync, independent pictures, Main/Touch swaps, Screen Peek,
and the core menu. Report exact DAC/adapter, TV standard, settings, and whether
the same connection has color in another known-working MiSTer core.

## Validation boundaries

`tools/test_dv1_yc.py` compiles the actual sys_top encoder connections, routing
instance and DV data/sync reconstruction. It exercises all output-control
combinations, different simultaneous analog/digital pictures, carrier frequency,
and transmitted back-porch burst through four 262-line frames per waveform.
PAL carrier simulation does not establish PAL television compatibility.
Host tests cover capability fallback, explicit target changes despite a stale
CRT status flag, persistence, screen selection and unchanged metadata behavior.

The RT4K's direct HDMI input can verify transport timing and baseline display
behavior, but cannot certify the HDMI-DAC/Y-C-board analog chain. A decoded
S-video/composite picture requires that physical chain into its analog input.
Build, timing and physical-test receipts accompany the experimental package.
