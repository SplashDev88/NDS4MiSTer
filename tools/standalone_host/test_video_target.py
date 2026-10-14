# SPDX-License-Identifier: GPL-3.0-only
from pathlib import Path
from unittest.mock import patch
import json
import tempfile
import unittest
import os
import pty
import select
import subprocess
import sys
import time
import video_target as v


class VideoTarget(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.kit = self.root / "kit"
        self.kit.mkdir()
        self.normal = self.root / "config/NDS_v1.CFG"
        self.normal.parent.mkdir()
        self.payload = bytes((0x20, 0x44)) + bytes(range(2, 16))

    def test_preference_default_round_trip_and_unknown_is_safe(self):
        self.assertEqual(v.read_target(self.kit), "crt")
        self.assertFalse((self.kit / v.PREFERENCE).exists())
        for target in v.TARGETS:
            v.save_target(self.kit, target)
            self.assertEqual(v.read_target(self.kit), target)
        path = self.kit / v.PREFERENCE
        path.write_text("future version")
        self.assertEqual(v.read_target(self.kit), "crt")
        self.assertEqual(path.read_text(), "future version")
        with self.assertRaises(ValueError): v.save_target(self.kit, "wrong")

    def test_initial_raster_safe_for_every_layout_and_other_bits_preserved(self):
        allowed = (1 << 13) | (1 << 10) | (3 << 5)
        for status in range(65536):
            data = status.to_bytes(2, "little") + self.payload[2:]
            result = v.bootstrap_settings(data)
            word = int.from_bytes(result[:2], "little")
            self.assertTrue(word & (1 << 13))
            self.assertTrue(word & (1 << 6))
            self.assertEqual(word & ~allowed, status & ~allowed)
            self.assertEqual(result[2:], data[2:])
            if status & (1 << 6): self.assertEqual(word & (3 << 5), status & (3 << 5))

    def test_existing_settings_are_restored_exactly_and_mode_preserved(self):
        original = bytes(range(16))
        self.normal.write_bytes(original)
        self.normal.chmod(0o640)
        v.stage_bootstrap(self.kit, self.root, self.payload)
        self.assertEqual(self.normal.read_bytes(), v.bootstrap_settings(self.payload))
        self.assertTrue((self.kit / v.JOURNAL).exists())
        self.assertTrue(v.restore_bootstrap(self.kit, self.root))
        self.assertEqual(self.normal.read_bytes(), original)
        self.assertEqual(self.normal.stat().st_mode & 0o777, 0o640)
        self.assertFalse(v.restore_bootstrap(self.kit, self.root))

    def test_missing_normal_settings_are_removed_on_recovery(self):
        v.stage_bootstrap(self.kit, self.root, self.payload)
        v.restore_bootstrap(self.kit, self.root)
        self.assertFalse(self.normal.exists())

    def test_interruption_before_config_write_keeps_original(self):
        original = bytes(range(16))
        self.normal.write_bytes(original)
        real = v.atomic_bytes
        def fail_config(path, *args):
            if path == self.normal: raise OSError("interrupted")
            real(path, *args)
        with patch.object(v, "atomic_bytes", side_effect=fail_config):
            with self.assertRaises(OSError): v.stage_bootstrap(self.kit, self.root, self.payload)
        self.assertEqual(self.normal.read_bytes(), original)
        v.restore_bootstrap(self.kit, self.root)
        self.assertEqual(self.normal.read_bytes(), original)

    def test_interruption_after_restore_rename_is_idempotent(self):
        original = bytes(range(16))
        self.normal.write_bytes(original)
        v.stage_bootstrap(self.kit, self.root, self.payload)
        self.normal.write_bytes(original)  # disk rename completed; journal removal did not
        self.assertTrue(v.restore_bootstrap(self.kit, self.root))
        self.assertEqual(self.normal.read_bytes(), original)

    def test_recovery_does_not_overwrite_an_external_change(self):
        original = bytes(range(16))
        self.normal.write_bytes(original)
        v.stage_bootstrap(self.kit, self.root, self.payload)
        changed = bytes(reversed(range(16)))
        self.normal.write_bytes(changed)
        with self.assertRaisesRegex(RuntimeError, "changed during bootstrap"):
            v.restore_bootstrap(self.kit, self.root)
        self.assertEqual(self.normal.read_bytes(), changed)
        self.assertEqual(json.loads((self.kit / v.JOURNAL).read_text())["original"], original.hex())

    def test_invalid_or_linked_config_is_not_overwritten(self):
        self.normal.write_bytes(b"bad")
        with self.assertRaises(RuntimeError): v.stage_bootstrap(self.kit, self.root, self.payload)
        self.assertEqual(self.normal.read_bytes(), b"bad")
        self.normal.unlink()
        destination = self.root / "linked"
        destination.write_bytes(self.payload)
        self.normal.symlink_to(destination)
        with self.assertRaises(RuntimeError): v.stage_bootstrap(self.kit, self.root, self.payload)
        self.assertTrue(self.normal.is_symlink())
        self.assertEqual(destination.read_bytes(), self.payload)

    def test_terminal_sequences_and_fragmentation(self):
        for sequence in v.StartupKeys.F4:
            for split in range(1, len(sequence)):
                keys = v.StartupKeys()
                self.assertIsNone(keys.feed(sequence[:split]))
                self.assertEqual(keys.feed(sequence[split:]), "advanced")
        self.assertEqual(v.StartupKeys().feed(b"\r"), "start")
        self.assertIsNone(v.StartupKeys().feed(b"random"))

    def test_noninteractive_launch_never_waits_or_writes(self):
        with patch.object(v.sys.stdin, "isatty", return_value=False), patch.object(v, "advanced_menu") as menu:
            v.startup_menu(self.kit)
            menu.assert_not_called()
            with self.assertRaises(RuntimeError): v.startup_menu(self.kit, force=True)
        self.assertFalse((self.kit / v.PREFERENCE).exists())

    def test_real_terminal_f4_selection_and_cancel_restore_terminal(self):
        for sequence, answer, expected in [(b"\x1b[[D", b"2\n", "retrotink"),
                                            (b"\x1bOS", b"\n", "retrotink")]:
            master, slave = pty.openpty()
            # Reproduce Main's queued script-selection input before startup.
            os.write(master, b"\x1b[B\r\n")
            program = (
                "import sys,termios,video_target as v; "
                "v.shutil.which=lambda _:None; "
                "before=termios.tcgetattr(0); "
                "v.startup_menu(sys.argv[1],seconds=3); "
                "assert before==termios.tcgetattr(0); print('TERMINAL_RESTORED')"
            )
            child = subprocess.Popen([sys.executable, "-c", program, str(self.kit)],
                                     cwd=str(Path(v.__file__).parent), stdin=slave, stdout=slave, stderr=slave)
            os.close(slave)
            output = b""
            def until(marker):
                nonlocal output
                deadline = time.monotonic() + 5
                while marker not in output and time.monotonic() < deadline:
                    if select.select([master], [], [], 0.1)[0]:
                        output += os.read(master, 4096)
                self.assertIn(marker, output)
            try:
                until(b"Starting in")
                self.assertIn(b"\x1b[2J\x1b[H", output)
                os.write(master, sequence)
                until(b"Enter to cancel")
                os.write(master, answer)
                until(b"TERMINAL_RESTORED")
                self.assertEqual(child.wait(timeout=5), 0)
                self.assertEqual(v.read_target(self.kit), expected)
            finally:
                if child.poll() is None: child.kill(); child.wait()
                os.close(master)


if __name__ == "__main__": unittest.main()
