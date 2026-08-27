#!/usr/bin/env python3
"""Small start-stop-daemon double used only by the offline H3D test."""

from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def service_loop() -> int:
    stopping = False

    def stop(_signum: int, _frame: object) -> None:
        nonlocal stopping
        stopping = True

    def snapshot(_signum: int, _frame: object) -> None:
        snapshot_text = os.environ.get("H3D_FAKE_SNAPSHOT_MARKER")
        if snapshot_text:
            Path(snapshot_text).write_text("requested\n", encoding="ascii")

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGUSR1, snapshot)
    marker_text = os.environ.get("H3D_FAKE_SERVICE_MARKER")
    marker = Path(marker_text) if marker_text else None
    while not stopping:
        time.sleep(0.02)
    if marker:
        marker.unlink(missing_ok=True)
    return 0


def parse(argv: list[str]) -> dict[str, object]:
    parsed: dict[str, object] = {
        "action": None,
        "test": False,
        "oknodo": False,
        "remove": False,
        "pidfile": None,
        "executable": None,
        "nicelevel": None,
        "child": [],
    }
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument == "--":
            parsed["child"] = argv[index + 1 :]
            break
        if argument == "-S":
            parsed["action"] = "start"
        elif argument == "-K":
            parsed["action"] = "stop"
        elif argument == "-t":
            parsed["test"] = True
        elif argument == "-o":
            parsed["oknodo"] = True
        elif argument == "--remove-pidfile":
            parsed["remove"] = True
        elif argument in ("-p", "-x", "-R", "-N"):
            index += 1
            if index >= len(argv):
                raise ValueError(f"missing value for {argument}")
            if argument == "-p":
                parsed["pidfile"] = argv[index]
            elif argument == "-x":
                parsed["executable"] = argv[index]
            elif argument == "-N":
                parsed["nicelevel"] = argv[index]
        elif argument not in ("-b", "-m", "-q"):
            raise ValueError(f"unsupported fake start-stop-daemon option: {argument}")
        index += 1
    if parsed["action"] not in ("start", "stop"):
        raise ValueError("exactly one of -S/-K is required")
    if not parsed["pidfile"] or not parsed["executable"]:
        raise ValueError("-p and -x are required")
    if parsed["action"] == "start" and parsed["nicelevel"] != "-20":
        raise ValueError("production start must request nice level -20")
    return parsed


def read_pid(path: Path) -> int | None:
    try:
        text = path.read_text(encoding="ascii").strip()
        if not text.isdigit() or int(text) <= 1:
            return None
        return int(text)
    except (OSError, ValueError):
        return None


def alive(pid: int | None) -> bool:
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def main(argv: list[str]) -> int:
    if argv == ["--service-loop"]:
        return service_loop()
    parsed = parse(argv)
    trace = os.environ.get("H3D_FAKE_SSD_TRACE")
    if trace:
        with Path(trace).open("a", encoding="utf-8") as output:
            output.write(json.dumps(argv) + "\n")

    pidfile = Path(str(parsed["pidfile"]))
    execfile = Path(str(pidfile) + ".exec")
    marker = Path(str(pidfile) + ".alive")
    pid = read_pid(pidfile)
    recorded = None
    try:
        recorded = execfile.read_text(encoding="utf-8")
    except OSError:
        pass
    matches = alive(pid) and marker.exists() and \
        recorded == parsed["executable"]

    if parsed["action"] == "start":
        if matches:
            return 1
        if parsed["child"]:
            print("fake start-stop-daemon: deployed service received arguments",
                  file=sys.stderr)
            return 2
        environment = os.environ.copy()
        environment["H3D_FAKE_SERVICE_MARKER"] = str(marker)
        marker.write_text("running\n", encoding="ascii")
        child = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "--service-loop"],
            start_new_session=True,
            env=environment,
        )
        pidfile.write_text(f"{child.pid}\n", encoding="ascii")
        execfile.write_text(str(parsed["executable"]), encoding="utf-8")
        return 0

    if parsed["test"]:
        return 0 if matches else 1
    if not matches:
        return 0 if parsed["oknodo"] else 1

    assert pid is not None
    os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 2.0
    while alive(pid) and marker.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    if alive(pid) and marker.exists():
        os.kill(pid, signal.SIGKILL)
    if parsed["remove"]:
        pidfile.unlink(missing_ok=True)
        execfile.unlink(missing_ok=True)
        marker.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError) as error:
        print(f"fake start-stop-daemon: {error}", file=sys.stderr)
        raise SystemExit(2)
