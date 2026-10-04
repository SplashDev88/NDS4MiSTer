#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Model shared cpufreq policy and boost side effects without hardware access."""
import contextlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import clock_control as c


class Clock(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.cpu = self.base / 'cpu'
        self.policy = self.cpu / 'cpufreq/policy0'
        self.policy.mkdir(parents=True)
        for n in (0, 1):
            p = self.cpu / ('cpu%d' % n)
            p.mkdir()
            (p / 'cpufreq').symlink_to(self.policy, target_is_directory=True)
        self.values = dict(scaling_max_freq='800000', scaling_min_freq='400000',
            scaling_cur_freq='800000', cpuinfo_min_freq='400000',
            scaling_governor='performance', boost='0',
            scaling_available_frequencies='400000 800000',
            scaling_boost_frequencies='1000000 1200000',
            scaling_available_governors='powersave performance ondemand')
        for name, value in self.values.items():
            (self.policy / name).write_text(value)
        (self.cpu / 'cpufreq/boost').write_text('0')
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(c, 'CPU', self.cpu))
        self.stack.enter_context(patch.object(c, 'STATE', self.base / 'state.json'))
        self.stack.enter_context(patch.object(c.time, 'sleep'))
        self.modprobe = self.stack.enter_context(patch.object(c.subprocess, 'run'))
        self.writes = []
        self.frequencies = []
        self.original_write = c.write
        self.stack.enter_context(patch.object(c, 'write', side_effect=self.kernel_write))

    def kernel_write(self, path, value):
        value = str(value)
        self.writes.append((path.name, value))
        if path == self.policy / 'boost' and c.read(self.cpu / 'cpufreq/boost') == '0':
            raise OSError('per-policy boost disabled by global switch')
        self.original_write(path, value)
        if path == self.cpu / 'cpufreq/boost':
            self.original_write(self.policy / 'boost', value)
        if path.name == 'boost':
            # Linux boost rebuilds the table and raises the maximum, which
            # would select 1.2 GHz immediately under performance governor.
            self.original_write(self.policy / 'scaling_max_freq', '1200000' if value == '1' else '800000')
        gov = c.read(self.policy / 'scaling_governor')
        name = 'scaling_min_freq' if gov == 'powersave' else 'scaling_max_freq'
        freq = int(c.read(self.policy / name))
        self.original_write(self.policy / 'scaling_cur_freq', freq)
        self.frequencies.append(freq)

    def test_shared_policy_boost_never_runs_at_1200_and_restores(self):
        before = c.snapshot()
        c.start()
        self.assertEqual(len(c.policies()), 1)
        self.assertEqual(c.read(self.policy / 'scaling_cur_freq'), '1000000')
        self.assertLessEqual(max(self.frequencies), 1000000)
        c.restore()
        self.assertEqual(c.snapshot(), before)
        self.assertFalse(c.STATE.exists())

    def test_repeated_start_keeps_original_snapshot(self):
        before = c.snapshot()
        c.start(); saved = c.STATE.read_bytes()
        c.start(); self.assertEqual(c.STATE.read_bytes(), saved)
        c.restore(); self.assertEqual(c.snapshot(), before)

    def test_legacy_kernel_without_boost_switch(self):
        (self.policy / 'boost').unlink()
        (self.cpu / 'cpufreq/boost').unlink()
        before = c.snapshot()
        c.start(); self.assertEqual(c.read(self.policy / 'scaling_cur_freq'), '1000000')
        c.restore(); self.assertEqual(c.snapshot(), before)

    def test_rejected_frequency_rolls_back(self):
        before = c.snapshot()
        def fail(path, value):
            if path.name == 'scaling_max_freq' and str(value) == '1000000':
                raise OSError('frequency rejected')
            self.kernel_write(path, value)
        with patch.object(c, 'write', side_effect=fail):
            with self.assertRaisesRegex(OSError, 'rejected'): c.start()
        self.assertEqual(c.snapshot(), before)
        self.assertFalse(c.STATE.exists())

    def test_missing_frequency_changes_nothing(self):
        (self.policy / 'scaling_boost_frequencies').write_text('1200000')
        with self.assertRaisesRegex(RuntimeError, '1 GHz'): c.start()
        self.assertEqual(self.writes, [])
        self.assertFalse(c.STATE.exists())

    def test_probe_loads_driver_only_if_sysfs_is_missing(self):
        c.probe(); self.modprobe.assert_not_called()
        (self.policy / 'scaling_max_freq').unlink()
        def register(*args, **kwargs):
            (self.policy / 'scaling_max_freq').write_text('800000')
        self.modprobe.side_effect = register
        c.probe()
        self.modprobe.assert_called_once_with(['modprobe', 'socfpga-cpufreq'], check=True, timeout=10)
        self.assertEqual(self.writes, [])

    def test_no_owned_state_leaves_external_clock_unchanged(self):
        c.restore(); self.assertEqual(self.writes, [])


if __name__ == '__main__':
    unittest.main()
