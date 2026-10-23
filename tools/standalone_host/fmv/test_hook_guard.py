# SPDX-License-Identifier: GPL-3.0-only
import hashlib
import unittest
import zlib
from hook_guard import select_profile, verify_target


class GuardTests(unittest.TestCase):
    def test_identity_and_collision_fail_closed(self):
        header=bytearray(512);header[12:16]=b'A2DE'
        arm9=b'synthetic ARM9 fixture'
        profile=dict(game_code='A2DE',revision=0,arm9_crc32=f'{zlib.crc32(arm9):08x}')
        registry=dict(version=1,profiles=[profile])
        self.assertIs(select_profile(registry,header,arm9),profile)
        self.assertIsNone(select_profile(registry,header,arm9+b'!'))
        header[30]=1;self.assertIsNone(select_profile(registry,header,arm9))
        header[30]=0;header[15]=ord('P');self.assertIsNone(select_profile(registry,header,arm9))
        header[15]=ord('E');registry['profiles'].append(profile)
        self.assertIsNone(select_profile(registry,header,arm9))

    def test_live_itcm_waits_and_rechecks_each_time(self):
        memory=bytearray(range(16));reads=[]
        def read(addr,size):
            reads.append((addr,size));return bytes(memory[:size])
        h=dict(address=0x01ff9145,guard_bytes=16,
               guard_sha256=hashlib.sha256(memory).hexdigest(),phase='autoload_complete')
        self.assertFalse(verify_target(h,read)[0]);self.assertEqual(reads,[])
        self.assertTrue(verify_target(h,read,autoload_complete=True)[0])
        self.assertEqual(reads,[(0x01ff9144,16)])
        memory[12]^=1
        self.assertFalse(verify_target(h,read,autoload_complete=True)[0])
        # A later reset cannot reuse an earlier authorization.
        self.assertFalse(verify_target(h,read)[0])

    def test_main_bounds_and_short_guard(self):
        data=bytes(range(16))
        h=dict(address=0x02001000,guard_bytes=16,
               guard_sha256=hashlib.sha256(data).hexdigest(),phase='main_loaded')
        self.assertTrue(verify_target(h,lambda a,n:data)[0])
        self.assertFalse(verify_target(h,lambda a,n:data[:8])[0])
        h['guard_bytes']=4;self.assertFalse(verify_target(h,lambda a,n:data)[0])


if __name__=='__main__':unittest.main()
