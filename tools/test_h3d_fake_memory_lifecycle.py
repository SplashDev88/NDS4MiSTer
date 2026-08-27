#!/usr/bin/env python3
"""Exercise the real H3D service lifecycle against a shared regular file."""

from __future__ import annotations

import mmap
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time


MAPPING_BYTES = 0x400000
GUARD_BYTES = 4096
MAGIC_H3D1 = 0x31443348
MAGIC_H3DQ = 0x51443348
VERSION = 1
HEADER_BYTES = 128

OFF_MAGIC = 0x00
OFF_SESSION = 0x08
OFF_SESSION_RESERVED = 0x0C
OFF_SERVICE_STATE = 0x28
OFF_ACCEPTED_SESSION = 0x2C
OFF_HPS_HEARTBEAT = 0x68
OFF_QUIESCE_REQUEST = 0x70
OFF_QUIESCE_ACK = 0x78

STATE_OFFLINE = 0
STATE_READY = 2
STATE_RESTART_REQUESTED = 4


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def u32(memory: mmap.mmap, offset: int) -> int:
    return struct.unpack_from("<I", memory, offset)[0]


def put_u32(memory: mmap.mmap, offset: int, value: int) -> None:
    struct.pack_into("<I", memory, offset, value)


def put_identity(memory: mmap.mmap) -> None:
    struct.pack_into("<HH", memory, 0x04, VERSION, HEADER_BYTES)


def clear_window(memory: mmap.mmap) -> None:
    memory[:] = b"\0" * MAPPING_BYTES


def publish_quiesce(memory: mmap.mmap, token: int) -> None:
    put_identity(memory)
    put_u32(memory, OFF_QUIESCE_REQUEST, token)
    put_u32(memory, OFF_QUIESCE_REQUEST + 4, 0)
    # The preceding generation's ack is deliberately left untouched until
    # the service performs its one final old-generation write.
    put_u32(memory, OFF_MAGIC, MAGIC_H3DQ)
    memory.flush()


def publish_fresh(memory: mmap.mmap, session: int, token: int) -> None:
    clear_window(memory)
    put_identity(memory)
    put_u32(memory, OFF_SESSION, session)
    # Packet mode reuses the former entry-count word as the reserved high half
    # of the FPGA session fence.
    put_u32(memory, OFF_SESSION_RESERVED, 0)
    put_u32(memory, OFF_SERVICE_STATE, STATE_OFFLINE)
    put_u32(memory, OFF_ACCEPTED_SESSION, 0)
    put_u32(memory, OFF_QUIESCE_REQUEST, token)
    put_u32(memory, OFF_QUIESCE_ACK, token)
    # Magic is the FPGA publication commit and is written last.
    put_u32(memory, OFF_MAGIC, MAGIC_H3D1)
    memory.flush()


def process_error(process: subprocess.Popen[str]) -> str:
    if process.poll() is None:
        return ""
    stdout, stderr = process.communicate(timeout=1)
    return f"process exited {process.returncode}: stdout={stdout!r} stderr={stderr!r}"


def wait_until(
    process: subprocess.Popen[str], predicate: object, description: str,
    timeout: float = 8.0,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():  # type: ignore[operator]
            return
        error = process_error(process)
        if error:
            raise RuntimeError(f"while waiting for {description}: {error}")
        time.sleep(0.005)
    raise RuntimeError(f"timed out waiting for {description}")


def assert_read_only(
    process: subprocess.Popen[str], memory: mmap.mmap, description: str,
) -> None:
    before = memory[:]
    time.sleep(0.15)
    require(process.poll() is None,
            f"service exited during read-only phase: {process_error(process)}")
    require(memory[:] == before, f"service wrote while {description}")


def start_service(executable: Path, memory_file: Path) -> subprocess.Popen[str]:
    return subprocess.Popen(
        [str(executable), "--memory", str(memory_file)],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def stop_service(process: subprocess.Popen[str]) -> None:
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
    try:
        stdout, stderr = process.communicate(timeout=8)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate(timeout=2)
        raise RuntimeError("service ignored SIGTERM")
    require(
        process.returncode == 0,
        f"TERM exit was {process.returncode}: stdout={stdout!r} stderr={stderr!r}",
    )


def verify_source_window_contract() -> None:
    source = (Path(__file__).resolve().parents[1] /
              "src" / "replay" / "Hybrid3DService.cpp").read_text()
    require("constexpr std::size_t MappingBytes = 0x400000;" in source,
            "service mapping length is no longer the H3D window length")
    require("constexpr off_t PhysicalBase = 0x3fc00000;" in source,
            "service physical mapping base is no longer 0x3fc00000")
    require("physical ? PhysicalBase : 0" in source,
            "/dev/mem mapping no longer uses the fixed physical base")


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print(f"usage: {Path(sys.argv[0]).name} SERVICE", file=sys.stderr)
        return 2
    executable = Path(argv[0]).resolve()
    require(executable.is_file(), f"service does not exist: {executable}")
    verify_source_window_contract()

    guard = bytes((index * 29 + 7) & 0xFF for index in range(GUARD_BYTES))
    with tempfile.TemporaryDirectory(prefix="h3d-memory-lifecycle-") as temporary:
        memory_file = Path(temporary) / "h3d-window.bin"
        with memory_file.open("wb") as output:
            output.truncate(MAPPING_BYTES)
            output.seek(MAPPING_BYTES)
            output.write(guard)

        process = start_service(executable, memory_file)
        replacement: subprocess.Popen[str] | None = None
        try:
            with memory_file.open("r+b", buffering=0) as shared_file:
                memory = mmap.mmap(shared_file.fileno(), MAPPING_BYTES)
                try:
                    # The resident process is intentionally launched before a
                    # candidate core.  An all-zero/absent header is read-only.
                    assert_read_only(process, memory, "the FPGA core was absent")

                    # The process singleton rejects a second resident helper
                    # before either instance can touch shared state.
                    duplicate = start_service(executable, memory_file)
                    duplicate_stdout, duplicate_stderr = duplicate.communicate(timeout=3)
                    require(duplicate.returncode != 0,
                            "a second resident service acquired the singleton")
                    require("lock hybrid 3D service" in duplicate_stderr,
                            "singleton rejection did not identify its lock")
                    require(not duplicate_stdout,
                            "rejected singleton emitted unexpected stdout")

                    # Initial core load: acknowledge H3DQ exactly once, then
                    # remain read-only until the FPGA publishes fresh H3D1.
                    # Word15 is HPS-owned but untrusted on first use; dirty
                    # value and reserved high half must not prevent repair.
                    put_u32(memory, OFF_QUIESCE_ACK, 0xDEADBEEF)
                    put_u32(memory, OFF_QUIESCE_ACK + 4, 0xBAD0C0DE)
                    publish_quiesce(memory, 0x41)
                    wait_until(process,
                               lambda: u32(memory, OFF_QUIESCE_ACK) == 0x41 and
                               u32(memory, OFF_QUIESCE_ACK + 4) == 0,
                               "initial H3DQ acknowledgement")
                    assert_read_only(process, memory,
                                     "waiting after the initial H3DQ ack")
                    publish_fresh(memory, 0x101, 0x41)
                    wait_until(
                        process,
                        lambda: u32(memory, OFF_SERVICE_STATE) == STATE_READY and
                        u32(memory, OFF_ACCEPTED_SESSION) == 0x101 and
                        u32(memory, OFF_HPS_HEARTBEAT) != 0,
                        "fresh H3D1 initialization",
                    )

                    # The public launcher sends SIGUSR1 for a manual dump.
                    # Even with the FPGA monitor disabled on this file-backed
                    # test path, the production signal handler must be linked
                    # and retain the resident service. This prevents the
                    # launcher's diagnostic action from taking the default
                    # process-terminating disposition.
                    process.send_signal(signal.SIGUSR1)
                    time.sleep(0.05)
                    require(
                        process.poll() is None,
                        "manual crash snapshot signal terminated the service",
                    )

                    # TERM is bounded and leaves the active fence intact.  A
                    # replacement process must request a new FPGA session and
                    # then perform no repeated state writes while it waits.
                    stop_service(process)
                    replacement = start_service(executable, memory_file)
                    process = replacement
                    wait_until(
                        process,
                        lambda: u32(memory, OFF_SERVICE_STATE) ==
                        STATE_RESTART_REQUESTED,
                        "one-shot restart request",
                    )
                    assert_read_only(process, memory,
                                     "waiting for H3DQ after process restart")
                    publish_quiesce(memory, 0x42)
                    wait_until(process,
                               lambda: u32(memory, OFF_QUIESCE_ACK) == 0x42,
                               "restart H3DQ acknowledgement")
                    assert_read_only(process, memory,
                                     "waiting after restart H3DQ ack")
                    publish_fresh(memory, 0x102, 0x42)
                    wait_until(
                        process,
                        lambda: u32(memory, OFF_SERVICE_STATE) == STATE_READY and
                        u32(memory, OFF_ACCEPTED_SESSION) == 0x102,
                        "replacement H3D1 initialization",
                    )

                    # A live FPGA reconfiguration follows the same destroy,
                    # final-ack, read-only, fresh-session sequence without
                    # restarting the resident process.
                    publish_quiesce(memory, 0x43)
                    wait_until(process,
                               lambda: u32(memory, OFF_QUIESCE_ACK) == 0x43,
                               "live-reconfiguration H3DQ acknowledgement")
                    assert_read_only(process, memory,
                                     "waiting during live reconfiguration")
                    publish_fresh(memory, 0x103, 0x43)
                    wait_until(
                        process,
                        lambda: u32(memory, OFF_SERVICE_STATE) == STATE_READY and
                        u32(memory, OFF_ACCEPTED_SESSION) == 0x103,
                        "post-reconfiguration H3D1 initialization",
                    )
                finally:
                    memory.close()
        finally:
            if process.poll() is None:
                stop_service(process)
            if replacement is not None and replacement is not process and \
                    replacement.poll() is None:
                stop_service(replacement)

        # A patterned guard beyond 0x400000 proves the file-backed path never
        # reaches above the shared window.  The /dev/mem base/length contract
        # is checked directly from the same Mapping implementation above.
        with memory_file.open("rb") as input_file:
            input_file.seek(MAPPING_BYTES)
            require(input_file.read(GUARD_BYTES) == guard,
                    "service wrote beyond the 0x400000-byte H3D window")

    print("H3D_FAKE_MEMORY_LIFECYCLE_TEST_PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"H3D_FAKE_MEMORY_LIFECYCLE_TEST_FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
