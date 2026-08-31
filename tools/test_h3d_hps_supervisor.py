#!/usr/bin/env python3
"""Offline regression for the fixed-path MiSTer H3D service supervisor."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
CONTROL = ROOT / "tools" / "nds_hybrid_3d_service_ctl.sh"
FAKE_SSD = ROOT / "tools" / "h3d_fake_start_stop_daemon.py"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_control(
    action: str, environment: dict[str, str], expected: int = 0
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [str(CONTROL), action],
        env=environment,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=10,
    )
    require(
        result.returncode == expected,
        f"{action} returned {result.returncode}, expected {expected}: "
        f"stdout={result.stdout!r} stderr={result.stderr!r}",
    )
    return result


def records(trace: Path) -> list[list[str]]:
    if not trace.exists():
        return []
    return [json.loads(line) for line in trace.read_text().splitlines()]


def starts(trace: Path) -> list[list[str]]:
    return [entry for entry in records(trace) if "-S" in entry]


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="h3d-supervisor-") as temporary:
        test_root = Path(temporary)
        media = test_root / "media" / "fat"
        runtime = test_root / "tmp"
        media.mkdir(parents=True)
        runtime.mkdir()
        support = media / "Scripts" / "NDS_Support"
        support.mkdir(parents=True)
        service = support / "nds_hybrid_3d_service"
        manifest = support / "nds_hybrid_3d_service.sha256"
        wc_module = support / "nds_mem_wc.ko"
        wc_manifest = support / "nds_mem_wc.ko.sha256"
        pidfile = runtime / "nds-hybrid-3d-service.pid"
        logfile = runtime / "nds-hybrid-3d-service.log"
        trace = runtime / "fake-ssd.jsonl"
        snapshot_marker = runtime / "fake-snapshot-requested"
        fake_proc = runtime / "proc"
        fake_mister_pid = 4242
        fake_mister = fake_proc / str(fake_mister_pid)
        fake_mister.mkdir(parents=True)
        fake_mister_start = 987654
        fake_mister.joinpath("stat").write_text(
            f"{fake_mister_pid} (MiSTer) R "
            + " ".join(["0"] * 18)
            + f" {fake_mister_start} 0\n",
            encoding="ascii",
        )
        fake_affinity = runtime / "fake-mister-affinity"
        fake_affinity.write_text("1\n", encoding="ascii")
        fake_taskset_trace = runtime / "fake-taskset.jsonl"
        fake_taskset = runtime / "taskset"
        fake_taskset.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "state=$H3D_FAKE_AFFINITY_STATE\n"
            "trace=$H3D_FAKE_TASKSET_TRACE\n"
            "if [ \"$#\" -eq 2 ] && [ \"$1\" = -pc ]; then\n"
            "  printf \"pid %s's current affinity list: %s\\n\" \"$2\" \"$(cat \"$state\")\"\n"
            "elif [ \"$#\" -eq 3 ] && [ \"$1\" = -pc ]; then\n"
            "  printf '%s\\n' \"$2\" >\"$state\"\n"
            "  printf '[\"%s\",\"%s\"]\\n' \"$2\" \"$3\" >>\"$trace\"\n"
            "  printf \"pid %s's current affinity list: %s\\n\" \"$3\" \"$2\"\n"
            "else\n"
            "  exit 2\n"
            "fi\n",
            encoding="ascii",
        )
        fake_taskset.chmod(0o755)
        fake_pidof = runtime / "pidof"
        fake_pidof.write_text(
            f"#!/bin/sh\n[ \"${{1:-}}\" = MiSTer ] && echo {fake_mister_pid}\n",
            encoding="ascii",
        )
        fake_pidof.chmod(0o755)

        # The fake daemon never executes this artifact; it only needs a real,
        # executable, hashable file at the production-relative path.
        shutil.copy2(sys.executable, service)
        service.chmod(0o755)

        def authorize(name: str = service.name, value: str | None = None) -> None:
            manifest.write_text(
                f"{value or digest(service)}  {name}\n", encoding="ascii"
            )

        authorize()
        environment = os.environ.copy()
        environment.update(
            {
                "H3D_LIFECYCLE_TEST_ROOT": str(test_root),
                "H3D_TEST_START_STOP_DAEMON": str(FAKE_SSD),
                "H3D_FAKE_SSD_TRACE": str(trace),
                "H3D_FAKE_SNAPSHOT_MARKER": str(snapshot_marker),
                "H3D_TEST_TASKSET": str(fake_taskset),
                "H3D_TEST_PIDOF": str(fake_pidof),
                "H3D_TEST_PROC_ROOT": str(fake_proc),
                "H3D_FAKE_AFFINITY_STATE": str(fake_affinity),
                "H3D_FAKE_TASKSET_TRACE": str(fake_taskset_trace),
            }
        )

        run_control("preflight", environment)
        wc_module.write_bytes(b"test WC module")
        wc_manifest.write_text(
            f"{digest(wc_module)}  {wc_module.name}\n", encoding="ascii"
        )
        run_control("preflight", environment)
        wc_manifest.write_text(
            f"{'0' * 64}  {wc_module.name}\n", encoding="ascii"
        )
        bad_wc_hash = run_control("preflight", environment, 1)
        require("WC module SHA-256" in bad_wc_hash.stderr,
                "bad WC module hash was not diagnosed")
        wc_manifest.write_text(
            f"{digest(wc_module)}  {wc_module.name}\n", encoding="ascii"
        )
        authorize(value="0" * 64)
        bad_hash = run_control("preflight", environment, 1)
        require("does not match" in bad_hash.stderr, "bad hash was not diagnosed")
        authorize(name="some_other_program")
        bad_name = run_control("preflight", environment, 1)
        require("wrong executable" in bad_name.stderr,
                "wrong manifest basename was not diagnosed")
        authorize()

        try:
            run_control("start", environment)
            require(pidfile.is_file(), "start did not create the fixed pidfile")
            require(logfile.is_file(), "start did not create the fixed logfile")
            first_starts = starts(trace)
            require(len(first_starts) == 1, "first start was not singular")
            require(first_starts[0][-1] == "--",
                    "deployed service received an argument after '--'")
            require(first_starts[0][first_starts[0].index("-x") + 1] ==
                    str(service), "start used a non-fixed executable path")
            require(first_starts[0][first_starts[0].index("-p") + 1] ==
                    str(pidfile), "start used a non-fixed pidfile path")
            require(first_starts[0][first_starts[0].index("-N") + 1] == "-20",
                    "start did not prioritize the H3D service")
            require(fake_affinity.read_text(encoding="ascii").strip() == "0",
                    "start did not move only the MiSTer frontend to CPU0")

            # Idempotent start must not create a second process.
            twice = run_control("start", environment)
            require("already running" in twice.stdout,
                    "second start did not report the resident instance")
            require(len(starts(trace)) == 1, "second start launched another process")
            run_control("status", environment)
            dump = run_control("dump", environment)
            require("snapshot requested" in dump.stdout,
                    "manual dump did not report success")
            for _ in range(50):
                if snapshot_marker.exists():
                    break
                time.sleep(0.02)
            require(snapshot_marker.exists(),
                    "manual dump did not deliver SIGUSR1")
            run_control("status", environment)
            run_control("stop", environment)
            require(not pidfile.exists(), "stop left the pidfile behind")
            require(fake_affinity.read_text(encoding="ascii").strip() == "1",
                    "stop did not restore MiSTer's original affinity: "
                    f"affinity={fake_affinity.read_text(encoding='ascii')!r} "
                    f"trace={fake_taskset_trace.read_text(encoding='ascii')!r}")
            run_control("status", environment, 3)

            # A stale pidfile, even one naming a live unrelated PID, must be
            # replaced without signalling that process.
            pidfile.write_text(f"{os.getpid()}\n", encoding="ascii")
            Path(str(pidfile) + ".exec").write_text(
                "/definitely/not/the/h3d/service", encoding="utf-8"
            )
            Path(str(pidfile) + ".alive").write_text(
                "unrelated\n", encoding="ascii"
            )
            run_control("start", environment)
            require(len(starts(trace)) == 2,
                    "stale pidfile prevented a clean service start")
            os.kill(os.getpid(), 0)

            # Restart performs a bounded TERM stop followed by one fresh start.
            run_control("restart", environment)
            require(len(starts(trace)) == 3,
                    "restart did not launch exactly one replacement")
            run_control("stop", environment)

            # Stopped-log maintenance is limited to the fixed 64 KiB file.
            logfile.write_bytes(b"L" * 70000)
            run_control("stop", environment)
            require(logfile.stat().st_size == 65536,
                    "stopped logfile was not bounded to 64 KiB")

            # A changed executable is rejected before start-stop-daemon sees a
            # launch request.
            with service.open("ab") as output:
                output.write(b"changed")
            before = len(starts(trace))
            run_control("start", environment, 1)
            require(len(starts(trace)) == before,
                    "hash failure reached start-stop-daemon")
        finally:
            subprocess.run(
                [str(CONTROL), "stop"], env=environment,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=10,
            )

    print("H3D_HPS_SUPERVISOR_TEST_PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"H3D_HPS_SUPERVISOR_TEST_FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
