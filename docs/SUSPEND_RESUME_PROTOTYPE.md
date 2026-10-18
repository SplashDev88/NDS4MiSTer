# Bounded suspend/resume experiment

Branch: `experiment/suspend-resume-20261017`, based on rc9 (`021acd592`).

The intended player feature is **one suspend slot for the exact same ROM and
runtime build**, first across a clean core exit/relaunch, then across power loss.
Normal game saves must remain isolated during development. This work does not
add an installation package, menu entry, or working whole-game resume yet.

## What works now

The first milestone is a persistent **CPU component checkpoint**. Both actual
Nitro CPU RTL implementations can stop at a retired taken branch, export their
architectural state, and restart that state in a fresh simulator process. The
program continues its counter stores without skipping or duplicating them.
Tests use authored instructions; no commercial ROM or user save is required.

A second component milestone coordinates those CPU holds across clock domains,
with a deadline, cancellation and acknowledgement draining. It is tested with
both real CPU implementations together. A third milestone adds an optional
halted-pipeline format: ARM7 HALT and ARM9 WFI can preserve their pending
instructions across a fresh-process restore. The branch-only format still
refuses sleeping CPUs. A fourth milestone adds a read-only CPU state transport,
an expiring host lease, and optional wiring to the actual console CPUs. Further
component steps add DMA admission stopping/draining, ARM9 memory-island idle
status, audio drain/pause and raster/timer event stopping. Memory, remaining
devices and the renderer still lack a common freeze boundary; these partial
signals do not authorize a whole-machine checkpoint.

`EXPERIMENTAL_CHECKPOINT` and `EXPERIMENTAL_HALT_CHECKPOINT` default to `false`
in both CPUs. The console's `CHECKPOINT_CPU_ENABLE` option also defaults to
`false`; no shipping wrapper or ARM9 adapter enables it. The released FPGA,
host, renderer, settings and 1 GHz operating point are unchanged.

The old `SS_PRESET_ONLY=0` path is insufficient by itself: it omits ARM9 CP15
configuration and CPSR.Q, and its exported PC is only updated on a branch.
Open-bus `lastread` also needs preservation. The new path covers those values
and acknowledges only a boundary for which that PC is valid.

The prototype first used full restore shadow registers. Synthesis showed that
this would add thousands of registers, so the retained implementation writes
the **existing live registers while reset is held**. It retains the small boot
preset bank and uses a read mux for capture. The legacy nonexperimental path
remains available, with its original limitations.

## Component protocol and limits

Set `EXPERIMENTAL_CHECKPOINT=true` and `SS_PRESET_ONLY='0'` explicitly. To
capture a halted CPU, also set `EXPERIMENTAL_HALT_CHECKPOINT=true` and use the
`arm9-pipeline-v1` / `arm7-pipeline-v1` file identity and all 12 extra words.
Do not restore a branch-only file into the halted-pipeline protocol.

1. Raise `checkpoint_req` in the CPU clock domain. Continue servicing its memory
   responses. A taken B/BL/BX retires, its outstanding fetch completes, and the
   target fetch is suppressed. DMA ownership, a saved bus request and ARM9 cache
   maintenance prevent acknowledgement. With the halted-pipeline extension,
   an already halted CPU may also acknowledge after its memory bus and execution
   state machines are idle, with no wake or IRQ input and no pending IRQ decode.
   That path keeps the actual decoded instruction and fetched word intact.
2. Wait for `checkpoint_paused`. Read the complete state while keeping the
   request high. The CPU clock enable is held internally, not the input clock.
   Dropping the request cancels the hold. A branch capture refills at the saved
   target PC; a halted capture retains its pipeline and waits for a normal wake.
3. Before restore, validate the entire file and exact identity. Hold `reset`
   and `checkpoint_restore` high together, then write **every** state word,
   using full-word byte enables. Read back the live state while still in reset.
   Drop restore and reset together, with the request low, only after the complete
   image is accepted.
   CPU bus requests must remain disconnected from the rest of the machine until
   every other subsystem is restored too.

The caller must impose a bounded deadline and cancel on timeout. This component
has no internal timeout controller. Without the pipeline extension it cannot
acknowledge HALT/WFI. Even with the extension, active memory/cache transactions,
pending IRQ entry, a lid-sleep DMA hold, and running code with no taken branch
may prevent capture; the coordinator must time out safely. Arbitrary
mid-instruction capture and cache/RAM/device-state restoration are not provided.
A failed partial restore must stay in reset and use a clean boot;
releasing reset with a partially loaded image is invalid.

### CPU-pair coordinator

`rtl/nds_checkpoint_coordinator.vhd` and `rtl/nds_checkpoint_endpoint.vhd`
provide an isolated CPU-pair barrier. They do not freeze console devices, RAM,
graphics or audio and cannot authorize writing a whole-machine state file.

- The caller waits for `ready`, then holds `request` high. An accepted request
  increments a 32-bit attempt `epoch`. It is a control-domain label, not a
  persisted common machine timestamp; reset clears it and it can wrap.
- Each endpoint synchronizes the request in its own CPU clock domain and
  returns both delivery receipt and the CPU's actual pause acknowledgement.
  Only both CPU acknowledgements establish `pair_paused`.
- If both CPUs cannot pause within `TIMEOUT_CYCLES` control clocks (including
  crossing latency), the attempt fails with sticky `timed_out`. Withdrawal of
  `request` also cancels immediately from the caller's perspective.
- Cleanup finishes delivery of the high request to both endpoints, then
  withdraws it and waits for both request receipts and CPU acknowledgements to
  return low. This four-phase handshake prevents a late acknowledgement from
  being mistaken for a new attempt. Cleanup never waits for an unsupported CPU
  to reach a capture boundary.
- Keeping a failed caller request high cannot retry it. A new request requires
  withdrawal and completed cleanup. A stopped endpoint clock or stuck receipt
  raises `release_stalled`; `ready` stays low. Actual release cannot be promised
  while a CPU clock is stopped. Once clocks/receipts recover, cleanup completes.
- Coordinator, endpoints and CPUs require a common reset spanning at least
  three rising edges in every domain. Clocks stay running during a hold; CPU
  enables stop internally. Host transport must synchronize its request before
  this interface.
- A held pair expires after `LEASE_CYCLES` control clocks without a fresh
  `keepalive` rising edge carrying the current attempt's epoch. The default is
  33,513,982 clocks (about one second at clk1x). Wrong epochs, a stuck-high input
  and keepalives during acquisition cannot extend the hold. Expiry invalidates
  `pair_paused`, sets sticky `lease_expired` and `timed_out`, and releases the
  CPUs through the normal handshake. A stopped CPU clock can still prevent
  physical release; this is reported rather than hidden by a false `ready`.

### CPU state transport and console wiring

`nds_checkpoint_cpu_capture.vhd` combines the coordinator, endpoints and two
`nds_checkpoint_read_port.vhd` mailboxes. Its host interface is synchronous to
the control clock; it is not yet connected to SPI or the ARM host.

- Wait for `read_ready`, then issue a **one-cycle** `read_strobe` with CPU
  selection (0 = ARM9, 1 = ARM7), word address and the current hold epoch.
  Address/selection/epoch may change after that accepted edge.
- Each mailbox keeps its address stable through a four-phase request/reply
  crossing. The CPU-domain reader registers the address, samples the mux on
  the next clock, and keeps the reply stable until acknowledgement is withdrawn.
  Only a paused CPU and valid word address can produce a successful reply.
- `read_done` is a one-cycle completion. Accept its data only with
  `read_error=0`, the matching `result_epoch`, and a still-valid pair hold.
  Invalid addresses, stale epochs and reads outside a hold return errors.
  Cancellation or lease expiry also masks a reply arriving on that same edge.
- A read deadline reports an error but still drains the late request/reply.
  It cannot rearm while a stopped CPU clock leaves that handshake unfinished.
  It never forwards a late completion into the next attempt.
- These are bundled-data CDC paths: the handshake holds addresses/replies
  stable. Simulation tests clock ratios and phases; physical CDC constraints
  and timing still require validation in the integrated FPGA build.

With `CHECKPOINT_CPU_ENABLE=true`, `nds_nitro_console_top.vhd` connects this
controller to both actual CPUs. The ARM9 reader uses clk2x, the ARM7 reader uses
clk1x, and the host side uses clk1x. Reset preserves the existing boot preset
buses; during execution only the CPU read mux addresses are borrowed. Timer
state buses retain their original owners. There are **no restore writes** and
no user-facing control. The source closure analyzes successfully, but a full
console simulation or hardware capture has not yet qualified this wiring.

`checkpoint_pair_paused` says only that both CPUs acknowledged. Caches can
finish posted work after CPU retirement; audio/event stopping has separate
acknowledgements, and remaining devices, IRQ delivery and host queues still
need coordination. This signal must not be treated as permission to save a
coherent whole-machine image.

### Partial memory and DMA drain

The console's experimental option also enables `checkpoint_stop` on both DMA
controllers. It follows the coordinator's internal hold request, including
acquisition and cancellation delivery, rather than the possibly stuck host
request. Lease expiry/abort therefore releases admission after the endpoint
handshake completes.

- New channel admissions stop at IDLE. An ungranted GRANT returns ownership
  without consuming its pending request. A transfer that already started
  continues to completion or its ordinary GX pause boundary. There is no new
  arbitrary mid-word interruption or forced memory acknowledgement.
- Requests already latched while stopped remain pending. In the experimental
  ARM7 configuration, a VBlank/card trigger on the LATCH edge is retained too:
  previously that edge's trigger could be overwritten by the old request's
  consumption. The default-disabled ARM7 configuration is unchanged.
- `checkpoint_stopped` requires IDLE, released ownership, no outgoing request
  or completion IRQ pulse, and (ARM9) no posted main-RAM operation in flight.
  Full transfers can take longer than the acquisition deadline. If memory or
  GX/VRAM acceptance stops responding, capture must fail/cancel rather than
  discard the held word. Posted VRAM traffic still needs draining at its owner.
- This stops admissions, not register/trigger state updates. Event sources must
  be frozen separately before serializing the DMA state. Existing one-bit
  trigger coalescing is not a general event queue.

The ARM9 cache now exports an observation-only idle indication covering its
FSM, queued requests/maintenance, outstanding response and write enables. The
memory bus combines that with its own requests and delayed TCM write/forwarding
slots. It does not invalidate cache contents or alter request/return timing.
Native-mode policy bits are not mistaken for work pending forever.

The console exposes `checkpoint_dma_stopped` and a synchronized
`checkpoint_arm9_memory_idle`. Neither is a complete freeze acknowledgement:
the main-RAM owner, cross-domain requests, VRAM posting, remaining device
events and renderer queues still require their own drain/freeze contracts.
Dirty caches and TCM contents also still need serializers and restore paths.

### Audio and event stopping

The same default-disabled console option connects the internal hold request
to the SPU, both timer groups and the raster timing unit. Each component keeps
register writes live during acquisition: stopping a playback/timing clock must
not discard a CPU/DMA write that the IO bus has already accepted. Their stopped
flags withdraw while the corresponding IO bus is active. They become a stable
snapshot boundary only after every bus master and other event owner is held.

- Audio holds channel timers/decoders, buffer promotion, mixer accumulators and
  the split left/right output phase. The ADPCM table reader and its channel-tag
  pipeline stop together; immutable table initialization can finish first.
- An unowned sound fetch grant is withdrawn without moving its fetch pointer.
  A granted or issued read still finishes, including committing the updated
  fetch-state RAM word. No new read starts from the scanner while stopped.
  A missing response prevents acknowledgement; cancellation preserves the read
  until the real response arrives. Sound `ce` and its bus clock must remain
  enabled for this drain. No memory completion is fabricated.
- The raster counter holds its exact cycle/line. Already emitted registered
  IRQ/draw pulses clear on the next clock, after downstream consumers can
  receive them once. DISPSTAT and queued VCOUNT writes still work.
- Timer prescaler/counters hold. Their IRQ and cascade outputs describe the
  *next* counter edge, so both are suppressed while that edge is suspended.
  The counter/start-delay state retains a pending overflow for resume. Timer
  start/stop writes still update control state while `ce=1` during acquisition.

The console exports `checkpoint_sound_stopped` and `checkpoint_timing_stopped`
(both timer groups plus raster). They are partial status only, not a replacement
for the CPU hold, memory-owner drain or IRQ/CDC/renderer freeze. None of these
devices has a complete serializer/restore interface yet. Audio output muting
and restoration of the physical output path also remain integration work.

Do not force a sleeping CPU awake to obtain a branch checkpoint or discard its
prefetched instructions. Those would change the guest state. The optional
pipeline extension serializes the actual fetch and decode registers instead.
The barrier refuses unsupported capture conditions and releases any peer that
did pause.

The state bus uses **word addresses**, not byte addresses:

| Word address | Contents |
| --- | --- |
| 0 | Next fetch PC: branch target or halted fetch position; restore uses boot PC shadow |
| 1–16 | Current r0–r15 |
| 17–18 | CPSR/SPSR readback; writes are ignored (restored through mixed/banked words) |
| 19–45 | User, FIQ, IRQ, supervisor, abort and undefined banked registers/SPSRs |
| 46 | Halt, NZCV, Thumb, CPU mode, IRQ/FIQ masks |
| 128–130, ARM9 | CP15 control, DTCM and ITCM configuration |
| 131–138, ARM9 | Eight protection-unit regions |
| 139–146, ARM9 | PU cache/write-buffer/permission controls, cache lockdown and PID |
| 147, ARM9 | CPSR.Q in bit 0 |
| 148, both | Open-bus last-read value |
| 160–169, optional | Complete registered decoder controls, ready flag, decode PC and buffered instruction |
| 170, optional | Already fetched instruction word |
| 171, optional | Fetch-ready and first-fetch flags |

The branch-only format exports 68 ARM9 / 48 ARM7 words. The halted-pipeline
format exports **80 ARM9 / 60 ARM7 words**. A halted next-fetch PC is ahead of
pending instructions, so rewinding or restoring the PC alone is insufficient.
All pipeline words must be restored while reset and restore are held.

`tools/suspend_resume/pipeline_layout.py` defines the packed pipeline ABI.
`generate_pipeline.py` verifies coverage against every registered decoder
signal and checks the generated read/load/reset muxes. The excluded `decode_data`
is combinational, halt is in word 46, and unhalt is constrained to zero at capture.
Execution state machines must be idle at the halted boundary; this format is
not a general mid-instruction snapshot. The format remains an experimental
component ABI, not a supported user save-state format.

## Persistence proof

`tools/suspend_resume/capsule.py` wraps the captured CPU words in a bounded,
versioned file with exact program/build/component identity and a SHA-256 digest.
It validates everything before returning any state to a restore consumer.
Writes go to a temporary file in the same directory, are flushed and read back,
then replace the single slot atomically and sync the directory. A failure before
replace leaves the previous slot intact; failure after replace means durability
is unconfirmed and the caller must not exit the running machine.

The developer harness serializes slot access. Its identity hashes the authored
instruction fixture and the exact RTL/simulator inputs; it does not claim to
identify a deployed FPGA image. Full-machine images are explicitly unsupported
and rejected. The magic includes `CPU-PROOF` to prevent confusing this file with
a future game-state format. No launcher or device connection invokes this tool.

## Validation

Run:

```sh
bash tools/test_cpu_checkpoint.sh
```

The script runs in the existing `nds4mister-nvc-arm64:1.22.1` container with
network disabled and source mounted read-only. Generated files stay in a
private temporary directory.

- 48 capture/restore pairs: ARM9 and ARM7, ARM and Thumb, memory response delays
  1 and 11, clock-enable periods 1 and 5, and three request phases. Every pair
  passes through the checked capsule and a fresh simulator process.
- Four additional fresh-process restores capture the ARM-to-Thumb BX transition
  itself. ARM-loop captures verify the BL link-register write has retired.
- 16 additional branch restores enable the halted-pipeline extension, checking
  both instruction sets, memory delays and CPU-enable periods.
- Each restored run completes at least 30 counter/flags/PID iterations. ARM7
  uses an authored register value in the PID position (it has no CP15).
- Captured state remains stable while held; cancelling both an acknowledged
  hold and a DMA-blocked request preserves subsequent progress.
- Every CP15 configuration field is seeded away from reset defaults where
  practical, and all exported architectural words are compared after restore.
  Deliberately omitting the extended state fails the test.
- Native/direct boot reset checks pass. Ten persistence tests cover identity
  mismatch, all four component formats, every truncation boundary, corruption,
  version, incomplete state, failed write/fsync and symlink refusal. Pipeline
  validation rejects invalid enum/range/reserved bits even with a valid checksum.

Existing regression suites also exercise console sleep, ARM9 load addressing
with DMA/IRQ/clock-enable overlap, ARM9 WFI return, and ARM7 HALT/prefetch
interworking. These are component/simulation checks, not a gameplay or sound
qualification of persistent suspend.

Run the paired-CPU barrier checks separately:

```sh
bash tools/test_checkpoint_coordinator.sh
```

The 108 cases use three unrelated clock periods, memory delays 1 and 11,
CPU-enable periods 1 and 5, and three request offsets. They cover successful
hold/release/retry, DMA blocking either CPU, ARM9 WFI, ARM7 HALT, a branchless
ARM9 path, cancellation before delivery, stale release acknowledgements and a
stopped endpoint clock. Counter stores check continued execution without
duplicates or omissions. Sleeping paths retain their original halt and wake
after cancellation. The HALTCNT fixture is a toy adapter with NOP padding, not
a cycle-accurate console IO model. Existing dedicated HALT tests retain their
separate scope. A negative control that skips delivery acknowledgement must
fail the stopped-clock test. Simulation does not model physical metastability
or establish CDC placement/timing closure.

With the halted-pipeline extension enabled, another 24 paired-CPU cases accept
and release an ARM7 HALT or ARM9 WFI without waking the sleeping CPU during the
hold. The same scenarios time out with the branch-only format.

Another **96 real-CPU transport/lease cases** vary the same memory delays,
clock-enable periods and request phases. They read all 80 ARM9 and 60 ARM7
words, change command inputs after acceptance, reject invalid addresses and
epochs, cancel pending reads, recover from stopped read clocks, expire lost or
stale host leases, invalidate a read during lease expiry, and reset both domains
during a read. Subsequent counter stores verify resumed CPU progress. Negative
controls deliberately accept stale keepalive epochs or skip read-handshake
draining and must fail. The existing 132 coordinator cases remain passing.

DMA/cache drain checks:

```sh
bash tools/test_checkpoint_dma.sh
bash tools/test_nds_dma9_mainram_fast.sh
bash tools/test_dma9_gx.sh
bash tools/test_nds_cache_instruction_return.sh
```

- 12 DMA configurations cover both CPUs, three response latencies, VBlank/card
  triggers, cancellation before grant, active drain, queued repeats, LATCH-edge
  trigger collisions and unavailable memory. Lost-pending and lost-LATCH-event
  negative controls fail as expected.
- 216 default-disabled and 216 enabled DMA9 transfer cases cover fast/fallback
  lanes, 16/32-bit words, fixed/increment/decrement addressing and pair offsets.
  A stop before admission and during an active transfer must retain exact data,
  write counts and completion ownership. GX/VRAM tests also check held words
  during backpressure, drain and cancellation.
- Four direct-session cache cases cover early critical-word returns, background
  fills, dirty maintenance, request attribution and deferred TCM writes. Both
  warm instruction streams still return 128 words in 128 modeled clocks.
  Two native-mode smoke cases use its existing uncached-data policy and verify
  eventual idle after I-cache fills, data traffic and TCM writes.
- Deliberately reporting cache idle early or omitting delayed TCM state fails
  the new tests. Existing sound/DMA yield and GX-overlap regression checks pass.
  These are functional/model timing results, not a hardware speed comparison.

Audio and timing stop checks:

```sh
bash tools/test_checkpoint_sound.sh
bash tools/test_checkpoint_timing.sh
bash tools/test_nds_sound_dma_yield.sh
```

- Seven audio configurations cover PCM8, PCM16, ADPCM (direct and RAM tables),
  PSG/noise, 1/16 channels and memory delays of 1/4/31 clocks. Each compares
  600 stereo pairs against uninterrupted playback, including a full 64-word
  ADPCM loop. Independent per-channel fetch-address checks detect repeated or
  skipped words. Stops cover ungranted/granted/issued/completing reads, withheld
  responses, mixer slots 16/17, repeated holds, register writes and common reset.
- Four timing configurations cover all timer prescalers, cascades, overflow
  edges, register writes while stopped and existing sleep/CE behavior. Each
  compares 1,130,000 virtual clocks against the old CE-paced reference,
  including more than two frames, raster IRQs and all draw/lifecycle pulses.
- Negative controls discard a sound response, let the mixer run while stopped,
  leave timer IRQs unmasked, run a held counter or stretch a raster IRQ. All
  must fail. Six existing sound/DMA-yield cases also compare a checkpoint-enabled
  but unrequested SPU with the disabled implementation cycle by cycle.

These tests establish pause/drain behavior in simulation, not persistent audio
or device restoration, full-console capture, FPGA timing or gameplay speed.

Run the sleeping-CPU persistence checks:

```sh
bash tools/test_halt_checkpoint.sh
```

- 192 ARM7 capture/fresh-process restore pairs use the real CPU, memory bus and
  HALTCNT system-control RTL. They vary ARM/Thumb execution and return modes,
  IRQ masking, weighted post-HALT operations, DMA pauses and request timing.
- 18 ARM9 WFI pairs vary memory latency, wake timing and IRQ masking. The
  prefetched BX must return to its caller after wake/IRQ handling.
- Nine further ARM9 pairs change the RAM word holding the already decoded BX
  after capture. A masked wake must execute the saved instruction, preserving
  the distinction between prefetched code and current memory contents.
- Every pair passes through the checksummed capsule and a fresh simulator
  process. Omitting the pipeline deliberately fails both CPUs' resumed guest
  behavior, even when the pipeline readback comparison is skipped.

The earlier branch-format capsule code also passed its nine tests on the
MiSTer's Python 3.9.6, then wrote, synced, atomically replaced and read a test
slot from a fresh process on the SD-card filesystem. Temporary test folders
were removed. The FAT mount
reports mode `0755` despite `fchmod(0600)`; POSIX per-file permissions cannot be
assumed there. This verifies file operations only, not power-loss durability or
capture/restore of a live FPGA. No NDS session or ordinary game save was used.

## FPGA resource measurement

Use `tools/suspend_resume/measure_area.py --runtime QUARTUS_ROOT
--udev-shim SHIM --output NEW_OUTPUT_DIRECTORY` to reproduce isolated Quartus
17.0.2 mappings. Add `--halt-pipeline` to measure the optional pipeline format.
The output directory must be outside the source checkout.
The script freezes its source inputs and records their hashes before mapping.
It uses Cyclone V 5CSEBA6U23I7, area optimization and one mapper worker.

Completed mapping results:

| CPU / implementation | Registers | Mapped logic cells | DSP blocks |
| --- | ---: | ---: | ---: |
| ARM9, checkpoint disabled | 3,074 | 8,379 | 9 |
| ARM9, initial shadow-bank checkpoint | 4,965 | 11,731 | 9 |
| ARM9, retained direct-load checkpoint | 3,128 | 9,905 | 9 |
| ARM7, checkpoint disabled | 2,264 | 6,395 | 6 |
| ARM7, initial shadow-bank checkpoint | 3,524 | 8,530 | 6 |
| ARM7, retained direct-load checkpoint | 2,296 | 7,314 | 6 |
| ARM9, direct load plus halted pipeline | 3,142 | 10,164 | 9 |
| ARM7, direct load plus halted pipeline | 2,311 | 7,584 | 6 |

Across both isolated CPUs, direct loading reduces the added register count from
**3,151 to 86**, and the added mapped logic-cell count from **5,487 to 2,445**.
Disabled mappings retain the same counts before and after this change. No DSP
or block RAM is added by these probes.

Adding the halted pipeline to direct loading adds **29 registers and 529 mapped
logic cells** across both CPUs. Total overhead versus disabled is 115 registers
and 2,974 mapped logic cells. Both disabled CPU mappings still match the earlier
baseline counts. The full-core cost and performance remain unmeasured.

These are **mapped logic cells, not final ALMs**. Mapping does not establish
full-core fit, routing, timing or gameplay throughput. The probe contains only
one CPU and its external interfaces, with virtual pins. It omits console
memories, caches, peripheral snapshots, host transport and coordination.
The wildcard virtual-pin assignment also produces ignored-assignment warnings
on internal nodes; all four retained mappings completed with zero errors.
The initial shadow-bank implementation is retained only in private measurement
evidence, not as a second maintained implementation in this branch.

## Remaining state coverage

| Owner | Needed before a game can resume | Current status |
| --- | --- | --- |
| Both FPGA CPUs | Registers, banked state, valid resume boundary | Branch and idle HALT/WFI proofs; optional console CPU-only read wiring; host/restore integration missing |
| ARM9 memory island | TCM contents, I/D cache data/tags/dirty state, write buffers | Explicit idle observation tested; serialization missing; invalidation is not equivalent |
| Shared memory | Main RAM, WRAM, VRAM, palette, OAM and ownership/mapping registers | Missing |
| FPGA devices | DMA progress, timers, IRQ, IPC/FIFOs, cartridge/save-chip transactions, SPI, math units, timing counters | DMA drain and timer/raster stop tested; remaining owners, coherent freeze and serializers missing |
| Audio | Voice state, playback position, FIFOs, capture/mixer state and output phase | Playback stop and accepted-refill drain tested; serialization/restore and output integration missing |
| ARM graphics helper | GPU/VRAM mirrors, partial GX commands, replay queues, display capture, paired publication and worker state | Existing melonDS serializers are only a starting point |
| RTC/input/host | Clock offset/elapsed-time policy, touch/input state, save-file isolation, exact package identity | Existing clock persistence is separate; checkpoint integration missing |
| Coordinator | Common machine epoch, bounded pause/abort, restore ordering, capability gate | CPU-pair barrier, lease and read transport tested; device freeze, host connection and restore ordering missing |

Current H3D lifecycle quiesce **destroys the renderer** before acknowledgement;
it is a session-exit operation, not a checkpoint. A full melonDS emulator state
also cannot substitute for the live FPGA CPUs/peripherals. Restoring a frame or
RAM dump alone is therefore deliberately not exposed as Resume.

## Next acceptance gates

1. Extend the optional CPU-only console wiring into a coherent machine freeze.
   Combine the tested DMA/audio/event stops and ARM9 idle signals with memory
   owners, remaining device events, IRQ and lid-sleep control, verifying no pending
   access or interrupt is dropped. Connect the bounded read transport and host
   lease to the host control plane, and qualify the full console path. Preserve
   delivery/release handshakes and keep all endpoint clocks running.
2. Add memory/cache and device coverage, then a renderer-preserving checkpoint
   path. Do not reuse the destructive H3D session quiesce. Validate complete Main
   and Touch publication together and invalidate only disposable host caches.
3. Require exact ROM plus FPGA/host/helper hashes and complete component coverage
   before presenting a user control. Define RTC elapsed-time behavior using the
   existing offline-clock rules rather than silently rewinding wall time.
4. Fit and route the private checkpoint build. Compare throughput and pacing to
   rc9 at 1 GHz; source-level clock-enable equality is not a hardware performance
   measurement.
5. With isolated game saves, suspend Castlevania and NSMB, exit to Menu, relaunch
   the same build and resume. Check gameplay, touch/input, audio, RTC and a normal
   save/reload. Only then attempt a power-cycle resume.

No hardware suspend/resume or power-cycle test has passed for this experiment.
