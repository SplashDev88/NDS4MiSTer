#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Frontend discovery and recovery using an offline /proc fixture."""
from pathlib import Path
import contextlib
import importlib.util
import json
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "frontend_supervisor", Path(__file__).with_name("supervisor.py"))
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


class Frontends(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.proc = self.root / "proc"
        self.proc.mkdir()
        self.sd = self.root / "media/fat"
        self.sd.mkdir(parents=True)
        self.kit = self.sd / "Scripts/.NDS_Standalone"
        self.kit.mkdir(parents=True)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir()
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)

        def path(*args):
            value = Path(*args)
            if value == Path("/proc") or Path("/proc") in value.parents:
                return self.proc / value.relative_to("/proc")
            return value

        stack.enter_context(patch.object(s, "Path", side_effect=path))
        for name, value in (("SD_ROOT", self.sd), ("KIT", self.kit),
                            ("RUNTIME", self.runtime)):
            stack.enter_context(patch.object(s, name, value))
        for name in s.MAIN_PATHS:
            self.executable(self.sd / name)

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"frontend fixture")
        path.chmod(0o755)
        return path

    def process(self, pid, executable, epoch="1234", state="S", comm=None):
        directory = self.proc / str(pid)
        directory.mkdir()
        comm = comm or Path(executable).name[:15]
        (directory / "comm").write_text(comm + "\n")
        (directory / "stat").write_text(
            "%d (%s) %s " % (pid, comm, state) + "0 " * 18 + epoch + " 0\n")
        (directory / "exe").symlink_to(executable)
        return directory

    def exit_process(self, pid):
        directory = self.proc / str(pid)
        for path in directory.iterdir():
            path.unlink()
        directory.rmdir()

    def test_supported_frontends_are_found_by_executable_with_truncated_comm(self):
        for pid, name in enumerate(s.MAIN_PATHS, 100):
            with self.subTest(name=name):
                self.process(pid, self.sd / name)
                self.assertEqual(s.require_main(), {
                    "pid": pid, "epoch": "1234", "exe": str(self.sd / name)})
                self.exit_process(pid)

    def test_argv_and_comm_do_not_authorize_an_unrelated_executable(self):
        paths = (self.root / "other/MiSTer", self.sd / "MiSTer_backup",
                 self.sd / "MiSTer_Physical-CD-helper",
                 self.sd / "other/MiSTer_Zaparoo")
        for pid, path in enumerate(paths, 100):
            directory = self.process(pid, self.executable(path), comm="MiSTer")
            (directory / "cmdline").write_bytes(str(self.sd / "MiSTer").encode() + b"\0")
        self.assertEqual(s.mains(), [])
        with self.assertRaisesRegex(RuntimeError, "found 0"):
            s.require_main()

    def test_stock_symlink_to_physical_cd_uses_resolved_executable(self):
        stock = self.sd / "MiSTer"
        stock.unlink()
        stock.symlink_to(self.sd / "MiSTer_Physical-CD")
        self.process(100, stock.resolve())
        self.assertEqual(s.require_main()["exe"], str(stock.resolve()))

    def test_multiple_frontends_are_rejected(self):
        for pid, name in enumerate(("MiSTer", "zaparoo/MiSTer_Zaparoo"), 100):
            self.process(pid, self.sd / name)
        with self.assertRaisesRegex(RuntimeError, "found 2"):
            s.require_main()

    def test_launcher_ui_and_core_service_are_not_main_processes(self):
        for pid, name in enumerate(("zaparoo/frontend", "Scripts/zaparoo.sh",
                                    "zaparoo/zaparoo.service.sh", "degauss/degauss",
                                    "ConsoleMode/ConsoleMode_arm"), 100):
            self.process(pid, self.executable(self.sd / name))
        self.assertEqual(s.mains(), [])
        self.process(200, self.sd / "zaparoo/MiSTer_Zaparoo")
        self.assertEqual(s.require_main()["pid"], 200)

    def test_symlinked_frontend_directory_cannot_redirect_recovery(self):
        zaparoo = self.sd / "zaparoo"
        (zaparoo / "MiSTer_Zaparoo").unlink()
        zaparoo.rmdir()
        outside = self.executable(self.root / "other/MiSTer_Zaparoo")
        zaparoo.symlink_to(outside.parent, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "Unsupported"):
            s.main_executable(zaparoo / "MiSTer_Zaparoo")
        self.process(100, outside)
        self.assertEqual(s.mains(), [])

    def test_zombie_and_vanished_processes_are_ignored(self):
        self.process(100, self.sd / "MiSTer", state="Z")
        directory = self.process(101, self.sd / "MiSTer_Physical-CD")
        (directory / "exe").unlink()
        self.assertEqual(s.mains(), [])

    def test_reused_pid_during_discovery_is_not_selected(self):
        self.process(100, self.sd / "MiSTer")
        with patch.object(s, "epoch", side_effect=["old", "new"]):
            self.assertEqual(s.mains(), [])

    def test_deleted_frontend_counts_as_owner_but_blocks_takeover(self):
        self.process(100, str(self.sd / "MiSTer_Physical-CD") + " (deleted)")
        self.assertEqual(len(s.mains()), 1)
        with self.assertRaisesRegex(RuntimeError, "Cannot restore.*normal MiSTer was not changed"):
            s.require_main()

    def test_nonexecutable_frontend_blocks_takeover(self):
        executable = self.sd / "MiSTer_Physical-CD"
        executable.chmod(0o644)
        self.process(100, executable)
        with self.assertRaisesRegex(RuntimeError, "Cannot restore"):
            s.require_main()

    def test_replaced_running_binary_blocks_takeover(self):
        self.process(100, self.sd / "MiSTer")
        with patch.object(Path, "samefile", return_value=False):
            with self.assertRaisesRegex(RuntimeError, "changed during validation"):
                s.require_main()

    def test_recovery_refuses_unsupported_and_redirected_saved_paths(self):
        physical = self.sd / "MiSTer_Physical-CD"
        outside = self.executable(self.root / "other/MiSTer")
        physical.unlink()
        physical.symlink_to(outside)
        for target in (physical, outside, self.sd / "MiSTer_backup"):
            with self.subTest(target=target), patch.object(s, "kill"), \
                    patch.object(s.subprocess, "run"), patch.object(s.subprocess, "Popen") as spawn:
                with self.assertRaisesRegex(RuntimeError, "Unsupported"):
                    s.recover({"original_main": {"exe": str(target)}})
                spawn.assert_not_called()

    def recovery_after_core_switch(self, name):
        frontend = self.sd / name
        self.process(100, frontend)
        # This identity is journaled before a core-specific main= setting can
        # replace the menu frontend with stock Main while bootstrapping NDS.
        state = json.loads(json.dumps({"original_main": s.require_main()}))
        self.exit_process(100)
        self.process(101, self.sd / "MiSTer")
        self.assertEqual(s.require_main()["exe"], str(self.sd / "MiSTer"))
        self.exit_process(101)  # Standalone host takes ownership.
        events = []
        core = ["NDS"]

        def spawn(args, **kwargs):
            events.append("restart")
            self.assertEqual(args, [str(frontend), str(s.CORE)])
            self.assertEqual(kwargs["cwd"], str(self.sd))
            self.process(102, frontend)

        def command(value, timeout):
            self.assertEqual(value, "load_core menu.rbf")
            events.append("menu")
            self.exit_process(102)
            self.process(103, frontend)
            core[0] = "MENU"

        with patch.object(s, "kill", side_effect=lambda p: events.append("stop host")), \
                patch.object(s.fcntl, "flock", side_effect=lambda *a: events.append("lock")), \
                patch.object(s.subprocess, "run", side_effect=lambda *a, **k: events.append("stop helper")), \
                patch.object(s.subprocess, "Popen", side_effect=spawn) as popen, \
                patch.object(s, "core_name", side_effect=lambda: core[0]), \
                patch.object(s, "cmd", side_effect=command):
            s.recover(state)
        self.assertEqual(events, ["stop host", "lock", "stop helper", "restart", "menu"])
        popen.assert_called_once()
        self.assertEqual(s.require_main()["exe"], str(frontend))
        self.assertEqual(json.loads((self.runtime / "recovery.json").read_text())["core"], "MENU")
        self.exit_process(103)

    def test_recovery_restores_each_variant_after_core_switched_to_stock(self):
        for name in s.MAIN_PATHS:
            with self.subTest(frontend=name):
                self.recovery_after_core_switch(name)

    def test_menu_recovery_uses_alias_for_startup_and_core_load(self):
        frontend = self.sd / "zaparoo/MiSTer_Zaparoo"
        events = []

        def spawn(args, **kwargs):
            self.assertEqual(args, [str(frontend), "menu.rbf"])
            self.process(100, frontend)

        def command(value, timeout):
            events.append(value)
            self.exit_process(100)
            self.process(101, frontend)

        with patch.object(s, "kill"), patch.object(s.subprocess, "run"), \
                patch.object(s.subprocess, "Popen", side_effect=spawn), \
                patch.object(s, "core_name", return_value="MENU"), \
                patch.object(s, "cmd", side_effect=command):
            s.recover({"original_main": {"exe": str(frontend)}})
        self.assertEqual(events, ["load_core menu.rbf"])

    def test_recovery_reuses_existing_physical_cd_without_duplicate_start(self):
        physical = self.sd / "MiSTer_Physical-CD"
        self.process(100, physical)
        state = {"original_main": s.require_main()}

        def command(value, timeout):
            self.exit_process(100)
            self.process(101, physical)

        with patch.object(s, "kill"), patch.object(s.subprocess, "run"), \
                patch.object(s.subprocess, "Popen") as spawn, \
                patch.object(s, "core_name", return_value="MENU"), \
                patch.object(s, "cmd", side_effect=command):
            s.recover(state)
        spawn.assert_not_called()
        self.assertEqual(len(s.mains()), 1)


if __name__ == "__main__":
    unittest.main()
