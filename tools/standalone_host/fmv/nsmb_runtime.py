# SPDX-License-Identifier: GPL-3.0-only
"""Experimental, revision-guarded single-player bookkeeping fast paths.

Only a virtual load image is changed. No ROM, save or cache file is written.
The original local input packet, active connection and sequencer paths remain.
"""
import struct
import json
from pathlib import Path
from ndspy import code, _common
from prepare import VirtualRom, digest, require
from hook_guard import select_profile, verify_target

SOURCE_SHA256 = '9f67fef1b4c73e966767f6153431ada3751dc1b0da2c70f386c14a5e3017f354'
ARM9_SHA256 = '72a43c39fa4ab0e233519d5ecbcd90813117fdd2c330cbebd864331817ff695a'
LOOKUP_SHA256 = 'd77ee1ce2b479ab985749ed886b2165b0d59a62f4583617c0536b1e931700fcb'
# Generated from nsmb_runtime.S at the addresses in nsmb_runtime.ld.
LOOKUP = bytes.fromhex('58109fe50010d1e5000051e30d00000a080051e30b00000a090051e30900000a10402de90040a0e10008a0e12008a0e12cc09fe53cff2fe1000050e31080bd180400a0e11040bde818109fe50010d1e5010050e110009f050000a0131eff2fe1fc870802986e0402f0870802e0880802')
SKIP_CLIENTS = bytes.fromhex('40009fe50000d0e5000050e30b00001a34009fe50000d0e500005ae10700000a28009fe50a00d0e7000050e30300001a1c009fe50010a0e30a1180e714f09fe50a00a0e110f09fe5fc870802f0870802548a0802848a080264150102e0140102')


def assemble(source, mode, progress=lambda n: None):
    require(mode in ('lookup', 'skip', 'both'), 'unknown NSMB experiment mode')
    require(source.size == 33554432, 'unqualified NSMB cartridge size')
    header = bytearray(source.read(0, 512))
    require(header[12:16] == b'A2DE' and header[30] == 0,
            'unqualified NSMB region or revision')
    require(source.sha256(progress) == SOURCE_SHA256, 'unqualified NSMB cartridge hash')
    offset, entry, address, length = struct.unpack_from('<4I', header, 0x20)
    require((offset, entry, address, length) == (0x4000, 0x02000800, 0x02000000, 389028),
            'unexpected NSMB ARM9 layout')
    raw = source.read(offset, length)
    registry = json.loads((Path(__file__).parent/'nsmb_hooks.json').read_text())
    profile = select_profile(registry, header, raw)
    require(profile is not None, 'no game-code/ARM9-CRC32 hook profile')
    require(digest(raw) == ARM9_SHA256, 'unexpected NSMB ARM9 code')
    arm = code.MainCodeFile(raw, address)
    require(arm.codeSettingsOffs == 0xb48 and len(arm.sections) == 5,
            'unexpected NSMB autoload table')
    section = arm.sections[0]
    require(section.ramAddress == address and section.implicit and len(section.data) == 275328,
            'unexpected NSMB main section')
    data = bytearray(section.data)
    requested = {'lookup': {'packet_lookup'}, 'skip': {'idle_clients'},
                 'both': {'packet_lookup', 'idle_clients'}}[mode]
    def main_memory(at, size):
        require(address <= at and at+size <= address+len(data),
                'hook is not in initial main RAM')
        return data[at-address:at-address+size]
    qualified = set()
    for hook in profile['hooks']:
        if hook['flag'] not in requested:
            continue
        ok, reason = verify_target(hook, main_memory)
        require(ok, hook['flag']+': '+reason)
        qualified.add(hook['flag'])
    require(qualified == requested, 'missing requested hook guard')
    require(digest(data[0xeb50:0xebe0]) == LOOKUP_SHA256 and
            data[0x114dc:0x114e0] == bytes.fromhex('0a00a0e1') and
            data[0xc00:0xc00+len(SKIP_CLIENTS)] == bytes(len(SKIP_CLIENTS)),
            'NSMB patch sites differ')
    if mode in ('lookup', 'both'):
        data[0xeb50:0xeb50+len(LOOKUP)] = LOOKUP
    if mode in ('skip', 'both'):
        data[0xc00:0xc00+len(SKIP_CLIENTS)] = SKIP_CLIENTS
        branch = 0xea000000 | (((0x02000c00-0x020114dc-8)//4) & 0xffffff)
        struct.pack_into('<I', data, 0x114dc, branch)
    section.data = data
    progress(source.size)
    packed = arm.save(compress=True)
    # The SDK footer and overlay table immediately follow the original ARM9.
    # Append a virtual ARM9 image instead of treating that region as padding.
    # Every original asset, overlay, file table and ARM7 byte keeps its offset.
    require(len(packed) <= 1024*1024, 'NSMB ARM9 unexpectedly large')
    new_offset = source.size
    new_size = new_offset + len(packed)
    struct.pack_into('<I', header, 0x20, new_offset)
    struct.pack_into('<I', header, 0x2c, len(packed))
    struct.pack_into('<I', header, 0x80, new_size)
    capacity = 0
    while (128*1024 << capacity) < new_size:
        capacity += 1
    header[0x14] = capacity
    struct.pack_into('<H', header, 0x6c, _common.crc16(packed[:0x4000]))
    struct.pack_into('<H', header, 0x15e, _common.crc16(header[:0x15e]))
    image = VirtualRom(source, new_size)
    image.add(0, header)
    image.add(new_offset, packed)
    progress(source.size)
    return image.finish()
