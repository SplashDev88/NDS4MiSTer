# Engine B session policy

The Engine B menu setting defaults to Off. A selection takes effect after
Reset or a completed ROM load. Changing the menu while playing does not change
the running session. Restarting only the ARM helper retains the applied choice.

## Off and On paths

Off uses the beta.11 3D-only ARM replay/renderer settings. The FPGA keeps 2D
register, palette, OAM and non-LCDC VRAM traffic local, and sends no extra LCD
phase records. ARM does not render Engine B pixels or sprites, or copy/publish
its framebuffer. Scanout fetches one local screen and displays that image in
both screen positions. Local guest registers, palettes and VRAM still work.

On adds the state and LCD phase records needed to render Engine B on ARM.
Writes retain their posting scanline even if transport is delayed. Engine A
continues rendering on FPGA. ARM publishes a paired 3D plane and Engine B bank
with the physical screen assignment; scanout adopts the pair at a frame
boundary. The ARM 2D backend preserves display-capture ordering and draws
Engine A as an auxiliary capture source when capture requires it. This costs
CPU and DDR time, so On is expected to run slower than Off.

The event gate retains the beta.11 32-entry MLAB queue and empty-queue bypass.
Additional line request scheduling applies only while external Engine B video
is enabled. The second full FPGA 2D engine is not instantiated.

## H3P1 mailbox

This policy requires a matching FPGA/helper pair. It is available only in
frame-packet mode: the legacy event ring overlaps its reserved control area.
An old helper cannot acknowledge the policy, and an old FPGA cannot provide a
valid request. Initialization fails closed in either case.

The FPGA owns a 32-byte request at control offset `0x300`; ARM owns an exact
32-byte acknowledgement at `0x340`. Each contains eight little-endian words:

| Word | Meaning |
| --- | --- |
| 0 | Magic `0x31503348` (H3P1) |
| 1 | Version/size `0x00200001` |
| 2 | Nonzero FPGA session |
| 3 | Flags: bit 0 enables Engine B pixels; all other bits zero |
| 4 | Nonzero quiesce epoch |
| 5 | Reserved, zero |
| 6 | Commit: the same epoch, written last |
| 7 | Reserved, zero |

Readers sample commit before and after the body and validate every field.
ARM resets its renderer and initializes the consumer before acknowledging,
then confirms that the request and session are still current before committing
the ACK and reporting Ready. FPGA releases the console only after the normal
header and the complete policy ACK match. A changed ACK after acceptance
faults the current session instead of silently changing rendering behavior.

Before replacing a session, H3DQ waits for the helper acknowledgement and for
external video to quiesce. An already queued/accepted DDR read drains to its
final beat before ownership is released. No new Engine B read begins after
withdrawal, and a stale publication cannot re-enable a bank. A later On
session requires a fresh publication.

## Validation

- `tools/test_h3d_session_policy.sh`: reset/menu boundaries, strict mailbox,
  stale/torn acknowledgements, delayed memory and legacy control mode.
- `tools/test_hybrid_3d_service.sh`: eight Off/On publication combinations,
  byte-preserved poisoned Engine B memory in Off, existing 3D oracles and
  fake-memory restart lifecycle.
- `tools/test_engine_b_video_quiesce.sh`: queued/in-flight DDR draining,
  paired bank ownership, Off single-fetch scanout, and fresh On adoption.
- `tools/test_h3d_console_event_gate.sh`: CPU pulse retention and exactly-once
  held DMA acceptance under full-queue backpressure.
- `tools/test_h3d_vram9_retirement.sh`: local/event receipts across Off/On,
  LCDC/BG writes, CPU/DMA accesses and stalls.
- `tools/test_nitro_console_island_host.sh` and
  `tools/test_nitro_console_vhdl_analyze.sh`: integration and prior regressions.

Simulation and host tests do not establish MiSTer performance. The candidate
still needs FPGA fit and TV/gameplay checks against beta.11 at the same clocks.
The deferred Pokémon GX readback protocol is not part of this policy.
