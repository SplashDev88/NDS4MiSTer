# NAND cartridge saves

rc.10 retains the earlier NAND3 save implementation for the ARM-assisted
standalone product, with the bounded hardware coverage below. The separate
Band Brothers DX serial-flash experiment is paused and excluded from rc.10.
The private launcher references below identify historical tests. The NAND1 prototype completed WarioWare first-run setup,
played Mona microgames, saved the player profile and restored it after a full
core exit/relaunch. The corrected rc.9-settings NAND3 build also loads that
profile and displays its saved Mona high score of 4. A new score was then
committed on NAND3 and recovered after another full core exit/relaunch. Both
NAND capacities pass authored program/readback and clean-relaunch persistence
checks on NAND3.
The rc.9 baseline reached the WarioWare intro/title sequence on the RetroTINK
rig, with a 512-byte erased fallback sidecar; this is not a save-success result.

The private test uses **Scripts → NDS_NAND_Test** and a separate hidden support
folder. See [test instructions](release/NAND_PRIVATE_TEST.txt) and the
[validation record](release/NAND_VALIDATION.json). Keep the matched FPGA and
host together. Normal installation files and original saves were hash-checked
throughout the board tests; the test runs used separate save copies or new
diagnostic saves.

| Cartridge | Game codes | Save size | Status |
| --- | --- | --- | --- |
| WarioWare D.I.Y. / Made in Ore | UORE, UORP, UORJ | 16 MiB | UORE setup/gameplay/profile reload on prototype; new Mona score save/reload on NAND3; other regions untested |
| Jam with the Band | UXBP | 8 MiB | UXBP first-run setup, one-button demo and profile reload pass on NAND3; broader modes untested |
| Daigasso! Band Brothers DX | AXBJ | 8 MiB | Unsupported in rc.10: separate serial-flash protocol; experimental first hardware save fails |

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

NAND3 completes synthesis, fitting, assembly and standalone timing analysis.
It uses 34,512 ALMs, 41,230 registers, 536/553 RAM blocks, 4,130,644 block-memory
bits and 27 DSP blocks. Relative to the exact published rc.9 image, this adds
252 ALMs, 325 registers, two RAM blocks and 2 KiB logical RAM, with no extra
DSPs. All 851 renderer source inputs are unchanged from rc.9.

Timing requirements remain **unmet**, and the design is not fully constrained.
The slow 100 C model reports -15.254 ns worst setup slack, +0.248 ns hold slack
and -12.981 ns recovery slack. The frozen rc.9 build lacks standalone timing
analysis, so no numerical timing-regression comparison is claimed. Successful
tool completion and a working board do not establish timing closure.

On NAND3, the authored 8/16 MiB tests each program two 2 KiB pages, exit fully,
relaunch, and detect the persisted pages without writing again. Each first run
records eight sector writes; each second run records zero. Independent scans
of both entire files match the expected pages and erased remainder exactly.
These authored diagnostics do not establish full retail-game compatibility or
power-cut safety. A separate Jam with the Band retail check is recorded below.

NAND3 also loads the private WarioWare test profile from NAND1. Its Mona table
initially shows `4, 0, 0`. A second microgame run followed by the game's Quit
button changes that to `4, 4, 0`, with 48 sector writes. After a full core exit
and fresh launch, the table still shows `4, 4, 0`; this session writes zero
sectors and retains the same whole-file hash. Both direct framebuffer and
physical RetroTINK capture confirm the restored score. A 40-second gameplay
recording has audible captured audio and zero OBS render/encoding drops.
An earlier attempt exited before the normal Quit transition and did not commit
the new score; it is not counted as a successful save. Always use the game's
normal save process before exiting the core.

These are short Mona microgame checks, not coverage of every WarioWare mode,
other regions, long sessions, or power loss. Retail first-run setup was tested
on NAND1; NAND3 blank-file initialization is covered by the authored diagnostic
and actual-host tests.

## Jam with the Band retail check

On NAND3, the user-supplied European UXBP cartridge starts with a fresh 8 MiB
NAND file, completes member-card registration and plays the one-button
"Smoke on the Water" demo. The remaining tour is dismissed with End, then the
main menu is reached. Button and touch input work;
successful note hits were observed. Setup records 208 sector writes before a
clean core exit. A fresh core launch skips registration and displays the saved
`test` profile, verified in both the framebuffer and RetroTINK capture.

That second session shows the first-shop help and records eight further sector
writes, changing two 2 KiB pages. A third full core launch restores the profile
again with zero sector writes and an unchanged complete-file SHA-256. All three
exits are clean. Normal installation files, original saves and configuration
remain unchanged; the checks use a separate test save. The uploaded retail ROM
is available under `games/NDS` for a fresh user session.

The capture device was initially unplugged and was reconnected before two
40-second recordings. Both contain video and non-silent capture audio with zero
OBS render/encoding drops. Observed framebuffer transport-fault counters stay
zero. This does not qualify audio fidelity, rhythm-input latency or game FPS.
Normal-song score persistence, composition save/reload, singing/microphone,
wireless/download features, long sessions and power loss remain untested. See
the `retail_jam` entry in the validation record for counts and evidence hashes.

## Ordinary-game performance check

NSMB World 2-5 was checked at 1 GHz using the same private save copy, renderer,
new host and repeated-jump input sequence with either the released rc.9 FPGA
or NAND3. Each build has three recorded approximately 20-second active samples,
including a fresh-launch confirmation. At the preselected character-image
threshold of 20 with at least 12 changed pixels, the means are 55.46 visible
changes/second for rc.9 and 55.31 for NAND3. These are animation-dependent image
changes, not whole-game FPS. Saves retain their original hashes.

The strict primary capture-quality gate **did not pass**: one baseline video
has one OBS render drop, and two NAND3 videos each have one false detection in
their paused control window. The confirmation and all earlier results are
retained. Predeclared threshold-24/32 sensitivity checks have no paused false
detections and also show small differences (about -0.7%/-1.2% across all
samples); they are not substituted for the primary gate. No substantial
slowdown is indicated in this scene, but this remains capture-limited smoke
evidence, not performance qualification or a claim of statistical equivalence.
It does not qualify every ordinary game or resolve FPGA timing closure.

## References and provenance

The protocol and ID constants follow the GPL melonDS implementation already
vendored in `third_party/melonDS/src/NDSCart/CartRetailNAND.cpp`, with cartridge
profiles from its ROMList. See [upstream CartRetailNAND](https://github.com/melonDS-emu/melonDS/blob/master/src/NDSCart/CartRetailNAND.cpp)
and [GBATEK NAND documentation](https://problemkaputt.de/gbatek-ds-cartridge-nand.htm).
The new VHDL command implementation is a local adaptation of the vendored
Nitro card and loader files. ROM, firmware and user-save bytes are not included
in tests or source.
