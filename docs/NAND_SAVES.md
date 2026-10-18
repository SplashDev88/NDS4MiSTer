# Experimental NAND cartridge saves

This branch adds NAND saves to the ARM-assisted standalone product. It is not
release-qualified. The NAND1 prototype completed WarioWare first-run setup,
played Mona microgames, saved the player profile and restored it after a full
core exit/relaunch. The corrected rc.9-settings NAND3 build still needs final
hardware qualification.
The rc.9 baseline reached the WarioWare intro/title sequence on the RetroTINK
rig, with a 512-byte erased fallback sidecar; this is not a save-success result.

| Cartridge | Game codes | Save size | Status |
| --- | --- | --- | --- |
| WarioWare D.I.Y. / Made in Ore | UORE, UORP, UORJ | 16 MiB | UORE prototype setup/gameplay/profile reload passed; final build qualification pending |
| Jam with the Band | UXBP | 8 MiB | 8 MiB authored hardware persistence test passes; retail game unavailable |
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
Known NAND cartridges also reject ordinary backup types, so an older host
cannot release them using its 512-byte fallback.
The legacy FPGA profile ROM remains unchanged; this prototype requires the
ARM-assisted product and matching host.

## File handling

Saves retain the usual `saves/NDS/<ROM name>.sav` location. New NAND files are
filled with FF in a temporary file, synced and renamed into place. Existing
nonempty saves must be the exact expected size. Incorrect sizes and unsupported
file types are rejected without rewriting the existing file. Interrupted
initialization leaves the previous destination intact. Unique temporary names
allow a later retry after a power loss leaves an unfinished temporary file. No imported save is
silently resized. The prior save descriptor is retained if mounting fails.

If an earlier unsupported core left a small fallback sidecar, keep a backup and
move that file aside before starting a fresh NAND save. Do not truncate, pad or
overwrite a save containing progress. Imported saves must be raw files of the
exact capacity; conversion of other emulator container formats is not provided.

Ordinary saves retain their existing 1 MiB host bound. NAND saves allow only
their own sector count, and the firmware save slot retains its independent
bound. Renderer code and CPU clocks are unchanged.

## Repeatable checks

- [`tools/nand_diagnostic/build.sh`](../tools/nand_diagnostic/README.md): build
  the authored 8/16 MiB cartridge diagnostics used on the board. Both rebuilt
  ROMs exactly reproduce the tested bytes. Use unique basenames/test saves.
- `tools/test_nand_card.sh`: actual card registers, both capacities, CPU CE
  periods 1/5, high-bank page writes, streamed reads, cache stalls, short writes,
  protected ID region, write enable, discard/reset, both CPU owners.
- `tools/test_nand_cache.sh`: actual save cache, final-sector persistence,
  non-aliasing, read-only and invalid-size protection, plus ordinary save cases.
- `tools/test_nand_host.sh`: actual Host load/mount/sector paths, matching-core
  and header gates, atomic blank-file creation, cancellation, preservation of
  existing data, highest-sector I/O and file reopen.
- Existing host-profile, EEPROM/flash/IR, long transaction, large-ROM and
  complete-console VHDL checks pass. All 42 ordinary cartridge/loader cases
  match the rc.9 baseline pass results and elapsed simulation times; this is
  not a gameplay FPS comparison.
- `tools/test_nand_faults.py --output <directory>` detects intentional high-bank,
  cache-wait, discard, read-wrap and protected-region faults.

Initial Quartus synthesis passes and infers the staging buffer as M10K RAM.
The build reports 38,884 registers, 4,121,684 block-memory bits and 27 DSP blocks.
The RTC synchronization-register synthesis check also passes. These counts are
from the first candidate, before the stricter old-host/NAND-profile guard.

Board checks completed before the NAND bitstream was available:

- New host with rc.9 FPGA: UORE is rejected before save creation, then MENU is
  restored. Protected installation/configuration/save hashes remain unchanged.
- New host with rc.9 FPGA: NSMB loads a private copy of the existing World 2
  save, enters World 2-5, responds to movement/jumping, and exits cleanly. The
  test copy and original save retain their hashes. This checks the host change;
  it does not qualify the new FPGA or establish a frame-rate comparison.
- The current NAND file-initialization code runs directly on the MiSTer SD
  filesystem. 8/16 MiB all-FF initialization/full readback, durable rename,
  existing-file preservation, wrong-size rejection, cancellation and retry with
  a leftover temporary file pass. No SPI or live game state is involved.

The initial NAND1 bitstream also passes an authored cartridge diagnostic on
physical MiSTer for both capacities. It programs two complete 2 KiB pages (one
above 1 MiB and one at the writable region's end), reads them back, then finds
them intact after clean exit and a fresh core launch. The second launch performs
no programming. An independent scan of each entire save file matches the two
expected pages, with every other byte still FF. The RetroTINK capture confirms
the diagnostic's pass screen. The same diagnostic fails the initial NAND status
check on rc.9, as expected. This is cartridge-bus/storage validation, not a
retail-game save qualification or a power-cut test.

NAND1 uses 34,399 ALMs, 534/553 RAM blocks and 27 DSP blocks after fitting.
Fitting, assembly and timing analysis completed. Timing requirements are **not**
met: the slow 100 C report has -14.274 ns worst setup slack, +0.256 ns hold slack
and -14.137 ns recovery slack. These values describe NAND1 only.

NAND1 and NAND2 were built with source defaults, which omit the three graphics
options enabled in the published rc.9 FPGA. They are diagnostic builds, not
performance-qualified successors to rc.9. NAND2 was intentionally cancelled
while routing after this mismatch was identified. The corrected NAND3 build
applies the exact `fpga_qsf_override.appended_text` from
[the rc.9 provenance record](release/BETA12_BUILD_PROVENANCE.json):
`NDS_GX_SWAP_RETIREMENT_EXPERIMENT`, `NDS_HBLANK_RUN_QUEUE_EXPERIMENT` and
`NDS_GX_BUSY_STATUS_EXPERIMENT`, all set to 1. Its final QSF hash must match that
record's `build_sha256`; seed 7 and one fitter worker are retained. This is a
build override, leaving the repository's documented source defaults intact.
NAND1 also predates the stricter known-NAND/profile guard; NAND3 includes it.

Still required: completed NAND3 routing/timing review and hardware checks;
WarioWare first-run format, gameplay and meaningful save/reload through the
RetroTINK rig; ordinary gameplay/performance comparisons. Simulation and the
authored diagnostic do not establish retail-game compatibility.

## References and provenance

The protocol and ID constants follow the GPL melonDS implementation already
vendored in `third_party/melonDS/src/NDSCart/CartRetailNAND.cpp`, with cartridge
profiles from its ROMList. See [upstream CartRetailNAND](https://github.com/melonDS-emu/melonDS/blob/master/src/NDSCart/CartRetailNAND.cpp)
and [GBATEK NAND documentation](https://problemkaputt.de/gbatek-ds-cartridge-nand.htm).
The new VHDL command implementation is a local adaptation of the vendored
Nitro card and loader files. ROM, firmware and user-save bytes are not included
in tests or source.
