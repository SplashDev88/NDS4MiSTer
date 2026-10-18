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
status, audio drain/pause, raster/timer event stopping and memory-owner drain
observers, including the ARM7 bus and shared WRAM. IRQ and IPC observations
also verify that accepted events have settled without clearing pending flags
or messages. Cartridge/SPI stops retain partial transactions and drain issued
backing requests. Input levels can be held, the live RTC can produce a coherent
calendar/subsecond sample, and the product DIV/SQRT unit exposes retirement
status. An optional common acquisition controller combines local observations
with a required external-owner handshake and takes the final RTC sample after
those owners settle. The real renderer/storage ownership path is still missing; these partial signals do not authorize a whole-machine checkpoint.

The connected console test now adds active DMA on both CPUs and three audio
formats, comparing the resumed audio sequence to an independent uninterrupted
SPU. The first non-CPU restore components also preserve interrupt enable/pending
state, timers, IPC queues, both DMA controllers and audio across fresh simulator
processes. These ports remain unconnected to the console control plane; whole-machine persistence
still needs the other owners.

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
no user-facing control. An authored-console simulation now exercises this
wiring under common ownership; hardware capture remains unqualified.

`checkpoint_pair_paused` says only that both CPUs acknowledged. Caches can
finish posted work after CPU retirement; audio/event stopping has separate
acknowledgements, and remaining devices, IRQ delivery and host queues still
need coordination. This signal must not be treated as permission to save a
coherent whole-machine image.

### Optional common acquisition contract

`CHECKPOINT_OWNERS_ENABLE=true` adds two owner groups to the existing bounded
CPU barrier: local console devices and external host/storage/renderer work.
It requires `CHECKPOINT_CPU_ENABLE=true`, both FPGA 2D drawers disabled and the
debugger disabled. This matches the intended ARM-rendered experiment; supporting
live FPGA drawers would require their complete state/hold protocol too.

The shipping wrapper does not expose or enable these ports. External status and
math idle default to zero, so simply enabling the option cannot report a common
capture. **The external owner implementation and enabled full-console gameplay
qualification are not complete.** `checkpoint_owners_paused` is a protocol
result under those input contracts, not a complete persistent image or a new
save-state capability.

- `nds_checkpoint_coordinator` now accepts an owner count (two by default).
  Acquisition, timeout, delivery, release and host lease cover every owner.
  `nds_checkpoint_cpu_capture(REQUIRE_OWNERS=true)` uses four owners and permits
  CPU reads only while both extra groups are also held. Its historical
  `pair_paused` output is more strictly qualified in this mode.
- `checkpoint_owner_request` follows the internal request through acquisition
  and cancellation delivery. The external endpoint returns a delivery receipt
  independently of its stopped acknowledgement. Receipt must be generated by
  running hardware after its CDC delivery, **not by waiting for ARM software**.
  Otherwise a missing host could strand delivery cleanup. High/low receipts and
  acknowledgements must all drain before the next attempt. A stopped endpoint
  clock reports `release_stalled`; no successful release is invented.
- Losing a synchronous local/external acknowledgement or receipt immediately
  invalidates capture reads, including a reply arriving on the same edge. A
  latched violation prevents a one-cycle loss from reopening the current
  attempt before the coordinator receives it. Lost receipt/status aborts the
  shared hold; a high caller request cannot silently retry it.
- The local group combines CPU-memory, DMA, audio, timer/raster, cartridge/SPI,
  IRQ/IPC, input and graphics-source status. Additional console predicates include related-clock
  request/return toggles **and** their receiver pulses, DMA fast lanes, IO/GX
  and H3D source completions, boot/loader/debug/BIOS writes, palette/OAM clearing
  and sleep propagation. The clk2x predicate includes the product math idle
  input and crosses through two registers. These are observations, not new
  admission gates. The enabled authored-console test now exercises CPU memory
  and IO traffic, graphics backpressure and common capture through these
  predicates. Active DMA/audio/cartridge/SPI/math work and a real external
  renderer/storage owner still require joined-console coverage; individual
  component tests do not establish that coverage.
- `nds_checkpoint_console_guard` waits for both CPUs, all local observations,
  external receipt/stopped status and three quiet control-clock edges before
  requesting the RTC sample. The RTC's own settled-sample acknowledgement then
  completes the local group. Any qualifying owner loss withdraws that request.
  The live clock still advances. An elapsed-time reference and complete RTC
  serial state still need inclusion in the eventual persistent image.

The external owner must exclude incompatible host operations, including ROM or
BIOS replacement and RTC seeding. It must account for accepted backing-memory
requests, firmware/save persistence and frozen backing bytes, H3D queues and
partial commands, ARM worker state and paired display publication. The existing
destructive renderer session-exit acknowledgement is unsuitable. Neither a
quiet SPI byte nor a clean cache line substitutes for this combined ownership.

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
remaining cross-domain requests, device events and host renderer queues still
require their own drain/freeze contracts. Memory-owner observations described
below now cover main RAM, VRAM, the ARM7 bus/private writes and shared WRAM.
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

### Cartridge and SPI stopping

Both owners have default-disabled `EXPERIMENTAL_CHECKPOINT` support. The
console exposes `checkpoint_card_stopped` and `checkpoint_spi_stopped` as
partial owner acknowledgements. New register accesses remain live during
acquisition and immediately withdraw the corresponding acknowledgement.

- The cartridge freezes ROM pacing, new word publication and new prefetch
  requests. An issued backing request still lands in its original queue slot.
  Busy transfers, queued words and a published but unconsumed word are retained;
  no fake data-port read is used to finish a block. A data-port read already
  accepted during acquisition still consumes exactly one word and emits its
  ordinary completion IRQ if it was the final word.
- A flash erase pauses between byte issues. Its address/count remain intact,
  while an already emitted write commits and its write notification retires.
  An accepted AUXSPI byte finishes its busy countdown. The observer also waits
  for the active backup-cache address to become ready. This is a **local**
  boundary: dirty backing-cache contents and external persistence transactions
  still need their own snapshot/durability contract.
- The console stops the cartridge only after both DMA controllers acknowledge
  their admission stop/drain. This lets an admitted DMA finish receiving data;
  a word-ready trigger arriving during acquisition remains pending for resume.
  Cartridge clock enable must remain active while accepted work drains.
- Product SPI finishes an accepted byte, including its real firmware read/write
  response, chip-select release pulse and IRQ. Command/address, PM registers,
  touchscreen conversion and microphone history survive the stop. `fw_busy`
  belongs to the external firmware cache; local SPI acknowledgement does not
  mean its dirty data is durable or its host traffic has stopped.
- SPI holds the last observed lid state. After release it samples the current
  physical lid and emits the usual reopen IRQ if appropriate. Transient lid
  changes entirely inside the hold are not replayed as an event log. The
  console now holds the corresponding key/touch/microphone levels too, as
  described below. Common acquisition/release ordering still needs integration.

A missing backing response prevents acknowledgement. Cancelling the stop
preserves the outstanding request and permits normal progress when the real
response arrives. Common reset invalidates the acknowledgement. No complete
cartridge/SPI serializer or persistent restore path is implemented yet.

### RTC, physical inputs and math retirement

The clock is a battery-time exception to the gameplay hold. The default-off
RTC extension **does not stop or rewind the running calendar**. It samples all
seven date/time bytes and the subsecond divider on one edge, after four quiet
bus edges and a settled seed synchronizer. Both values describe the state
before that sampling edge. The sample remains stable even across midnight;
reset, request withdrawal, any guest bus access or a newly synchronized seed
revokes it. Serial commands, partial input/output bytes, guest date edits,
reset retention and offline startup retain their original behavior.

In CPU-only mode this remains a local timestamp requested during acquisition.
The optional common-owner mode now requests it after the other owners settle.
The host still needs to pair that final sample with an elapsed real-time
reference. Host seed ownership must be held separately: this observer
cannot prevent a seed from arriving after synchronization. RTC serial/status
state still needs serialization, including a partial read buffer that must not
be replaced by the later live time. Restore catch-up and the existing offline
clock policy have not yet been joined to a suspend image.

`nds_checkpoint_inputs.vhd` captures one 31-bit word containing all twelve
buttons, touch X/Y and activity, lid and microphone-blow levels. The console
uses that word for KEYINPUT, EXTKEYIN and SPI. Normal operation and the disabled
configuration remain combinational. During a hold the sampled levels are
stable. Withdrawal exposes the current physical controls immediately; changes
made entirely during the hold are not replayed. SPI retains its own previous-lid
history so reopening after release follows its existing interrupt behavior.
The request must be low for a clock edge between captures; the CPU coordinator's
release handshake provides this interval. No persistent input restore is wired.

The live product uses `nds_nitro_arm9_math_unit.sv`, not the older
`nds_arm9_math_unit.sv`. Its observation-only `checkpoint_idle` excludes new
requests, outstanding MMIO replies, completion pulses, transaction-signature
guards and both running arithmetic engines. The engines finish using their
original clock/credit path; zero or invalid credits keep architectural BUSY
asserted. The island already supplies real credits continuously, so stopping
CPUs need not strand accepted arithmetic. No arithmetic or bus timing changes.
The new clk2x status is still only an internal island wire. The console now
has a qualified crossing for its corresponding input, but the mixed-language
wrapper has not yet connected that wire to the optional common barrier. Math state read/restore is missing.

### Graphics event clock and queue drain

The default-off `CHECKPOINT_ENABLE` option in `nds_h3d_console_event_gate`
provides a separate source-owner contract. A checkpoint request alone does not
stop its timestamp: both CPUs, DMA, raster/timers and the console source fabric
must first report stopped. Any live GPU/VRAM source or timing pulse keeps the
clock advancing and revokes readiness immediately. Accepted records continue
through the original ready/valid paths; acquisition does not clear a queue or
change architectural posting credit.

`checkpoint_stopped` requires empty GPU posting and overflow-skid stages, both
VRAM stages, the frame queue and the selected HBlank queue. The compressed
HBlank queue's real pending count participates, rather than its unused legacy
counter. Two quiet edges allow empty-queue housekeeping to settle before
acknowledgement. The timestamp stays frozen while the queues drain and during
the hold; cancellation resumes it immediately. Frame/scanline epochs retain
normal accepted-pulse behavior.

A stream fault prevents acquisition even after surviving records drain.
`service_ready=0` is the existing **destructive session reset**, not a pause.
It withdraws readiness and poisons the current request until release, including
a one-cycle interruption followed by apparently empty queues. The external
owner must keep the service alive and consume already posted records until
`checkpoint_local_idle` qualifies, before acknowledging its own held state.
It must also exclude destructive host commands for the entire attempt.

The console's optional common barrier includes this fifteenth local owner and
exports `checkpoint_graphics_stopped`. This does not freeze or serialize the
external packet writer, partial GX parser, ARM renderer, publication buffers or
backing memory. A drained local event source is only one part of that larger
ownership contract. No graphics state restore has been implemented.

### IRQ and IPC retirement observations

The interrupt controllers and IPC owner now export observation-only
`checkpoint_idle` outputs. The console exposes `checkpoint_irq_idle` (both
CPUs) and `checkpoint_ipc_idle` when its experimental option is enabled.
Neither observation stops sources, blocks bus accesses or authorizes capture.

- The IRQ observer requires every currently asserted source bit to be latched
  in IF, and the registered IRQ/wake outputs to agree with IME, IE and IF.
  A held level source, such as GX, may remain asserted once its flag is latched.
  Requiring all source lines to go low would reject that valid local boundary.
  New unlatched bits, active register accesses/reset, and the output cycle after
  an IME/IE write revoke idle. Pending IF bits and HALT wake semantics remain
  intact, including a source asserted during write-one-to-clear.
- IPC requires both buses quiet, emitted pulses retired and all four IRQ edge
  history bits settled. Enabling a FIFO interrupt can create an event on the
  following cycle, after the original bus write is gone; an empty pulse vector
  alone is insufficient. Nonempty or full queues are allowed. No queued word,
  pointer, last-read value or error flag is cleared to obtain idle.

The outputs describe a fixed point under the **current** inputs. All remaining
event sources and bus masters must be stopped before treating that fixed point
as a stable checkpoint boundary. IRQ and IPC now have the optional fixed-point
component images described below. Pending guest events and every other owner
must still be part of the eventual complete image.

### Memory-owner drain observations

The memory owners export an observation-only `checkpoint_idle`. They do
not stop admissions, reserve storage for the host, invalidate caches, change
arbitration or stop SDRAM clocks/refresh. The console exposes these as
`checkpoint_mainram_idle` and `checkpoint_vram_idle` only when the experimental
option is enabled. All request producers must already be held before treating
either observation as a stable boundary.

- Main RAM includes queued ARM9/ARM7 requests, the memory FSM, pending return
  strobes and the reservation between a SWP's read and write. Its memory-domain
  observation crosses to clk1x through two registers. Three quiet clk1x edges
  after local retirement/synchronized idle prevent an old idle level from
  surviving a new request; live request inputs revoke the output immediately.
  This uses the existing phase-related `clkMem >= clk1x` contract. It says
  nothing about other clients of the physical SDRAM controller.
- VRAM covers CPU requests, posted writes, BRAM writes, backing requests,
  renderer admissions/completion queues, staged backing/cache-hit replies and
  the last completion pulse. A posted acknowledgement or an empty renderer
  completion queue alone is insufficient. Read-only caches can remain valid;
  this observer does not flush or otherwise change them.
- The ARM7 bus includes external-memory waits, IO alignment, direct private
  WRAM/Wi-Fi writes, delayed baseband commits and completion cycles that can
  accept a new request. The console's `checkpoint_arm7_memory_idle` also
  excludes private-WRAM loader writes and a busy loader. Shared WRAM waits
  for both ports' admission and registered completion strobes to clear;
  `checkpoint_shared_wram_idle` is masked during CPU reset.

Remaining clock crossings, loader/debug ownership and external host/rendering
queues still need inclusion in a common machine hold. No RAM/VRAM/TCM/cache
serializer or restore path is provided
by these status signals, and no global `machine_held` claim is exposed.

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

### Interrupt component capture and restore

`nds_irq(EXPERIMENTAL_CHECKPOINT=true)` adds a default-off, **component-only**
read/restore port. Neither console IRQ instance enables or connects it yet.
The provisional image contains three 32-bit words: address 0 is IME (bit 0
only), address 1 is IE and address 2 is IF. Capture is valid only at the existing
IRQ fixed point with normal restore inactive; the caller must keep every IRQ
source and bus master held across all reads. Invalid addresses return no data.

Assert `checkpoint_restore` only with the device and CPUs held in reset. Write
all three words using `checkpoint_address`, `checkpoint_write_data` and a
clocked `checkpoint_write`. Any order is permitted. This reuses the live IE/IME
registers and IF accumulator; it does not allocate a second register image.
The internal register bus suppresses its ordinary reset while loading so gaps
between writes do not erase earlier words. IF loads directly, bypassing its
normal guest write-one-to-clear behavior.

`checkpoint_restore_ready` requires all three distinct words, no error, no
active write and settled IRQ/unhalt outputs. Those outputs are reconstructed
from IME/IE/IF **while reset remains held**, so the first resumed CPU edge sees
the pending interrupt from the captured fixed point. They are not separate
image words because capture excludes transient output latency. Readback is
available when restore is ready. Zero-valued words still require actual writes.

An unsupported word, nonzero reserved IME bits or a restore attempt without
reset raises `checkpoint_restore_error`. Invalid attempts stay invalid until
`checkpoint_restore` is low for a clock edge, and a new attempt requires all
three words again. Live checkpoint writes do not modify IRQ state. The caller
must keep the machine in reset after a rejected or incomplete restore and either
start a fresh complete load or clean boot; this local port cannot enforce a
whole-machine reset policy. Release reset and restore together only after the
**entire** machine image, identity and all owners are validated.

`tools/test_checkpoint_irq_restore.sh` records state and a 513-step continuation
from normal execution, then loads that state in fresh simulator processes.
Thirty-six restores cover all six write orders, enabled/masked interrupts,
zero IE/IF, held level sources, byte writes, simultaneous acknowledgements and
new sources, and clock-enable stalls. Missing words, unsupported addresses,
reserved bits and writes to a live device are rejected. Five deliberate faults
lose IF, accept incomplete coverage, erase earlier IE/IME writes, omit pending
IRQ reconstruction or allow live writes; each is detected. IRQ/IPC comparison
against the pinned pre-experiment RTL also passes with IRQ capture disabled
and enabled but unrequested.

The test files are private simulator fixtures, not a supported on-device state
file format. This does not provide a whole-image parser/checksum, host command,
console restore wiring or a gameplay beta.

### Timer component capture and restore

`gba_timer(EXPERIMENTAL_CHECKPOINT=true)` now exposes a 13-word image for its
four timers. This reuses the existing default-off checkpoint switch; the console
still leaves the new read/restore ports unconnected. The legacy partial savestate
registers are not used to restore this image.

| Address | State | Defined bits |
| --- | --- | --- |
| 0 | Shared prescaler phase | 9:0 |
| 1 + 3 × timer | Reload and control registers | Reload 15:0; prescaler 17:16; count-up 18; IRQ enable 22; start/stop 23 |
| 2 + 3 × timer | Live counter and guest readback | Counter 15:0; readback 31:16 |
| 3 + 3 × timer | Execution flags | `timer_on` 0; `startwait` 1 |

The timer index is 0–3. Capture requires the existing stopped acknowledgement,
no live register write/reset, and restore inactive. The common owner must hold
all bus masters across the reads. The readback value is saved independently:
normal reset can leave it different from the live counter. A pending start and
an overflow/cascade poised for the next edge must also survive.

Restore requires reset and every distinct word, including zero-valued words.
Words may arrive in any order with gaps. Existing live reload/control registers
are reused; their internal bus reset is suppressed during loading, and normal
start/reload side effects are bypassed. Counter, readback, phase and flags load
directly. IRQ/cascade outputs stay masked throughout active reset-held loading,
then resume from the preserved state when the common stop releases. Diagnostic
counter outputs are not guest state: their existing two-edge pipeline settles
from the saved readback while the machine remains held.

Unsupported addresses, reserved bits or a live restore attempt poison the
attempt until restore is withdrawn for a clock edge. Ready requires all 13
words, no error or active write, and no register write in progress. Invalid or
incomplete images never authorize CPU release. The caller owns the complete
machine validation/reset policy; after failure it must load a fresh complete
image or perform a clean core reload. The private ports on `gba_timer_module`
are validated by the parent `gba_timer`, not a separate host interface.

`tools/test_checkpoint_timer_restore.sh` records normal execution and checks
36 fresh-process restores in ascending, descending and interleaved word orders.
Each compares 8,705 observations of guest reads, IRQ/cascade events and diagnostic
outputs. Cases cover all four prescalers, pending overflow, cascades, a pending
start, stopped timers, distinct counter/readback, all-zero state, byte writes and
clock-enable stalls. Six deliberate faults discard prescaler/start/readback,
erase registers between writes, accept partial coverage or allow live writes;
each is detected. The existing timing/event-stop comparison and complete console
VHDL analysis remain required. This is component persistence, not whole-console
or on-device resume.

### IPC component capture and restore

`nds_ipc(EXPERIMENTAL_CHECKPOINT=true)` adds a default-off, 36-word component
image. The console does not yet enable or connect this interface. Capture is
valid only at the existing fixed point: both buses quiet, all six emitted IRQ
pulses retired and four FIFO interrupt histories settled. Nonempty and full
queues remain valid capture states.

| Address | State |
| --- | --- |
| 0 | Sync outputs 7/9 in bits 3:0/7:4; sync IRQ enables 8/9; FIFO enables 10/11; send-empty IRQ enables 12/13; receive IRQ enables 14/15; error flags 16/17 |
| 1 | Counts 79/97 in bits 4:0/9:5; read/write pointers 79 in 13:10/17:14 and 97 in 21:18/25:22 |
| 2, 3 | Last-read words for ARM7 and ARM9 |
| 4–19 | All sixteen physical words in the ARM7-to-ARM9 FIFO |
| 20–35 | All sixteen physical words in the ARM9-to-ARM7 FIFO |

Reserved bits must be zero. Counts must be 0–16 and each ring must satisfy
`write = (read + count) mod 16`. Every word is required, including zero values
and currently unoccupied slots. The current RTL can expose an old unoccupied
slot when an ARM7 send and an ARM9 empty-queue receive share an edge. Zeroing
those slots would therefore change the resumed execution. This implementation
preserves that existing behavior; it does not change the IPC hardware model.
The fixture initializes all physical cells through ordinary guest sends/pops,
not forced state, because uninitialized simulation cells are otherwise unknown.

Reset-held restore writes the live registers and FIFO arrays directly. Words
can arrive in any order with gaps; ordinary bus traffic is ignored under reset.
All IRQ outputs remain zero during loading. The four settled edge-history bits
are reconstructed from counts/enables before ready, so releasing reset does not
invent a new FIFO interrupt. The separate IRQ controllers restore their own IF,
IE and IME values. The common caller must validate and hold every machine owner
before releasing the CPUs.

Unsupported addresses, reserved bits, impossible ring metadata and live restore
attempts poison the attempt until restore is withdrawn for an edge. Ready
requires all 36 distinct words, settled edge history, no error and no active
write. An invalid image never authorizes CPU release. As with other components,
whole-image identity/checksum validation and the reset policy belong to the
future host/console integration.

`tools/test_checkpoint_ipc_restore.sh` records normal IPC execution with both
real IRQ controllers, then restores their combined 42 words in fresh processes.
Twenty-seven restores cover ascending, descending and interleaved writes, full
and wrapped queues, empty retained data, disabled FIFO access, queue clear,
errors, all-zero state and three random traffic seeds. Each compares 4,106
observations at both sides of the bus clock edge, preserving the intentional
ARM7/ARM9 receive sampling difference. Live bus noise during reset, rejected
writes, failed attempts and fresh coverage are also checked.

Nine negative controls detect lost queue data, last-read data or pointers,
premature ready, an extra wake-up, live writes, stale coverage, invalid ring
metadata and zeroed empty slots. The empty-slot corruption passes structural
checks/readback and fails the first resumed send/pop, demonstrating why the
physical storage is part of the image. The default-off and enabled-unrequested
IRQ/IPC paths also match the pinned pre-experiment RTL. This is joined IPC/IRQ
component persistence; no whole-game resume or hardware beta is provided yet.

### DMA component capture and restore

Both `nds_dma7` and `nds_dma9` now expose component images under the existing
`EXPERIMENTAL_CHECKPOINT` switch. The console leaves these read/restore ports
unconnected. Capture requires their drained **IDLE** boundary, no memory or bus
ownership, retired completion/IRQ pulses, no guest register access and quiet
trigger inputs. ARM9 also requires its GX edge history to match the held GX
level. The caller must hold those sources for the entire image read; the older
`checkpoint_stopped` acknowledgement alone does not stop incoming triggers or
CPU register writes.

The first 24 words contain six words for each of four channels:

| Address within channel | State |
| --- | --- |
| 0, 1 | Programmed source and destination, bits 27:0 |
| 2 | Full guest count/control register, including enable, repeat and trigger mode |
| 3, 4 | Current source and destination, bits 27:0 |
| 5 | Pending request in bit 31; remaining count in bits 16:0 (ARM7) or 21:0 (ARM9) |

ARM7's 26-word image finishes with the active-channel index at 24 and data-read
latch at 25. ARM9's 37-word image additionally preserves:

| Address | State |
| --- | --- |
| 24–27 | Four DMA FILL registers |
| 28 | Active index 1:0; GX edge history 2; current/next prefetch valid flags 3/4; GX slice count 11:5; remembered RAM read/prefetch kind 12/13 |
| 29 | Data-read latch |
| 30, 31–32 | Current prefetch block address and its 64-bit data |
| 33, 34–35 | Next prefetch block address and its 64-bit data |
| 36 | Remembered fast-RAM request block address |

Prefetch block addresses occupy 19 bits. No request remains active at capture;
remembered request metadata does not recreate an outstanding transaction.
These images retain both prefetch buffers rather than assuming cached bytes
can be discarded. Bus payload outputs with no asserted enable are not image
state; each new transaction rebuilds those outputs before use.

Restore writes the existing channel registers and buffers directly while reset
is held. It does not replay ordinary enable writes, which would relatch addresses
and clear transfer progress. All image words, including zero values, are required.
Unsupported addresses, reserved bits, out-of-range remaining counts or GX slice
counts, and live restore attempts are rejected. A failed attempt stays invalid
until restore is withdrawn for a clock edge and a fresh complete image is loaded.
The caller must keep the complete machine held after failure or reload the core.
During loading, ownership, memory requests and IRQs stay inactive. ARM9's GX
history is retained through load gaps even if the live input differs; restore
that external source before the common release.

`tools/test_checkpoint_dma_restore.sh` compares 84 fresh-process restores, each
with 16,384 observations of register reads, enabled memory/IO transactions,
ownership and interrupts. Cases include all channels, halfword/word copies,
increment/fixed/decrement addressing, address wrap, queued and repeated
VBlank/card/HBlank work, all-zero state, ARM9 prefetch, posted RAM completion,
credit stalls, and a GX transfer captured after 112 words with 118 still pending.
Ascending, descending and interleaved image writes run at two response latencies.
An independent copy scoreboard checks addresses, data and byte lanes as well as
the recorded continuation. Fifteen deliberate faults cover lost pending requests,
pointers/progress/prefetch/GX history, premature ready, invalid images, live
mutation and capture during an unsettled trigger.

This testing exposed ARM7's existing use of `unsigned + integer` for a negative
DMA step, which selects a nonnegative operand in `numeric_std` and fails in
simulation. Both ARM7 address updates now use the same explicitly signed,
width-limited step as ARM9. Independent decrement and modulo-2^28 wrap checks
cover that correction. Existing DMA stop/drain, ARM9 fast/fallback and graphics
backpressure tests remain required. No gameplay speed or routed timing result
is implied by these component checks.

### Audio component capture and restore

`nds_sound` now has a 270-word component image under the default-off
`EXPERIMENTAL_CHECKPOINT` option. The console leaves its read/restore ports
unconnected. Capture requires the existing playback hold and drained fetch
boundary, no guest register access or memory completion, and an initialized
ADPCM table. Hold the playback request and all guest writers throughout the
read; this is a component boundary, not complete machine ownership.

Each channel occupies 16 words at `channel * 16`:

| Offset | State |
| --- | --- |
| 0 | Stored channel control; hold is bit 15, matching its write field |
| 1 | Sample address, bits 26:0 |
| 2 | Timer reload 15:0 and loop point 31:16 |
| 3 | Programmed length, bits 21:0 |
| 4 | Timer 16:0, subposition 19:17, start delay 21:20, current/next valid 22/23, ADPCM header 24, PSG position 27:25 |
| 5 | Remaining playback words, bits 23:0 |
| 6, 7 | Current and prefetched sample words |
| 8, 9 | Current and loop ADPCM state: signed value 15:0, index 22:16 |
| 10 | Noise generator 15:0 and current signed sample 31:16 |
| 11 | Cached ADPCM step value, bits 14:0 |
| 12, 13 | Next fetch pointer 24:0 and remaining fetch words 23:0 |
| 14, 15 | Reserved zero words, still required for complete coverage |

The fetch pointer/count stay in their existing 49-bit dual-port RAM. Capture
borrows its idle channel-start port. Restore reads the selected row, changes
one field and writes the whole row atomically. There is no new asynchronous
RAM read or duplicate fetch-state bank. The physical port's registered read
must settle: wait for `checkpoint_valid` on reads and
`checkpoint_write_ready` before each write. A write to a newly selected RAM
channel before that acknowledgement poisons the attempt instead of combining
its data with a stale row. Restore now requires the exact ascending stream
0 through 269, so each pointer precedes its corresponding count.

| Global word | State |
| --- | --- |
| 256 | Sound control 15:0 and bias 25:16 |
| 257 | Capture-unit control bytes 7:0 and 15:8 |
| 258–261 | Capture 0 address/length, then capture 1 address/length |
| 262 | Timer cadence bit 0; fetch scan phase bit 1; selected channel 5:2; fetch gap 8:6 |
| 263 | Mixer slot, bits 9:0 |
| 264, 265 | Signed left/right mixer accumulators |
| 266 | Latched master gain 6:0 and bias 16:7 |
| 267 | Completed left-mix latch, bits 15:0 |
| 268 | Last output pair: left 15:0, right 31:16 |
| 269 | ADPCM lookup channel 3:0, delayed channel 7:4 and pending ROM result 22:8 |

The ADPCM lookup's last ROM result is necessary in addition to each channel's
cached step. The first resumed clock consumes the saved result while the real
ROM reader refills; subsequent clocks use the physical reader normally. With
the experimental option, the startup value before the first initialized-table
read is explicitly zero. This makes a suspend before any channel playback
serializable. The immutable step table itself is rebuilt, and ready waits for
initialization. The default-disabled path retains its previous startup behavior.

Restore writes live channel, decoder, mixer and buffer state while reset is
held; it does not restart channels through their normal control registers.
The programmed registers share their normal data input during reset-held
loading. The current sample word is loaded through the existing next-to-current
copy path: word 6 temporarily occupies the next-word buffer, then one held edge
copies it into the current-word register before word 7 supplies the actual next
word. Wait for `checkpoint_write_ready`; no gameplay or fetch advances here.

A nine-bit progress counter replaces 270 individual loaded flags. All 270 words
are required in exact ascending order, including zeros. Duplicate, skipped,
reordered or extra writes poison the attempt. Reserved bits, unsupported
addresses, ADPCM indices above 88, premature RAM writes and live restore
attempts are rejected. An error stays latched until restore is withdrawn for
an edge and a fresh complete load begins. After the last write, two idle edges
settle the restored fetch-channel RAM output before ready. Keep playback held
while withdrawing restore and releasing reset, then use the common machine
release. Failure requires another complete load or a clean core reload;
ordinary reset alone does not clear every RAM and pipeline value.

Diagnostic counters are not guest state. This component does not implement
missing hardware audio-capture behavior, the existing hold-bit functionality,
or additional output-selection modes. The state image stores the actual hold
field directly; the existing guest readback behavior is unchanged.

`tools/test_checkpoint_sound_restore.sh` first compares ten complete capture
images and continuations to the pinned pre-compaction implementation. It then
checks 20 fresh-process restores using ascending writes with short or varied
idle gaps. Each compares 65,536 resumed cycles of stereo
output, register reads and enabled memory requests, plus all 270 image words
after the first resumed edge. The latter catches a lost ROM pipeline result
even when a channel's timer would allow its cache to refresh before decoding.
Cases cover PCM8, PCM16, ADPCM, PSG/noise, looping, delayed reads, saturation,
newly started channels, idle audio, both table implementations and mixer slots
0, 16, 17 and 1023. Fast ADPCM cases additionally exercise the existing lookup
approximation; they test exact continuation of this implementation, not new
hardware-accuracy claims. Eleven deliberate faults cover buffers, the staged
current-word copy, decoder state, fetch pointers, mixer state, pending ROM
output, partial coverage, write ordering, invalid indices, stale RAM rows and
live mutation.

`tools/test_checkpoint_sound_baseline.sh` compares default-disabled and
unrequested-enabled playback to pinned pre-restore source, with both table
implementations. Four runs compare 580,756 clock phases, exercising all formats,
partial register writes, clock-enable stalls, delayed fetches and reset; two
observer faults are detected. Existing stop/drain tests compare another 4,200
stereo pairs to uninterrupted playback. DMA-yield and direct-boot bias checks
also remain required. These are simulation results, not routed timing,
performance or whole-game resume qualification.

A Quartus 17.0.2 audio-only synthesis probe at `7e94517` exposes every checkpoint
port as a virtual pin, using the Cyclone V target and area optimization:

| Audio configuration | Estimated ALMs | Combinational ALUTs | Registers |
| --- | ---: | ---: | ---: |
| Previous hold-only implementation (`41d4351`) | 6,107 | 9,414 | 5,188 |
| Capture only; restore inputs tied off | 7,935 | 11,112 | 5,258 |
| Restore only; capture outputs disconnected | 8,486 | 11,729 | 5,485 |
| Initial complete interface (`7e94517`) | 10,700 | 14,193 | 5,787 |
| Compact complete interface | 9,475 | 13,637 | 5,531 |

All configurations retain 2,704 used block-memory bits and seven DSP blocks.
The compact interface saves **1,225 estimated ALMs** versus the initial complete
interface, reducing its added cost from 4,593 to **3,368 estimated ALMs** (about
27%). It combines ordered coverage with shared register-data inputs and reuse
of the existing sample-buffer copy path. Two alternative capture-mux rewrites
increased ALUT usage and were discarded; the capture image and access latency
remain unchanged.

The isolated-path estimates are not additive. These mappings are not
full-console utilization, fitting or routing results. Virtual-pin and
virtual-clock warnings are expected, and no timing or gameplay-speed result is
inferred. The remaining cost still needs a complete-core resource check before
this can be accepted for a gameplay beta.

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

Memory-owner checks:

```sh
bash tools/test_checkpoint_mainram.sh
bash tools/test_checkpoint_arm7_memory.sh
python3 tools/test_vram_victim_equivalence.py \
  --reference-revision ec553bc6ef1ef19d4dfe4cd638f11d449364506f \
  --checkpoint-idle --output /path/to/new/output-directory
```

- 24 main-RAM configurations vary clock ratios 1/3, phase offsets 0/2 ns,
  response latency 1/4/17 memory clocks and both CPU priorities. Independent
  memory/data/ownership checks cover queued admission, reads/writes, a missing
  upper pair word, both CPUs' SWP gaps with a peer waiting, simultaneous
  requests, a withheld response and reset while accepted work drains.
- Six complete VRAM comparisons use three seeds with posted writes on/off.
  Each checks over 1.1 million clocks, including full reset clearing, all eight
  renderer channels, both CPU ports, cache hits/misses, paired LCDC reads,
  write/fill races and backing stalls. Every pre-existing output and the
  canonical cache records remain cycle-identical to the preceding commit.
  The new idle status is checked independently against client ownership and
  backing work at both clock phases, and must assert after each final drain.
  Ownership accounting starts a new generation after common reset.
- Main-RAM fault injections expose stale idle at admission or drop the SWP
  reservation. Add `--checkpoint-mutant posted`, `renderer` or `completion`
  to the VRAM command (using a separate new output directory) to omit each
  class of work from its observer. All five faulty observers are detected.
  Existing cache critical-word/writeback/SWP checks also pass at five latencies.
- The actual ARM7 bus and shared/private RAM test covers all four WRAM mappings,
  private fallback, simultaneous mapped port writes, 18 external-response
  delays per memory path, IO alignment, BIOS and open bus. The existing Wi-Fi
  register/baseband/RAM suite additionally checks access/completion idle
  exclusion and eventual drain. Two more faulty observers expose pending IO or
  ignore a shared-WRAM completion and are detected.

These are simulations of owner drain and unchanged transfer behavior. They do
not establish physical CDC timing or whole-machine snapshot consistency.

IRQ/IPC retirement checks:

```sh
bash tools/test_checkpoint_irq_ipc.sh
```

- Both CPUs exercise all 32 interrupt bits, held levels, simultaneous source
  assertion and IF acknowledgement, IME/IE output latency, CE stalls and reset.
- IPC checks full queues in both directions, pointer wrapping and exact word
  order after a quiet interval, delayed receive/send-empty IRQs, error/last-read
  behavior and sync IRQ delivery. Full queues become locally idle without
  dropping messages.
- Three seeds add 60,000 randomized cycles of concurrent bus traffic, byte
  enables, level/pulse sources, CE changes and resets. Across the directed and
  random runs, all original outputs match the pre-observer source revision
  `eb7580c` at 133,947 clock phases. A separate temporal check verifies that
  an idle owner has no state/output transition left for the next edge.
- Four faulty observers ignore an unlatched source, the registered CPU output
  delay, IPC edge history or an emitted IPC pulse. All are detected.

This verifies retirement and behavioral equivalence only. IRQ sources and
bus masters still need a common freeze, and no IRQ/IPC image is restored yet.

Cartridge/SPI checks:

```sh
bash tools/test_checkpoint_card.sh
bash tools/test_checkpoint_spi.sh
bash tools/test_checkpoint_card_dma.sh
```

- 36 cartridge configurations cover both CPU owners, prefetch depths 1/4/7,
  backing latencies 1/17/97 clocks and checkpoint exercises on/off. Unrequested
  runs compare every original output with the pre-change `372cba7` RTL at both
  clock phases. Paused runs cover all six transfer FSM states, accepted register
  writes/data reads while held, withheld replies, cancel/retry, page programs,
  a partial 256-byte erase, backing-cache readiness and reset. Independent
  patterns verify every resumed word/address and every erase byte in order.
- 18 SPI configurations cover backing delays 1/97/1500, baud settings 0/3 and
  stop offsets 0/17/63. Every byte drains against the original source's output
  timing, including program 02h/0Ah, delayed reads, RDSR persistence status,
  chip-select release, PM registers, touchscreen and microphone transactions.
  Missing replies/cancellation and held/released lid transitions are checked.
- Six actual DMA/cartridge combinations cover both CPUs and response latencies
  1/17/97. Each transfers 128 independently checked words through repeated
  holds, retaining exact read/write/IRQ counts. An unavailable memory response
  prevents DMA acknowledgement and keeps the cartridge's stop deasserted.
  This uses a modeled ARM7 memory-bus response and actual ARM9 fast IO;
  it is not an enabled full-console simulation.
- Seven negative controls run pacing/prefetch/erase while held, drop a card or
  firmware reply, allow a held lid wake, or stop the cartridge before DMA drain.
  All are detected. Existing back-to-back card and save-transaction regressions
  also pass with the feature disabled.

These prove component stop/drain and resume-after-cancellation behavior, not
persistent cartridge/SPI state restoration, cache durability, timing closure
or gameplay suspend/resume.

RTC/input and math checks:

```sh
bash tools/test_checkpoint_rtc_inputs.sh
bash tools/test_checkpoint_math.sh
bash tools/test_nitro_rtc_vhdl.sh
```

- Six RTC configurations vary simulated second length and host seed timing.
  They compare every original output against immutable revision `62a5907`
  through leap-day/midnight rollover, a multi-second hold, host seeding during
  acquisition, partial serial reads/writes, reset and CE changes. Each accepts
  77 or 78 timestamp samples; calendar and fraction are checked against the
  reference's same pre-edge state. Samples remain stable until revoked.
- 128 input holds exercise every bit, disabled bypass, immediate release,
  reset and recapture. These prove the helper, not a full-console game session.
  Full-console VHDL analysis and the existing island input-boundary simulation
  also pass; the latter does not simulate the VHDL console internals.
- Both math interface modes compare cycle by cycle against `62a5907`, including
  reply tails, concurrent arithmetic, zero/invalid credits, restarts, random
  operand/control accesses, continuous product DMA transactions and reset.
  A temporal check requires architectural state to stay fixed after idle.
  The existing compact DIV/SQRT numeric/timing regression also passes.
- Six negative controls stop the live clock, move a valid timestamp, tear its
  fraction, let held controls change, or report math idle before a reply or
  calculation retires. All are detected. Existing Gregorian/BCD/hour-mode RTC
  tests also pass with the feature disabled.

These checks do not implement RTC/math serialization, elapsed-time restoration,
full-machine capture or a gameplay beta. They make no hardware speed claim.

Common-owner acquisition checks:

```sh
bash tools/test_checkpoint_owners.sh
bash tools/test_checkpoint_coordinator.sh
```

- 44 additional-owner cases use both real CPUs and their read transport, with
  controlled local/host acknowledgement fixtures. They cover delayed memory,
  request phases, blocked owner acquisition, missing high delivery, stale low
  release, one-cycle status/receipt loss, lease expiry, cancelled/late reads and
  common reset. Resumed counter stores detect skipped or repeated execution.
- Eight more runs join both real CPUs, the actual final-stage guard and the
  actual running RTC for full CPU-state reads, timeout, owner loss and lease
  expiry. Other device/storage observations remain fixtures in this test.
- The guard/RTC test independently blocks every local-owner bit, CPU status,
  external receipt and external completion. It checks late timestamp capture,
  a multi-second hold, a fresh sample after cancellation, guest RTC access and
  reset. Receipt remains independent of whether a device can stop.
- Five deliberate faults skip external delivery cleanup, allow a stale read
  permit, reopen a poisoned attempt, ignore a lost receipt or sample the RTC
  before other owners settle. All are detected. The existing 228 CPU-only
  coordinator/transport cases and their three fault controls remain passing.

These tests establish the common controller and timestamp ordering. They do
not alone qualify console-fabric predicates or implement actual host/renderer
freeze, device serialization, restoration or a gameplay beta. The separate
enabled-console test below exercises the connected local path.

Enabled console checks:

```sh
ALTERA_MF_COMPONENTS=/path/to/quartus/eda/sim_lib/altera_mf_components.vhd \
  bash tools/test_checkpoint_console.sh
```

This bench instantiates the actual `nds_nitro_console_top`, CPU cores, loader,
simulation RAM primitives and local devices with both checkpoint options on.
`tools/suspend_resume/console_fixture.py` supplies an authored direct-boot ROM;
there are no game/BIOS dumps. The loader copies and verifies both programs.
ARM9 verifies main RAM, LCDC VRAM, palette and OAM; ARM7 verifies main RAM,
private WRAM and shared WRAM. Both start a timer and exercise keys and IPCSYNC;
ARM7 also reads the RTC port. Counter stores must increase exactly once and a
bad read enters a distinct failure loop, which fails progress/PC checks.
The active-device variant starts repeating PCM8, PCM16 and ADPCM voices and
runs 64-word immediate DMA copies on both CPUs. Authored source bytes are
loaded by the actual HLE loader. Every physical DMA destination word is checked
for address order, data and byte lanes; the guest also verifies both buffer ends.
A pending DMA may leave a CPU paused in its completion-poll branch, which is a
supported CPU checkpoint boundary.

External SDRAM/VRAM/card backing and the host event sink are explicit behavioral
fixtures. The external delivery receipt is independent of host completion.
The host fixture keeps consuming records until local idle and then acknowledges
its hold. The math idle input is justified only by asserting that these authored
programs never request DIV/SQRT; no SystemVerilog math engine is bound here.
Firmware operations and renderer VRAM reads are also asserted absent.

The runner freezes its complete source closure and prints an input-manifest
SHA-256 before starting. `all` runs one baseline smoke plus four active-device
cases; `baseline` and `devices` can be selected separately. The matrix varies
1.5x/2x ARM9 clocks and two memory latencies. Each run makes
four common captures, reads all 80 ARM9 and 60 ARM7 words twice, compares the
stable images, checks PC/R0/R1 against committed memory and requires resumed
progress. It also holds the graphics sink, lets it drain, times out an absent
host and a withheld real SDRAM reply, and expires an acquired host lease.
Cancellation must retain the accepted memory transaction and resume execution.

The active-device cases explicitly request holds during ARM9 DMA, ARM7 DMA,
SPU ownership and an accepted DMA memory operation. A separate withheld SPU
response must time out without fabricating completion. An uninterrupted SPU
reference receives the same observed guest configuration and independent
source-memory responses, but never sees the pause request or the console bus
grants. The resumed stereo samples must match in playback order. Every voice
must fetch past its first complete loop, and hundreds of nonconstant samples
must compare. The final common hold must leave both immediate DMA transfers
complete. No internal owner state or handshake is forced to obtain a pass.

This is a **connected local acquisition/read/release test**, not persistent
restore or a real ARM renderer test. Card traffic is still the loader's authored
ROM reads. Active game-card/SPI/math work, other DMA/audio modes, native boot,
mixed-language backing/cache ownership, host exclusion and complete memory/
device serialization still require integrated qualification.

Graphics source checks:

```sh
bash tools/test_checkpoint_graphics.sh
bash tools/test_h3d_console_event_gate.sh
bash tools/test_hblank_run_queue.sh
```

- 24 configurations cover enabled/disabled checkpoint logic, raw/compressed/
  sparse HBlank, 4/32-entry GPU queues and two request spacings. Independent
  output scoreboards check exact payload, order and original timestamps through
  a full GPU queue plus overflow skid, both stalled VRAM stages, timing queues,
  late producers, cancellation, service loss, reset and frame overflow.
- Seven deliberate defects keep virtual time running, stop it prematurely,
  omit a frame or compressed-HBlank queue, forget a destructive interruption,
  ignore a stream fault or clear work on pause. Each is detected.
- Existing event-gate behavior passes with checkpoint support disabled and
  enabled but unrequested. The compressed-HBlank backlog regression also
  passes. These are simulation results, not routed performance measurements.

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
| Shared memory | Main RAM, WRAM, VRAM, palette, OAM and ownership/mapping registers | Main-RAM/VRAM/ARM7/shared-WRAM drain observations tested; common ownership and all serialization/restore missing |
| FPGA devices | DMA progress, timers, IRQ, IPC/FIFOs, cartridge/save-chip transactions, SPI, math units, timing counters | DMA/card/SPI drain, timer/raster stop and IRQ/IPC/math retirement tested; connected DMA/SPU holds verified; IRQ/timers/IPC/DMA have component restore; other serializers and real external ownership missing |
| Audio | Voice state, playback position, FIFOs, capture/mixer state and output phase | Playback stop/drain and fresh-process component restore tested; console transport, physical output integration and hardware qualification missing |
| ARM graphics helper | GPU/VRAM mirrors, partial GX commands, replay queues, display capture, paired publication and worker state | Existing melonDS serializers are only a starting point |
| RTC/input/host | Clock offset/elapsed-time policy, touch/input state, save-file isolation, exact package identity | Input hold and coherent RTC timestamp tested; complete serial state, elapsed-time restore and host integration missing |
| Coordinator | Common machine epoch, bounded pause/abort, restore ordering, capability gate | Optional common-owner barrier, lease/read guards and final RTC ordering tested; authored enabled-console acquisition/read/release passes; real external ownership, host connection and restore ordering missing |

Current H3D lifecycle quiesce **destroys the renderer** before acknowledgement;
it is a session-exit operation, not a checkpoint. A full melonDS emulator state
also cannot substitute for the live FPGA CPUs/peripherals. Restoring a frame or
RAM dump alone is therefore deliberately not exposed as Resume.

## Next acceptance gates

1. Implement the real external owner behind the optional common barrier and
   extend enabled-console coverage beyond the authored CPU/IO/DMA/audio fixture
   to active game-card/SPI/math and actual mixed-language backing. Exclude host
   loader/debug/seed changes and
   use real backing-cache persistence acknowledgements. Ensure no pending
   access or interrupt is dropped. Connect the bounded read transport and host
   lease to the host control plane, and qualify the full console path. Preserve
   delivery/release handshakes and keep all endpoint clocks running.
2. Extend IRQ/timer/IPC/DMA/audio component coverage to the remaining devices,
   then memory/cache coverage and a renderer-preserving checkpoint
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
