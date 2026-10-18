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
both real CPU implementations together. Sleeping CPUs are currently **refused
by timeout**, not captured; their pending instruction/prefetch state still needs
coverage. This coordinator is not yet connected to the console or host.

`EXPERIMENTAL_CHECKPOINT` defaults to `false` in both CPUs. No console top level
or ARM9 adapter enables it. The released FPGA, host, renderer, settings and
1 GHz operating point are unchanged.

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

Set `EXPERIMENTAL_CHECKPOINT=true` and `SS_PRESET_ONLY='0'` explicitly.

1. Raise `checkpoint_req` in the CPU clock domain. Continue servicing its memory
   responses. A taken B/BL/BX retires, its outstanding fetch completes, and the
   target fetch is suppressed. DMA ownership, a saved bus request and ARM9 cache
   maintenance prevent acknowledgement.
2. Wait for `checkpoint_paused`. Read the complete state while keeping the
   request high. The CPU clock enable is held internally, not the input clock.
   Dropping the request cancels the hold and refills at the saved target PC.
3. Before restore, validate the entire file and exact identity. Hold `reset`
   and `checkpoint_restore` high together, then write **every** state word,
   using full-word byte enables. Read back the live state while still in reset.
   Drop restore and reset together, with the request low, only after the complete
   image is accepted.
   CPU bus requests must remain disconnected from the rest of the machine until
   every other subsystem is restored too.

The caller must impose a bounded deadline and cancel on timeout. This component
has no internal timeout controller. It cannot yet acknowledge a CPU already in
HALT/WFI/sleep, or a path with no taken branch. Arbitrary mid-instruction capture,
IRQ/exception-entry capture, and cache/RAM/device-state restoration are not
provided. A failed partial restore must stay in reset and use a clean boot;
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
  this interface, and future integration still needs a host-liveness watchdog
  for a caller that disappears while a successful hold is active.

Do not force a sleeping CPU awake to obtain a branch checkpoint or discard its
prefetched instructions. Those would change the guest state. The present
barrier safely refuses such a snapshot and releases any peer that did pause.

The state bus uses **word addresses**, not byte addresses:

| Word address | Contents |
| --- | --- |
| 0 | Next fetch PC at the acknowledged branch target; restore uses boot PC shadow |
| 1–16 | Current r0–r15 |
| 17–18 | CPSR/SPSR readback; writes are ignored (restored through mixed/banked words) |
| 19–45 | User, FIQ, IRQ, supervisor, abort and undefined banked registers/SPSRs |
| 46 | Halt, NZCV, Thumb, CPU mode, IRQ/FIQ masks |
| 128–130, ARM9 | CP15 control, DTCM and ITCM configuration |
| 131–138, ARM9 | Eight protection-unit regions |
| 139–146, ARM9 | PU cache/write-buffer/permission controls, cache lockdown and PID |
| 147, ARM9 | CPSR.Q in bit 0 |
| 148, both | Open-bus last-read value |

ARM9 exports 68 words; ARM7 exports 48. The format is an experimental component
ABI, not a supported user save-state format.

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
- Each restored run completes at least 30 counter/flags/PID iterations. ARM7
  uses an authored register value in the PID position (it has no CP15).
- Captured state remains stable while held; cancelling both an acknowledged
  hold and a DMA-blocked request preserves subsequent progress.
- Every CP15 configuration field is seeded away from reset defaults where
  practical, and all exported architectural words are compared after restore.
  Deliberately omitting the extended state fails the test.
- Native/direct boot reset checks pass. Nine persistence tests cover identity
  mismatch, both component types, every truncation boundary, byte corruption,
  format version, incomplete state, failed write/fsync, and symlink refusal.

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

The capsule code also passed its nine tests on the MiSTer's Python 3.9.6, then
wrote, synced, atomically replaced and read a test slot from a fresh process on
the SD-card filesystem. Temporary test folders were removed. The FAT mount
reports mode `0755` despite `fchmod(0600)`; POSIX per-file permissions cannot be
assumed there. This verifies file operations only, not power-loss durability or
capture/restore of a live FPGA. No NDS session or ordinary game save was used.

## FPGA resource measurement

Use `tools/suspend_resume/measure_area.py --runtime QUARTUS_ROOT
--udev-shim SHIM --output NEW_OUTPUT_DIRECTORY` to reproduce isolated Quartus
17.0.2 mappings. The output directory must be outside the source checkout.
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

Across both isolated CPUs, direct loading reduces the added register count from
**3,151 to 86**, and the added mapped logic-cell count from **5,487 to 2,445**.
Disabled mappings retain the same counts before and after this change. No DSP
or block RAM is added by these probes.

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
| Both FPGA CPUs | Registers, banked state, valid resume boundary | Component proof above; not wired to host or console |
| ARM9 memory island | TCM contents, I/D cache data/tags/dirty state, write buffers | Missing; resetting or simply invalidating caches is not equivalent |
| Shared memory | Main RAM, WRAM, VRAM, palette, OAM and ownership/mapping registers | Missing |
| FPGA devices | DMA progress, timers, IRQ, IPC/FIFOs, cartridge/save-chip transactions, SPI, math units, timing counters | Missing; require coherent freeze and versioned serializers |
| Audio | Voice state, playback position, FIFOs, capture/mixer state and output phase | Missing |
| ARM graphics helper | GPU/VRAM mirrors, partial GX commands, replay queues, display capture, paired publication and worker state | Existing melonDS serializers are only a starting point |
| RTC/input/host | Clock offset/elapsed-time policy, touch/input state, save-file isolation, exact package identity | Existing clock persistence is separate; checkpoint integration missing |
| Coordinator | Common machine epoch, bounded pause/abort, restore ordering, capability gate | CPU-pair pause/abort simulation proof; console/device freeze and host transport missing |

Current H3D lifecycle quiesce **destroys the renderer** before acknowledgement;
it is a session-exit operation, not a checkpoint. A full melonDS emulator state
also cannot substitute for the live FPGA CPUs/peripherals. Restoring a frame or
RAM dump alone is therefore deliberately not exposed as Resume.

## Next acceptance gates

1. Integrate a top-level pause/abort and state-read transport with a common
   machine epoch, extending the CPU-pair proof to already-halted CPUs without
   losing prefetch state. Verify no pending access or IRQ is dropped. Preserve
   the coordinator's delivery/release handshake and add a host-liveness limit.
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
