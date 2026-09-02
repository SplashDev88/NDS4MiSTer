# melonDS sound-format reference suite v2

This host-only suite expands the stable PCM8 v1 oracle with four independent,
copyright-free synthetic cases:

- PCM16 on channel 2;
- IMA-ADPCM on channel 3;
- PSG on channel 8; and
- noise on channel 14.

The PCM8 v1 source, fixture, documentation, and test script are not included
or modified by this suite.

Each case uses melonDS's physical ARM7 I/O path and external-CPU scheduler.
The PCM cases observe every SPU `ARM7Read32()` sample fetch and returned word.
PSG and noise assert that no sample-memory transaction occurs. All cases
capture signed stereo through the public SPU output.

`AudioSample` records are specifically the frames returned by
`SPU::ReadOutput()` after melonDS has passed its internal mixer deltas through
blip-buf. They are not the raw signed `output[2]` values immediately before
`blip_add_delta()` in `SPU::Mix()`.

## Deterministic contract

All cases configure 32,768 Hz, 16-bit output with interpolation disabled and
use `SOUNDxTMR=0xFE00`. ARM9 advances 4,096 cycles before ARM7, followed by
eight alternating 8,192-cycle reports. This proves that shared time remains
the minimum normalized CPU timestamp: unilateral reports stall it and the
other CPU catches it up. Every case ends at shared timestamp 69,632.

PCM16 uses 32 generated signed samples. ADPCM uses a generated 64-byte block
whose header selects initial sample -4,096 and index 32. Neither seed contains
game or recorded audio data. PSG and noise are hardware-generated and have a
zero seed CRC.

## Binary format

All integers are little-endian. The 40-byte header contains:

| Offset | Size | Meaning |
| --- | ---: | --- |
| 0 | 8 | `NDSAUD2\0` |
| 8 | 2 | version 2 |
| 10 | 2 | header size 40 |
| 12 | 2 | record size 24 |
| 14 | 2 | reserved zero |
| 16 | 4 | case ID |
| 20 | 4 | record count |
| 24 | 4 | payload CRC-32 |
| 28 | 4 | canonical seed CRC-32 |
| 32 | 8 | final shared timestamp |

The 24-byte records use the same layout as PCM8 v1: type, flags, reserved,
shared timestamp, and three 32-bit type-specific values. Types cover exact
ARM7 writes, normalized time reports, sample reads/data, signed stereo frames,
and phase markers.

The versioned manifest under `fixtures/` pins the decoded trace and base64
fixture hashes plus exact record coverage. The verifier additionally checks
the case-specific register sequence, seed data returned by every memory read,
no-memory behavior for PSG/noise, timing order, access widths, signed stereo,
CRC, reserved fields, monotonic timestamps, and length bounds.

Run:

```sh
./tools/test_sound_format_reference_suite.sh
```

Each case is generated twice, checked against its immutable fixture and
manifest, and subjected to six malformed-input rejection cases.

## Oracle limitations

melonDS keeps its raw pre-blip stereo values and channels private and exposes
no callback at that point. Adding an exact raw-mix hook without changing
vendored melonDS would require a brittle private-layout/preprocessor shim or a
second copied mixer implementation, neither of which is an authoritative
low-risk oracle. A dedicated upstream/non-vendored instrumentation seam for
the two raw `SPU::Mix()` samples remains the next comparison gap.

The cases use one timer rate, one channel and pan setting per format, 32 kHz
output, and looping playback. ADPCM covers startup and FIFO refill but does not
reach its loop boundary. The suite does not cover one-shot/hold behavior,
47 kHz mode, mixer routing, clipping endpoints, capture/recording, hardware
DDR latency, or NSMB traffic. Hashes are pinned to the current Darwin arm64
melonDS build.
