# rc.8 bug-fix experiment

This branch starts from rc.8 plus its README formatting correction. The approved
backlog excludes issue #42 (SS1 launcher detection). Save integrity comes first,
followed by progression, graphics correctness, frame measurement and performance.
Reported game failures must be reproduced and checked individually before closure.

## Latest validation status

The follow-up hardware pass checks Mushroom Men, Ninja Reflex, Wizard of Oz,
Need for Speed Carbon and Shrek racing, with Final Fantasy Tactics A2 and
Pokémon White 2 as additional regression workloads. The detailed observations
below distinguish earlier findings from the latest tests.

- Mushroom Men's first checkpoint survives a cold reload and can be saved
  again. Its graphics defect remains: the sampled display updates already
  carry visible-line timing at the FPGA source.
- Ninja's tested category menus and completed Firefly Catch challenge work;
  Oz's tested labels, movement and temporary save/reload work. Selected label
  regions remain visible in the physical rotation checks.
- NFS and Shrek respond to acceleration and retain their race views on both
  rc.8 and RUN1 in the tested opening scenes. Neither test completes a race.
  Skate's reported Flickit scene also retains its full view on rc.8, including
  the rotated HDMI output.
- Tactics and White 2 preserve progress across cold reloads. The limited
  matched measurements demonstrate no slowdown, but do not establish distinct
  displayed FPS or broad performance acceptance.

These findings do not close the backlog or qualify RUN1 for release. The
experimental SWAP retirement and HBlank storage options remain off by default,
and RUN1 still fails FPGA timing. This follow-up adds validation evidence;
it does not introduce another source-code fix.

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
checks and complete console VHDL analysis pass.

The combined OAM/SWAP/compact-queue core completes mapping, fitting, assembly
and timing analysis with 34,364 ALMs, 534 of 553 M10Ks and 27 DSPs. Synthesis
confirms both opt-in experiments are active, the old scanline queue is absent,
and the descriptor RAM is 512 × 122 bits. Frozen source-input and RTC CDC
checks pass. Worst setup slack is -14.649 ns versus -13.834 ns for rc.8;
neither build meets timing. Extended game tests remain required; this is not an
accepted fix for Mushroom Men or Ninja Reflex.

A fresh matched NSMB World 2-5 check at 1 GHz advances 172 timer units in
128.87 seconds on the combined core and revised renderer, versus 171 in 128.94
seconds on rc.8 (1.335 versus 1.326 units/s). Both use the same save, fire Mario
with 11 lives, and the same stationary interval without diagnostic sampling
between captures. Both remain fault-free, respond to pause and preserve the
save. The 0.64% difference is within integer-HUD sampling resolution; this pair
shows no measurable slowdown, not a general speed improvement or acceptance
of every workload.

Mushroom Men completes a ten-minute observation on the combined core with no
FPGA or HPS transport fault. Resident renderer memory stays between 63.6 and
64.4 MiB. The test holds the **Startup Game** menu for about six minutes,
continues through character selection and the opening story, and advances
the story with touch input. A follow-up reaches the playable village, moves
the character/camera with Right input and opens Pause. No save checkpoint is
reached. This exceeds the previous candidate's failure window, but the main
screen still has a black band and missing text pixels; RetroTINK output
confirms those defects. Full gameplay and save/reload remain unverified, and
#31 stays open. Both experiments remain disabled by default.

A separate software-reference control increases ARM9 instruction costs by
four or eight times only after reaching the same menu pixels as the normal
run. Twenty consecutive sampled frames per condition retain stable screen
and VRAM-bank mappings throughout visible lines, with no near-black full-width
rows. The hardware trace instead changes the mapping at visible lines 6–7.
Uniform instruction slowdown alone does not reproduce the sampled defect.
This synthetic control leaves DMA and ARM7 timing unchanged and does not model
specific FPGA bus stalls or replay ordering; those remain investigation leads.

Ninja Reflex also completes a ten-minute observation with no FPGA/HPS fault
and resident renderer memory between 62.7 and 63.4 MiB. Its profile labels are
visible at the first capture. Touch input creates an isolated profile,
selects **1 Player Start**, advances the rendered sensei introduction and
welcome screen, and reaches the six labelled game choices. Selecting
**Hotaru** opens its readable instructions and minigame choices. After a
clean exit and cold relaunch, the newly created profile remains visible in
slot 1. This validates those menus, named-profile persistence and the bounded
memory behavior, not every minigame or a full playthrough. Issue #24 remains
open pending the remaining menu and flicker checks.

The Wizard of Oz's **New Game** label also passes on this combined core:
the label pixels in all 60 sampled native publications match the software
reference exactly, and selecting the option opens the story. The top logo and button-region
images match the reference's two alternating phases. The label is also visible
through the RetroTINK. This confirms the OAM correction survives integration;
it does not settle reported physical/TATE flicker or later save-dependent
options, so #34 remains open.

## Further race-view checks

Skate It (USA CSVE revision 0) reaches **Tutorial → Basic → Flickit!** on
unmodified rc.8 with a new isolated save. The skater and park render at the
reported introduction prompt and after entering the active board tutorial.
Two separate captures each contain 60 consecutive native publications over
about 3.7 seconds, with a detailed, changing top-screen image in every sample.
Neither shows the mostly flat grey output reported in #37, and no transport
fault occurs. These are bounded native captures, not physical/TATE validation
or a complete playthrough. The reporter's region/revision remains unknown;
this is an unreproduced older-release symptom, not a new candidate fix.

Need for Speed Carbon (USA AN7E revision 0) also draws its car and track on
the unprobed SWAP-retirement experiment using the existing valid isolated
8 KiB profile. Pause responds, and the dashboard animates with no transport
fault or substantial memory growth. However, the final captures still show
zero speed and timer values after repeated A-button holds. Driving remains
unverified, as in the earlier rc.8 comparison. Issue #38 stays open; visible
race scenery alone is insufficient gameplay acceptance.

## Follow-up investigation and regression coverage

The next pass covers Mushroom Men, the remaining Ninja Reflex and Wizard of Oz
menus, and the NFS/Shrek race reports. Final Fantasy Tactics A2 and Pokémon
White 2 provide additional regression workloads. Every hardware run uses an
isolated save, with 53 original save/configuration paths checked for changes.

Mushroom Men's display-capture control register is another ruled-out cause of
the sampled menu defect. The software reference performs no reads of that
register in the tested sequence, and forcing its reads to zero leaves all
sampled pixels unchanged. In a separate 20-frame software trace, all 160
capture-control, VRAM C/D mapping, screen-swap and Engine B display-control
writes occur on VCOUNT 192. VBlank interrupt acknowledgement precedes the
screen-swap write by 1,495–1,559 emulated ARM9 cycles. This establishes the
reference's update phase; the earlier hardware trace's changes on visible
lines 6–7 still require a source-versus-replay explanation.

White 2 (USA/Europe IRDO revision 0) cold-loads the copied Pokémon Center save
on rc.8, responds to movement, and performs explicit in-game saves. A matched
endpoint procedure records the game's saved play clock after each save, with
a six-minute quiet interval between the save sequences. The first release run
advances by 415 saved seconds across 415.47 wall seconds between save-confirm
inputs. Both copies of the player-data block pass their checksums. Renderer
resident memory remains 63.0 MiB, the ARM clock stays at 1 GHz, and no FPGA/HPS
transport fault occurs. Main-screen output is also visible through the
RetroTINK using Screen Peek. This measures saved-clock progression in one room,
not distinct displayed FPS or general gameplay speed.

The combined RUN1 core and revised renderer repeat the same room, movement
and save sequence at 1 GHz. The saved clock advances by 415 seconds over
414.94 wall seconds, with both player-data checksums valid and no transport
faults. Resident memory changes from 63.01 to 63.07 MiB. The 0.13% difference
from the release control is within the one-second saved-clock resolution; no
clock-progression slowdown is demonstrated in this scene. The starting native
captures have the same player/camera position and room, with only 194
top-screen animation pixels differing and an identical bottom screen.

Final Fantasy Tactics A2 (USA A6FE revision 0) reaches its first battle on rc.8
and creates a normal Quick Save. RUN1 cold-loads a separate copy of that save,
moves units, executes a Fire spell, advances multiple turns and creates a
second Quick Save at Luso's turn. The battlefield and menus are visible through
the RetroTINK. This is a bounded opening-battle check, not a complete battle
or playthrough.

An idle first-turn comparison uses identical copies of the original battle
checkpoint. With the same White Mage, command menu and camera, rc.8 publishes
2,008 framebuffers in 94.39 seconds (21.27/s); RUN1 publishes 2,029 in 94.01
seconds (21.58/s). Both runs remain at 1 GHz with zero transport faults.
Renderer resident memory is 64.93–64.95 MiB on rc.8 and 65.00 MiB on RUN1.
The candidate's publication throughput is 1.45% higher in this one pair. This
is an endpoint counter measurement without continuous probes, not distinct
rendered FPS or a general emulated-game-speed benchmark.

A further Mushroom Men software-reference trace observes both CPUs' byte,
halfword and word writes overlapping VCOUNT throughout 4,443 boot/menu frames.
It sees no such writes. Software-directed VCOUNT changes therefore do not
explain the reference sequence's display phase; the hardware phase still
requires direct investigation.

Both candidate persistence checks also pass after clean shutdown and a cold
relaunch. Tactics restores the progressed unit positions and Luso's turn,
then creates another Quick Save successfully. White 2 returns to the Pokémon
Center after switching to Tactics and back; the saved file hash and both valid
player-data blocks exactly match its last explicit save. Basic blackout checks
of both White 2 RetroTINK recordings find no blank or low-detail game-region
frames in 969 captured frames per clip; this does not measure fine flicker
or subjective audio quality.

A one-frame diagnostic on the combined core now separates Mushroom Men's
source tags from ARM replay. All ten captured VRAM-map/display-control writes
carry visible-line source tags 85–86 and arrive immediately after replay
phases 85–86. The register transitions therefore already have the wrong
visible-line phase at the FPGA source; this sample does not show ARM replay
reordering them. The earlier 6–7-line sample was a different session, so the
phase is not fixed. Why the source reaches these updates during visible scanout
remains unresolved. The private trace helper is excluded from speed acceptance.

Mushroom Men's save check now reaches the first Reminiscent checkpoint through
normal play: shoulder-button jumping, stylus drag to equip the stick, melee
combat and the paper obstacle. Touching the checkpoint and confirming Yes
changes the isolated 8 KiB save. After a clean exit, normal RUN1 cold-loads the
saved location with the weapon and health state retained, and another explicit
save succeeds. No transport fault occurs. The first save used the combined
core with the private one-shot trace helper; reload and the subsequent save
used the normal RUN1 helper. This does not reproduce the unspecified save
failure at that checkpoint, but the graphics band and duplicated menu content
remain. Issue #31 is still open.

The Ninja Reflex follow-up opens all six category instruction screens and
unlocked-choice lists, plus Meditation, and revisits the menus. The tested
Koi and Nunchaku choices show their descriptions. Firefly Catch completes
through normal touchscreen inputs, receives its completion checkmark and
retains that mark after a clean exit and cold launch. The session lasts
56 minutes with no transport fault and final renderer resident memory of
65.06 MiB. This covers menu navigation and one completed challenge, not
every minigame or a full playthrough.

Ninja's main-menu labels are also readable through analog RGB and normal
HDMI with 90-degree counterclockwise core rotation. Selected label regions
have no abrupt dropout in the two approximately 16-second recordings
(973 and 981 captured frames respectively). Their minimum correlations to
the median image are 0.962 and 0.964. These compressed-capture checks do not
establish whole-game pixel equivalence or subjective audio quality. The
core's original layout and rotation are restored after the test.

Wizard of Oz also displays **Continue** with an isolated temporary-save
fixture. Both New Game and Continue label regions exactly match the software
reference in all 60 sampled native publications. The middle button remains
blank in the matching software reference, so this save state is not evidence
of a missing middle label. The fixture was created by the reference's normal
Quit Game operation; loading it alone does not validate hardware save writes.

The same Oz menu is readable through HDMI with 90-degree counterclockwise
core rotation. In an 8.37-second recording, both label regions remain stable
across 503 captured frames, with a minimum correlation of 0.998 to the median
image. The title's idle attract sequence is excluded from this menu check.
This is a bounded label-region test, not every save state or whole-game
flicker acceptance.

Oz's Continue option resumes Yellow Brick Road A, trackball strokes move
Dorothy, and the normal Quit Game command creates a new temporary save on
RUN1. A clean exit and cold relaunch preserve the exact saved file at the
title screen, and Continue restores the progressed road position. The
11-minute pre-reload session has no transport fault and finishes at
62.16 MiB renderer resident memory. The regular permanent-save Load option
and later gameplay remain untested.

The NFS start sequence is now resolved: A leaves the cycling race
introduction, then R accelerates. R alone leaves the introduction cycling
in the software reference too, even across an extended run. On rc.8 and
RUN1, the corrected sequence moves the car into the tunnel and advances
the odometer and minimap. Earlier A-only or intro-only captures therefore
do not establish a gameplay freeze.

Both builds retain the car and track through HDMI with 90-degree
counterclockwise rotation. Each native capture contains 60 consecutive
publications with no near-black full-width rows; both physical recordings
retain image detail in the selected race-view region. RUN1's recording
shows movement through the city, followed by a collision. The old flat-grey
race-view symptom is not reproduced in these bounded checks. Neither run
completes a lap, and the moving-city and collided-wall samples are different
workloads, so their publication rates must not be used as a speed comparison
or proof that this branch caused a graphics fix.

Shrek Smash n' Crash Racing (USA A4IE revision 0) also draws its first
Swamp track on both rc.8 and RUN1. Quick Race with Shrek and the default
profile responds to A acceleration: the racer moves, the minimap advances
and the race timer runs. The racer and track remain visible in normal native
captures and HDMI with 90-degree counterclockwise rotation. Each build's
60 consecutive native publications contains a detailed top image with no
near-black full-width rows. Neither reproduces the reported streaked upper
band with a missing lower race view. Both bounded drives end at a track
barrier before completing a lap; this is not full-race or speed acceptance.

Skate It (USA CSVE revision 0) also retains its full skater/park view on
unmodified rc.8 at the reported Flickit introduction and after entering the
board tutorial. The HDMI 90-degree counterclockwise introduction recording
has no abrupt blackout across 975 captured frames. The next recording spans
the scripted trick demonstration and its transition to player control. Its
single 0.43-second dark interval is a scene fade; the images before and after
show the demonstration changing to the player's board and three objectives.
It does not reproduce the reported mostly grey gameplay view. This checks
the reported scene, not completion of the challenge or a new candidate fix.

A separate cold-launch repeat waits for the demonstration to finish and
visually confirms the player's board and objectives before sampling. All
60 consecutive native publications retain image detail without near-black
full-width rows. The settled player-view recording retains the scene through
981 HDMI capture frames over 16.33 seconds; the selected skater/park region
has no abrupt blackout. An earlier repeat accidentally reached a location
menu and is excluded from these gameplay results.

The next graphics investigation is Mushroom Men's VBlank delivery and ARM9
interrupt-service timing before the display-register writes. Matching source
and replay tags narrow the location of the problem but do not establish its
cause. Full race/challenge coverage, broader matched performance tests and
the unresolved timing failures remain acceptance limits. No GitHub issue is
closed by this follow-up.

After testing, all 53 protected original save/configuration paths still match
their recorded hashes. The original core session and test-save hash are
restored, along with the RetroTINK's HD15 RGBS input at 59.64 Hz native 240p.
No recording or software-reference container remains running. Private game
assets, saves, diagnostic binaries and captures remain outside this repository.
