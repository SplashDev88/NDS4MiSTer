# Experimental NDS audio headroom

This branch prepares a deliberately narrow A/B experiment for issue #13. It
does not claim that the reported distortion is fixed, because no hardware
capture of the failing scene has yet measured clipping.

## Traced production path

1. `third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd` decodes and mixes the
   16 DS channels. Its channel volume, pan, master-volume, bias, and signed
   clamp arithmetic matches the corresponding operations in melonDS
   `SPU.cpp`.
2. `rtl/nds_nitro_console_island.sv` previously forwarded that signed 16-bit
   pair unchanged.
3. `fpga/mister_nitro_console_island/NDS4MiSTer.sv` forwards the pair unchanged
   to MiSTer's normal audio boundary and asserts `AUDIO_S=1`.
4. MiSTer's `audio_out.sv` therefore preserves the sign bit. Its user-volume
   control can attenuate the signal, and its saturator does not add gain at the
   default zero-boost setting.

The DS accumulators are wide enough for their worst-case intermediate values:
21 bits after the maximum channel shift, 30 after channel volume, 39 after
pan, 32-bit stereo accumulators, and 41 bits for master volume. No arithmetic
overflow was found before the intended signed 16-bit clamp.

## What remains unproven

- How often a failing game reaches the DS mixer's `-32768`/`32767` clamp.
- Whether distortion grows with active-channel count, indicating real mixer
  clipping, or remains constant, indicating presentation/filtering.
- Whether the direct-boot game writes the normal `SOUNDBIAS=0x200` value.
- Whether the disabled MiSTer IIR low-pass, the 32.73-to-48 kHz held-sample
  presentation, or the sound engine's documented fetch-underrun behavior is
  the audible problem.
- Games using the still-unimplemented `SOUNDCNT` channel 1/3 direct-output
  routes can also sound different from a DS even when output gain is correct.

## Prepared A/B candidate

`nds_audio_headroom` applies a constant signed right shift after the emulated
DS mixer and before MiSTer's audio boundary. `SHIFT=1` is exactly -6.02 dB and
synthesizes as wiring: no DSP, adder, register, state, or additional latency.
The vendored Nitro_DarkSide mixer is unchanged, preserving Sarah Aronson's
GPL-licensed implementation and its melonDS-derived arithmetic.

This can lower an overly hot signal delivered to a TV/receiver, but it cannot
reconstruct peaks already clipped inside the DS mixer. It must therefore be
tested as an A/B experiment, not described as a root-cause fix.

## Required hardware test before acceptance

1. Build baseline and `SHIFT=1` from the same commit and Quartus seed.
2. Use the same saved scene in at least one music-heavy and one overlapping-SFX
   game, with MiSTer and TV volume controls unchanged.
3. Capture at least 30 seconds of digital HDMI/I2S audio from each candidate.
4. Report peak, RMS, and the percentage of samples equal to each signed clamp
   endpoint. Compare the same scene against melonDS at matched loudness.
5. If baseline endpoint counts are high and the attenuated candidate only makes
   the already-flat peaks quieter, instrument the pre-clamp mix next; do not
   stack more output attenuation.
6. If endpoint counts are low but the harshness remains, test the low-pass or
   sample-rate presentation path instead of changing mixer gain.

Host-only verification:

```sh
./tools/test_nds_audio_headroom.sh
./tools/test_nds_sound_vhdl_analyze.sh
```
