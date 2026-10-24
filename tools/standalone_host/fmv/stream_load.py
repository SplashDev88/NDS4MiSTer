# SPDX-License-Identifier: GPL-3.0-or-later
"""Copy compacted files while verifying the source, before releasing DS reset.

Only the parent can write its reserved cartridge aperture. Every original byte
is hashed on a fresh preparation; an optional observer stores verified writes.
"""
import hashlib
import struct
import sys
from prepare import CHUNK, CompactedFiles, assemble, require


def select_plan(source, profiles):
    header = source.read(0, 512)
    matches = []
    for profile in profiles:
        if (profile['code_hex'] != header[12:16].hex() or profile['revision'] != header[30]
                or profile['source_size'] != source.size or profile['output_size'] != source.size
                or 'compact_files' not in profile):
            continue
        try:
            backing = CompactedFiles(source, profile['compact_files'], profile['movies'])
        except ValueError:
            continue
        matches.append((profile, backing))
    # The FAT identifies a relocation plan, never permission to install hooks.
    # Full original SHA-256 is checked after the sequential copy, before patches.
    return matches[0] if len(matches) == 1 else None


def transfer(source, plan, emit, assembler=assemble, observe=lambda at, data: None,
             prepared=lambda: None, recovery=False):
    profile, backing = plan
    limit = min(source.size, (464 if source.size > 256*1024*1024 else 252)*1024*1024)
    spans = sorted((origin, origin+b-a, a) for a, b, origin in backing.spans
                   if isinstance(origin, int))
    require(all(a[1] <= b[0] for a, b in zip(spans, spans[1:])), 'overlapping source spans')
    require(all(0 <= a < b <= source.size and 0 <= dest <= limit-(b-a)
                for a, b, dest in spans), 'streamed relocation outside cartridge')
    source.unchanged()
    if not recovery:
        emit(struct.pack('<Qii', source.size, 0, 9))

    def record(at, data):
        require(0 <= at <= limit and len(data) <= limit-at, 'streamed patch outside cartridge')
        for n in range(0, len(data), CHUNK):
            part = memoryview(data)[n:n+CHUNK]
            emit(struct.pack('<Qii', at+n, len(part), 10))
            emit(part)
            observe(at+n, part)

    h = hashlib.sha256()
    index = 0
    native_padding = True
    for at in range(0, source.size, CHUNK):
        block = source.read(at, min(CHUNK, source.size-at))
        end = at+len(block)
        h.update(block)
        if end > limit:
            tail = block[max(0, limit-at):]
            native_padding = native_padding and tail == b'\xff'*len(tail)
        while index < len(spans) and spans[index][1] <= at:
            index += 1
        i = index
        while i < len(spans) and spans[i][0] < end:
            begin, stop, dest = spans[i]
            lo, hi = max(begin, at), min(stop, end)
            if lo < hi:
                record(dest+lo-begin, memoryview(block)[lo-at:hi-at])
            i += 1
        emit(struct.pack('<Qii', source.size if recovery else end, 0, 7))
    source.unchanged()
    source._sha256 = h.hexdigest()
    if not recovery:
        emit(struct.pack('<Qii', 0, 0, 11))
    try:
        require(source._sha256 == profile['source_sha256'], 'cartridge revision/content differs')
        image = assembler(source, profile, progress=lambda n: emit(struct.pack('<Qii', source.size, 0, 7)))
        require(image.size == source.size and image.source.spans == backing.spans,
                'relocation plan changed during preparation')
    except (ValueError, KeyError, IndexError, struct.error, OSError) as error:
        # A modified/unsupported cartridge gets the same native fallback as the
        # original worker. Overwrite ALL provisional bytes, not just patches.
        source.unchanged()
        require(native_padding, 'native fallback data exceeds cartridge memory')
        for at in range(0, limit, CHUNK):
            record(at, source.read(at, min(CHUNK, limit-at)))
        print('FMV_AUTO_FALLBACK '+str(error), file=sys.stderr, flush=True)
    else:
        for a, b, origin in backing.spans:
            if isinstance(origin, bytes):
                record(a, origin)
        for at, data in image.patches:
            record(at, data)
        source.unchanged()
        prepared()
        print('FMV_AUTO_APPLIED '+profile['key']+' streamed verification; save identity retained',
              file=sys.stderr, flush=True)
    source.unchanged()
    emit(struct.pack('<Qii', limit, 0, 8))
