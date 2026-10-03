#!/usr/bin/env python3
"""Bounded consistency checks; argument must be the pinned public synthetic seed."""
import hashlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
import generate_nitro_firmware_vhdl as gen

SEED = Path(sys.argv.pop(1)).read_bytes()
ROOT = Path(__file__).resolve().parents[1]

def independent_crc(data):
    crc = 0xffff
    for byte in data:
        for bit in range(8):
            low = (crc ^ (byte >> bit)) & 1
            crc >>= 1
            if low: crc ^= 0xa001
    return crc

class Defaults(unittest.TestCase):
    def test_exact_seed(self):
        self.assertEqual(len(SEED), 0x20000)
        self.assertEqual(hashlib.sha256(SEED).hexdigest(), gen.EXPECTED_SYNTHETIC_SHA256)
    def test_both_pages_name_crc_and_only_intended_bytes(self):
        image = gen.apply_melonds_runtime_defaults(SEED)
        allowed = set()
        for base in (0x1fe00, 0x1ff00):
            self.assertEqual(image[base+6:base+26], b'M\0i\0S\0T\0e\0r\0' + bytes(8))
            self.assertEqual(image[base+26:base+28], b'\6\0')
            self.assertEqual(image[base+0x58:base+0x64], bytes.fromhex('000000000000f00ff00bffbf'))
            self.assertEqual(int.from_bytes(image[base+0x72:base+0x74], 'little'), independent_crc(image[base:base+0x70]))
            self.assertEqual(image[base+0x72:base+0x74], bytes.fromhex('4c4c'))
            self.assertEqual(image[base+0x70:base+0x72], SEED[base+0x70:base+0x72])
            allowed.update(range(base+6,base+28)); allowed.update(range(base+0x58,base+0x64));allowed.update(range(base+0x72,base+0x74))
        self.assertEqual(image[0x1fe00:0x1ff00],image[0x1ff00:0x20000])
        self.assertFalse([i for i,(a,b) in enumerate(zip(SEED,image)) if a!=b and i not in allowed])
    def test_three_generated_consumers(self):
        image = gen.apply_melonds_runtime_defaults(SEED)
        self.assertEqual((ROOT/'rtl/nds_nitro_firmware.vhd').read_text(),gen.render(image))
        mif=(ROOT/'rtl/nds_nitro_firmware.mif').read_text()
        self.assertEqual(mif,gen.render_mif(image))
        words={int(a,16):int(v,16) for a,v in re.findall(r'^([0-9A-F]{3}) : ([0-9A-F]{8});$',mif,re.M)}
        self.assertEqual(set(words),set(range(512)))
        expected=image[:0x200]+image[0x1fa00:0x20000]
        self.assertEqual(b''.join(words[i].to_bytes(4,'little') for i in range(512)),expected)

        header=(ROOT/'tools/standalone_host/builtin_firmware_profile.h').read_text()
        self.assertEqual(header,gen.render_profile_header(image))
        arrays = re.findall(r'(builtin_user_pages|builtin_profile)\{\{(.*?)\}\};',header,re.S)
        parsed={n:bytes(int(x,16) for x in re.findall('0x([0-9a-f]{2})',v)) for n,v in arrays}
        self.assertEqual(parsed['builtin_user_pages'],image[0x1fe00:0x20000])
        self.assertEqual(parsed['builtin_profile'],image[0x1fe00:0x1fe70])
        loader=(ROOT/'third_party/Nitro_DarkSide/d2dabe/rtl/nds_loader.vhd').read_text()
        self.assertEqual(loader,gen.update_loader_defaults(loader,image))
        table=re.search(r'constant BUILTIN_USER_WORDS.*?\((.*?)others =>',loader,re.S).group(1)
        words=[0]*28
        for i,v in re.findall(r'(\d+) => x"([0-9A-F]+)"',table):words[int(i)]=int(v,16)
        self.assertEqual(b''.join(x.to_bytes(4,'little') for x in words),parsed['builtin_profile'])
        self.assertEqual(int.from_bytes(image[0x20:0x22],'little')*8,0x1fe00)
        self.assertEqual(image[4:6]+image[0x26:0x28],bytes(4))
        self.assertIn('builtin_user_offset = 0x0001fe00',header)
        self.assertIn('builtin_checksums = 0x00000000',header)
        self.assertNotIn('0007FE00',loader)
    def test_reject_non_pinned_input_before_output(self):
        before=hashlib.sha256((ROOT/'rtl/nds_nitro_firmware.vhd').read_bytes()).hexdigest()
        with tempfile.TemporaryDirectory() as d:
            f=Path(d)/'bad.bin';b=bytearray(SEED);b[6]^=1;f.write_bytes(b)
            r=subprocess.run([sys.executable,str(ROOT/'tools/generate_nitro_firmware_vhdl.py'),str(f)],capture_output=True,text=True)
            self.assertNotEqual(r.returncode,0);self.assertIn('not the pinned synthetic',r.stderr)
        self.assertEqual(before,hashlib.sha256((ROOT/'rtl/nds_nitro_firmware.vhd').read_bytes()).hexdigest())

if __name__=='__main__':unittest.main()
