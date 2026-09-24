#!/usr/bin/env python3
"""Exercise the actual Kickstart guard without touching the host network."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CONTROL = Path(__file__).resolve().with_name("nds_hybrid_3d_service_ctl.sh")


class WifiGuardTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nds-wifi-guard-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.proc = self.root / "proc"
        self.proc.mkdir()
        (self.root / "run").mkdir()
        self.config = {"addresses": {}, "states": {}, "mode": "normal"}
        self.add_wifi("wlan0", 501)
        tool = self.root / "fake-network"
        tool.write_text("#!" + sys.executable + "\n" + r'''
import json, os, pathlib, shutil, sys
r = pathlib.Path(os.environ['H3D_LIFECYCLE_TEST_ROOT'])
c = json.loads((r / 'config.json').read_text())
args = sys.argv[1:]
def record(event):
    with (r / 'actions.jsonl').open('a') as out:
        out.write(json.dumps(event) + '\n')
if args[:2] == ['-o', 'address']:
    interface = args[args.index('dev') + 1]
    counter = r / ('checks-' + interface)
    count = int(counter.read_text()) + 1 if counter.exists() else 1
    counter.write_text(str(count))
    if c.get('mode') == 'query-fails': sys.exit(1)
    if c.get('mode') == 'pid-reused' and count == 2:
        p = r / 'proc/501/stat'
        p.write_text(p.read_text().replace('12345', '54321'))
    if c.get('mode') == 'connects' and count == 2:
        (r / 'sys/class/net' / interface / 'carrier').write_text('1\n')
        print('inet 192.168.86.190/24 scope global')
    else:
        print(c['addresses'].get(interface, ''), end='')
elif args[:1] == ['-i']:
    if c.get('mode') == 'no-control-socket': sys.exit(1)
    print('wpa_state=' + c['states'].get(args[1], 'SCANNING'))
elif args[:1] == ['-K']:
    pid = pathlib.Path(args[args.index('-p') + 1]).read_text().strip()
    record(['stop', pid, args])
    if c.get('mode') == 'stop-fails': sys.exit(1)
    if c.get('mode') != 'stop-hangs': shutil.rmtree(r / 'proc' / pid)
elif args[:3] == ['link', 'set', 'dev']:
    assert args[4] == 'down'
    record(['down', args[3]])
else:
    raise RuntimeError(args)
''')
        tool.chmod(0o755)
        self.environment = dict(os.environ,
            H3D_LIFECYCLE_TEST_ROOT=str(self.root),
            H3D_TEST_PROC_ROOT=str(self.proc),
            H3D_TEST_IP=str(tool), H3D_TEST_WPA_CLI=str(tool),
            H3D_TEST_WIFI_STOP=str(tool))

    def add_wifi(self, interface, pid, carrier="0", comm="wpa_supplicant", args=None):
        net = self.root / "sys/class/net" / interface
        net.mkdir(parents=True)
        (net / "carrier").write_text(carrier + "\n")
        p = self.proc / str(pid)
        p.mkdir()
        (p / "stat").write_text(f"{pid} ({comm}) S " + "0 " * 18 + "12345 0\n")
        args = args or ["wpa_supplicant", "-s", "-B", "-i", interface]
        (p / "cmdline").write_bytes(b"\0".join(a.encode() for a in args) + b"\0")
        (p / "exe").symlink_to("/usr/sbin/wpa_supplicant")
        (self.root / "run" / f"wpa_supplicant.{interface}.pid").write_text(str(pid) + "\n")

    def run_guard(self):
        (self.root / "config.json").write_text(json.dumps(self.config))
        result = subprocess.run(["/bin/sh", str(CONTROL), "__test_quiet_wifi"],
            env=self.environment, capture_output=True, text=True, timeout=8)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        trace = self.root / "actions.jsonl"
        return [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []

    def assert_stopped(self):
        actions = self.run_guard()
        self.assertEqual([x[0] for x in actions], ["stop", "down"])
        self.assertEqual(actions[0][1], "501")
        self.assertEqual(actions[1][1], "wlan0")

    def test_offline_play_stops_retries_without_ethernet(self):
        self.assert_stopped()

    def test_wired_play_stops_retries(self):
        wired = self.root / "sys/class/net/eth0"
        wired.mkdir(); (wired / "carrier").write_text("1\n")
        self.assert_stopped()

    def test_connected_wifi_is_preserved(self):
        (self.root / "sys/class/net/wlan0/carrier").write_text("1\n")
        self.assertEqual(self.run_guard(), [])

    def test_addresses_protect_transient_wifi_link_drop(self):
        for address in ["inet 192.168.86.190/24 scope global", "inet6 2001:db8::1/64 scope global"]:
            with self.subTest(address=address):
                self.config["addresses"]["wlan0"] = address
                self.assertEqual(self.run_guard(), [])

    def test_association_in_progress_is_preserved(self):
        for state in ["ASSOCIATING", "ASSOCIATED", "4WAY_HANDSHAKE", "GROUP_HANDSHAKE", "COMPLETED"]:
            with self.subTest(state=state):
                self.config["states"]["wlan0"] = state
                self.assertEqual(self.run_guard(), [])

    def test_missing_control_socket_uses_carrier_and_addresses(self):
        self.config["mode"] = "no-control-socket"
        self.assert_stopped()

    def test_unknown_address_state_is_preserved(self):
        self.config["mode"] = "query-fails"
        self.assertEqual(self.run_guard(), [])

    def test_stale_pid_file_cannot_signal_another_process(self):
        p = self.proc / "501/stat"
        p.write_text(p.read_text().replace("wpa_supplicant", "MiSTer"))
        self.assertEqual(self.run_guard(), [])

    def test_wrong_interface_is_preserved(self):
        (self.proc / "501/cmdline").write_bytes(b"wpa_supplicant\0-i\0wlan1\0")
        self.assertEqual(self.run_guard(), [])

    def test_multi_interface_daemon_is_preserved(self):
        (self.proc / "501/cmdline").write_bytes(b"wpa_supplicant\0-i\0wlan0\0-N\0-i\0wlan1\0")
        self.assertEqual(self.run_guard(), [])

    def test_symlink_pid_file_is_preserved(self):
        pidfile = self.root / "run/wpa_supplicant.wlan0.pid"
        pidfile.rename(self.root / "other.pid"); pidfile.symlink_to(self.root / "other.pid")
        self.assertEqual(self.run_guard(), [])

    def test_pid_reuse_during_checks_is_preserved(self):
        self.config["mode"] = "pid-reused"
        self.assertEqual(self.run_guard(), [])

    def test_connection_during_checks_is_preserved(self):
        self.config["mode"] = "connects"
        self.assertEqual(self.run_guard(), [])

    def test_failed_or_slow_shutdown_does_not_lower_interface(self):
        for mode in ["stop-fails", "stop-hangs"]:
            with self.subTest(mode=mode):
                trace = self.root / "actions.jsonl"
                if trace.exists(): trace.unlink()
                self.config["mode"] = mode
                self.assertEqual([x[0] for x in self.run_guard()], ["stop"])

    def test_connected_second_adapter_is_preserved(self):
        self.add_wifi("wlan1", 502, carrier="1")
        self.assert_stopped()
        self.assertTrue((self.proc / "502").exists())

    def test_repeated_kickstart_is_idempotent(self):
        self.assert_stopped()
        self.assertEqual(len(self.run_guard()), 2)


if __name__ == "__main__":
    unittest.main()
