# Raw pre-blip PCM8 reference

This is a third, independent, host-only sound oracle. It does not modify or
include the stable PCM8 v1 generator, the v2 format suite, Robert's source, or
production MiSTer files.

## Exact observation stage

The test includes melonDS `Platform.h` and `Savestate.h` normally, changes the
`private` keyword to `public` only while parsing `SPU.h`, immediately restores
the keyword, and then includes `NDS.h`. This test-TU access relaxation changes
neither the vendored source nor the compiled `SPU` layout/ABI.

After each exact 1,024-shared-cycle SPU event, the test reads
`SPU.OutputLastSamples[0:1]`. In melonDS `SPU::Mix()`, those values are:

1. after per-channel mixing, pan, routing and master volume;
2. after the configured bias adjustment and signed 16-bit clamp;
3. after the optional 10-bit degradation stage (disabled in this fixture);
4. copied from the exact two values passed to `blip_add_delta()`; and
5. before blip-buf filtering/resampling and before `SPU::ReadOutput()`.

The generator verifies 32 kHz mixing, 16-bit/no-degrade mode, bias `0x200`,
master enable, and an unmuted SPU. It also proves that draining the post-blip
output does not change the last raw pair.

## Test case

The register configuration and 64-byte copyright-free seed are byte-identical
to the PCM8 v1 case. Both external CPUs advance in alternating 1,024-cycle
reports through shared timestamp 75,776. ARM7 enters HALT after timestamp
2,048, while timing reports continue, matching the hybrid wall-clock contract.

The trace contains:

- ten exact ARM7 writes across 8/16/32-bit widths;
- 148 normalized CPU-time reports;
- all eight aligned sample-memory reads and returned seed words; and
- 74 raw signed stereo pairs, one after every scheduled SPU mix.

The selected timer and window reach negative and zero PCM8 values but not the
seed's later positive samples. The raw trace still proves nonzero signed and
asymmetric stereo; the post-blip v1 trace separately crosses both signs due to
filter response.

## Binary format

The 40-byte little-endian header uses magic `NDSRAW1\0`, version 1, 24-byte
records, stage flags `0x0007`, record count, payload CRC-32, seed CRC-32, raw
sample count, and final shared timestamp. Records encode exact writes, timing
reports with both CPU halt states, memory reads/data, raw signed stereo, and
phase markers.

The verifier checks exact ordering and values, each 1,024-cycle event and next
SPU deadline, the seed data, signed encoding, stage flags, timestamps, CRC,
reserved fields, length bounds, and six malformed-input cases.

Run:

```sh
./tools/test_sound_raw_pcm8_reference.sh
```

The gate regenerates twice, verifies the immutable base64 fixture, and pins
both encoded and decoded SHA-256 values. It currently targets Darwin arm64 and
the current non-stale melonDS host archive.
