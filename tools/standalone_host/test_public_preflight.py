#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline package/preflight/ownership regressions. Never talks to MiSTer."""
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import contextlib, hashlib, importlib.util, json, os, tempfile, unittest

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('public_supervisor', ROOT/'supervisor.py')
s = importlib.util.module_from_spec(spec); spec.loader.exec_module(s)

class Preflight(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name); self.kit = self.root/'media/fat/Scripts/.NDS_Standalone'
        self.kit.mkdir(parents=True)
        self.stack = contextlib.ExitStack(); self.addCleanup(self.stack.close)
        def mockpath(*args):
            result = Path(*args)
            return self.root/str(result).lstrip('/') if str(result).startswith(('/dev/', '/sys/', '/proc/', '/tmp/')) and not str(result).startswith(str(self.root)) else result
        self.stack.enter_context(patch.object(s,'Path',side_effect=mockpath))
        for name,value in [('KIT',self.kit),('SD_ROOT',self.root/'media/fat'),('CORE',self.kit/'NDS_Standalone.rbf'),('HELPER',self.kit/'support/nds_hybrid_3d_service'),('KICK',str(self.kit/'Kickstart.sh'))]:
            self.stack.enter_context(patch.object(s,name,value))
        self.paths = {}
        for relative, data in [('media/fat/MiSTer',b'main'),('media/fat/menu.rbf',b'menu'),('dev/mem',b''),('dev/MiSTer_cmd',b''),('media/fat/Scripts/.NDS_Standalone/NDS_Standalone.rbf',b'core'),('media/fat/Scripts/.NDS_Standalone/support/nds_hybrid_3d_service',b'helper'),('media/fat/Scripts/.NDS_Standalone/Kickstart.sh',b'kick'),('media/fat/Scripts/.NDS_Standalone/support/nds_mem_wc.ko',b'\0vermagic=5.15.1-MiSTer SMP mod_unload ARMv7 p2v8 \0'),('media/fat/Scripts/.NDS_Standalone/nds_standalone_host',b'host')]:
            target=self.root/relative;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data);target.chmod(0o755)
            self.paths[target.name]=target
        for name,file in [('EXPECTED_CORE','NDS_Standalone.rbf'),('EXPECTED_HELPER','nds_hybrid_3d_service'),('EXPECTED_KICKSTART','Kickstart.sh'),('EXPECTED_WC','nds_mem_wc.ko')]:
            self.stack.enter_context(patch.object(s,name,s.sha(self.paths[file])))
        (self.kit/'manifest.json').write_text(json.dumps({'host_sha256':s.sha(self.paths['nds_standalone_host'])}))
        for cpu in (0,1):
            base=self.root/('sys/devices/system/cpu/cpu%d/cpufreq'%cpu);base.mkdir(parents=True)
            (base/'scaling_max_freq').write_text('800000')
            (base/'scaling_available_frequencies').write_text('800000 400000')
            (base/'scaling_boost_frequencies').write_text('1200000 1000000')
        self.stack.enter_context(patch.object(s.os,'geteuid',return_value=0))
        self.stack.enter_context(patch.object(s.os,'uname',return_value=SimpleNamespace(release='5.15.1-MiSTer')))
        self.stack.enter_context(patch.object(s.shutil,'which',return_value='/bin/tool'))
        self.stack.enter_context(patch.object(s,'mains',return_value=[{'pid':12,'epoch':'a'}]))
        self.run=self.stack.enter_context(patch.object(s.subprocess,'run'))
        self.spawn=self.stack.enter_context(patch.object(s.subprocess,'Popen'))
        self.command=self.stack.enter_context(patch.object(s,'cmd'))
        self.kill=self.stack.enter_context(patch.object(s,'kill'))
    def no_changes(self):
        self.spawn.assert_not_called();self.command.assert_not_called();self.kill.assert_not_called()
    def test_fresh_install_has_no_normal_nds_dependency(self):
        s.preflight();self.no_changes()
        self.run.assert_called_once_with(['sh',s.KICK,'preflight'],check=True,timeout=15,stdout=s.subprocess.DEVNULL)
        self.assertFalse((s.SD_ROOT/'Scripts/NDS_Kickstart.sh').exists())
        self.assertFalse((self.kit/'NDS_v1.CFG').exists())
    def test_hash_mismatch_rejects_before_hardware_action(self):
        self.paths['NDS_Standalone.rbf'].write_bytes(b'wrong')
        with self.assertRaisesRegex(RuntimeError,'checksum mismatch'):s.preflight()
        self.no_changes();self.run.assert_not_called()
    def test_incompatible_kernel_rejects_even_if_old_wc_node_exists(self):
        (self.root/'dev/nds_mem_wc').touch()
        with patch.object(s.os,'uname',return_value=SimpleNamespace(release='other-kernel')):
            with self.assertRaisesRegex(RuntimeError,'write-combining module'):s.preflight()
        self.no_changes();self.run.assert_not_called()
    def test_missing_one_ghz_rejects(self):
        (self.root/'sys/devices/system/cpu/cpu1/cpufreq/scaling_boost_frequencies').write_text('1200000')
        with self.assertRaisesRegex(RuntimeError,'1 GHz'):s.preflight()
        self.no_changes();self.run.assert_not_called()
    def test_old_python_rejects(self):
        with patch.object(s.sys,'version_info',(3,7,10)):
            with self.assertRaisesRegex(RuntimeError,'Python 3.8'):s.preflight()
        self.no_changes();self.run.assert_not_called()
    def test_missing_tool_rejects(self):
        with patch.object(s.shutil,'which',return_value=None):
            with self.assertRaisesRegex(RuntimeError,'Missing system command'):s.preflight()
        self.no_changes();self.run.assert_not_called()
    def test_unknown_helper_never_stopped(self):
        pidfile=self.root/'tmp/nds-hybrid-3d-service.pid';pidfile.parent.mkdir();pidfile.write_text('99')
        exe=self.root/'proc/99/exe';exe.parent.mkdir(parents=True);exe.symlink_to(self.paths['nds_standalone_host'])
        with self.assertRaisesRegex(RuntimeError,'Another NDS test helper'):s.preflight()
        self.no_changes();self.run.assert_not_called()
    def test_existing_guard_prevents_takeover(self):
        flag=self.root/'tmp/nds-standalone-guard-ready';flag.parent.mkdir();flag.write_text('123')
        with self.assertRaisesRegex(RuntimeError,'recovery is already active'):s.preflight()
        self.no_changes();self.run.assert_not_called()

class Settings(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.kit=self.root/'kit';self.kit.mkdir()
        self.normal=self.root/'config/NDS_v1.CFG';self.normal.parent.mkdir()
        self.private=self.kit/'NDS_v1.CFG'
        self.stack=contextlib.ExitStack();self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(s,'KIT',self.kit))
        self.stack.enter_context(patch.object(s,'SD_ROOT',self.root))
    def test_fresh_install_initializes_only_private_defaults(self):
        s.initialize_settings()
        self.assertEqual(self.private.read_bytes(),bytes((0x20,0x04))+bytes(14))
        self.assertFalse(self.normal.exists())
    def test_existing_normal_config_is_imported_without_copy_or_change(self):
        data=bytes(range(16));self.normal.write_bytes(data)
        s.initialize_settings()
        self.assertEqual(self.normal.read_bytes(),data);self.assertFalse(self.private.exists())
    def test_private_config_preserves_all_128_bits(self):
        data=bytes(range(240,256));self.private.write_bytes(data);self.normal.write_bytes(bytes(16))
        s.initialize_settings()
        self.assertEqual(self.private.read_bytes(),data);self.assertEqual(self.normal.read_bytes(),bytes(16))
    def test_malformed_normal_config_is_not_replaced(self):
        self.normal.write_bytes(b'broken')
        with self.assertRaisesRegex(RuntimeError,'Invalid 16-byte'):s.initialize_settings()
        self.assertEqual(self.normal.read_bytes(),b'broken');self.assertFalse(self.private.exists())
    def test_malformed_private_config_is_not_replaced(self):
        self.private.write_bytes(b'broken');self.normal.write_bytes(bytes(16))
        with self.assertRaisesRegex(RuntimeError,'Invalid 16-byte'):s.initialize_settings()
        self.assertEqual(self.private.read_bytes(),b'broken')
    def test_failed_creation_removes_only_new_partial_file(self):
        with patch.object(s.os,'write',side_effect=OSError('disk full')):
            with self.assertRaisesRegex(OSError,'disk full'):s.initialize_settings()
        self.assertFalse(self.private.exists());self.assertFalse(self.normal.exists())
    def test_concurrent_private_config_is_preserved(self):
        original=s.os.open
        data=bytes(range(16))
        def create_first(path,flags,mode=0o777):
            if str(path)==str(self.private):
                self.private.write_bytes(data)
            return original(path,flags,mode)
        with patch.object(s.os,'open',side_effect=create_first):s.initialize_settings()
        self.assertEqual(self.private.read_bytes(),data)

class Handoff(unittest.TestCase):
    def test_unmatched_nds_core_recovers_menu_without_starting_pf3_helper(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);target=root/'NDS_old.rbf';target.write_bytes(b'old version')
            events=[];old={'pid':234,'epoch':'a'}
            with patch.object(s,'KIT',root),patch.object(s,'SD_ROOT',root),patch.object(s,'RUNTIME',root),patch.object(s,'kill',side_effect=lambda p:events.append('kill')),patch.object(s.fcntl,'flock',side_effect=lambda *a:events.append('lock')),patch.object(s.subprocess,'run',side_effect=lambda args,**kwargs:events.append('helper '+args[-1])),patch.object(s.subprocess,'Popen') as spawn,patch.object(s,'mains',return_value=[old]),patch.object(s,'core_name',return_value='MENU'),patch.object(s,'alive',return_value=False),patch.object(s,'cmd',side_effect=lambda command,timeout:events.append(command)):
                s.recover({'done':True,'host_returncode':0,'selected_core':str(target)})
            self.assertEqual(events,['kill','lock','helper stop','load_core /media/fat/menu.rbf'])
            spawn.assert_not_called()
            receipt=json.loads((root/'recovery.json').read_text())
            self.assertIsNone(receipt['selected_core']);self.assertEqual(receipt['rejected_core'],str(target.resolve()))
            self.assertIn('matching helper',receipt['message'])

class PackageSource(unittest.TestCase):
    def test_renderer_options_are_identical_to_accepted(self):
        accepted=json.loads((ROOT/'test_fixtures/accepted-runtime.json').read_text())
        after=(ROOT/'Kickstart.sh').read_text()
        original=after.replace('/media/fat/Scripts/.NDS_Standalone/support','/media/fat/Scripts/.NDS_Pacing_Prefix_20260930/support')
        self.assertEqual(hashlib.sha256(original.encode()).hexdigest(),accepted['kickstart_sha256'])
        self.assertEqual(accepted['shell_environment_checked'],s.EXPECTED_SPEED_ENV)
    def test_kickstart_hash_matches_public_bytes(self):
        self.assertEqual(s.sha(ROOT/'Kickstart.sh'),s.EXPECTED_KICKSTART)
    def test_no_bundled_user_settings(self):
        self.assertFalse((ROOT/'Scripts/.NDS_Standalone/NDS_v1.CFG').exists())
        self.assertFalse(list((ROOT/'Scripts/.NDS_Standalone').glob('inputs/*.map')))

if __name__=='__main__':unittest.main()
