# melonDS sound reference trace

`SoundReferenceTrace.cpp` is a simulator-only oracle for bringing Robert
Peip's DS sound RTL up against the hybrid core's existing melonDS model. It
uses the same `NDS::AdvanceExternalCPU` and physical ARM7 I/O paths as the HPS
responder. A small `NDS` subclass passively observes the virtual
`ARM7Read32()` calls made by the SPU FIFO.

The deterministic synthetic case covers:

- byte, halfword, and word ARM7 sound-register writes;
- normalized shared time from both external CPUs;
- shared-time stalling and later wall-clock progress while ARM7 is halted;
- exact aligned sample-memory read addresses and returned words; and
- signed, nonzero, asymmetric stereo samples from melonDS's public SPU output.

It intentionally does not require a copyrighted ROM or BIOS. The case is a
small PCM8 loop seeded at `0x02001000`, so failures are reproducible and fast.
NSMB boot capture can be layered on later without changing the format.

## Canonical binary format (version 1)

All integers are little-endian. The 32-byte header is:

| Offset | Size | Meaning |
| --- | ---: | --- |
| 0 | 8 | `NDSAUD1\0` magic |
| 8 | 2 | version (`1`) |
| 10 | 2 | header bytes (`32`) |
| 12 | 2 | record bytes (`24`) |
| 14 | 2 | flags/reserved (`0`) |
| 16 | 4 | record count |
| 20 | 4 | IEEE CRC-32 of all records |
| 24 | 8 | final shared timestamp |

Every 24-byte record contains a one-byte type, one-byte flags field, two
reserved zero bytes, a 64-bit shared timestamp, and three type-specific
32-bit values:

| Type | Meaning | Flags | `a`, `b`, `c` |
| ---: | --- | --- | --- |
| 1 | ARM7 write | access code 0/1/2 | address, value, zero |
| 2 | external time advance | issuing CPU plus ARM9/ARM7 halt-before/after bits | cycles, prior shared time, normalized issuing-CPU time |
| 3 | SPU sample read | word access (`2`) | address, returned data, ordinal |
| 4 | signed stereo frame | zero | ordinal, sign-extended left, sign-extended right |
| 5 | phase marker | zero | marker ID, detail, zero |

The validator rejects unknown types, invalid access widths or
alignment, nonzero reserved fields, nonmonotonic time, malformed signed
samples, count/length mismatches, truncation, and CRC failures.

Run:

```sh
./tools/test_sound_reference_trace.sh
```

The test builds only the host trace tool, generates the trace twice to prove
determinism, runs five malformed-input rejection cases, verifies required
coverage, and checks the canonical file byte-for-byte against the immutable
base64 fixture in `fixtures/` and its pinned SHA-256.
