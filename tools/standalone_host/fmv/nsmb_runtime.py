# SPDX-License-Identifier: GPL-3.0-only
"""Experimental, revision-guarded NSMB fast paths.

Only a virtual load image is changed. No ROM, save or cache file is written.
The original local input packet, active connection and sequencer paths remain.
Bone-read reduction deliberately retains stale transforms for six body parts;
it is an optional compatibility tradeoff, not a proven equivalent shortcut.
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

# Generated from nsmb_bones.S; runtime overlay checks remain in the ARM stub.
BONE_READS = bytes.fromhex('b0c09fe50c005ee11f00003aa8c09fe50c005ee11c00002aa0c09fe500309ce59cc09fe50c0053e11700001a94c09fe500309ce590c09fe50c0053e11200001a88c09fe500309ce584c09fe50c0053e10d00001a7cc09fe500309ce578c09fe50c0053e10800001a30c08fe20630a0e304302de504309ce403005ee104309de40400000a013053e2f8ffff1a580090e5400080e244f09fe50100a0e31eff2fe1e4c91202f8c912020cca120234ca120248ca12025cca1202c0c9120270ca12028cc9120230402de990c9120204d04de294c912020050a0e198c91202030c85e240970102')
MODES = {
    "lookup": {"packet_lookup"}, "skip": {"idle_clients"},
    "both": {"packet_lookup", "idle_clients"},
    "bones": {"bone_reads"}, "lookup+bones": {"packet_lookup", "bone_reads"},
    "skip+bones": {"idle_clients", "bone_reads"},
    "both+bones": {"packet_lookup", "idle_clients", "bone_reads"},
}


def assemble(source, mode, progress=lambda n: None):
    require(mode in MODES, 'unknown NSMB experiment mode')
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
    requested = MODES[mode]
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
    if 'packet_lookup' in requested:
        data[0xeb50:0xeb50+len(LOOKUP)] = LOOKUP
    if 'idle_clients' in requested:
        data[0xc00:0xc00+len(SKIP_CLIENTS)] = SKIP_CLIENTS
        branch = 0xea000000 | (((0x02000c00-0x020114dc-8)//4) & 0xffffff)
        struct.pack_into('<I', data, 0x114dc, branch)
    if 'bone_reads' in requested:
        require(data[0xd00:0xd00+len(BONE_READS)] == bytes(len(BONE_READS)),
                'bone-read scratch space differs')
        data[0xd00:0xd00+len(BONE_READS)] = BONE_READS
        branch = 0xea000000 | (((0x02000d00-0x0201972c-8)//4) & 0xffffff)
        struct.pack_into('<I', data, 0x1972c, branch)
    section.data = data
    progress(source.size)
    # The DS loader accepts an uncompressed ARM9 (as used by our FMV profiles).
    # Recompressing this small executable in Python costs tens of seconds on
    # HPS, only to make the guest decompress it again at boot. save(False)
    # clears the SDK compressed-end marker and preserves all autoload sections.
    packed = arm.save(compress=False)
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
