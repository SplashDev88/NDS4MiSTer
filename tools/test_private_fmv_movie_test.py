#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Exercise launcher rejection using synthetic files; no MiSTer is accessed."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class MovieTestAdmission(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.program = self.root / "movie_test.py"
        shutil.copyfile(Path(__file__).with_name("private_fmv_movie_test.py"), self.program)
        self.components = {}
        for name in ["NDS_Standalone.rbf", "nds_standalone_host", "supervisor.py",
                     "Kickstart.sh", "support/nds_hybrid_3d_service"]:
            path = self.root / name
            path.parent.mkdir(exist_ok=True)
            path.write_bytes(("synthetic " + name).encode())
            self.components[name] = sha(path)
        self.rom = self.root / "synthetic.nds"
        data = bytearray(512)
        data[12:16] = b"TEST"
        self.rom.write_bytes(data)
        self.alias = Path("/tmp") / ("NDS FMV synthetic " + self.root.name + ".nds")
        self.registry = {"version": 1, "components": self.components, "games": {
            "fixture": {"title": "Synthetic fixture", "rom": str(self.rom),
                        "alias": str(self.alias), "sha256": sha(self.rom),
                        "code": "TEST", "revision": 0}}}
        self.seal()

    def seal(self):
        registry = self.root / "FMV_MOVIE_TEST.json"
        registry.write_text(json.dumps(self.registry))
        (self.root / "manifest.json").write_text(json.dumps({
            "private_test_ready": True,
            "movie_test_registry_sha256": sha(registry),
            "movie_test_program_sha256": sha(self.program)}))

    def run_check(self, good, message="", game="fixture"):
        result = subprocess.run([sys.executable, str(self.program), "--game", game,
                                 "--validate-only"], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0 if good else 1, result.stdout + result.stderr)
        self.assertIn(message, result.stdout + result.stderr)
        self.assertFalse(self.alias.exists())

    def test_valid_bundle_remains_read_only(self):
        original = self.rom.read_bytes()
        self.run_check(True, "FMV_MOVIE_TEST_VALIDATION_PASS fixture")
        self.assertEqual(self.rom.read_bytes(), original)

    def test_changed_rom_tail_is_rejected(self):
        data = bytearray(self.rom.read_bytes())
        data[-1] = 1
        self.rom.write_bytes(data)
        self.run_check(False, "Prepared test copy changed")

    def test_mixed_renderer_is_rejected(self):
        (self.root / "support/nds_hybrid_3d_service").write_bytes(b"other build")
        self.run_check(False, "Mismatched component")

    def test_changed_registry_is_rejected(self):
        with (self.root / "FMV_MOVIE_TEST.json").open("a") as stream:
            stream.write(" ")
        self.run_check(False, "registry does not match")

    def test_header_revision_is_checked(self):
        self.registry["games"]["fixture"]["revision"] = 1
        self.seal()
        self.run_check(False, "Unexpected cartridge identity")

    def test_unknown_game_is_rejected(self):
        self.run_check(False, "Unknown prepared game", "unlisted")

    def test_incomplete_component_checks_are_rejected(self):
        del self.components["supervisor.py"]
        self.seal()
        self.run_check(False, "Incomplete movie-test component")


if __name__ == "__main__":
    unittest.main()
