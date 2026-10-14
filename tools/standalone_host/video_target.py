#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Shared Direct Video preference, pre-launch UI, and recoverable bootstrap CFG."""
from pathlib import Path
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import time

PREFERENCE = "NDS_video.cfg"
JOURNAL = "bootstrap-video-restore.json"
HEADER = "NDS-DirectVideo-v1\n"
TARGETS = ("crt", "retrotink")


def sync_directory(path):
    fd = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_bytes(path, data, mode=0o644):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), mode)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_target(kit):
    try:
        contents = (Path(kit) / PREFERENCE).read_text()
    except FileNotFoundError:
        return "crt"
    for target in TARGETS:
        if contents == HEADER + target + "\n":
            return target
    # Fail safe without rewriting an unrecognized user preference.
    return "crt"


def save_target(kit, target):
    if target not in TARGETS:
        raise ValueError("Unknown Direct Video target")
    atomic_bytes(Path(kit) / PREFERENCE, (HEADER + target + "\n").encode())


def bootstrap_settings(payload):
    if len(payload) != 16:
        raise ValueError("NDS settings must contain exactly 16 bytes")
    status = int.from_bytes(payload[:2], "little")
    # Start in one fixed 262-line raster, before the standalone host can read
    # Main's actual output flags. Preserve order, rotation and every other word.
    # On scaled HDMI this is only the bootstrap picture, not a video-mode change.
    status |= (1 << 13) | (1 << 6) | (1 << 10)
    if not (int.from_bytes(payload[:2], "little") & (1 << 6)):
        status &= ~(1 << 5)
    return status.to_bytes(2, "little") + payload[2:]


def restore_bootstrap(kit, sd_root):
    journal = Path(kit) / JOURNAL
    if not journal.exists():
        return False
    record = json.loads(journal.read_text())
    if record.get("version") != 1:
        raise RuntimeError("Unrecognized bootstrap settings backup; recovery retained")
    original = bytes.fromhex(record["original"]) if record["original"] is not None else None
    applied = bytes.fromhex(record["applied"])
    if len(applied) != 16 or (original is not None and len(original) != 16):
        raise RuntimeError("Invalid bootstrap settings backup; recovery retained")
    path = Path(sd_root) / "config/NDS_v1.CFG"
    if path.is_symlink():
        raise RuntimeError("NDS config is a symbolic link; bootstrap backup retained")
    current = path.read_bytes() if path.exists() else None
    if current != original:
        if current != applied:
            raise RuntimeError("NDS settings changed during bootstrap; backup retained at " + str(journal))
        if original is None:
            path.unlink()
            sync_directory(path.parent)
        else:
            atomic_bytes(path, original, record.get("mode", 0o644))
    journal.unlink()
    sync_directory(journal.parent)
    return True


def stage_bootstrap(kit, sd_root, payload):
    journal = Path(kit) / JOURNAL
    if journal.exists():
        raise RuntimeError("Previous bootstrap settings backup needs recovery")
    path = Path(sd_root) / "config/NDS_v1.CFG"
    if path.is_symlink():
        raise RuntimeError("NDS config is a symbolic link; nothing overwritten")
    original = path.read_bytes() if path.exists() else None
    mode = (path.stat().st_mode & 0o777) if original is not None else 0o644
    if original is not None and len(original) != 16:
        raise RuntimeError("Invalid normal NDS settings; nothing overwritten")
    applied = bootstrap_settings(payload)
    # Journal is durable before touching normal settings. Recovery is idempotent
    # after interruption at any write/rename; power loss leaves this on the SD.
    atomic_bytes(journal, (json.dumps(dict(version=1, original=original.hex() if original is not None else None,
                                         applied=applied.hex(), mode=mode)) + "\n").encode())
    path.parent.mkdir(parents=True, exist_ok=True)
    atomic_bytes(path, applied, mode)


class StartupKeys:
    """Recognize terminal F4 sequences even when delivered across reads."""
    F4 = (b"\x1bOS", b"\x1b[14~", b"\x1b[[D")

    def __init__(self):
        self.pending = b""

    def feed(self, data):
        self.pending = (self.pending + data)[-64:]
        if any(key in self.pending for key in self.F4):
            self.pending = b""
            return "advanced"
        if b"\r" in data or b"\n" in data:
            return "start"
        return None


def advanced_menu(kit):
    selected = read_target(kit)
    explanation = (
        "Most users do not need to change this.\n\n"
        "Only applies to Direct Video through HDMI.\n"
        "Native analog outputs work automatically.\n"
        "Standard HDMI is unaffected.\n\n"
        "CRT: HDMI-to-VGA adapter -> RGB CRT / SCART.\n"
        "RetroTINK / Scaler: HDMI -> compatible scaler.\n\n"
        "Also available as DV Target in the NDS core menu."
    )
    if shutil.which("dialog"):
        result = subprocess.run([
            "dialog", "--stdout", "--clear", "--title", "NDS4MiSTer - Advanced Options",
            "--ok-label", "Save and Start", "--cancel-label", "Cancel",
            "--radiolist", explanation, "0", "0", "0",
            "CRT", "One screen at 240p", "on" if selected == "crt" else "off",
            "Scaler", "RetroTINK / Scaler - all layouts", "on" if selected == "retrotink" else "off",
        ], stdout=subprocess.PIPE, text=True)
        if result.returncode == 0:
            value = result.stdout.strip()
            if value not in ("CRT", "Scaler"):
                raise RuntimeError("Invalid Direct Video menu selection")
            save_target(kit, "crt" if value == "CRT" else "retrotink")
        elif result.returncode not in (1, 255):
            raise RuntimeError("Advanced Options could not open on this terminal")
    else:
        print("\nNDS4MiSTer - Advanced Options\n\n" + explanation)
        print("\n1. CRT - one screen at 240p\n2. RetroTINK / Scaler - all layouts")
        answer = input("Choose 1 or 2 to save and start; Enter to cancel: ").strip()
        if answer in ("1", "2"):
            save_target(kit, "crt" if answer == "1" else "retrotink")


def startup_menu(kit, force=False, seconds=3):
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        if force:
            raise RuntimeError("Advanced Options requires an interactive terminal")
        return
    if force:
        return advanced_menu(kit)
    fd = sys.stdin.fileno()
    original = termios.tcgetattr(fd)
    mode = termios.tcgetattr(fd)
    mode[3] &= ~(termios.ICANON | termios.ECHO)
    mode[6][termios.VMIN] = 0
    mode[6][termios.VTIME] = 0
    keys = StartupKeys()
    action = None
    print("\nNDS4MiSTer\n\n[F4] Advanced Options    [Enter] Start\n", flush=True)
    try:
        termios.tcsetattr(fd, termios.TCSANOW, mode)
        deadline = time.monotonic() + seconds
        shown = None
        while time.monotonic() < deadline:
            remaining = max(1, int(deadline - time.monotonic() + 0.999))
            if remaining != shown:
                print("\rStarting in %d... " % remaining, end="", flush=True)
                shown = remaining
            if select.select([fd], [], [], min(0.1, max(0, deadline - time.monotonic())))[0]:
                data = os.read(fd, 64)
                if not data:
                    break
                action = keys.feed(data)
                if action:
                    break
    finally:
        termios.tcsetattr(fd, termios.TCSANOW, original)
        print("\r" + " " * 30 + "\r", end="", flush=True)
    if action == "advanced":
        advanced_menu(kit)
