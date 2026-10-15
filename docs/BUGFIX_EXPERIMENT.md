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

A later test of the combined save/VRAM/renderer candidate selected **Save** in
Spyro's pause menu, exited cleanly, relaunched with the same separate 8 KiB save,
and resumed playable opening-room content with working movement and pause.
The saved bytes matched across the cold relaunch. This extends coverage beyond
startup, but the original reporter's save-write error has not been reproduced
and issue #21 remains open.

Lunar Knights (USA ALKE revision 0) saved slot 1 at Hunting Mansion/Forecourt
on rc.8. The combined candidate cold-loaded that checkpoint, accepted movement
and dialogue input, and saved a previously empty slot 3 in its separate 64 KiB
file. The new file bytes matched across a clean exit and cold relaunch, and the
new slot resumed the same playable checkpoint. No transport faults occurred.
This verifies an explicit in-game write and reload beyond language settings;
the original startup write-error report remains unreproduced, so issue #22
remains open.

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

A longer follow-up changes the classification of this observation. A private
CPU/FIFO diagnostic core samples repeated reads of GXSTAT's test-busy/result
fields, but the CPU also visits other addresses, both FIFOs remain empty and
VBlank advances. After a longer A/Start/X/Y input sequence, its phone scene
continues. The same sequence on unmodified rc.8 also reaches the phone
conversation, about 138 seconds after the first phone-icon capture, and further
A input reaches a rendered street/tutorial view. Thus the initial 91-second
window does not establish a permanent freeze, and this is not evidence of a new
core fix. The cause of the long delay and the contribution of input versus elapsed
time were initially unresolved. A subsequent rc.8 control with the identical save
and no further synthetic input still shows the phone icon at about 115 seconds,
then reaches the conversation by 153 seconds. This establishes automatic
progression after a long transition in this case. The cause of that delay remains
unresolved; issue #40 stays open.

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
verification remains open. The OAM readback investigation below identifies a
cause of the missing New Game label.

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
2. Investigate Jackass's long automatic phone transition while preserving the
   known ordered-query counterexample. The longer rc.8 control advances without
   input; Zelda's exact lid puzzle is still unknown.
3. Finish Wizard of Oz's physical-display/flicker checks after the verified
   label correction below. Investigate Ninja Reflex's source backpressure and
   verify later menus/minigames after the memory controls below. Spectral Force needs
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

Normal builds leave this behavior **disabled**. It can be selected only with
`NDS_GX_SWAP_RETIREMENT_EXPERIMENT`; it is retained for investigation, not accepted
for a release. Ordered readback fences
wait for transport and autonomous normalization, not the retirement barrier.
The initial geometry-enable state matches direct boot and the ARM renderer.
POWCNT1 low-byte writes qualify new SWAP waits; disabled VBlanks do not release
an existing geometry flush. While geometry is disabled, ignored commands
still pass through transport without consuming retirement slots. The separate
retirement tail preserves older queued work across power-off, even when full.
Session reset clears both queues.

`tools/test_gx_swap_retirement.sh` checks CPU/DMA full stalls after transport
drains, consecutive and same-edge SWAPs, packed commands, transport stalls,
power transitions, reset, and the product CDC with 259 ordered readbacks and
LCD progress. The transport-only negative control fails the intended missing
SWAP-credit assertion. Existing clip/readback tests pass.

This is a minimum SWAP barrier, not cycle-accurate geometry execution. It does
not implement command-specific latency or change GXSTAT busy/matrix timing.
The first routed hardware candidate reduced Mushroom Men's renderer memory
usage and kept transport advancing without fault bits, but both screens were
black and new SWAP submissions stopped. NSMB also stopped responding at its
menu. These are compatibility regressions, so this candidate is rejected;
flat memory usage and a live transport do not establish a fix.

That candidate routed and assembled with 34,047 ALMs and 531/553 RAM blocks.
Worst setup slack was -15.483 ns, compared with -14.031 ns for the preceding
diagnostic build and -13.834 ns for rc.8. It is not timing clean, and no speed
acceptance is claimed. A bounded ARM replay log kept geometry enabled throughout
the observed early stall; this alone did not establish the FPGA's internal state.

A later private diagnostic core contains the power-off/full-FIFO correction
and passive CPU/FIFO snapshots, but not the DMA pause-edge correction below.
It reaches Mushroom Men's New Game, hero selection and opening story scene.
Across a 30-second sample, native VBlank advances, the CPU visits 17 different
sampled addresses, transport is empty and retirement levels vary from 129 to
256 entries. Renderer resident memory stays around 64 MiB through the observed
menus and story, without transport faults. The menu graphics remain corrupted.
This is progress beyond the previous fault/stall, not a complete game fix or a
speed acceptance result. The source changes, added probes and physical build
also differ, so this run alone does not isolate the cause of that improvement.
The same diagnostic core passes NSMB's menu, enters World 2-5, advances its
game timer and responds to pause without transport faults or save changes.
Its diagnostic observations are kept separate from the non-probe speed gate.

The subsequent core includes the DMA pause correction and removes the private
probes. It completes map, fit, assembly and timing analysis with 34,110 ALMs,
531 M10Ks and worst setup slack of -13.945 ns. Like rc.8, it is not timing clean.
It reaches Mushroom Men's main menu and opening story without transport faults,
with bounded renderer memory, but still reproduces the corrupted menu graphics.
This opt-in core is an experimental hardware candidate, not a release artifact.

Longer follow-up testing rejects this core for stability. Mushroom Men later
stops in its menu with `0x00400100` (HBlank exhaustion), while the HPS fault
word remains zero. A separate longer run of the diagnostic core without the
DMA pause correction also reaches HBlank exhaustion. The shorter progression
checks above remain valid observations but do not establish stable gameplay.
The last four retained packets in each fault capture are mostly packed
geometry commands, with no SWAP command. This alone does not identify the
ordering or pacing cause. SWAP retirement remains disabled in normal builds.

Its matched NSMB World 2-5 run advances 194 game-timer units in 153.94 seconds
(1.260 units/s). A fresh rc.8 repeat advances 179 in 141.94 seconds (1.261
units/s), within 0.1% of the candidate. Both use the identical save and scene
at 1 GHz, with no transport faults or save changes. An earlier control was
1.277 units/s; the adjacent repeat avoids mistaking that control variation for
a small regression. This supports no measurable loss in this bounded scene,
not general speed equivalence.

Castlevania's opening street battle accepts attack input, advances its game
clock and returns to pause without transport faults on this core. Its short
clock sample advances 21 integer seconds over 21.83 seconds of active input;
the earlier release sample advanced 22 over 21.87 seconds, with a different
starting health/battle state. These short, unmatched samples cannot establish
speed equivalence or a small regression. A longer idle attempt returns to the
title screen after the low-health battle and is excluded from timing analysis.
Broader performance acceptance remains open.


## GX DMA pause-edge request loss

A new below-half FIFO request on the `GX_PAUSE` clock edge was overwritten by
that state's unconditional pending-bit clear. The channel kept its enable bit
and remaining words, but never resumed while the request stayed high. This can
strand software waiting for DMA completion even after the FIFO has emptied.
The pause state now retains an active, supported GX request before releasing
the bus; transfer counts and the 112-word arbitration interval are unchanged.

`tools/test_dma9_gx.sh` reproduces the lost request against the previous DMA
implementation. With the correction, all four channels finish the same
118-word transfer for requests arriving on the pause edge, the next idle edge
and a later idle edge, without lost/duplicate words or repeated completion.
The existing GX/VRAM backpressure, channel preemption, CPU yield and repeat-DMA
checks pass, as do the query-overlap and main-RAM transfer suites. The routed
opt-in core containing this correction passes the bounded Mushroom Men
progression and NSMB speed checks above. The diagnostic core without this DMA
change also advances both games, so these runs do not establish it as the cause
of a game-specific improvement. SWAP retirement remains disabled in normal builds.

## OAM readback and Wizard of Oz menu labels

ARM9 CPU and DMA reads from OAM previously returned zero. Games that read a
sprite attribute, change one field and write it back therefore lost the other
fields. This includes its position, shape and palette selection.

A full software-reference run of Wizard of Oz displays **New Game** in the
otherwise blank first menu button. Forcing only ARM9 OAM reads to zero in a
private reference build removes that label. All 72 bytes of the nine affected
sprite entries then match the hardware capture exactly, in the same alternating
screen phase. Isolating the hardware's OBJ layer and disabling blending did not
restore the label. This identifies a cause independently of layer composition;
the routed hardware result below confirms the label correction. It does not
resolve every menu/flicker report.

The correction adds a 2 KiB OAM readback shadow beside the existing palette
shadow. Reads use the existing synchronous video-memory wait state and read
rotator, including completion-cycle requests. Engine power gating and ROM-reset
clearing apply to both banks; byte stores are ignored by the OAM shadow.
Reads need no ARM service round trip. Geometry pacing, renderer code and clock
rates are unchanged. Broader game and performance acceptance remain required.

`tools/test_nds_oam_readback.sh` fails on the preceding bus implementation's
zero result and passes with the correction. It covers all 512 words, both
engines, CPU/DMA reads, halfword and byte reads, mirrors, unaligned rotation,
sprite attribute updates, ignored byte stores, power-off behavior, reset and
back-to-back requests. The existing palette and GX DMA suites and complete
console VHDL analysis also pass.

The core completes mapping, fitting, assembly and timing analysis with 33,999
ALMs, 532 of 553 M10Ks and 27 DSPs. Its source-input and RTC CDC checks pass.
Worst reported setup slack is -14.326 ns versus -13.834 ns for rc.8; neither
build meets timing. This build contains no private probes and leaves the SWAP
retirement experiment disabled.

On hardware, **New Game** is now visible and selecting it opens the story.
Across 60 distinct sampled native publications, the label pixels are identical
and match the full software reference exactly at the DS's 6-bit channel depth.
The sampled top-logo and button regions each alternate between two images;
both images also match the reference exactly. Thus the native output agrees
with the reference in these regions, but this does not establish flicker-free
physical/TATE output or original-DS behavior. The other two buttons are blank
in the matching fresh-save reference state too; later save-dependent options
remain unverified. Issue #34 stays open.

A matched NSMB World 2-5 check at 1 GHz advances 171 timer units in 128.79
seconds on this core with the revised renderer, versus 172 in 128.86 seconds
on rc.8 (1.328 versus 1.335 units/s, a 0.53% reduction). Both use the same save,
fire Mario with 11 lives, and a stationary interval without diagnostic sampling
between the endpoint captures. Both remain fault-free, respond to pause and
preserve the test save. The difference is within integer-HUD sampling uncertainty;
one pair does not exclude a small regression or establish general speed
acceptance. An earlier control that ran past the level timer was discarded.

Mushroom Men's menu corruption has a separate cause. Its normal and forced-zero
OAM-read software controls produce identical menu pixels. The captured hardware
changes screen/VRAM phase during visible scanlines, unlike the stable per-frame
mapping in the sampled software reference. Display/capture timing remains an
investigation lead; the OAM correction is not claimed to fix those bands.

## Extended Ninja Reflex investigation

A full software-reference run displays the title artwork, **Touch to Start**
and the profile-selection labels. Private controls that force OAM or VRAM bank
register reads to zero still render those sampled screens. Later hardware runs
also show the title and profile labels on the combined candidate and on the
rc.8 core with a private trace helper. The uninstrumented startup controls below
reproduce an early blank lower screen followed by readable profile slots; a
short blank capture alone is not evidence of a permanent rendering failure.

After about ten minutes, the latter diagnostic session exhausts memory and the
Linux OOM killer terminates its renderer; the watchdog returns to the menu and
the host exits cleanly. The renderer's anonymous resident memory was about
325 MiB at termination. Because this helper contains both the command-retention
change and private tracing, this is not yet a clean attribution to either the
release or a candidate change. It blocks extended stability acceptance until an
uninstrumented control isolates it. Original saves and settings remain unchanged.

The uninstrumented comparison reproduces substantial early memory growth in
both helpers with the same rc.8 FPGA, host, settings and identical starting save
copies. Resident memory grows from about 124 MiB to 190 MiB in both runs, with
nearly identical readings at the first two observation points. The runs stop
before another OOM; neither reports a transport fault. The release's initially
blank lower screen later shows four readable profile slots without additional
input. This establishes that memory growth and the early blank capture are not
unique to the new helper or private trace instrumentation. It does not identify
the allocation or establish which build reaches a later OOM first. Game-created
save bytes differ between runs after initialization, but each test save remains
unchanged over its observation window. Original files remain unchanged.

A five-minute check of the unprobed SWAP-retirement core with the same revised
helper and starting save copy keeps resident memory between 62.7 and 63.4 MiB,
with no transport faults. The profile labels are visible at the first capture.
Touch input creates a separate profile, selects **1 Player Start**, advances
the introductory prompt and reaches the rendered sensei scene with **Ready!**
visible. The isolated save changes as expected from profile creation. This
points toward source geometry backpressure as a useful lead, but the compared
cores contain multiple changes, so it is not an isolated causal toggle or a
speed test. It does not validate every menu or minigame, and it does not reverse
the SWAP core's longer Mushroom Men failure. That experiment remains disabled.


## Opt-in compact HBlank event storage

The next candidate addresses the short scanline-marker queue that overflows
during Mushroom Men's extended replay/render stalls. It stores a regular run
implicitly and records every discontinuity in timestamp, scanline or display
frame. Only received pulses increase its count; output still expands every
individual event in its original order, with its original timestamp. Nothing
coalesces or drops VBlank ownership tokens, and this does not gate LCD timing
or change CPU, renderer or clock settings.

Normal builds leave it disabled. `NDS_HBLANK_RUN_QUEUE_EXPERIMENT` selects it
for a separate hardware experiment. The queue holds up to 131,071 received
events and 512 discontinuity descriptors. Descriptor/event exhaustion remains
a sticky HBlank source fault, including after service stop; reset clears it.
Irregular cadence is retained explicitly rather than assumed to be periodic.

`tools/test_hblank_run_queue.sh` compares literal input records against expanded
output through long stalls, timestamp/frame/index wraparound, line jumps,
full-queue simultaneous reads/writes, randomized stalls, overflow, service stop
and reset. Its integrated source gate retains 4,096 regular scanline markers
and all 15 independent VBlank tokens exactly. The legacy gate fails on marker
513 under the same test. Existing event-gate, VRAM retirement, SWAP/readback CDC
checks and complete console VHDL analysis pass. Routing, extended game testing
and matched speed measurements remain required; this is not an accepted fix
for Mushroom Men or Ninja Reflex.
