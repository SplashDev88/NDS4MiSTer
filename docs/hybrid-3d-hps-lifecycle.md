# Hybrid 3D HPS lifecycle and beta deployment

Status: offline implementation and regression coverage. Nothing in this
document has been installed on a MiSTer yet.

## User-launched process contract

The HPS renderer is a singleton background process for one play session. The
user launches it before loading the NDS core; it is deliberately not installed
as a boot-persistent `user-startup.sh`. It takes no ROM argument. Its production
invocation is exactly:

```text
/media/fat/nds_hybrid_3d_service
```

With no arguments, the executable opens `/dev/mem` and maps exactly
`0x180000` bytes beginning at physical `0x3fc00000`. The control/packet window
and both plane banks all fit in that mapping. The supervisor provides no way
to pass a different memory path, physical base, length, or ROM.

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

The supervisor starts the service at nice level -20. MiSTer's main loop is
normally continuously runnable on CPU1; prioritizing the bounded H3D work lets
command replay use that CPU when needed without killing MiSTer or losing the
normal menu, input, and core lifecycle.

## Offline staging and guarded deployment

After the final ARMHF rebuild, create a new local payload directory:

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

For the first beta deployment:

1. Preserve the known-good `cfeeda58` RBF, current NDS service, and current
   core as distinct rollback files.
2. Transfer every payload file under temporary names on the same FAT volume.
   Verify the payload `SHA256SUMS` on MiSTer before renaming anything live.
3. Stop the previous helper, if any. Install the verified service and manifest
   first, then the manual control script. Do not replace an executable
   while its old inode is running.
4. Run `NDS4MiSTer_H3D.sh preflight`, then `start`. Confirm exactly one PID and
   `status` success while the non-H3D core is still loaded.
5. Only then load the candidate RBF. The candidate must complete
   `H3DQ -> ack -> fresh H3D1 -> Ready` before releasing the NDS console.
6. If the candidate fails, reload the preserved 2D RBF, stop the H3D service,
   and restore the prior service. The service and RBF are independent rollback
   units.

No service, control script, or RBF should be copied to the board until all
host regressions, the final ARM self-test/hash, Quartus fit, and assembly have
passed.

## Offline gates

Run the complete lifecycle gate with:

```sh
tools/test_h3d_hps_lifecycle.sh
```

It covers exact hash preflight, zero-argument launch, start twice, status,
bounded TERM stop, restart, corrupt and live-unrelated stale PID files, fixed
log paths, and hash rejection. It then builds the real host renderer and runs
it against a guarded fake memory file, covering core absent, singleton
rejection, one-shot restart request, three `H3DQ` acknowledgements followed by
read-only waits, fresh `H3D1` initialization, live core reconfiguration,
process restart, TERM, and an unchanged guard beyond the 0x180000-byte window.
