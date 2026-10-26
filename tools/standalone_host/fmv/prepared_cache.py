# SPDX-License-Identifier: GPL-3.0-or-later
"""Local, bounded cache of fully qualified cartridge writes.

The first launch verifies the entire original. Hits trust its canonical path
and stat identity, and verify every cached byte before releasing reset. Changing
source metadata or any paired loader code invalidates the entry. This is not a
fresh content check of a network source whose metadata has been preserved.
"""
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import sys
from prepare import CHUNK, ROOT, require
from stream_load import transfer, transfer_limit
from load_progress import LoadProgress

DEFAULT_ROOT = Path('/media/fat/.cache/NDS4MiSTer/prepared-roms')
BUDGET = 2 * 1024**3
MAX_ENTRY = 513 * 1024**2
RESERVE = 128 * 1024**2
NAME = re.compile(r'^[0-9a-f]{64}\.(json|data|tmp)$')


def log(message):
    print('ROM_CACHE '+message, file=sys.stderr, flush=True)


def stat_identity(s):
    return (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)


def loader_identity(root=ROOT):
    h = hashlib.sha256(b'NDS prepared write cache v1\0')
    paths = sorted(p for p in root.rglob('*') if p.is_file() and p.suffix in ('.py', '.json', '.bin'))
    host = root.parent/'nds_standalone_host'
    if host.is_file():
        paths.append(host)
    for p in paths:
        h.update(str(p.relative_to(root.parent)).encode()+b'\0')
        with p.open('rb') as f:
            for block in iter(lambda: f.read(CHUNK), b''):
                h.update(block)
    return h.hexdigest()


def cache_key(source, profile, loader):
    # The fd resolves symlinks and retains the opened source's identity.
    path = os.path.realpath('/proc/self/fd/'+str(source.fd))
    values = [1, path, stat_identity(source.stat), loader, profile]
    return hashlib.sha256(json.dumps(values, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


class Store:
    def __init__(self, root, key):
        self.root, self.key, self.lock = Path(root), key, None
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock = (self.root/'.lock').open('a+b')
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.lock.close()
            raise
        # Only this namespace is pruned, while no writer/replayer can use it.
        for p in self.root.iterdir():
            if NAME.fullmatch(p.name) and (p.suffix == '.tmp' or
                    (p.suffix == '.data' and not p.with_suffix('.json').is_file())):
                p.unlink()

    def close(self):
        if self.lock:
            self.lock.close()
            self.lock = None

    def path(self, suffix):
        return self.root/(self.key+suffix)

    def invalidate(self):
        for suffix in ('.json', '.data'):
            try:
                self.path(suffix).unlink()
            except FileNotFoundError:
                pass

    def entry(self):
        f = None
        try:
            p = self.path('.json')
            require(p.stat().st_size <= 4096, 'oversized cache metadata')
            m = json.loads(p.read_text())
            require(m['version'] == 1 and m['key'] == self.key and
                    isinstance(m['bytes'], int) and 0 < m['bytes'] <= MAX_ENTRY and
                    re.fullmatch('[0-9a-f]{64}', m['sha256']), 'invalid cache metadata')
            f = self.path('.data').open('rb')
            require(os.fstat(f.fileno()).st_size == m['bytes'], 'cache size differs')
            return f, m
        except (OSError, ValueError, KeyError, TypeError):
            if f:
                f.close()
            return None

    def reserve(self, required=MAX_ENTRY):
        require(0 < required <= MAX_ENTRY, 'invalid cache reservation')
        entries = sorted((p for p in self.root.glob('*.data') if NAME.fullmatch(p.name)),
                         key=lambda p: p.with_suffix('.json').stat().st_mtime_ns)
        used = sum(p.stat().st_size for p in entries)
        def free():
            s = os.statvfs(self.root)
            return s.f_bavail*s.f_frsize
        while entries and (used+required > BUDGET or free() < required+RESERVE):
            p = entries.pop(0)
            used -= p.stat().st_size
            p.with_suffix('.json').unlink()
            p.unlink()
        return used+required <= BUDGET and free() >= required+RESERVE


class Writer:
    def __init__(self, store, required=MAX_ENTRY):
        self.store, self.file = store, None
        self.max_size = required
        self.size, self.hash = 0, hashlib.sha256()
        self.temp = store.path('.tmp')
        if store.reserve(required):
            self.file = self.temp.open('wb', buffering=CHUNK)
        else:
            log('disabled for this load: insufficient free space')

    def abort(self):
        if self.file:
            try:
                self.file.close()
            except OSError:
                pass
            self.file = None
        try:
            self.temp.unlink()
        except FileNotFoundError:
            pass

    def append(self, at, data):
        if not self.file:
            return
        try:
            header = struct.pack('<QI', at, len(data))
            require(self.size+len(header)+len(data) <= self.max_size, 'cache exceeds size bound')
            for b in (header, data):
                self.file.write(b)
                self.hash.update(b)
                self.size += len(b)
        except (OSError, ValueError) as error:
            log('write skipped: '+str(error))
            self.abort()

    def commit(self):
        if not self.file:
            return
        try:
            self.file.flush()
            os.fsync(self.file.fileno())
            self.file.close()
            self.file = None
            os.replace(self.temp, self.store.path('.data'))
            manifest = dict(version=1, key=self.store.key, bytes=self.size, sha256=self.hash.hexdigest())
            # Publish metadata last. A killed writer leaves an orphan that is
            # discarded on the next launch, never a usable partial entry.
            with self.temp.open('w') as f:
                json.dump(manifest, f)
                f.flush()
                os.fsync(f.fileno())
            os.replace(self.temp, self.store.path('.json'))
            fd = os.open(self.store.root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                try:
                    os.fsync(fd)
                except OSError as error:
                    if error.errno != errno.EINVAL:
                        raise
            finally:
                os.close(fd)
            log('stored verified preparation ('+str(self.size)+' bytes)')
        except OSError as error:
            log('commit skipped: '+str(error))
            self.abort()


def replay(source, entry, emit, image_size=None, work=None):
    f, meta = entry
    before = os.fstat(f.fileno())
    image_size = source.size if image_size is None else image_size
    limit = transfer_limit(image_size)
    count, h = 0, hashlib.sha256()
    while count < meta['bytes']:
        header = f.read(12)
        require(len(header) == 12, 'short cache record')
        at, n = struct.unpack('<QI', header)
        require(0 < n <= CHUNK and at <= limit-n and count+12+n <= meta['bytes'],
                'invalid cache write')
        data = f.read(n)
        require(len(data) == n, 'short cache payload')
        h.update(header)
        h.update(data)
        emit(struct.pack('<Qii', at, n, 10))
        emit(data)
        count += 12+n
        emit(struct.pack('<Qii', count*image_size//meta['bytes'], 0, 7))
        if work:
            work.update(0, 9700, count, meta['bytes'])
    require(not f.read(1) and stat_identity(before) == stat_identity(os.fstat(f.fileno())) and
            h.hexdigest() == meta['sha256'], 'cache verification failed')
    source.unchanged()


def cached_transfer(source, plan, emit, root=None, loader=None, assembler=None):
    work = LoadProgress(emit)
    root = root if root is not None else os.environ.get('NDS_ROM_CACHE_DIR', str(DEFAULT_ROOT))
    store, writer, recovery = None, None, False
    image_size = plan[0]['output_size']
    limit = transfer_limit(image_size)
    kwargs = {} if assembler is None else {'assembler': assembler}
    try:
        if root and root != 'off':
            try:
                store = Store(root, cache_key(source, plan[0], loader or loader_identity()))
            except OSError as error:
                log('unavailable; reading original: '+str(error))
        if store:
            entry = store.entry()
            if entry:
                source.unchanged()
                emit(struct.pack('<Qii', image_size, 0, 9))
                try:
                    replay(source, entry, emit, image_size, work)
                except (ValueError, OSError) as error:
                    log('invalid; rebuilding from original: '+str(error))
                    store.invalidate()
                    # Previous cache bytes were provisional. Clear ALL of them
                    # before a fresh full-source verification/preparation.
                    emit(struct.pack('<Qii', image_size, 0, 7))
                    emit(struct.pack('<Qii', 0, 0, 11))
                    for at in range(0, limit, CHUNK):
                        data = b'\xff'*min(CHUNK, limit-at)
                        emit(struct.pack('<Qii', at, len(data), 10))
                        emit(data)
                    recovery = True
                    work.recovery()
                else:
                    emit(struct.pack('<Qii', image_size, 0, 7))
                    emit(struct.pack('<Qii', 0, 0, 11))
                    work.update(9700, 9900)
                    emit(struct.pack('<Qii', limit, 0, 8))
                    try:
                        os.utime(store.path('.json'), None)
                    except OSError:
                        pass
                    log('hit verified; original metadata unchanged; '+plan[0]['key'])
                    print('FMV_AUTO_APPLIED '+plan[0]['key']+' verified local cache; save identity retained',
                          file=sys.stderr, flush=True)
                    return
                finally:
                    entry[0].close()
            try:
                store.invalidate()
                # Full images have a known upper bound; don't evict half a GiB
                # for a 128 MiB title. Compacted writes retain their old bound.
                patches = 2+3*len(plan[0].get('overlays', []))+2*len(plan[0].get('movies', []))
                required = MAX_ENTRY if plan[1] is not None else min(MAX_ENTRY,
                    limit+12*((limit+CHUNK-1)//CHUNK+2*patches+1))
                writer = Writer(store, required)
            except OSError as error:
                log('cannot create entry: '+str(error))
        # Optional UI metadata is negotiated by the paired host. Old hosts
        # retain the original stream; hits and disabled caches keep Loading ROM.
        if writer and writer.file and os.environ.get('NDS_ROM_CACHE_STATUS') == '1':
            emit(struct.pack('<Qii', 0, 1, 12))
        transfer(source, plan, emit, recovery=recovery, work=work,
                 observe=writer.append if writer else lambda at, data: None,
                 prepared=writer.commit if writer else lambda: None, **kwargs)
    finally:
        if writer:
            writer.abort()
        if store:
            store.close()
