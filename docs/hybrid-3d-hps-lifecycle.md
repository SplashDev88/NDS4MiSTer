# Hybrid 3D HPS lifecycle and beta deployment

Updated 17 October 2026. The standalone package uses one launcher and an
indivisible matching kit. The old August manual helper workflow is retained
below as historical implementation reference, not current installation advice.

## Current standalone lifecycle

Run `Scripts/NDS4MiSTer.sh` for the public package, or the named private-beta
launcher for its separate kit. The public kit is `Scripts/.NDS_Standalone`;
private kit paths are recorded in the package manifest. Do not start a separate
H3D helper or replace individual binaries from another beta.

`NDS4MiSTer.sh` invokes `supervisor.py`. Preflight checks the fixed component
hashes and expected runtime configuration. The supervisor coordinates Main's
bootstrap/exit, temporary video-state journaling, helper startup and the native
standalone host. The native host becomes the frontend/SPI owner for menu, input,
ROM and save transactions. A recovery guard can restore Main after handled
failures; a kernel/FPGA hang may still require reboot.

`Kickstart.sh` starts the singleton helper from the same kit's `support` folder,
selects the matching publication WC module for Linux 5.15.1 or 6.18.38, sets the
accepted runtime environment and requests the tested 1 GHz ARM operating point.
On clean shutdown the host flushes saves/clock edits while holding the guest,
then the supervisor stops its processes and restores frontend/clock state.
PID/start-time identity checks prevent stale cleanup from targeting a new process.

The current physical mappings are separate: 1 MiB of Device control/packet pages
at `0x3FC00000` and 3 MiB of publication pixels at `0x3FD00000`, preferably through
the WC module. There is no overlapping Device mapping of the publication pages.
The rejected packet-input NC experiment and its lifecycle draft are not shipped.

The H3DQ/fresh-H3D1 ownership handshake, one-second heartbeat deadline and strict
packet acknowledgement rules remain required. A restarted helper cannot resume
an old session. See [the architecture](architecture.md),
[ABI](hybrid-3d-abi.md), [frontend details](../tools/standalone_host/README.md) and
[private freeze](PRIVATE_BETA_20261017.md).

## Historical manual helper deployment (August 2026)

Everything below describes the earlier independently launched helper. Its fixed
paths, monolithic mapping, MiSTer affinity watcher and separate RBF/helper update
instructions are not the standalone package's current deployment procedure.

## User-launched process contract

The HPS renderer is a singleton background process for one play session. The
user launches it before loading the NDS core; it is deliberately not installed
as a boot-persistent `user-startup.sh`. It takes no ROM argument. Users launch
the supervisor installed as:

```text
/media/fat/Scripts/NDS4MiSTer_H3D.sh
```

After its hash preflight, the supervisor starts the fixed service executable at
`/media/fat/nds_hybrid_3d_service` with no arguments. The executable opens
`/dev/mem` and maps exactly `0x400000` bytes beginning at physical
`0x3fc00000`. The mapping contains the control/packet window, two 3D plane
banks, and four final-framebuffer banks. The supervisor provides no way to pass
a different memory path, physical base, length, or ROM.

The process holds `/tmp/nds-hybrid-3d-service.lock` with `flock(LOCK_EX |
LOCK_NB)`. A second instance exits before it can become a shared-memory
writer. `SIGINT` and `SIGTERM` set a signal-safe stop flag; the loop destroys
the renderer and exits normally.

While a session is Ready, the service advances its shared heartbeat every 256
units of active progress: poll entries and successfully applied packet records
both count. FPGA allows a full one-second gap, then records a sticky service
fault and holds the console in reset. Counting records matters because one
packet poll can contain thousands of ordered writes. This covers an uncatchable
`SIGKILL`, a process crash, or failed supervision after startup without relying
on all four packet slots eventually becoming full.

The service copies and applies one complete packet per poll. `CONT` packets
advance the renderer but do not publish a plane; `FRAME_END` publishes the
completed plane and remains unacknowledged while that plane is backpressured.
The shared packet acknowledgement therefore always names the last completely
applied packet. Each poll checks the active session, and every acknowledgement
repeats that validation immediately before publication.

The shared-memory lifecycle is:

| FPGA header | HPS behavior |
| --- | --- |
| absent, invalid, or zero | Poll read-only. This is the normal pre-core state. |
| old active `H3D1` after an HPS process restart | Publish `RestartRequested` once, destroy/no renderer, then poll read-only. Never resume an old packet fence with a new melonDS instance. |
| `H3DQ` with a new nonzero token | Destroy the old renderer first, write the matching quiesce ack once, then poll strictly read-only. The ack is the last HPS write to the old generation. |
| fresh `H3D1`, with `ack == request`, state `Offline`, and accepted session zero | Create a ROM-less GPU3D instance, accept the new session, and become `Ready`. |
| active `H3D1` changes magic, session, or quiesce token | Stop all active shared-memory writes and re-enter the `H3DQ` handshake. |

The busy packet path checks that ownership at service-poll entry, inside the
packet consumer, and immediately before any shared acknowledgement. Each
check reads the complete session/quiesce tuple as one
ordered Device-memory snapshot bracketed by `H3D1` magic reads, followed by one
system barrier. This preserves the fail-closed lifecycle boundary without
paying a separate barrier for every unchanged header word.

The FPGA holds the console in reset while this exchange occurs. It publishes
`H3DQ`, waits for the exact HPS ack, clears/reinitializes its HPS-owned region,
and commits fresh `H3D1` last. HPS publication and heartbeat writes are legal
only while magic, session, accepted session, and quiesce generation all still
match.

## Fixed MiSTer supervisor

`tools/nds_hybrid_3d_service_ctl.sh` is a POSIX/BusyBox-compatible manual
launcher and supervisor.
It uses only these production paths:

| Purpose | Path |
| --- | --- |
| Service | `/media/fat/nds_hybrid_3d_service` |
| Exact hash manifest | `/media/fat/nds_hybrid_3d_service.sha256` |
| PID | `/tmp/nds-hybrid-3d-service.pid` |
| Log | `/tmp/nds-hybrid-3d-service.log` |

`start` requires an executable non-symlink regular file and a one-record
sha256sum manifest naming exactly `nds_hybrid_3d_service`. It recomputes and
compares the digest before invoking `start-stop-daemon`. There are no child
arguments after `--`. A second `start` is idempotent. Corrupt and stale PID
files are never trusted to identify a process: BusyBox stop test-mode matches
both the PID file and exact executable before any real stop action.

`stop` uses the already-established MiSTer BusyBox form
`TERM/5/KILL/1`, with PID and executable matching. Runtime files are fixed,
non-symlink paths under `/tmp`, mode 0600. A start truncates the old log, the
child inherits a 64 KiB file-size limit, and stopped-log maintenance retains
at most 64 KiB.

The supported commands are `preflight`, `start`, `stop`, `restart`, `status`,
and `dump`. `dump` sends `SIGUSR1` to request a bounded manual crash snapshot.
With no command the script performs `start`. Install it only as:

```text
/media/fat/Scripts/NDS4MiSTer_H3D.sh
```

The required user sequence is: run that script, then load the NDS core.
If a game is misbehaving but has not automatically produced a report, run
`NDS4MiSTer_H3D.sh dump`. Share the resulting
`/media/fat/NDS4MiSTer_crash_*.txt` together with the beta name and
`nds_hybrid_3d_service.sha256`; no ROM is needed.

The supervisor requests the board's tested 1 GHz HPS clock and starts the
service at nice level -20. MiSTer's main loop is normally continuously runnable
on CPU1; prioritizing the bounded H3D work lets command replay use that CPU when
needed without killing MiSTer or losing the normal menu, input, and core
lifecycle. A one-shot, at-most-1 Hz watcher waits up to five minutes for one
stable replacement MiSTer process epoch and exact `/tmp/CORENAME` value `NDS`,
then pins only that frontend to CPU0. The saved original affinity is restored
on stop only while the same PID/start-time epoch still exists. The watcher and
Stop serialize the mutation; a stale operation lock fails closed and is cleared
by reboot. Stopping the service also restores the default 800 MHz limit.

## Staging and guarded updates

After an ARMHF rebuild, create a new local payload directory:

```sh
tools/build_hybrid_3d_service_armhf.sh
tools/stage_hybrid_3d_hps_payload.sh \
  build-mister-hybrid-3d-armhf/nds_hybrid_3d_service \
  /path/to/new-empty-h3d-hps-payload
```

The staging tool rejects symlinks, non-ARM artifacts, dynamically linked
artifacts, and an existing output directory. The output mirrors `/media/fat`
and contains the service, its exact authorization manifest, interactive
control script, and `SHA256SUMS`.

For a beta update:

1. Preserve the current known-good RBF, HPS service, and manifest as distinct
   rollback files.
2. Transfer every payload file under temporary names on the same FAT volume.
   Verify the payload `SHA256SUMS` on MiSTer before renaming anything live.
3. Stop the previous helper, if any. Install the verified service and manifest
   first, then the manual control script. Do not replace an executable
   while its old inode is running.
4. Run `NDS4MiSTer_H3D.sh preflight`, then `start`. Confirm exactly one PID and
   `status` success before loading the updated core.
5. Only then load the candidate RBF. The candidate must complete
   `H3DQ -> ack -> fresh H3D1 -> Ready` before releasing the NDS console.
6. If the candidate fails, return to the MiSTer menu, stop the H3D service, and
   restore the prior service and RBF. The service and RBF are independent
   rollback units.

No service, control script, or RBF should be copied to the board until all
host regressions, the final ARM self-test/hash, Quartus fit, and assembly have
passed.

## Offline gates

Run the service and supervisor lifecycle gates with:

```sh
tools/test_hybrid_3d_service.sh
python3 tools/test_h3d_hps_supervisor.py
```

Together they cover exact hash preflight, zero-argument launch, start twice,
status, bounded TERM stop, restart, corrupt and live-unrelated stale PID files,
fixed log paths, and hash rejection. They also build the real host renderer and
run it against a guarded fake memory file, covering core absent, singleton
rejection, one-shot restart request, `H3DQ` acknowledgement followed by
read-only waits, fresh `H3D1` initialization, live core reconfiguration,
process restart, TERM, and an unchanged guard beyond the 0x400000-byte window.
