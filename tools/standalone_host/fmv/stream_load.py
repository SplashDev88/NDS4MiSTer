# SPDX-License-Identifier: GPL-3.0-or-later
"""Copy compacted files while verifying the source, before releasing DS reset.

Only the parent can write its reserved cartridge aperture. Every original byte
is hashed on a fresh preparation; an optional observer stores verified writes.
"""
import hashlib
import struct
import sys
from prepare import CHUNK, CompactedFiles, VirtualRom, assemble, require


def transfer_limit(size):
    require(512 <= size <= 512*1024**2, 'invalid prepared cartridge size')
    return min(size, (464 if size > 256*1024**2 else 252)*1024**2)


def select_plan(source, profiles):
    header = source.read(0, 512)
    matches = []
    for profile in profiles:
        if (profile['code_hex'] != header[12:16].hex() or profile['revision'] != header[30]
                or profile['source_size'] != source.size):
            continue
        try:
            transfer_limit(profile['output_size'])
            if 'compact_files' in profile:
                require(profile['output_size'] == source.size, 'expanded compacted cartridge')
                backing = CompactedFiles(source, profile['compact_files'], profile['movies'])
            else:
                backing = None
        except ValueError:
            continue
        matches.append((profile, backing))
    # Header/FAT matches select a cache namespace, never permission to patch.
    # Full original SHA-256 is checked after the sequential copy, before patches.
    return matches[0] if len(matches) == 1 else None


def transfer_image(source, profile, emit, assembler, observe, prepared, recovery):
    """Cache other qualified images, including cartridges expanded by movies.

    Fresh failures retain the original cartridge and its original size. After
    a corrupt cache has already announced a size, reconstruction must qualify
    that same image or fail closed; never change the parent's reserved aperture.
    """
    size = profile['output_size']
    qualified = False
    def progress(n):
        emit(struct.pack('<Qii', size if recovery else min(n, size), 0, 7))
    try:
        require(source.sha256(progress) == profile['source_sha256'], 'cartridge revision/content differs')
        image = assembler(source, profile, progress=progress)
        require(image.size == size, 'prepared cartridge size differs')
        qualified = True
    except (ValueError, KeyError, IndexError, struct.error, OSError) as error:
        source.unchanged()
        if recovery:
            raise ValueError('cache recovery could not qualify original: '+str(error)) from error
        image = VirtualRom(source, source.size).finish()
        print('FMV_AUTO_FALLBACK '+str(error), file=sys.stderr, flush=True)
    size = image.size
    limit = transfer_limit(size)
    # The excluded upper aperture belongs to graphics/Linux, even on cache hits.
    for block in image.blocks(limit, size):
        require(block == b'\xff'*len(block), 'prepared data exceeds cartridge memory')
    source.unchanged()
    if not recovery:
        emit(struct.pack('<Qii', size, 0, 9))
    at = 0
    for block in image.blocks(0, limit):
        require(0 < len(block) <= CHUNK and at <= limit-len(block), 'invalid prepared block')
        emit(struct.pack('<Qii', at, len(block), 10))
        emit(block)
        if qualified:
            observe(at, block)
        at += len(block)
        emit(struct.pack('<Qii', size if recovery else at*size//limit, 0, 7))
    require(at == limit, 'incomplete prepared image')
    source.unchanged()
    if qualified:
        prepared()
        print('FMV_AUTO_APPLIED '+profile['key']+' verified image; save identity retained',
              file=sys.stderr, flush=True)
    if not recovery:
        emit(struct.pack('<Qii', 0, 0, 11))
    emit(struct.pack('<Qii', limit, 0, 8))


def transfer(source, plan, emit, assembler=assemble, observe=lambda at, data: None,
             prepared=lambda: None, recovery=False):
    profile, backing = plan
    if backing is None:
        return transfer_image(source, profile, emit, assembler, observe, prepared, recovery)
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
