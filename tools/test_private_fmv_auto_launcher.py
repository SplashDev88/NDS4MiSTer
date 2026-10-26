# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib,json,subprocess,sys,tempfile,unittest
from pathlib import Path

SOURCE=Path(__file__).with_name('private_fmv_auto_launcher.py')
class LauncherTests(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.kit=Path(self.temp.name)
  (self.kit/'auto_movies.py').write_bytes(SOURCE.read_bytes())
  self.names=['nds_standalone_host','support/nds_hybrid_3d_service','NDS_Standalone.rbf',
   'supervisor.py','Kickstart.sh','auto_movies.py','fmv/stream.py','fmv/prepare.py','fmv/profiles.json','fmv/stream_load.py','fmv/prepared_cache.py','fmv/load_progress.py']
  for n in self.names:
   p=self.kit/n;p.parent.mkdir(parents=True,exist_ok=True)
   if n!='auto_movies.py':p.write_text(n)
  self.manifest={'automatic_movie_files':{n:hashlib.sha256((self.kit/n).read_bytes()).hexdigest() for n in self.names}}
  self.save()
 def tearDown(self):self.temp.cleanup()
 def save(self):(self.kit/'manifest.json').write_text(json.dumps(self.manifest))
 def run_launcher(self):return subprocess.run([sys.executable,str(self.kit/'auto_movies.py'),'--validate-only'],capture_output=True,text=True)
 def test_paired_package(self):self.assertEqual(self.run_launcher().returncode,0)
 def test_missing_member(self):
  del self.manifest['automatic_movie_files']['fmv/profiles.json'];self.save()
  self.assertNotEqual(self.run_launcher().returncode,0)
 def test_changed_decoder(self):
  (self.kit/'support/nds_hybrid_3d_service').write_text('wrong decoder')
  self.assertNotEqual(self.run_launcher().returncode,0)
 def test_changed_recipe(self):
  (self.kit/'fmv/profiles.json').write_text('{}')
  self.assertNotEqual(self.run_launcher().returncode,0)
 def test_missing_hook(self):
  self.manifest['automatic_movie_files']['fmv/guest/hook.bin']='0'*64;self.save()
  self.assertNotEqual(self.run_launcher().returncode,0)
 def test_escape_path(self):
  self.manifest['automatic_movie_files']['../other']='0'*64;self.save()
  self.assertNotEqual(self.run_launcher().returncode,0)
if __name__=='__main__':unittest.main()
