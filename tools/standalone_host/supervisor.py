#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""NDS4MiSTer v0.6.0-beta: Main boots the accepted FPGA, then this host owns SPI.
No system binary/init/config overwrites. Independent guard survives supervisor death.
"""
from pathlib import Path
import argparse, fcntl, hashlib, json, os, signal, subprocess, sys, time, shutil

KIT = Path(__file__).resolve().parent
LEASE = Path("/tmp/nds-standalone-lease.json")
BEAT = Path("/tmp/nds-standalone-heartbeat")
KICK = str(KIT / "Kickstart.sh")
CORE = KIT / "NDS_Standalone.rbf"
RUNTIME = Path("/tmp/nds-standalone")
EXPECTED_WC = "c3c67f88de36a853db7d4537ddce3202df6329a54b2600fa90b7104c803a7113"
NORMAL_HELPER_SHA = "91ce15eed06269380b78ba505e6f5cb19eeb99d3845ce21fb176566a390febe3"
HELPER = KIT / "support/nds_hybrid_3d_service"
SD_ROOT = Path("/media/fat")
EXPECTED_HELPER = "f944454751764bc6b1fde45b07a0e9ba4935ac0cae5cc256b377ed6d056ff729"
EXPECTED_CORE = "de443f91e8d3251053a6c881be78b28ca26c27b930f8f5ba9828b0c2089a45d9"
EXPECTED_KICKSTART = "8a8b205effdc14fed1d7c479d357dd1b4eaaad2742cea0e93df2d21002801659"
EXPECTED_SPEED_ENV = {
    "NDS4MISTER_GX_MATRIX_PREFIX": "auto",
    "NDS4MISTER_STANDALONE_REUSE_3D": "1",
    "NDS4MISTER_STANDALONE_FRAME_SKIP": "nsmb-half",
    "NDS4MISTER_GX_QUERY_FAST_POLL": "1",
    "NDS4MISTER_PACKET_NC": "0",
    "NDS4MISTER_H3D_DIAGNOSTICS": "0",
    "NDS4MISTER_BLACK_EVENT_TRACE": "0",
    "NDS_GPU_STANDARD_PALETTE_CACHE": "1",
    "NDS4MISTER_H3D_DISABLE_WC": "0",
    "NDS4MISTER_DUAL_CORE_3D": "1",
    "NDS4MISTER_ADAPTIVE_RASTER_SPLIT": "1",
    "NDS4MISTER_RASTER_BAND_QUEUE": "1",
    "NDS4MISTER_WEIGHTED_RASTER_BANDS": "1",
    "NDS4MISTER_RASTER_X_PARTITION": "1",
    "NDS4MISTER_DIRECT_PLANE_PUBLICATION": "1",
    "NDS4MISTER_MATCHED_DISPLAY_TEST": "1",
    "NDS4MISTER_MATCHED_DISPLAY_FULL_RATE": "1",
    "NDS4MISTER_STANDALONE_PACING_PACKETS": "16",
    "NDS4MISTER_STANDALONE_QUERY_BURST": "0",
    "NDS4MISTER_STANDALONE_CAUSAL_TRACE": "1",
    "NDS4MISTER_STANDALONE_QUERY_PRIORITY": "1",
    "NDS4MISTER_STANDALONE_LOW_TIMER_SLACK": "1",
    "NDS4MISTER_STANDALONE_UPLOAD_CPU0": "1",
    "NDS4MISTER_STANDALONE_PACING_TRACE": "1",
    "NDS4MISTER_H3D_UPLOAD_SNAPSHOT": "1",
}


def renderer_environment(pid):
    return dict(
        item.decode().split("=", 1)
        for item in Path("/proc/%d/environ" % pid).read_bytes().split(b"\0")
        if item.startswith(b"NDS")
    )


def epoch(pid):
    try:
        s = Path("/proc/%d/stat" % pid).read_text().split(") ")[1].split()
        return s[19] if s[0] != "Z" else None
    except (FileNotFoundError, ProcessLookupError):
        return None


def ident(pid):
    return dict(pid=pid, epoch=epoch(pid))


def alive(p):
    return p and p["epoch"] is not None and epoch(p["pid"]) == p["epoch"]


def mains():
    out = []
    for p in Path("/proc").iterdir():
        try:
            if (
                p.name.isdigit()
                and (p / "comm").read_text().strip() == "MiSTer"
                and epoch(int(p.name))
            ):
                out.append(ident(int(p.name)))
        except (FileNotFoundError, ProcessLookupError, NotADirectoryError):
            pass
    return out


def kill(p):
    if not alive(p):
        return
    os.kill(p["pid"], signal.SIGCONT)
    os.kill(p["pid"], signal.SIGTERM)
    for _ in range(40):
        if not alive(p):
            return
        time.sleep(0.05)
    if alive(p):
        os.kill(p["pid"], signal.SIGKILL)
    for _ in range(20):
        if not alive(p):
            return
        time.sleep(0.05)
    raise RuntimeError("process did not exit")


def cmd(s, timeout=15):
    deadline = time.monotonic() + timeout
    while True:
        try:
            fd = os.open("/dev/MiSTer_cmd", os.O_WRONLY | os.O_NONBLOCK)
            break
        except OSError:
            if time.monotonic() > deadline:
                raise
            time.sleep(0.1)
    try:
        os.write(fd, (s + "\n").encode())
    finally:
        os.close(fd)


def core_name():
    try:
        return Path("/tmp/CORENAME").read_text().strip()
    except FileNotFoundError:
        return ""


def wait_for(test, timeout=45):
    end = time.monotonic() + timeout
    while not test():
        if time.monotonic() > end:
            raise RuntimeError("condition timed out")
        time.sleep(0.1)


def selected_core(path):
    """Validate a picker result again before passing it to Main's command FIFO."""
    try:
        if not path or any(c in path for c in "\0\r\n") or len(path.encode()) >= 1000:
            return None
        target = Path(path).resolve(strict=True)
        target.relative_to(SD_ROOT.resolve())
        if target.suffix.lower() not in (".rbf", ".mra", ".mgl"):
            return None
        return target if target.is_file() and target.stat().st_size else None
    except (OSError, ValueError):
        return None


def collect_core_request(returncode):
    request = KIT / "core-request.txt"
    try:
        return selected_core(request.read_text()) if returncode == 0 else None
    except (OSError, UnicodeError):
        return None
    finally:
        request.unlink(missing_ok=True)


def recover(state):
    # Never restart Main until our SPI owner is gone. Do not kill unrelated epochs.
    kill(state.get("host"))
    # The host can be spawned before its identity is journaled. It has a parent
    # death signal, and this lock proves its SPI owner is gone even in that gap.
    with open("/tmp/nds-standalone-host.lock", "a+") as ownership:
        deadline = time.monotonic() + 25
        while True:
            try:
                fcntl.flock(ownership, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise RuntimeError("SPI host remains alive; refusing a second owner")
                time.sleep(0.05)
        subprocess.run(
            ["sh", KICK, "stop"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
        started_main = not mains()
        if started_main:
            with open(RUNTIME / "recovery-main.log", "wb", buffering=0) as log:
                subprocess.Popen(
                    ["/media/fat/MiSTer", str(CORE) if core_name() == "NDS" else "/media/fat/menu.rbf"],
                    stdin=subprocess.DEVNULL,
                    stdout=log,
                    stderr=log,
                    start_new_session=True,
                )
        # Main's argv names the already-loaded FPGA; it does not program it.
        # A command FIFO with a live reader proves Main reached its event loop.
        wait_for(lambda: len(mains()) == 1, 15)
        previous_main = mains()[0]
        cmd("load_core /media/fat/menu.rbf", 30)
        # Loading an RBF replaces Main. Require the previous epoch to exit so
        # an old CORENAME=MENU file cannot satisfy recovery prematurely.
        wait_for(lambda: not alive(previous_main) and core_name() == "MENU"
                 and len(mains()) == 1, 45)
        print("Normal MiSTer menu restored", flush=True)
        target = selected_core(state.get("selected_core")) if state.get("done") and state.get("host_returncode") == 0 else None
        if target and target.suffix.lower() == ".rbf" and target.stem.upper().startswith("NDS") and sha(target) != EXPECTED_CORE:
            state["selected_core_rejected"] = str(target)
            state["selected_core_message"] = (
                "This NDS core requires its matching helper. Normal MiSTer has been restored. "
                "Run that release's NDS_Kickstart, then select its core."
            )
            print("NDS4MiSTer: " + state["selected_core_message"], flush=True)
            target = None
        if target and target != SD_ROOT / "menu.rbf":
            # Only our exact FPGA may run with this package's renderer.
            # Other cores use Main alone; do not leave an NDS helper waiting.
            if target.suffix.lower() == ".rbf" and target.stem.upper().startswith("NDS"):
                assert sha(HELPER) == EXPECTED_HELPER and sha(Path(KICK)) == EXPECTED_KICKSTART
                env = {k: v for k, v in os.environ.items() if not k.startswith(("NDS", "H3D_"))}
                subprocess.run(["sh", KICK, "start"], check=True, env=env,
                               stdout=subprocess.DEVNULL, timeout=15)
            previous_main = mains()[0]
            cmd("load_core " + str(target), 30)
            wait_for(lambda: not alive(previous_main) and len(mains()) == 1, 45)
            print("Selected core loaded by normal MiSTer: " + str(target), flush=True)
        (RUNTIME / "recovery.json").write_text(
            json.dumps(
                dict(
                    at=time.time(),
                    core=core_name(),
                    reason=state.get("reason", "normal exit"),
                    selected_core=str(target) if target else None,
                    rejected_core=state.get("selected_core_rejected"),
                    message=state.get("selected_core_message"),
                )
            )
        )


def guard():
    # The guard owns cleanup; no competing recovery in the supervisor.
    state = json.loads(LEASE.read_text())
    Path("/tmp/nds-standalone-guard-ready").write_text(str(os.getpid()))
    host_exit_seen = None
    while True:
        try:
            state = json.loads(LEASE.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        if state.get("done"):
            state["reason"] = "host exited"
            break
        if not alive(state.get("supervisor")):
            state["reason"] = "supervisor disappeared"
            break
        if state.get("phase") == "running":
            if not alive(state.get("host")):
                # host.wait() and the supervisor's final journal can lag this
                # observer. Let it record the clean exit / selected core first.
                if host_exit_seen is None:
                    host_exit_seen = time.monotonic()
                if time.monotonic() - host_exit_seen < 2:
                    time.sleep(0.05)
                    continue
                state["reason"] = "host disappeared"
                break
            if not alive(state.get("helper")):
                state["reason"] = "renderer disappeared"
                break
            try:
                age = time.monotonic() - int(BEAT.read_text()) / 1000
            except (FileNotFoundError, ValueError):
                age = time.monotonic() - state["host_started"]
            if age > 20:
                state["reason"] = "host heartbeat expired"
                break
        elif time.monotonic() - state["started"] > 180:
            state["reason"] = "bootstrap timeout"
            break
        time.sleep(0.5)
    # Lock out a still-live supervisor before cleanup to avoid late startup.
    if state.get("reason") != "host exited" and alive(state.get("supervisor")):
        kill(state["supervisor"])
    try:
        recover(state)
    except Exception as e:
        (RUNTIME / "recovery-failed.txt").write_text(str(e))
        raise
    finally:
        Path("/tmp/nds-standalone-guard-ready").unlink(missing_ok=True)


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()



def prerequisite(condition, message):
    if not condition:
        raise RuntimeError(message + "; normal MiSTer was not changed")


def validate_previous_renderer():
    """Read-only check; never stop an unrecognized renderer."""
    pidfile = Path("/tmp/nds-hybrid-3d-service.pid")
    if not pidfile.exists():
        return
    try:
        pid = int(pidfile.read_text())
    except (ValueError, OSError):
        raise RuntimeError("Invalid existing renderer PID file; reboot before launching NDS4MiSTer")
    process = Path("/proc/%d/exe" % pid)
    if not process.exists():
        return
    normal = SD_ROOT / "Scripts/NDS_Support/nds_hybrid_3d_service"
    actual = process.resolve()
    if actual == normal:
        prerequisite(sha(process) == NORMAL_HELPER_SHA,
                     "Unrecognized normal NDS helper; reboot before starting NDS4MiSTer")
        prerequisite((SD_ROOT / "Scripts/NDS_Kickstart.sh").is_file(),
                     "Existing NDS helper has no matching stop script; reboot first")
    else:
        prerequisite(actual == HELPER and sha(process) == EXPECTED_HELPER,
                     "Another NDS test helper is running; exit it or reboot first")


def validate_settings():
    """Preserve the complete selected 128-bit config; reject malformed input."""
    for path in (KIT / "NDS_v1.CFG", SD_ROOT / "config/NDS_v1.CFG"):
        if path.exists():
            prerequisite(path.is_file() and len(path.read_bytes()) == 16,
                         "Invalid 16-byte NDS settings file: " + str(path))
            return path
    return None


def initialize_settings():
    """Create defaults exclusively on first install, never replace user config."""
    if validate_settings() is not None:
        return
    path = KIT / "NDS_v1.CFG"
    # Top/Bottom, Engine B On; rotation/FPS Off. No per-controller input maps.
    payload = bytes((0x20, 0x04)) + bytes(14)
    try:
        fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        validate_settings()
        return
    try:
        # A normal config may have appeared while obtaining the exclusive file.
        # It takes priority over newly generated defaults on this first run.
        if (SD_ROOT / "config/NDS_v1.CFG").exists():
            os.close(fd); fd = None
            path.unlink()
            validate_settings()
            return
        offset = 0
        while offset < len(payload):
            written = os.write(fd, payload[offset:])
            if written <= 0:
                raise OSError("Could not write first-run NDS settings")
            offset += written
        os.fsync(fd)
        os.close(fd); fd = None
        directory = os.open(str(KIT), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException:
        if fd is not None:
            os.close(fd)
        # Only this call could create this file because O_EXCL succeeded.
        path.unlink(missing_ok=True)
        raise


def preflight():
    """Check public dependencies and package before core loads or process changes."""
    prerequisite(sys.version_info >= (3, 8), "Python 3.8 or newer is required")
    prerequisite(os.geteuid() == 0, "Launch this script as the MiSTer root user")
    for program in ("sh", "sha256sum", "taskset", "start-stop-daemon", "pidof", "insmod", "rmmod"):
        prerequisite(shutil.which(program) is not None, "Missing system command: " + program)
    for path in (SD_ROOT / "MiSTer", SD_ROOT / "menu.rbf", Path("/dev/mem"), Path("/dev/MiSTer_cmd")):
        prerequisite(path.exists(), "Missing MiSTer system file: " + str(path))
    for path, expected in ((CORE, EXPECTED_CORE), (HELPER, EXPECTED_HELPER),
                           (Path(KICK), EXPECTED_KICKSTART),
                           (KIT / "support/nds_mem_wc.ko", EXPECTED_WC)):
        prerequisite(path.is_file() and sha(path) == expected,
                     "Package checksum mismatch or missing file: " + path.name)
    manifest = json.loads((KIT / "manifest.json").read_text())
    host = KIT / "nds_standalone_host"
    prerequisite(host.is_file() and sha(host) == manifest["host_sha256"],
                 "Standalone menu checksum mismatch")
    prerequisite(os.access(host, os.X_OK) and os.access(HELPER, os.X_OK),
                 "Standalone executables are not executable")
    for cpu in (0, 1):
        clock_root = Path("/sys/devices/system/cpu/cpu%d/cpufreq" % cpu)
        prerequisite(os.access(clock_root / "scaling_max_freq", os.W_OK),
                     "CPU%d clock control is unavailable; a compatible MiSTer kernel is required" % cpu)
        advertised = []
        for name in ("scaling_available_frequencies", "scaling_boost_frequencies"):
            try:
                advertised += (clock_root / name).read_text().split()
            except FileNotFoundError:
                pass
        prerequisite("1000000" in advertised,
                     "CPU%d does not advertise the required 1 GHz frequency" % cpu)
    # Pin the kernel family to the included module. A previously loaded module
    # can disappear when the outgoing renderer stops; do not rely on its node.
    vermagic = next((x[len(b"vermagic="):] for x in
                     (KIT / "support/nds_mem_wc.ko").read_bytes().split(b"\0")
                     if x.startswith(b"vermagic=")), b"").decode("ascii", "replace")
    prerequisite(vermagic.split() and vermagic.split()[0] == os.uname().release,
                 "The included write-combining module does not match this kernel")
    prerequisite(len(mains()) == 1, "Expected one normal MiSTer frontend")
    prerequisite(not Path("/tmp/nds-standalone-guard-ready").exists(),
                 "A standalone session or recovery is already active")
    validate_previous_renderer()
    validate_settings()
    # The shell preflight validates both support manifests without loading the
    # module, changing clocks, touching Wi-Fi or starting/stopping any process.
    subprocess.run(["sh", KICK, "preflight"], check=True, timeout=15,
                   stdout=subprocess.DEVNULL)


def stop_previous_renderer():
    pidfile = Path("/tmp/nds-hybrid-3d-service.pid")
    if pidfile.exists():
        pid = int(pidfile.read_text())
        process = Path("/proc/%d/exe" % pid)
        if process.exists():
            actual = process.resolve()
            normal = Path("/media/fat/Scripts/NDS_Support/nds_hybrid_3d_service")
            if actual == normal:
                assert sha(process) == NORMAL_HELPER_SHA
                subprocess.run(["sh", "/media/fat/Scripts/NDS_Kickstart.sh", "stop"], check=True, timeout=20)
            else:
                assert actual == HELPER and sha(process) == EXPECTED_HELPER, "Unknown renderer; refusing to replace it"
    subprocess.run(["sh", KICK, "stop"], check=True, stdout=subprocess.DEVNULL, timeout=15)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rom")
    ap.add_argument("--seconds", type=int, default=0)
    ap.add_argument("--guard", action="store_true")
    a = ap.parse_args()
    if a.guard:
        return guard()
    preflight()
    initialize_settings()
    RUNTIME.mkdir(mode=0o700, exist_ok=True)
    os.sched_setaffinity(0, {0, 1})
    lock = open("/tmp/nds-standalone-supervisor.lock", "w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    assert (
        sha(CORE) == EXPECTED_CORE and sha(HELPER) == EXPECTED_HELPER
    ), "Standalone core/helper mismatch; nothing changed"
    assert sha(Path(KICK)) == EXPECTED_KICKSTART, "Standalone Kickstart mismatch; nothing changed"
    assert (
        sha(KIT / "nds_standalone_host")
        == json.loads((KIT / "manifest.json").read_text())["host_sha256"]
    ), "Host mismatch"
    assert len(mains()) == 1, "Expected one normal MiSTer frontend"
    assert not Path(
        "/tmp/nds-standalone-guard-ready"
    ).exists(), "Recovery guard already active"
    if a.rom:
        assert Path(a.rom).is_file() and Path(a.rom).suffix.lower() == ".nds"
    state = dict(
        supervisor=ident(os.getpid()),
        started=time.monotonic(),
        phase="bootstrap",
        original_main=mains()[0],
        config=Path("/media/fat/config/NDS_v1.CFG").read_bytes().hex() if Path("/media/fat/config/NDS_v1.CFG").exists() else None,
    )

    def request_stop(_sig, _frame):
        raise KeyboardInterrupt("Standalone stop requested")

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    def write():
        tmp = LEASE.with_suffix(".new")
        tmp.write_text(json.dumps(state))
        os.replace(tmp, LEASE)

    write()
    def stage(name):
        state["stage"] = name
        write()
        print("Bootstrap: " + name, flush=True)

    stage("guard starting")
    BEAT.unlink(missing_ok=True)
    (KIT / "core-request.txt").unlink(missing_ok=True)
    (RUNTIME / "recovery-failed.txt").unlink(missing_ok=True)
    g_log = open(RUNTIME / "guard.log", "wb", buffering=0)
    g = subprocess.Popen(
        [sys.executable, __file__, "--guard"],
        stdin=subprocess.DEVNULL,
        stdout=g_log,
        stderr=g_log,
        start_new_session=True,
    )
    wait_for(lambda: Path("/tmp/nds-standalone-guard-ready").exists(), 10)
    try:
        stage("enter normal menu")
        if core_name() != "MENU":
            cmd("load_core /media/fat/menu.rbf")
            wait_for(lambda: core_name() == "MENU")
        stage("stop previous helper")
        stop_previous_renderer()
        # Use the exact release defaults; do not inherit an old experiment's
        # renderer flags or the launcher's offline lifecycle-test overrides.
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("NDS", "H3D_"))}
        stage("start verified helper")
        subprocess.run(
            ["sh", KICK, "start"],
            check=True,
            env=env,
            stdout=subprocess.DEVNULL,
            timeout=15,
        )
        release_pid = int(Path("/tmp/nds-hybrid-3d-service.pid").read_text())
        actual_env = renderer_environment(release_pid)
        for key, value in EXPECTED_SPEED_ENV.items():
            assert actual_env.get(key) == value, (key, actual_env.get(key))
        assert actual_env.get("NDS4MISTER_TIMING_PROFILE", "0") == "0", "Timing profile must be off"
        assert Path("/dev/nds_mem_wc").exists(), "Expected write-combining device"
        for cpu in (0, 1):
            frequency=Path("/sys/devices/system/cpu/cpu%d/cpufreq/scaling_max_freq" % cpu)
            assert frequency.read_text().strip()=="1000000", "Expected stock 1 GHz"
        state["wc_mapping_present"] = "/dev/nds_mem_wc" in Path("/proc/%d/maps" % release_pid).read_text()
        assert state["wc_mapping_present"], "Renderer did not establish a write-combining mapping"
        state["renderer_environment"] = actual_env
        state["release"] = "v0.6.0-beta"
        write()
        stage("load standalone core")
        previous = mains()[0]
        cmd("load_core " + str(CORE))
        wait_for(lambda: core_name() == "NDS" and not alive(previous))
        time.sleep(3)
        stage("normal NDS core loaded, inspecting renderer")
        hp = int(Path("/tmp/nds-hybrid-3d-service.pid").read_text())
        assert sha(Path("/proc/%d/exe" % hp)) == EXPECTED_HELPER
        # Record the shared header before takeover to separate reload failures
        # from frontend failures. This is not proof of visible gameplay.
        import mmap, struct
        with open("/dev/mem", "rb", buffering=0) as memory:
            with mmap.mmap(memory.fileno(), 4096, flags=mmap.MAP_SHARED,
                           prot=mmap.PROT_READ, offset=0x3fc00000) as page:
                state["before_takeover_header"] = list(struct.unpack("<32I",page[:128]))
        write()
        owned = mains()
        assert len(owned) == 1
        state["owned_main"] = owned[0]
        main_pid = owned[0]["pid"]
        state["main_scheduling"] = dict(affinity=sorted(os.sched_getaffinity(main_pid)),
                                        nice=os.getpriority(os.PRIO_PROCESS, main_pid),
                                        policy=os.sched_getscheduler(main_pid))
        state["cpu_frequency"] = {str(cpu): {name: Path(
            "/sys/devices/system/cpu/cpu%d/cpufreq/%s" % (cpu,name)).read_text().strip()
            for name in ("scaling_governor","scaling_min_freq","scaling_max_freq","scaling_cur_freq")}
            for cpu in (0,1)}
        state["renderer_threads"] = {p.name: dict(affinity=sorted(os.sched_getaffinity(int(p.name))),
            nice=os.getpriority(os.PRIO_PROCESS,int(p.name)),policy=os.sched_getscheduler(int(p.name)))
            for p in Path("/proc/%d/task" % hp).iterdir()}
        state["helper"] = ident(hp)
        write()
        stage("stop normal Main")
        kill(owned[0])
        assert not mains()
        hlog = open(RUNTIME / "host.log", "wb", buffering=0)
        host = subprocess.Popen(
            [
                str(KIT / "nds_standalone_host"),
                str(KIT),
                "/media/fat/games/NDS",
                a.rom or "-",
                str(a.seconds),
                str(os.getpid()),
            ],
            stdin=subprocess.DEVNULL,
            stdout=hlog,
            stderr=hlog,
            start_new_session=True,
        )
        # Keep the normal frontend's measured placement and priority. Letting
        # this small polling loop migrate across both renderer CPUs worsened
        # frame cadence despite reducing its total CPU consumption.
        os.sched_setaffinity(host.pid, set(state["main_scheduling"]["affinity"]))
        os.setpriority(os.PRIO_PROCESS, host.pid, state["main_scheduling"]["nice"])
        state["host_scheduling"] = dict(affinity=sorted(os.sched_getaffinity(host.pid)),
                                        nice=os.getpriority(os.PRIO_PROCESS, host.pid),
                                        policy=os.sched_getscheduler(host.pid))
        state.update(
            host=ident(host.pid), host_started=time.monotonic(), phase="running"
        )
        write()
        print("Standalone host started", host.pid, flush=True)
        rc = host.wait()
        state["host_returncode"] = rc
        target = collect_core_request(rc)
        if target:
            state["selected_core"] = str(target)
        print("Host returned", rc, flush=True)
    finally:
        state["done"] = True
        write()
        g.wait(timeout=90)
        if (RUNTIME / "recovery-failed.txt").exists():
            raise RuntimeError((RUNTIME / "recovery-failed.txt").read_text())


if __name__ == "__main__":
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print("NDS4MiSTer: " + str(error), file=sys.stderr, flush=True)
        sys.exit(1)
