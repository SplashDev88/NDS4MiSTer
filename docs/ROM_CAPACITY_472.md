# Larger cartridge storage: Ni no Kuni experiment

This experimental branch extends backed cartridge storage from 316 MiB to
472 MiB. It is based on the NAND3 private runtime and retains its renderer,
clock behavior and NAND save support. Public rc.9 is unchanged.

## Reproduced failure

The supplied Japanese Ni no Kuni cartridge (`B2KJ`, DS mode, 512 MiB file)
contains real data above 316 MiB. The existing host exits before direct boot:

```
ROM data above 316 MiB must be FF padding (cartridge storage is reserved)
```

Its header declares 481,717,820 used bytes (about 459.4 MiB). The diagnosis does
not rely on that declaration: the original failure and the new padding checks
read actual file contents. Ni no Kuni uses EEPROM; the previous NAND work does
not fix this loader limit.

## DDR ownership

Addresses below are byte addresses, with the upper endpoint excluded.
The existing 252 MiB cartridge region stays in place. Two additional windows
provide 220 MiB without reducing Linux RAM or moving the video buffers.

| Physical DDR range | Owner | Logical ROM range |
| --- | --- | --- |
| `0x00000000..0x1ff00000` on tested board | Linux System RAM | None |
| `0x20000000..0x21800000` | Scaler: three 8 MiB buffers | None |
| `0x21800000..0x22000000` | Reserved guard | None |
| `0x22000000..0x24000000` | Cartridge, 32 MiB | 252..284 MiB |
| `0x24000000..0x24300000` | TATE: three 1 MiB buffers | None |
| `0x24300000..0x24400000` | Reserved guard | None |
| `0x24400000..0x30000000` | Cartridge, 188 MiB | 284..472 MiB |
| `0x30000000..0x3fc00000` | Cartridge, 252 MiB | 0..252 MiB |
| `0x3fc00000..0x40000000` | Graphics/control, audio and display publication | None |

The scaler allocation is defined by `sys_top.v`'s RAMBASE/RAMSIZE and
`ascal.vhd`'s three buffer indices. `nds_tate_video.sv` defines the rotation
allocation. This layout must be re-audited if those framework allocations
change. It is not a general claim that every byte above Linux RAM is free.

The host validates `/proc/iomem` before mapping the expanded bank and rejects
missing, redacted or overlapping System RAM descriptions. All destination
mappings must succeed before cartridge download starts. Every omitted byte
above 472 MiB must be `FF`; the FPGA synthesizes those reads. A trimmed large
file fills every backed byte after EOF with `FF`, preventing stale data from a
previous game from becoming visible.

## Protocol and compatibility

- FS3 index `0x0003`: existing 128 MiB address behavior.
- FS3 index `0x0103`: existing 256 MiB capacity / 252 MiB backed layout.
- FS3 index `0x0303`: old 512 MiB capacity / 316 MiB backed layout; still accepted
  by the new FPGA for older hosts.
- FS3 index `0x0703`: new 512 MiB capacity / 472 MiB backed layout.
- Firmware status bit 13 (`0x2000`) advertises the new layout. The new host
  requires it for files larger than 256 MiB, before ROM memory writes or save
  mounting. Keep the host and FPGA from this beta together.

The DDR cartridge cache retains its four-beat read-ahead and bank/address tag.
The expanded alternate aperture uses every offset bit; its bank remains owned
by the accepted command through stalls and refill. Other DDR clients keep their
original bank. Replacement flushes the old cache before direct boot. Guest
reset preserves the selected cartridge mode while discarding stale replies.

Files of 256 MiB or less retain their previous loading path and padding rule.
Larger files now stage up to 472 MiB, so loading may take longer than the old
316 MiB layout. The change does not alter gameplay clocks, frame skipping or
renderer settings. File capacity is still not a whole-game compatibility claim;
images with meaningful data above 472 MiB remain unsupported.

## Validation

Automated checks exercise actual cartridge bridge/cache RTL, both physical
bank modes, all five other DDR clients, boundary refills, cache-tag separation,
reset and replacement. Host checks reconstruct every backed byte, protect the
entire scaler/TATE/graphics regions, verify trimmed-file clearing, capability
rejection, failed mapping, read cancellation and outgoing-save preservation.
The supplied Ni no Kuni image passed full host reconstruction.

The low-ROM bridge benchmark remains 64 words / 8 DDR commands / 32 beats /
916 cycles, matching the retained baseline. This is a bus-level regression
check, not a whole-game FPS result.

Hardware baseline rejection and old-core/new-host rejection are reproduced.
Candidate FPGA fitting and game qualification are still in progress; no
successful Ni no Kuni gameplay or save/reload result is claimed here yet.
