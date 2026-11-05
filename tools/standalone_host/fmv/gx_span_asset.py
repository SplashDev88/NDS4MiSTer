# SPDX-License-Identifier: GPL-3.0-only
"""Atomic guarded resource preparation through the existing VirtualRom path."""
import hashlib
import struct
from ndspy import _common, lz10
from prepare import VirtualRom, require, LIMIT
from gx_spans import transform


def digest(data):
    return hashlib.sha256(data).hexdigest()


def transform_archive(data, config):
    require(config['transform'] == 'narc-model-gx-spans-v1', 'Unknown asset transform')
    require(4 <= len(data) <= 8*1024*1024 and data[0] == 0x10 and
            16 <= int.from_bytes(data[1:4], 'little') <= 8*1024*1024,
            'Unsupported LZ10 extent')
    arc = lz10.decompress(data)
    require(arc[:4] == b'NARC' and len(arc) == struct.unpack_from('<I', arc, 8)[0],
            'Archive identity/length differs')
    require(struct.unpack_from('<HH', arc, 12) == (16, 3), 'Unsupported NARC header')
    at, blocks = 16, {}
    for _ in range(3):
        name = arc[at:at+4]
        length = struct.unpack_from('<I', arc, at+4)[0]
        require(length >= 8 and at+length <= len(arc) and name not in blocks,
                'Invalid NARC block')
        blocks[name] = arc[at:at+length]
        at += length
    require(at == len(arc) and set(blocks) == {b'BTAF', b'BTNF', b'GMIF'},
            'Unsupported NARC block layout')
    fat, body = blocks[b'BTAF'], blocks[b'GMIF'][8:]
    count = struct.unpack_from('<H', fat, 8)[0]
    member = config['member']
    require(type(member) is int and 0 <= member < count <= 4096 and
            len(fat) == 12+8*count, 'Invalid archive member/FAT')
    files, end = [], 0
    for i in range(count):
        lo, hi = struct.unpack_from('<II', fat, 12+8*i)
        require(end <= lo <= hi <= len(body) and lo % 4 == 0, 'Invalid member extent')
        files.append(body[lo:hi]); end = hi
    require(digest(files[member]) == config['member_sha256'], 'Model identity differs')
    offset = config['model_offset']
    require(type(offset) is int and 0 <= offset < len(files[member]), 'Invalid model offset')
    old_bytes = len(files[member])
    files[member], stats, _ = transform(files[member], offset)
    require(len(files[member]) <= 8*1024*1024, 'Expanded model is too large')
    newfat, newbody = bytearray(fat), bytearray()
    for i, payload in enumerate(files):
        newbody.extend(b'\xff' * (-len(newbody) % 4))
        struct.pack_into('<II', newfat, 12+8*i, len(newbody), len(newbody)+len(payload))
        newbody.extend(payload)
    newbody.extend(b'\xff' * (-len(newbody) % 4))
    output = bytearray(arc[:16])+newfat+blocks[b'BTNF']+b'GMIF'+struct.pack('<I', 8+len(newbody))+newbody
    require(len(output) <= 8*1024*1024, 'Expanded archive is too large')
    struct.pack_into('<I', output, 8, len(output))
    packed = lz10.compress(output)
    require(lz10.decompress(packed) == bytes(output), 'Asset compression round trip differs')
    return packed, dict(member_extra_bytes=len(files[member])-old_bytes, shapes=stats)


def append_asset(source, image, report, config):
    header = bytearray(b''.join(image.blocks(0, 512)))
    fat, size = struct.unpack_from('<II', header, 0x48)
    file_id = config['file_id']
    require(type(file_id) is int and 0 <= file_id and fat >= 512 and
            size % 8 == 0 and (file_id+1)*8 <= size and fat+size <= source.size,
            'Invalid cartridge FAT selection')
    original_header = source.read(0, 512)
    row = fat+file_id*8
    for offset in (0x20, 0x30):
        first, _, _, length = struct.unpack_from('<4I', original_header, offset)
        require(row+8 <= first or row >= first+length, 'Asset FAT overlaps CPU image')
    lo, hi = struct.unpack('<II', source.read(row, 8))
    require(512 <= lo < hi <= source.size and (hi <= fat or lo >= fat+size),
            'Invalid cartridge asset extent')
    original = source.read(lo, hi-lo)
    require(digest(original) == config['stored_sha256'], 'Asset identity differs')
    output, stats = transform_archive(original, config)
    require(digest(output) == config['output_sha256'], 'Transformed asset identity differs')
    at = (image.size+511) & ~511
    end = (at+len(output)+511) & ~511
    require(end <= LIMIT, 'Expanded asset exceeds cartridge limit')
    struct.pack_into('<I', header, 0x80, end)
    capacity = 0
    while (128*1024 << capacity) < end:
        capacity += 1
    header[0x14] = capacity
    struct.pack_into('<H', header, 0x15e, _common.crc16(header[:0x15e]))
    result = VirtualRom(source, end)
    for offset, payload in image.patches:
        if offset == 0:
            require(len(payload) == 512, 'Unexpected header patch')
        else:
            result.add(offset, payload)
    result.add(0, header)
    result.add(row, struct.pack('<II', at, at+len(output)))
    result.add(at, output)
    result.finish()
    report.update(virtual_bytes=end, header_sha256=digest(header), asset=dict(
        file_id=file_id, cartridge_offset=at, original_sha256=digest(original),
        output_sha256=digest(output), original_bytes=len(original), output_bytes=len(output), **stats))
    return result, report
