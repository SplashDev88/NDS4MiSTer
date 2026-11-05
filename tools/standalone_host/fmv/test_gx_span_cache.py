# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from gx_span_cache import prepared_asset

sha=lambda data:hashlib.sha256(data).hexdigest()


class AssetCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.original=b'original synthetic asset';self.output=b'prepared synthetic asset'
        self.config=dict(file_id=2,stored_sha256=sha(self.original),output_sha256=sha(self.output),recipe='synthetic')
        self.stats=dict(member_extra_bytes=4,shapes=[dict(shape=0,spans=2)])
        self.calls=0
        self.env=patch.dict('os.environ',NDS_GX_ASSET_CACHE='1',NDS_ROM_CACHE_DIR=str(self.root));self.env.start()

    def tearDown(self):
        self.env.stop();self.temp.cleanup()

    def prepare(self,original,config):
        self.assertEqual(original,self.original);self.calls+=1
        return self.output,self.stats

    def run_asset(self):
        return prepared_asset(self.original,self.config,self.prepare)

    def test_hit_returns_exact_preparation_without_recomputing(self):
        self.assertEqual(self.run_asset(),(self.output,self.stats));self.assertEqual(self.calls,1)
        self.assertEqual(self.run_asset(),(self.output,self.stats));self.assertEqual(self.calls,1)
        self.assertFalse(list(self.root.glob('*.tmp')))

    def test_corruption_rebuilds_before_any_payload_is_returned(self):
        self.run_asset();p=next(self.root.glob('*.data'));data=bytearray(p.read_bytes());data[-1]^=1;p.write_bytes(data)
        self.assertEqual(self.run_asset(),(self.output,self.stats));self.assertEqual(self.calls,2)

    def test_rehashed_wrong_output_cannot_bypass_manifest_hash(self):
        self.run_asset();p=next(self.root.glob('*.data'));data=bytearray(p.read_bytes());data[-1]^=1;p.write_bytes(data)
        meta=p.with_suffix('.json');m=json.loads(meta.read_text());m['sha256']=sha(data);meta.write_text(json.dumps(m))
        self.assertEqual(self.run_asset(),(self.output,self.stats));self.assertEqual(self.calls,2)

    def test_recipe_and_expected_output_invalidate_entry(self):
        self.run_asset();self.config['recipe']='changed';self.run_asset();self.assertEqual(self.calls,2)
        self.output=b'new output';self.config['output_sha256']=sha(self.output);self.run_asset();self.assertEqual(self.calls,3)

    def test_wrong_source_and_bad_preparation_are_never_cached(self):
        with self.assertRaises(ValueError):prepared_asset(b'changed',self.config,self.prepare)
        self.config['output_sha256']='0'*64
        with self.assertRaises(ValueError):self.run_asset()
        self.assertFalse(list(self.root.glob('*.data')))

    def test_disabled_or_unavailable_cache_keeps_normal_preparation(self):
        for env in [dict(NDS_GX_ASSET_CACHE='0'),dict(NDS_ROM_CACHE_DIR='off')]:
            with patch.dict('os.environ',env):self.run_asset();self.run_asset()
        p=self.root/'ordinary-file';p.write_text('not a directory')
        with patch.dict('os.environ',NDS_ROM_CACHE_DIR=str(p)):self.run_asset()
        self.assertEqual(self.calls,5);self.assertFalse(list(self.root.glob('*.data')))

    def test_partial_entry_is_discarded(self):
        self.run_asset();next(self.root.glob('*.json')).unlink()
        self.assertEqual(self.run_asset(),(self.output,self.stats));self.assertEqual(self.calls,2)


if __name__=='__main__':unittest.main()
