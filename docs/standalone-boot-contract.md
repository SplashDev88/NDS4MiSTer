# Standalone DS boot contract

This contract replaces the accidental zero-PC hardware start with the same
direct-boot state used by the melonDS reference. It is a bring-up seam between
MiSTer's HPS loader and FPGA logic; it must not become a Mac dependency.

## DDR layout

| Physical address | FPGA 64-bit word address | Purpose |
|---|---:|---|
| `0x2c000000` | `0x05800000` | Existing 32-byte oracle mailbox |
| `0x2c001000` | `0x05800200` | Read-only boot descriptor |
| `0x2c100000` | `0x05820000` | 4 MiB mirrored DS main RAM |
| `0x30000000` | `0x06000000` | Existing compact video publication |

The loader creates the reference with `NDS::Reset()` followed by
`NDS::SetupDirectBoot(romname)`, copies exactly `0x400000` bytes of
`NDS::MainRAM` to `0x2c100000`, writes the descriptor payload, executes a full
memory barrier, and publishes `generation` last. The FPGA accepts only a
supported version with matching size and checksum, latches the descriptor, and
does not release either CPU until all savestate writes have completed.

The compact input publication keeps controller buttons in bits 0-11 and uses
otherwise ignored high bits for remote bring-up telemetry: bit 31 standalone
enable, bit 30 descriptor valid, bit 29 CPU boot-ready, bit 28 descriptor
error, and bits 27-20 an eight-bit local CPU DDR command counter. This does not
change the DS key conversion and avoids adding another DDR arbitration client.

## Descriptor version 1

All fields are little-endian 32-bit words.

| Word | Field | Value |
|---:|---|---|
| 0 | magic | `0x4253444e` (`NDSB`) |
| 1 | version | `1` |
| 2 | generation | Nonzero; published last |
| 3 | flags | Bit 0: direct boot; all other bits zero |
| 4 | main RAM bytes | `0x00400000` |
| 5 | main RAM CRC-32 | CRC-32/ISO-HDLC over the copied bytes |
| 6 | ARM9 entry | ROM header `ARM9EntryAddress` |
| 7 | ARM7 entry | ROM header `ARM7EntryAddress` |
| 8 | ARM9 current SP | `0x03002f7c` |
| 9 | ARM9 IRQ SP | `0x03003f80` |
| 10 | ARM9 saved/system SP | `0x03003fc0` |
| 11 | ARM7 current SP | `0x0380fd80` |
| 12 | ARM7 IRQ SP | `0x0380ff80` |
| 13 | ARM7 saved/system SP | `0x0380ffc0` |
| 14 | initial CPSR | `0x000000d3` |
| 15 | descriptor CRC-32 | CRC over words 0-14 |

## CPU savestate sequence

Both `gba_cpu` instances remain in reset while their `proc_bus_gb_type`
savestate ports are written. For each CPU:

1. Address 0 receives the entry address (fetch PC).
2. Addresses 1-12 receive zero (`r0-r11`).
3. Address 13 receives the entry address (`r12`).
4. Address 14 receives that CPU's current SP (`r13`).
5. Address 15 receives the entry address (`r14`).
6. Address 16 receives entry + 8 (`r15`, ARM pipeline-visible PC).
7. Address 17 receives initial CPSR `0xd3`.
8. Address 24 receives the saved/system SP used by the proven ARM9 oracle
   fixture.
9. Address 34 receives the IRQ SP.
10. Address 46 receives mixed state `0x00000cc0`: ARM state, supervisor mode,
    IRQ and FIQ masked, flags clear, not halted.

After the final write, reset remains asserted for one additional rising edge
so both CPU instances synchronously load the saved registers. They are then
released on the same clock edge.

The reused core's ARM9 CP15 state is not part of its GBA savestate register
map. Direct boot therefore also requires the ARM9 reset path to initialize its
implemented CP15 control register to melonDS's `0x00052078` and derive the
high-vector flag from bit 13. Leaving the current RTL reset value at zero would
make an early MRC return a value different from the software reference even
with correct general registers. TCM contents/routing remain oracle-backed for
the first bring-up; local ITCM/DTCM replacement happens only after the seeded
boot trace proves correct.

## Acceptance gates

1. A descriptor encoder test checks all field offsets, both CRCs, publication
   ordering, and the values extracted from at least one retail and one
   homebrew ROM.
2. A VHDL test checks every savestate address/value for ARM9 and ARM7 and proves
   neither CPU issues a bus request before initialization completes.
3. An ARM9 CP15 read immediately after release returns `0x00052078`, with high
   exception vectors enabled; ARM7 retains its existing behavior.
4. The existing 129-state ARM9 lockstep is rerun from the descriptor-derived
   state rather than a duplicated testbench constant list.
5. Hardware mailbox profiling after release must begin in `0x02xxxxxx` at the
   actual ARM9/ARM7 ROM entries, show traffic from both CPUs, and must not
   devolve into sequential reads across zero-filled `0x01xxxxxx`.
6. Only after this gate passes should ITCM/DTCM, peripherals, GPU, and sound be
   moved from the HPS oracle into FPGA logic.
