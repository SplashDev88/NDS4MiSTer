#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Process identity and lock-based recovery checks; no FPGA or MiSTer access."""
from pathlib import Path
import importlib.util, os, tempfile, unittest, subprocess
from unittest.mock import patch, MagicMock
spec=importlib.util.spec_from_file_location('supervisor',Path(__file__).resolve().parent/'supervisor.py')
s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)
class RecoveryTests(unittest.TestCase):
 def setUp(self):
  self.runtime=tempfile.TemporaryDirectory();self.addCleanup(self.runtime.cleanup)
  self.runtime_patch=patch.object(s,'RUNTIME',Path(self.runtime.name));self.runtime_patch.start();self.addCleanup(self.runtime_patch.stop)
 def test_core_request_only_accepts_clean_exit_and_valid_sd_targets(self):
  with tempfile.TemporaryDirectory() as d, patch.object(s,'KIT',Path(d)), patch.object(s,'SD_ROOT',Path(d)):
   p=Path(d).resolve()/'Core with spaces.RBF';p.write_bytes(b'core')
   request=Path(d)/'core-request.txt'
   request.write_text(str(p));self.assertEqual(s.collect_core_request(0),p)
   self.assertFalse(request.exists())
   request.write_text(str(p));self.assertIsNone(s.collect_core_request(1))
   self.assertFalse(request.exists())
   for invalid in [str(p)+'\nload_core other',str(p)+'\0','/etc/passwd',str(Path(d)/'missing.rbf'),d]:
    self.assertIsNone(s.selected_core(invalid))
   wrong=Path(d)/'game.nds';wrong.write_bytes(b'game');self.assertIsNone(s.selected_core(str(wrong)))
   outside=Path(d)/'escape.rbf';outside.symlink_to('/etc/passwd');self.assertIsNone(s.selected_core(str(outside)))
   self.assertIsNone(s.collect_core_request(0))
 def test_recovery_hands_selected_core_to_main_after_release_of_spi(self):
  for name in ('Other core.rbf','Arcade.mra','Console.mgl','NDS_test.rbf'):
   with self.subTest(name=name), tempfile.TemporaryDirectory() as d, patch.object(s,'KIT',Path(d)), patch.object(s,'SD_ROOT',Path(d)):
    target=Path(d).resolve()/name;target.write_bytes(b'core')
    events=[]
    old={'pid':234,'epoch':'a'}
    def run(args,**kwargs):
     events.append('helper '+args[-1])
     if args[-1]=='start':self.assertFalse(any(k.startswith(('NDS','H3D_')) for k in kwargs['env']))
    with patch.object(s,'kill',side_effect=lambda p:events.append('kill')), patch.object(s.fcntl,'flock',side_effect=lambda *a:events.append('lock')), patch.object(s.subprocess,'run',side_effect=run), patch.object(s.subprocess,'Popen'),patch.object(s,'mains',return_value=[old]),patch.object(s,'core_name',return_value='MENU'),patch.object(s,'alive',return_value=False),patch.object(s,'cmd',side_effect=lambda command,timeout:events.append(command)),patch.object(s,'sha',side_effect=lambda p:s.EXPECTED_HELPER if p==s.HELPER else s.EXPECTED_CORE if p==target else s.EXPECTED_KICKSTART):
     s.recover({'done':True,'host_returncode':0,'selected_core':str(target)})
    expected=['kill','lock','helper stop','load_core /media/fat/menu.rbf']
    if name.startswith('NDS'):expected.append('helper start')
    self.assertEqual(events,expected+['load_core '+str(target)])
    self.assertEqual(__import__('json').loads((s.RUNTIME/'recovery.json').read_text())['selected_core'],str(target))
 def test_epoch_reuse_is_not_ours(self):
  with patch.object(s,'epoch',return_value='new'):
   self.assertFalse(s.alive({'pid':123,'epoch':'old'}))
  with patch.object(s,'alive',return_value=False), patch.object(s.os,'kill') as kill:
   s.kill({'pid':123,'epoch':'old'});kill.assert_not_called()
 def test_recovery_refuses_competing_spi_owner(self):
  with tempfile.TemporaryDirectory() as d, patch.object(s,'KIT',Path(d)), patch.object(s,'kill'), patch.object(s.fcntl,'flock',side_effect=BlockingIOError), patch.object(s.time,'monotonic',side_effect=[0,26]), patch.object(s.subprocess,'run') as run, patch.object(s.subprocess,'Popen') as popen:
   with self.assertRaisesRegex(RuntimeError,'SPI host remains alive'):s.recover({})
   run.assert_not_called();popen.assert_not_called()
 def recovery_case(self, existing):
  events=[]
  old={'pid':234,'epoch':'a'}
  calls=[old] if existing else []
  def popen(args,**kwargs):
   events.append(args);calls.append(old)
  def command(*args):
   events.append(args)
  with tempfile.TemporaryDirectory() as d, patch.object(s,'KIT',Path(d)), patch.object(s,'kill',side_effect=lambda p:events.append('kill')), patch.object(s.fcntl,'flock',side_effect=lambda *a:events.append('lock')), patch.object(s.subprocess,'run',side_effect=lambda *a,**k:events.append('helper stop')), patch.object(s.subprocess,'Popen',side_effect=popen), patch.object(s,'mains',side_effect=lambda:calls),patch.object(s,'core_name',side_effect=lambda:'MENU' if any(isinstance(e,tuple) for e in events) else 'NDS'),patch.object(s,'cmd',side_effect=command) as cmd,patch.object(s,'alive',return_value=False):
   s.recover({'reason':'unit test'})
   self.assertEqual(events[:3],['kill','lock','helper stop'])
   if not existing:self.assertEqual(events[3],['/media/fat/MiSTer',str(s.CORE)])
   cmd.assert_called_once_with('load_core /media/fat/menu.rbf',30)
   self.assertTrue((s.RUNTIME/'recovery.json').exists())
 def test_recovery_restarts_main_then_loads_menu(self):self.recovery_case(False)
 def test_recovery_reuses_main_then_loads_menu(self):self.recovery_case(True)
if __name__=='__main__':unittest.main()
