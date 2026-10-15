# rc.8 bug-fix experiment

This branch starts from rc.8 plus its README formatting correction. The approved
backlog excludes issue #42 (SS1 launcher detection). Save integrity comes first,
followed by progression, graphics correctness, frame measurement and performance.
Reported game failures must be reproduced and checked individually before closure.

## Save transaction boundaries

Two failures are reproducible through the actual cartridge register interface:

- Flash program (`02h`) and page write (`0Ah`) crossed a 256-byte page boundary
  into the next page. They now wrap within the selected page, matching the
  vendored software reference. EEPROM writes and all reads remain linear.
- The 16-bit SPI byte position wrapped during reads larger than 64 KiB and
  interpreted a data byte as a new command. Only prefix positions are meaningful;
  the position now saturates after the command/address/dummy/IR prefix. A new
  transaction still starts at zero.

`bash tools/test_save_transactions.sh` covers both failures, all flash profiles,
regular EEPROM writes, long tiny/regular/flash reads, fast-read dummy bytes,
IR passthrough and a new command after a long transfer. Each case fails against
the rc.8 card implementation and passes with the correction. The existing save
cache, EEPROM/flash, IR and loader suites also pass.

These changes affect cartridge backup SPI. Renderer settings, CPU/cartridge-ROM
timing and clock rates are unchanged. Game-specific hardware findings and the
limited speed comparison are recorded below; this does not establish resolution of any particular game's save issue.

The old combined Jackass/King Kong/NFS bundle remains excluded. Any reused change needs
its own regression evidence, including the recorded geometry timing counterexample
and matched NSMB/Castlevania gameplay checks.

## Geometry commands behind an ordinary FIFO tail

An external replay burst can arrive while the ordinary FIFO still contains work.
That bypasses the existing growable contiguous bank and fills the 16K stall
queue. The previous code then overwrote commands. A 30K-command test reproduces
the loss: command 16644 is replaced by command 30000.

The isolated overflow correction preserves those commands in a bounded deque,
strictly behind the stall queue. The contiguous fast bank remains the usual
external path. Reset clears both queued commands and the diagnostic peak. This
ports InsaneFriend (saneFriend)'s original fix `4c48874`, previously adapted in
`fd437999531df3a909264c240a1cd41ba286d9d8`. It does not include the Jackass geometry
debt/timing changes or the King Kong RTL change from that earlier bundle.

The GX ordering test covers the reproduced ordinary-tail loss, reset, deferred
swaps and bursts through 70K commands. It and the matrix-prefix oracle pass,
as do the complete renderer self-tests and fake-memory lifecycle checks. A
self-test counter now explicitly returns `std::size_t` so Clang's sign-compare
warning does not prevent these checks from compiling.

This is a command-retention correction, not yet a verified fix for issue #38.
ARM build validation and the initial speed checks are recorded below. The
reported NFS race and broader matched gameplay checks are still required
before accepting it for a release.

## VRAM bank register readback

ARM9 VRAMCNT A-I reads previously returned zero, so software could not save a
bank mapping before a texture upload and restore it afterward. The register
read mux now returns the implemented bits for each bank. The masks match
`GPU::MapVRAM_AB/CD/E/FG/H/I` and the ARM9 byte/halfword/word read handlers in
the vendored melonDS source. Existing mapping outputs and write timing remain
unchanged; this adds no state machine or gameplay pacing rule.

This adapts InsaneFriend (saneFriend)'s King Kong fix `6041052`, previously
ported in `204098d6ca62001a90e65f15d23fe9651d62decd`. Unlike that earlier port,
reserved bits read as zero. `tools/test_nds_syscnt_vram_readback.sh` reproduces
the original zero-read failure and verifies all 256 values for all nine banks,
byte lanes, texture upload/restore sequences, ARM7 status/write protection,
WRAM sharing and reset. The 27-case console sleep/wake suite also passes.
The King Kong issue remains open until a routed build passes gameplay testing.

## Initial rc.8 save triage

Bounded tests on the unmodified release have not reproduced the reported
Mage Knight or Spyro startup warnings (USA revision 0). Mage Knight created a
profile and resumed it into the world map after a cold relaunch. Spyro passed
save initialization and reached its opening gameplay with a fresh save. These
observations do not establish full-game save reliability or validate the
reported original saves; the issues remain open. All tests use separate save
files, with original files checked for changes.

## Identifying source queue failures

Both Mushroom Men and NFS reproduced the generic FPGA source fault `0x100`
on rc.8, while the HPS fault word remained zero. The source has two possible
causes: exhaustion of its 512 HBlank markers or its 256 frame boundaries.
The experiment preserves the aggregate bit and adds sticky detail bits:
`0x00400000` for HBlank overflow, `0x00800000` for frame overflow. The reason
bits cross through two synchronizer stages and are published with the aggregate
bit. Queue sizes, event ordering, CPU clocks and LCD pacing remain unchanged.
The gate regression checks each cause, combined reasons, service stop and reset.
This diagnostic does not itself fix either game's stall.

## Renderer performance gate

The first overflow candidate rendered the NFS track and car and passed profile
creation, but a matched NSMB World 2-5 A/B/A check at 1 GHz measured about a
2–3% reduction in game-timer progression. Publication counters stayed near the
same rate and did not expose that difference. This candidate is held for speed
regression; it is not accepted for release. A follow-up moves the new overflow
storage after the existing geometry fields, preserving their original offsets.
Command retention and overflow limits are unchanged. Its ordering, renderer
self-tests and fake-memory lifecycle checks pass. The follow-up ARM build
recovers the observed NSMB loss in the bounded comparison below; other games
remain required before release acceptance.

At World 2-5's spawn (USA A2DE revision 0, fire Mario, 11 lives), all runs used
1 GHz and the same host, save data and display settings. Timer readings come
from captured game HUDs against monotonic wall time, including idle animation
and bounded stationary-jump checks. These are game-timer units, not FPS.

| Candidate | Seconds sampled | Game timer units/s |
| --- | ---: | ---: |
| rc.8 before | 108.65 | 1.2517 |
| Original overflow renderer | 143.28 | 1.2214 |
| rc.8 repeat | 115.69 | 1.2534 |
| Overflow renderer with original geometry offsets | 119.49 | 1.2637 |
| Save-only FPGA, rc.8 renderer | 121.11 | 1.2551 |
| Save-plus-VRAM FPGA, rc.8 renderer | 76.66 | 1.2392 |
| Combined diagnostic FPGA and revised overflow renderer | 141.72 | 1.2490 |

No transport faults occurred in these runs. The first overflow renderer is
about 2.5% slower than the two release controls. The revised renderer and
save-only FPGA are within about 1% of the controls in this scene. The combined
candidate is 0.28% below the control mean, with an unchanged test save and no
faults throughout four 30-second header observations. This does not resolve the
shorter VRAM-only result discussed below. Integer HUD resolution, finite samples
and one scene limit these results; they do not establish general speed
equivalence or unique displayed 3D FPS.

Both save-only and save-plus-VRAM FPGA builds route. The save-only build has
33,811 ALMs and 530 M10Ks; worst reported setup slack is -15.400 ns versus
-13.834 ns for rc.8. Its worst path runs from the source reset synchronizer
through ARM9 math state. Neither baseline nor candidate is timing-clean;
hardware smoke tests do not establish timing closure. The save-plus-VRAM build
uses 33,955 ALMs and the same 530 M10Ks; worst reported setup slack is
-14.264 ns. Neither build changes the configured clock rates.

The new queue-reason tests and control-header publication check pass. The
product SystemVerilog boundaries elaborate, and the diagnostic build passes
Quartus mapping and the RTC CDC synthesis gate. The broad island test script
still stops at an obsolete FS3 menu-string assertion on both old and new
sources; its input-boundary fixture was repaired for rc.8's added interfaces.

The save-plus-VRAM core completed a shorter, 76.66-second NSMB check with no
transport faults or save changes. Timer progression was 1.2392 units/s, 1.06%
below the release controls. That is near the roughly 1% integer-HUD resolution
of this sample; a small regression is not excluded and a longer comparison
is still required. The revised renderer also passed a Castlevania opening
street-combat smoke test (ground attacks, a defeated skeleton, soul acquisition
and working pause menu), without transport faults. Those combat runs were not
sufficiently matched to support a quantitative speed claim.

NFS's existing 1-KiB save was also traced to a separate initialization problem:
its detected chip profile expects 8 KiB. The save bridge deliberately preserves
mismatched files and disables persistence instead of overwriting them. An empty
isolated file initializes to the expected 8 KiB and permits profile creation.
This explains that file's write warning; it does not resolve the race-view issue
or justify changing an original user save automatically.

## Progression blocker reproduction

On rc.8, Jackass (USA YJKE revision 0) passes profile creation and map selection,
then remains on a black first-level screen with a phone icon. It did not
advance through a roughly 91-second observation window including Start/A
input. Packet consumption and frame publication continued, FPGA/HPS fault
words stayed zero, and the 1,024-sample manual report showed a replay backlog
between zero and nine packets. Product CPU telemetry is disabled, so this
report cannot identify the exact instruction wait. The old geometry-credit
change remains excluded because its ordering counterexample is unresolved.

The diagnostic FPGA build also completes map, fit, assembly and timing analysis,
with 33,897 ALMs, 530 M10Ks and worst setup slack of -14.031 ns. It preserves
rc.8's clock configuration but, like rc.8, does not meet timing. Hardware checks
of its reason bits are recorded below; wider validation of the combined
candidate remains required.

Spectral Force: Genesis (USA YW4E revision 0) passed New Game and power selection
into the Unicorn Flag opening dialogue on rc.8. Both screens remained drawn,
multiple dialogue pages responded to A, and no transport faults occurred over
about 89 seconds after selection. The old report does not specify its chosen
power or ROM revision; this bounded path does not establish a general fix.

Both the diagnostic core with the rc.8 renderer and the combined core/renderer
candidate reproduced Mushroom Men with fault `0x00400100`: HBlank exhaustion,
with HPS fault zero. The first header check preceded framebuffer capture, and
both runs stopped at producer packet 5831. The rc.8-renderer flight recorder
shows the ARM replay queue filling to 512 packets while rendering is in
progress. It subsequently drains after the FPGA has stopped. A completed draw
interval reaches about 606 ms and replay-packet work about 501 ms. This narrows
the investigation to a rendering/replay backlog; it does not yet identify the
expensive operation or fix the incorrect menu graphics or save behavior.

The combined renderer's Mushroom Men run still faults at the same packet,
with a longest replay-packet interval around 365 ms (longest completed draw
around 54 ms). The long-work diagnosis must therefore distinguish replay
from raster drawing; increasing queue capacity alone would not establish a
correct or timely rendering path.

Saved causal timelines identify packet 5315 as the long replay in both runs:
500.75 ms with the release renderer and 365.06 ms with the revised renderer.
An additional run with the existing optional profiler attributes a 481.53 ms
interval to packed geometry records; the longest geometry execution flush is
only 0.36 ms. A separate private allocation probe confirms a 365.49 ms resize
from 2,097,152 to 4,194,304 eight-byte command entries, with no consumed prefix
and a pending SWAP. Smaller compactions also copy nearly full buffers.

This establishes a concrete allocation/copy stall and an accumulating deferred
geometry backlog. It does not establish why the authoritative source and replay
allow that backlog to grow: SWAP release, FIFO fullness and geometry-busy behavior
need an ordered comparison. Increasing capacity or dropping commands would not
resolve that correctness question. The instrumented run faults earlier, at
packet 4839; its extra profiling and log writes mean it cannot serve as a speed
control. The allocation probe remains private and is absent from this branch's
renderer. The game issue remains open.

## Menu and scene checks

Ninja Reflex (USA YNIE revision 0) draws all four profile slots and their labels
on rc.8. A input creates/selects the default profile and displays its name and
1 Player Start. The original screenshot matches the initially blank title/lower
screen, from which Start/A reaches the visible profile menu. Whether an expected title
prompt is missing and whether all later options work remain unverified.

The Wizard of Oz (USA COZE revision 0) reproduces the missing labels on all
three main-menu buttons, while the top logo and button frames draw correctly.
The save-plus-VRAM core with the release renderer has the same defect. Native
paired-screen captures agree with an eight-second RetroTINK lower-screen
capture; neither run faults. Opening credits do render text. Full flicker
verification and the responsible BG/OBJ/window state remain unresolved.

King Kong (USA AKQE revision 0) created a separate 512-byte profile on rc.8.
The save-plus-VRAM core cold-loaded an exact copy and rendered the same opening
boat scene without faults. That opening view does not show a decisive texture
difference. The original local video shows white/untextured polygons in an
interactive first-person view; that scene and a motion/speed comparison remain
required before claiming the texture issue is fixed.

The combined candidate cold-loads NFS's valid isolated profile and draws the
track and car through the race introduction, but it only reaches countdown 3
after a long observation window; the race timer remains zero. A follow-up rc.8
control using that same valid profile also draws the race scene. Therefore
visible race graphics in the candidate are not evidence that this patch fixed
issue #38. Command retention is proven by the failing/passing regression;
gameplay progression and speed acceptance remain separate and incomplete.

## Remaining acceptance work

Issue #42 remains excluded. No game issue has been closed from these tests.
The next work follows the approved priority order:

1. Finish game-specific save/reload coverage and identify why Mushroom Men's
   deferred geometry backlog grows across display frames, preserving ordered
   SWAP/query behavior and the established speed controls.
2. Identify Jackass's CPU/query wait with a bounded diagnostic, preserving the
   known ordered-query counterexample. Zelda's exact lid puzzle is still unknown.
3. Trace Wizard of Oz's missing label layer. Compare Ninja Reflex's blank title
   state with reference behavior and verify later menus. Spectral Force needs
   the original failing power/ROM details if the tested path continues to pass.
4. Validate the revised renderer through an actual NFS race and retain matched
   NSMB/Castlevania speed controls. Finish King Kong's matched texture check.
5. Continue the remaining graphics reports, distinct displayed-frame counter
   and measured performance work after these correctness checks.

Skate It, Shrek, both Prince of Persia titles, Lost in Blue, Linda Hyde,
Star Fox, Knights in the Nightmare, GoldenEye and C.O.R.E. have not yet received
new hardware reproduction runs in this experiment. The current 3D FPS display
still measures publication activity and must not be used as a unique-frame or
game-speed acceptance criterion.

## SWAP/VBlank retirement candidate

The Mushroom Men trace motivates a separate architectural FIFO-retirement
queue. Delivering a command to ARM no longer automatically releases its FIFO
credit when it is waiting behind SWAP_BUFFERS. SWAP retirement waits for the
next native console VBlank, while the transport continues to deliver records
and LCD events in order. CPU/DMA backpressure and GXSTAT FIFO thresholds use
the larger outstanding count from transport and retirement. The added queue
stores one bit per normalized command; payloads and queue capacities are
unchanged. Each consecutive SWAP requires a separate VBlank.

The product enables this behavior explicitly. The transport-only parameter
setting remains available for regression controls. Ordered readback fences
wait for transport and autonomous normalization, not the retirement barrier.
The initial geometry-enable state matches direct boot and the ARM renderer.
POWCNT1 low-byte writes qualify new SWAP waits; disabled VBlanks do not release
an existing geometry flush. Session reset clears both queues.

`tools/test_gx_swap_retirement.sh` checks CPU/DMA full stalls after transport
drains, consecutive and same-edge SWAPs, packed commands, transport stalls,
power transitions, reset, and the product CDC with 259 ordered readbacks and
LCD progress. The transport-only negative control fails the intended missing
SWAP-credit assertion. Existing clip/readback tests pass.

This is a minimum SWAP barrier, not cycle-accurate geometry execution. It does
not implement command-specific latency or change GXSTAT busy/matrix timing.
Hardware compatibility, speed and route/timing validation remain pending;
Mushroom Men is not yet confirmed fixed. Keep this candidate experimental.
