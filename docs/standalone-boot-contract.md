# Standalone DS boot contract (development/oracle path)

Status: descriptor version 3. This is retained for the HPS oracle and
hardware-development tools; it is **not** the boot path used by the public
NDS core.

The public core loads the selected ROM at `0x30000000`, reads its cartridge
header, copies both program sections, creates the direct-boot environment, and
releases the FPGA CPUs itself. The contract below instead seeds FPGA CPU and
memory experiments from a melonDS reference instance. Do not enable the oracle
publication and the public ROM-loading path at the same time because both use
the `0x30000000` aperture for different purposes.

## DDR layout

| Physical address | FPGA 64-bit word address | Purpose |
| --- | ---: | --- |
| `0x2C000000` | `0x05800000` | Oracle mailbox. |
| `0x2C001000` | `0x05800200` | Read-only boot descriptor. |
| `0x2C010000` | `0x05802000` | 32 KiB shared WRAM mirror. |
| `0x2C020000` | `0x05804000` | 64 KiB ARM7 WRAM mirror. |
| `0x2C030000` | `0x05806000` | FPGA-to-HPS posted-write ring. |
| `0x2C0C0000` | `0x05818000` | HPS-to-FPGA consumed-credit/acknowledgement ring. |
| `0x2C100000` | `0x05820000` | 4 MiB DS main-RAM mirror. |
| `0x30000000` | `0x06000000` | Development-only compact video/input publication. |

`HpsOracleResponder` resets melonDS, creates the reference direct-boot state,
copies main RAM and both WRAM regions, initializes the transport rings, and
publishes the descriptor. The FPGA accepts only a supported version with a
matching size and descriptor checksum. It does not release either CPU until
the descriptor is stable and all CPU-state writes have completed.

## Descriptor version 3

All fields are little-endian 32-bit words. The descriptor is 64 bytes.

| Word | Field | Contract |
| ---: | --- | --- |
| 0 | Magic | `0x4253444E` (`NDSB`). |
| 1 | Version | `3`. |
| 2 | Generation | Nonzero and published last. |
| 3 | ARM9 DTCM IRQ vector | Aligned, nonzero value installed at DTCM `0x3FFC`. |
| 4 | Main-RAM bytes | `0x00400000`. |
| 5 | ARM9 trace trigger | Aligned main-RAM execution PC, or zero to disable capture. |
| 6 | ARM9 entry | ROM-header `ARM9EntryAddress`. |
| 7 | ARM7 entry | ROM-header `ARM7EntryAddress`. |
| 8 | ARM9 current SP | `0x03002F7C`. |
| 9 | ARM9 IRQ SP | `0x03003F80`. |
| 10 | ARM9 saved/system SP | `0x03003FC0`. |
| 11 | ARM7 current SP | `0x0380FD80`. |
| 12 | ARM7 IRQ SP | `0x0380FF80`. |
| 13 | ARM7 saved/system SP | `0x0380FFC0`. |
| 14 | Initial CPSR | `0x000000D3`. |
| 15 | Descriptor CRC-32 | CRC-32/ISO-HDLC over words 0 through 14. |

Version 3 replaced the former flags word with the ARM9 DTCM IRQ vector and the
former informational main-RAM CRC word with a runtime-configurable trace
trigger. HPS verifies the copied memory directly before publication, so the
descriptor no longer carries a main-RAM CRC.

The publisher first writes generation zero, writes every other descriptor
word, executes a full system barrier, and then publishes the real generation.
The FPGA reads all eight 64-bit beats, validates the fixed fields and CRC, and
re-reads the generation before accepting the descriptor. A torn publication
is rejected and retried.

## CPU state-load sequence

Both `gba_cpu` instances remain in reset while their `proc_bus_gb_type`
savestate ports are written. For each CPU:

1. Address 0 receives the entry address (fetch PC).
2. Addresses 1 through 12 receive zero (`r0-r11`).
3. Address 13 receives the entry address (`r12`).
4. Address 14 receives that CPU's current SP (`r13`).
5. Address 15 receives the entry address (`r14`).
6. Address 16 receives entry plus 8 (`r15`, ARM pipeline-visible PC).
7. Address 17 receives initial CPSR `0xD3`.
8. Address 24 receives the saved/system SP.
9. Address 34 receives the IRQ SP.
10. Address 46 receives mixed state `0x00000CC0`: ARM state, supervisor mode,
    IRQ and FIQ masked, flags clear, and not halted.

After the final write, reset remains asserted for one additional rising edge
so both CPU instances synchronously load the state. They are then released on
the same clock edge.

The reused CPU core does not expose ARM9 CP15 through the GBA savestate map.
The ARM9 reset path therefore initializes the implemented CP15 control register
to melonDS's `0x00052078` and derives high-vector selection from bit 13.

## Verification contract

- `src/replay/StandaloneBoot.h` is the software source of truth for addresses,
  descriptor version, layout, and defaults.
- `rtl/nds_boot_descriptor_reader.sv` is the FPGA source of truth for atomic
  acceptance and field validation.
- `rtl/tb_nds_boot_descriptor_reader.sv` checks descriptor CRC, decode,
  generation publication, and retry behavior.
- The standalone boot and CPU-DDR testbenches must prove that neither CPU
  issues a bus request before state initialization completes.
- Oracle hardware traces must begin at the real ARM9 and ARM7 entries and show
  forward progress from both CPUs.

Changes to either side of this development contract must update the matching
source, tests, and this document together. They do not change the public
core's FPGA-owned HLE boot path described in [`architecture.md`](architecture.md).
