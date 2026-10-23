# NSMB speed-hack audit — 23 October 2026

Status: investigation and default-off experiments. No public release qualification.
The source base is `4f69549424efdb57a21486f9bf3417db7c096f65`.

## Actual execution path

The current standalone bitstream executes both DS CPUs in the FPGA. The HPS
runs ordered graphics replay, BOTH 2D engines, geometry, rasterization, and the
frontend. The old FPGA-2D description does not describe this package.

The retained production fit uses 34,475/41,910 ALMs (82%) and 536/553 RAM
blocks (97%). The quoted 97% is RAM-block occupancy, not total logic use.
This distinction matters when considering a register-only observation path.

The active ARM9 is `third_party/Nitro_DarkSide/d2dabe/rtl/nds_cpu9.vhd`, selected
by `fpga/mister_nitro_console_island/NDS4MiSTer.qsf`. Other similarly named
legacy CPU/router modules are not evidence for this runtime.

* **HALT/IntrWait:** FreeBIOS and the guest SDK reach CP15 wait-for-interrupt.
  `execute_wfi` sets `decode_halt`; fetch/execute stop until the interrupt
  controller asserts `cpu9_unhalt`. Timers, ARM7, sound, LCD and DMA continue
  independently. There is no HPS interpreter burning time in a cycle loop.
  Jumping the whole console to the next ARM9 IRQ would skip other owners' work.
* **GX/DMA:** `nds_dma9.vhd`, `nds_nitro_console_top.vhd`, the event gate,
  `nds_h3d_frame_record_cdc.sv` and packet writer implement accepted, ordered
  writes, packet credit, completion and query fences. A dedicated main-RAM
  read/held-GX-write path already exists. Transport acknowledgement is not
  geometry completion. The prior NSMB HBlank overlap fix preserves a pending
  matrix reply while eligible background DMA borrows its independent lane.
* **Divider/sqrt:** `nds_nitro_arm9_math_unit.sv` is a serial, area-saving
  arithmetic engine. Division takes 32/64 physical iterations, sqrt 16/32,
  with architectural minimum delays as well. Results remain OLD while busy.
  Clearing the busy bit alone is a correctness bug, not instant division.
  HPS offload adds a crossing and operand/result transfer to very short work.
* **D-cache:** `nds_cache9.vhd` implements an 8 KiB I-cache and 4 KiB write-back
  D-cache. Dirty data must reach main RAM before non-coherent DMA consumes it.
  `DC_StoreAll`/`DC_FlushAll` cannot safely become unconditional return stubs.
* **Memory visibility:** a guest main-RAM pointer names FPGA-attached SDRAM,
  not a directly dereferenceable HPS virtual/physical address. A display-list
  pointer plus length is insufficient for HPS bulk execution. Snapshotting
  requires a coherent FPGA read path, ordering and ownership of those bytes.

## Minimal-cost hook options

The existing CPU debug seam exports architectural R15, CPSR and control state,
but the production island disconnects it and disables the full debugger.
A passive sampler can reconnect observations only, reuse the existing 64-bit
heartbeat publication, and compile out completely without `NDS_ARM9_PC_PROFILE`.
It adds no CPU hold, IRQ, DMA or memory-write path. Fit/resource cost and native
sampling overhead must be measured; no timing-closure claim follows from RTL tests.

An HPS PC-match hook is not just a symbol table: ARM9 runs in the FPGA, and
arbitrary registers/dirty memory are not HPS-owned. A trap implementation needs
a precise instruction boundary, register transfer, cache visibility, IRQ policy,
result writeback and resume semantics. Restoring the historical full debugger
alone is not that implementation. Volatile guest shims can use an existing
ordered transport without a PC comparator, if such shims are within scope.
They still need revision guards and complete guest-visible side effects.

ITCM addresses are autoload destinations, not initial main-RAM code addresses.
An ITCM hook must remain unarmed until the relevant bytes exist in live ITCM
and match its guard. Verifying the cartridge's autoload payload is NOT proof
that autoload has completed or that those live bytes have not been replaced.

## Identity and scope

The available US cartridge has game code **A2DE**, revision 0. Its on-cartridge
ARM9 bytes (header offset/length, before decompression) have CRC32 **d68a9af0**.
CRC32 is a dispatch key, not an adequate integrity guarantee by itself. Keep
full-cartridge/ARM9 hashes and 16-byte target-prefix guards as additional checks.
Unknown region, revision, checksum, code, or phase must leave the original path.
Reset, another game, and failed installation must clear every armed hook.

Every accepted hack needs an independent OSD flag. Changes which replace code
or initialize state must apply on a fresh ROM load, with the menu clearly
showing that requirement. A flag must not advertise an unimplemented fast path.

## Priority decisions before optimizing

1. **Profile native waits.** Reference instruction counts are useful for
   identifying code, but omit FPGA memory latency, renderer stalls and halted
   time. The debug sampler records per-guest-frame histograms with loss counts.
2. **Study display-list/query stalls.** `NNS_G3dGeWaitSendDL` is prominent in the
   reference trace. Preserve DMA flags/IRQs, FIFO callbacks, partial lists,
   cache cleaning, original command order and readback/swap fences. A later
   compression layer belongs behind a versioned descriptor with byte length,
   codec, session and completion token; it must not redefine completion.
3. **Math HLE only if measured worthwhile.** Preserve fixed-point width,
   signed shifts, rounding, overflow, divide-by-zero and output aliasing.
   Compare original interpreted routines on randomized and boundary inputs,
   including overlapping matrices, before native deployment or default enable.
4. **Do not stub real cache maintenance or fake idle/busy state.** Optimize the
   actual mechanism only after finding a redundant operation and proving that
   memory/IRQ/DMA side effects remain equivalent.

## Separate single-player bookkeeping experiment

The initial unused-function audit found no wireless-manager instructions in
sampled single-player gameplay. Network-named local packet routines DO run and
carry inputs, so deleting all Wi-Fi-labelled code is unsafe. Two temporary
main-RAM fast paths preserve local packets and active-connection behavior:
local packet lookup and skipping inactive, zero-state remote clients.

500 randomized function-state comparisons passed, preserving return values,
callee-saved registers, stack pointer and tested memory effects. Interrupt
interleavings and nonempty callback registrations are not exhaustively covered.
A reference emulator showed identical paired images for 1,500 sampled gameplay
frames and 3.6–3.9% fewer ARM9 instructions. Boot/loading image timing differed
on 20 of 3,300 total frames. This is not a native FPS result.
Interleaved native controls and scrolling tests did not establish a throughput
gain (details below). Both options stay Off by default.

## Symbol sources

* [MammaMiaTeam NSMB code reference](https://github.com/MammaMiaTeam/NSMB-Code-Reference)
* [NSMB matching decompilation](https://github.com/NSMB-Decomp/nsmb)

A nearest symbol is only a label, not proof of function membership. Use explicit
function sizes where available, identify missing/ambiguous overlay ranges,
and preserve raw PCs in every report. Thumb entry tags are metadata; bit zero
must be removed before matching a code address.

## Reference priorities (not native timings)

A debug interpreter sampled one PC per 256 executed ARM9 instructions over
900 moving/jumping W2-5 frames. Using explicit decompilation function extents:

| Target | Share of instruction samples |
| --- | ---: |
| NNS_G3dGeWaitSendDL | 3.98% |
| MTX_Concat43 | 1.76% |
| VEC_Normalize | 1.52% |
| NNS_G3dGeBufferOP_N | 1.00% |
| NNSi_G3dAnmBlendJnt | 0.89% |
| FX_GetDivResult | 0.36% |
| MTX_Inverse43 | 0.33% |
| NNSi_G3dAnmCalcNsBca entry function | 0.28% |
| MI_SendGXCommandAsync | 0.22% |
| MI_WaitDma | 0.07% |
| DC_FlushAll / DC_StoreAll | no samples |
| Requested sqrt wrappers, MTX_Concat33/44, fast GX DMA wrapper | no samples |

These figures exclude time in called functions unless those functions appear
separately. No samples does not establish that a function is unused in the
whole game. The animation entry delegates most work to other routines.
Several of the hottest raw PCs lack adequate names in the supplied symbol
list: nearest-label attribution initially misidentified a sound routine and
overlay code. The report must keep those uncertainties explicit.

The two main-RAM bookkeeping flags are exposed only when the paired private
kit supplies its hook registry. Both default to Off. They apply on ROM load,
can be saved through System → Save settings, and do not alter FMV selection.
There are no implemented ITCM, cache-flush, instant-math or bulk-DMA hooks yet.
The ITCM guard API can refuse early installation; a live autoload-completion
observer and an actual trap/return transport still need implementation.

## Native bookkeeping A/B result

Same experimental host, same RBF/helper, 1 GHz, isolated copy of the same save,
W2-5, RetroTINK-4K capture. Three option-off jump trials and two option-on
trials were interleaved; two scrolling trials of each variant followed the
same jump sequence. Original saves/ROMs/settings were checked on clean exits.

| Scene / setting | Completed paired updates/s | Visible changes/s in selected crop |
| --- | ---: | ---: |
| Repeated jumping, Off | 59.49–59.56 | 56.77–57.94 |
| Repeated jumping, Both | 59.46–59.47 | 56.12–57.75 |
| Scrolling/jumping, Off | 59.25–59.28 | 57.33–58.34 |
| Scrolling/jumping, Both | 59.37–59.59 | 56.58–56.99 |

**Decision: no demonstrated speed/smoothness benefit. Keep Off by default.**
The small source-update rise in scrolling did not improve visible changes.
Most trials still included a 50 ms maximum detected-change gap. No transport
faults or OBS render/encode drops were reported. Save hashes stayed unchanged.
The source update counter can include repeated pictures; the visible detector
is animation/crop/threshold dependent. Neither column is whole-game FPS.
The scrolling endpoint showed the same timer and course progress, with small
movement/enemy-phase differences; it is not a pixel-identical replay benchmark.
These results do not establish full-game compatibility or resolve every busy scene.

A private A/B build can expose the two flags for further investigation; it
must not be advertised as a faster NSMB release on the strength of these tests.

The menu build was also checked on the MiSTer: initially Off/Off, independently
switchable, saved through System, and restored after a clean restart. The
loader reported that both guarded paths were applied. A short W2-5 jump check
then measured 59.46 paired updates/s and 57.64 detected changes/s, within the
earlier trial spread, with no transport faults or capture drops. Settings were
returned to Off/Off and saved. The isolated save hash was unchanged on exit.

## Diagnostic FPGA build

The passive sampler fit and routed with 34,694 ALMs and 41,355 registers:
219 additional ALMs and 132 registers relative to the retained production fit.
RAM blocks remain 536 and DSP blocks remain 27. These are whole-fit deltas,
including placement/optimization changes, not an isolated module cost estimate.
The production configuration does not define `NDS_ARM9_PC_PROFILE`.

Static timing is NOT closed: the reported worst setup slack changed from
-15.898 ns to -17.291 ns. A successful fit does not qualify a release bitstream.
The sampler is for bounded diagnostic sessions only; the normal A/B host uses
the retained production RBF. Native samples must preserve this limitation.

Reference source revisions used for symbol lookup and explicit function sizes:
`MammaMiaTeam/NSMB-Code-Reference` at
`f0d558928cc0ba879c0f7f822251788773e89254`, and `NSMB-Decomp/nsmb` at
`363b5cb02496b754aaab1b922a558b5ddf934251`, `config/A2DE/arm9`.

## Reproducing the diagnostic

Run `bash tools/test_arm9_pc_sampler.sh` and
`bash tools/test_nsmb_speed_hacks.sh` for the observer, symbol mapping,
identity/autoload guards, menu, settings and reader tests. These tests use
synthetic fixtures and require no game image. The separate private differential
oracle requires the operator's own cartridge; it is not included in a release.

Build the normal selected runtime configuration with the additional Verilog
macro `NDS_ARM9_PC_PROFILE=1`. Keep its RBF and matching supervisor pin in a
separate diagnostic kit. After verifying the ROM identity, entering gameplay
and recording the session identity, collect on MiSTer with:

```sh
python3 arm9_pc_profile.py --native ./arm9_pc_sample --seconds 20 --output nsmb-pcs.json
```

The collector opens the control page read-only and refuses a faulted session,
session change or missing diagnostic tag. The result includes raw architectural
R15, mode/HALT/DMA flags, per-frame histograms, observed and missed-sequence
counts, and the collector's process CPU time. It never halts the guest.
The sampler nominally observes approximately every millisecond with jitter;
the collector can miss samples and reports a modulo-256 lower bound on loss.

On the development machine:

```sh
python3 tools/symbolize_arm9_profile.py nsmb-pcs.json \
  --symbols NSMB-Code-Reference/symbols9.x \
  --bounds nsmb/config/A2DE/arm9 --output nsmb-top30.json
```

Each top-30 row aggregates one decoded PC across its observed states and also
preserves its raw R15 values. ARM R15 minus 8 was calibrated against the active
CPU's WFI implementation; Thumb uses minus 4. Boundary samples are not precise
retirement records. Frame IDs are 16-bit and reset with the guest. Residence at
a PC includes memory/transport stalls; a HALT or DMA-held PC is not evidence
that those instructions are consuming execution throughput. Missing samples,
unmapped functions and ambiguous overlays must not be silently reassigned.

## Requested hook implementation status

| Request | Current result |
| --- | --- |
| Generic HALT fast-forward | Existing CPU already stops instruction execution. No event-driven host CPU loop exists to skip. No new hack installed. |
| Instant divider/sqrt; DMA/GX polling skip | Not installed. Correct results still require the hardware arithmetic iterations; DMA/GX waits can represent real pending work. |
| Bulk display-list HPS handoff | Not installed. Needs a coherent guest-memory snapshot path, completion/IRQ/callback handling, and a precise trap ABI. Existing DMA and packet batching remain. |
| Native ITCM math/animation HLE | Not installed or enabled. No trap/register/return path or bit-exact HLE implementation exists yet; randomized original-vs-HLE tests remain required. |
| Cache maintenance stubs | Rejected as unconditional stubs because the actual D-cache is write-back and DMA is not coherent. |
| Guarded per-game dispatch and controls | Implemented for the two separate main-RAM bookkeeping experiments, both Off by default. ITCM guard API refuses pre-autoload use, but does not itself detect live autoload completion. |

The bookkeeping experiment never writes the stored cartridge; it does alter
a virtual load image and must not be described as interception-only HLE.

Native capture results, all 30 leading PCs and the requested target-by-target
sample counts are in [the native profile report](NSMB_NATIVE_PC_PROFILE_20261023.md).
The primary captures use the native C sampler: the earlier Python loop used
too much CPU. Compile `tools/arm9_pc_sample.c` with the normal ARM hard-float
Cortex-A9 toolchain (`-O2 -static -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard`).
Its output formatting and Python histogram construction happen after sampling.
