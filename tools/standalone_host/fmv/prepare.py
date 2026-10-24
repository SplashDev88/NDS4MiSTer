# SPDX-License-Identifier: GPL-3.0-or-later
"""Read-only virtual cartridge assembly for qualified movie player profiles.

Profiles contain hashes, addresses, packet lengths and quantizers, never game
code, textures or movie payloads. All original bytes come from the open ROM.
The entire identity is checked before any replacement is made visible.
"""
import base64
import bisect
import hashlib
import json
import os
from pathlib import Path
import struct
import zlib
from ndspy import code, codeCompression, _common

ROOT = Path(__file__).resolve().parent
LIMIT = 464 * 1024 * 1024
CHUNK = 262144


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


class Source:
    def __init__(self, fd):
        self.fd = fd
        self.stat = os.fstat(fd)
        self.size = self.stat.st_size
        self._sha256 = None

    def read(self, start, size):
        require(0 <= start <= self.size and 0 <= size <= self.size - start,
                'source range outside cartridge')
        result = bytearray()
        while len(result) < size:
            part = os.pread(self.fd, min(CHUNK, size - len(result)), start + len(result))
            require(part, 'source shortened during read')
            result.extend(part)
        return bytes(result)

    def sha256(self, progress=lambda n: None):
        self.unchanged()
        if self._sha256 is not None:
            return self._sha256
        h = hashlib.sha256()
        for at in range(0, self.size, CHUNK):
            h.update(self.read(at, min(CHUNK, self.size - at)))
            progress(at)
        self.unchanged()
        self._sha256 = h.hexdigest()
        return self._sha256

    def unchanged(self):
        now = os.fstat(self.fd)
        require((now.st_dev, now.st_ino, now.st_size, now.st_mtime_ns, now.st_ctime_ns) ==
                (self.stat.st_dev, self.stat.st_ino, self.stat.st_size,
                 self.stat.st_mtime_ns, self.stat.st_ctime_ns), 'source changed during load')


class VirtualRom:
    def __init__(self, source, size):
        require(512 <= size <= 512*1024*1024, 'invalid cartridge size')
        self.source, self.size = source, size
        self.patches = []

    def add(self, at, data):
        require(data and 0 <= at and at + len(data) <= min(self.size, LIMIT), 'patch outside cartridge memory')
        self.patches.append((at, bytes(data)))

    def finish(self):
        self.patches.sort()
        end = 0
        for at, data in self.patches:
            require(at >= end, 'overlapping cartridge patches')
            end = at + len(data)
        self.source.unchanged()
        return self

    def blocks(self, start=0, end=None):
        end = self.size if end is None else end
        require(0 <= start <= end <= self.size, 'invalid stream range')
        at = start
        for offset, data in self.patches + [(end, b'')]:
            if offset + len(data) <= at and data:
                continue
            until = min(offset, end)
            while at < until:
                n = min(CHUNK, until-at)
                if at < self.source.size:
                    n = min(n, self.source.size-at)
                    yield self.source.read(at, n)
                else:
                    yield b'\xff' * n
                at += n
            if at >= end:
                break
            lo, hi = max(0, at-offset), min(len(data), end-offset)
            for p in range(lo, hi, CHUNK):
                part = data[p:min(p+CHUNK,hi)]
                yield part
                at += len(part)
        require(at == end, 'incomplete virtual stream')


class CompactedFiles:
    """Read-only FAT relocation for an exact, separately qualified cartridge.

    Keep the boot/system prefix intact and stream file payloads at their new
    FAT offsets. Replaced movies are supplied by VirtualRom. No whole-ROM
    buffer or on-disk patched cartridge is created on MiSTer.
    """
    def __init__(self, source, spec, movies):
        self.source, self.size = source, source.size
        header = source.read(0, 512)
        fat, fat_size = struct.unpack_from('<II', header, 0x48)
        prefix, alignment = spec['prefix'], spec['alignment']
        require(alignment == 128 and 512 <= prefix <= LIMIT and
                fat_size % 8 == 0 and 512 <= fat < fat + fat_size <= prefix,
                'invalid compact file layout')
        original = source.read(fat, fat_size)
        require(digest(original) == spec['source_fat_sha256'], 'file table differs')
        table = bytearray(original)
        replacements = {m['id']: m for m in movies}
        require(len(replacements) == len(movies), 'duplicate compact movie')
        spans = [(0, fat, 0), (fat + fat_size, prefix, fat + fat_size)]
        files = [(i, *struct.unpack_from('<II', original, i*8))
                 for i in range(fat_size//8)]
        cursor, previous_end = prefix, 0
        found = set()
        for fid, start, end in sorted(files, key=lambda f: (f[1], f[2], f[0])):
            require(0 <= start <= end <= source.size and start >= previous_end,
                    'overlapping or invalid source files')
            previous_end = end
            if start < prefix:
                require(end <= prefix and fid not in replacements, 'file crosses compact prefix')
                continue
            cursor = (cursor + alignment - 1) & ~(alignment - 1)
            size = replacements[fid]['output_bytes'] if fid in replacements else end-start
            require(cursor + size <= LIMIT, 'compacted files exceed cartridge memory')
            struct.pack_into('<II', table, fid*8, cursor, cursor+size)
            if fid in replacements:
                require(replacements[fid]['output_offset'] == cursor, 'compact movie offset differs')
                found.add(fid)
            elif size:
                spans.append((cursor, cursor+size, start))
            cursor += size
        require(found == set(replacements) and cursor == spec['files_end'],
                'compact file extent differs')
        require(digest(table) == spec['output_fat_sha256'], 'compact file table differs')
        spans.append((fat, fat+fat_size, bytes(table)))
        self.spans = sorted(spans)
        self.starts = [s[0] for s in self.spans]
        require(all(a[1] <= b[0] for a, b in zip(self.spans, self.spans[1:])),
                'overlapping compact output')
        self.unchanged()

    def unchanged(self):
        self.source.unchanged()

    def read(self, start, size):
        require(0 <= start <= self.size and 0 <= size <= self.size-start,
                'compact read outside cartridge')
        out, end = bytearray(), start+size
        index = max(0, bisect.bisect_right(self.starts, start)-1)
        while start < end:
            while index < len(self.spans) and self.spans[index][1] <= start:
                index += 1
            if index == len(self.spans):
                out.extend(b'\xff'*(end-start)); break
            a, b, backing = self.spans[index]
            if start < a:
                stop = min(a, end); out.extend(b'\xff'*(stop-start)); start = stop
                continue
            stop = min(b, end)
            out.extend(backing[start-a:stop-a] if isinstance(backing, bytes)
                       else self.source.read(backing+start-a, stop-start))
            start = stop
        return bytes(out)


def profile_for(source, profiles, progress=lambda n: None):
    header = source.read(0, 512)
    matches = [p for p in profiles if header[12:16].hex() == p['code_hex'] and
               header[30] == p['revision'] and source.size == p['source_size']]
    if len(matches) > 1:
        # Translations can retain the retail code, revision and padded size.
        # Select by complete identity; never let registry order choose a patch.
        identity = source.sha256(progress)
        matches = [p for p in matches if p['source_sha256'] == identity]
        require(len(matches) <= 1, 'ambiguous cartridge profile')
    return matches[0] if matches else None


def movie(source, spec):
    """Reframe packets while preserving every original video and audio byte."""
    raw = source.read(spec['source_offset'], spec['source_bytes'])
    require(digest(raw) == spec['source_sha256'], 'movie identity differs')
    rows = zlib.decompress(base64.b64decode(spec['descriptors']))
    count = spec['frames']
    out = reframe_movie(raw, spec['family'], rows, count)
    require(len(out) == spec['output_bytes'] and digest(out) == spec['output_sha256'],
            'movie reconstruction differs from qualified stream')
    return out


def reframe_movie(raw, family, rows, count):
    """Build a lossless packet envelope, also used by offline qualification.

    Runtime callers must verify source and output identities through movie().
    Movie timing, audio payloads and seek entries retain their original values.
    """
    require(family in ('vx', 'mobiclip'), 'unknown movie family')
    require(len(rows) == count*16, 'invalid descriptor table')
    vx = family == 'vx'
    require(raw[:4] == (b'VXDS' if vx else b'MODS'), 'movie signature differs')
    require(struct.unpack_from('<I', raw, 4 if vx else 8)[0] == count, 'frame count differs')
    pos = 48 if vx else 52
    out = bytearray(raw[:pos]); offsets = {}; maximum = 0
    for frame in range(count):
        old = pos
        if vx:
            size, audio = struct.unpack_from('<HH', raw, pos)
            require(2 <= size <= 65519, 'VX frame size invalid')
            stop = pos + size + 2
        else:
            word = struct.unpack_from('<I', raw, pos)[0]
            size, audio = word >> 14, word & 16383
            stop = pos + size + 4
        require(pos+6 <= stop <= len(raw), 'packet outside asset')
        payload = raw[pos+4:stop]
        descriptor = rows[frame*16:(frame+1)*16]
        magic, consumed, quant, sequence = struct.unpack('<4I', descriptor)
        require(sequence == frame and 2 <= consumed <= len(payload), 'descriptor range differs')
        if vx:
            require(magic == 0x31585646 and 12 <= (quant & 65535) <= 161,
                    'VX descriptor invalid')
            packet_header = struct.pack('<HH', size+16, audio)
            maximum = max(maximum, size+18)
        else:
            key = struct.unpack_from('<H', payload)[0] & 0x8000
            require(magic == (0x43424453 | key) and 12 <= (quant & 65535) <= 161,
                    'MobiClip descriptor invalid')
            packet_header = struct.pack('<I', ((size+16) << 14) | audio)
            maximum = max(maximum, size+16)
        offsets[old] = len(out)
        out.extend(packet_header); out.extend(descriptor); out.extend(payload)
        pos = stop
    audio_offset, keys_offset, key_count = struct.unpack_from('<III', raw, 36)
    require(pos == (audio_offset or keys_offset), 'unexpected movie trailer')
    shift = len(out)-pos
    out.extend(raw[pos:])
    if vx:
        maximum = max(maximum, struct.unpack_from('<I', raw, 32)[0]+16)
    struct.pack_into('<III', out, 32, maximum, audio_offset+shift if audio_offset else 0, keys_offset+shift)
    require(keys_offset + key_count*8 <= len(raw), 'keyframe table out of range')
    for i in range(key_count):
        frame, offset = struct.unpack_from('<II', raw, keys_offset+i*8)
        require(frame < count and offset in offsets, 'invalid keyframe index')
        struct.pack_into('<II', out, keys_offset+shift+i*8, frame, offsets[offset])
    return out


def assemble(source, profile, root=ROOT, progress=lambda n: None):
    require(source.sha256(progress) == profile['source_sha256'], 'cartridge revision/content differs')
    header = bytearray(source.read(0,512))
    armoff, entry, load, size = struct.unpack_from('<4I', header, 32)
    main = code.MainCodeFile(source.read(armoff,size), load)
    fat, fat_size = struct.unpack_from('<II', header, 0x48)
    oe, osize = struct.unpack_from('<II', header, 0x50)
    backing = CompactedFiles(source, profile['compact_files'], profile['movies']) \
        if 'compact_files' in profile else source
    image = VirtualRom(backing, profile['output_size'])
    overlays = {}
    for spec in profile['overlays']:
        row = oe+spec['id']*32
        require(row+32 <= oe+osize, 'overlay index out of range')
        info = struct.unpack('<8I', source.read(row,32))
        require(info[0] == spec['id'] and info[1] == spec['ram'], 'overlay layout differs')
        require(info[6]*8+8 <= fat_size, 'overlay file ID invalid')
        a,b = struct.unpack('<II',source.read(fat+info[6]*8,8))
        raw = bytearray(codeCompression.decompress(source.read(a,b-a)))
        require(len(raw) == info[2], 'overlay size differs')
        overlays[spec['id']] = (raw,info[1],row,info[6],spec)

    def region(pc, overlay):
        if overlay is not None:
            raw,base,*_ = overlays[overlay]
        else:
            matches = [s for s in main.sections if s.ramAddress <= pc < s.ramAddress+len(s.data)]
            require(len(matches)==1, 'code address ambiguous')
            raw,base = matches[0].data,matches[0].ramAddress
        require(base <= pc < base+len(raw), 'code address out of range')
        return raw,pc-base

    c = profile['converter']
    raw, at = region(c['pc'],c['overlay'])
    converter = bytes(raw[at:at+c['bytes']])
    require(len(converter) == c['bytes'] and digest(converter) == c['sha256'], 'converter identity differs')
    extension = bytearray(0xe40)
    extension[:len(converter)] = converter
    for stub in profile['stubs']:
        blob = (root/'guest'/stub['file']).read_bytes()
        require(digest(blob) == stub['sha256'] and stub['offset']+len(blob) <= 0xe00,
                'guest hook differs')
        extension[stub['offset']:stub['offset']+len(blob)] = blob
    for patch in profile['code_patches']:
        raw,at = region(patch['pc'],patch['overlay'])
        before,after = bytes.fromhex(patch['before']),bytes.fromhex(patch['after'])
        require(raw[at:at+len(before)] == before and len(before)==len(after), 'code guard differs')
        raw[at:at+len(after)] = after
    for s in main.sections:
        require(s.ramAddress+len(s.data)+s.bssSize <= 0x1fff000 or s.ramAddress >= 0x1fffe40,
                'autoload scratch space occupied')
    main.sections.append(code.MainCodeFile.Section(extension,0x1fff000,0))
    arm9 = main.save(compress=False)
    require(arm9[:0x800] == source.read(armoff,0x800), 'secure area changed')
    require(len(arm9) == profile['arm9_bytes'] and digest(arm9) == profile['arm9_sha256'],
            'autoload reconstruction differs')
    image.add(profile['arm9_offset'],arm9)
    struct.pack_into('<4I',header,32,profile['arm9_offset'],entry,load,len(arm9))
    for raw,base,row,fid,spec in overlays.values():
        require(len(raw)==spec['output_bytes'] and digest(raw)==spec['output_sha256'], 'overlay reconstruction differs')
        image.add(spec['output_offset'],raw)
        image.add(fat+fid*8,struct.pack('<II',spec['output_offset'],spec['output_offset']+len(raw)))
        image.add(row+28,struct.pack('<I',0))
    for spec in profile['movies']:
        output = movie(source,spec)
        image.add(spec['output_offset'],output)
        image.add(fat+spec['id']*8,struct.pack('<II',spec['output_offset'],spec['output_offset']+len(output)))
        progress(spec['output_offset'])
    header[0x14] = profile['capacity']
    struct.pack_into('<I',header,0x80,profile['used'])
    struct.pack_into('<H',header,0x15e,_common.crc16(header[:0x15e]))
    image.add(0,header)
    return image.finish()
