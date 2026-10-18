# Experimental NAND cartridge saves

This branch adds NAND saves to the ARM-assisted standalone product. It is not
release-qualified. No gameplay save/reload result is available yet.

| Cartridge | Game codes | Save size | Status |
| --- | --- | --- | --- |
| WarioWare D.I.Y. / Made in Ore | UORE, UORP, UORJ | 16 MiB | Protocol tests; UORE available for board testing |
| Jam with the Band | UXBP | 8 MiB | Protocol tests; game not available on test rig |
| Daigasso! Band Brothers DX | AXBJ | 8 MiB | Recognized, but a missing save-region header is rejected; layout requires separate verification |

Face Training uses a DSi-specific variant and is outside this prototype.
Ni no Kuni uses ordinary EEPROM, so NAND support does not address that report.

## Storage and protocol

NAND saves use the cartridge command bus, rather than AUXSPI. The card model
implements window selection (B2), write enable (85), staging writes (81), page
commit (82), discard (84), ROM mode (8B), identity (94), status (D6), and NAND
reads (B7). A 2 KiB staging buffer is inferred as block RAM. The existing 512-byte
save cache transports committed data to the ARM host. It gains four address
bits; the full 8/16 MiB save remains on disk. Commands use the existing card
transfer pacing, DMA-ready and completion interrupt interface.

Reads wrap within 4 KiB. The final 128 KiB is read-only, with synthesized ID
metadata matching the reference implementation. Short writes retain the rest
of the staging buffer. Reset/discard do not commit staged bytes. Programming a
page is not an atomic filesystem transaction: interruption during programming
can leave a partially written page. Clean exit is required.

The loader reads the save-region header at 0x96 only for the explicit NAND
codes. It supplies a consistent NAND chip ID to boot metadata and B8. There is
no extra header read for ordinary cartridges. A zero or out-of-range NAND base
is rejected by the host before mounting its save; no address is guessed.

The firmware-control capability bit 12 prevents a new host from attempting
NAND saves with an older FPGA. Save profiles 8/9 are enabled only for the five
explicit game codes, not every database entry with those numeric save types.
The legacy FPGA profile ROM remains unchanged; this prototype requires the
ARM-assisted product and matching host.

## File handling

Saves retain the usual `saves/NDS/<ROM name>.sav` location. New NAND files are
filled with FF in a temporary file, synced and renamed into place. Existing
nonempty saves must be the exact expected size. Incorrect sizes and unsupported
file types are rejected without rewriting the existing file. Interrupted
initialization leaves the previous destination intact. No imported save is
silently resized. The prior save descriptor is retained if mounting fails.

Ordinary saves retain their existing 1 MiB host bound. NAND saves allow only
their own sector count, and the firmware save slot retains its independent
bound. Renderer code and CPU clocks are unchanged.

## Repeatable checks

- `tools/test_nand_card.sh`: actual card registers, both capacities, CPU CE
  periods 1/5, high-bank page writes, streamed reads, cache stalls, short writes,
  protected ID region, write enable, discard/reset, both CPU owners.
- `tools/test_nand_cache.sh`: actual save cache, final-sector persistence,
  non-aliasing, read-only and invalid-size protection, plus ordinary save cases.
- `tools/test_nand_host.sh`: actual Host load/mount/sector paths, matching-core
  and header gates, atomic blank-file creation, cancellation, preservation of
  existing data, highest-sector I/O and file reopen.
- Existing host-profile, EEPROM/flash/IR, long transaction, large-ROM and
  complete-console VHDL checks remain required.

Still required: Quartus resource/routing/timing review; WarioWare first-run
format, gameplay and meaningful save/reload through the RetroTINK rig; ordinary
gameplay/performance comparisons. Simulation is not game compatibility proof.

## References and provenance

The protocol and ID constants follow the GPL melonDS implementation already
vendored in `third_party/melonDS/src/NDSCart/CartRetailNAND.cpp`, with cartridge
profiles from its ROMList. See [upstream CartRetailNAND](https://github.com/melonDS-emu/melonDS/blob/master/src/NDSCart/CartRetailNAND.cpp)
and [GBATEK NAND documentation](https://problemkaputt.de/gbatek-ds-cartridge-nand.htm).
The new VHDL command implementation is a local adaptation of the vendored
Nitro card and loader files. ROM, firmware and user-save bytes are not included
in tests or source.
