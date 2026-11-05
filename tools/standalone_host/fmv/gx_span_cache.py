# SPDX-License-Identifier: GPL-3.0-or-later
"""Memoize guarded asset preparation in the existing bounded cache store.

Admission still verifies the full original ROM on every load. A cache hit must
match the manifest's exact transformed-asset hash before entering VirtualRom.
Only local disposable cache data is written; source ROMs remain read-only.
"""
import hashlib
import json
import os
import struct
from prepare import require
from prepared_cache import Store, Writer, DEFAULT_ROOT, log

# LZ10's worst case adds one flag byte per eight expanded bytes and its header.
MAX_ASSET = 9 * 1024 * 1024 + 4
MAX_STATS = 256 * 1024
MAX_PAYLOAD = MAX_ASSET + MAX_STATS + 8


def digest(data):
    return hashlib.sha256(data).hexdigest()


def prepared_asset(original, config, prepare):
    root = os.environ.get('NDS_ROM_CACHE_DIR', str(DEFAULT_ROOT))
    if os.environ.get('NDS_GX_ASSET_CACHE') != '1' or not root or root == 'off':
        return prepare(original, config)
    require(digest(original) == config['stored_sha256'], 'Asset cache source identity differs')
    # Expected output bytes, original bytes and every recipe option are pinned.
    # Code changes producing different output necessarily change this key.
    key = digest(b'GX asset preparation cache v1\0' +
                 json.dumps(config, sort_keys=True, separators=(',', ':')).encode())
    store = writer = None
    try:
        try:
            store = Store(root, key)
        except OSError as error:
            log('asset cache unavailable: '+str(error))
        if store:
            entry = store.entry()
            if entry:
                f, meta = entry
                try:
                    require(20 <= meta['bytes'] <= MAX_PAYLOAD+12, 'Invalid asset cache extent')
                    raw = f.read(MAX_PAYLOAD+13)
                    require(len(raw) == meta['bytes'] and digest(raw) == meta['sha256'],
                            'Asset cache record differs')
                    at, length = struct.unpack_from('<QI', raw)
                    require(at == 0 and length == len(raw)-12, 'Invalid asset cache record')
                    magic, stats_size = struct.unpack_from('<4sI', raw, 12)
                    require(magic == b'GXA1' and 0 < stats_size <= MAX_STATS and
                            20+stats_size < len(raw), 'Invalid asset cache envelope')
                    stats = json.loads(raw[20:20+stats_size])
                    data = raw[20+stats_size:]
                    require(isinstance(stats, dict) and type(stats.get('member_extra_bytes')) is int
                            and isinstance(stats.get('shapes'), list), 'Invalid asset cache statistics')
                    require(0 < len(data) <= MAX_ASSET and digest(data) == config['output_sha256'],
                            'Asset cache output identity differs')
                    log('asset hit verified; file '+str(config['file_id']))
                    try:
                        os.utime(store.path('.json'), None)
                    except OSError:
                        pass
                    return data, stats
                except (OSError, ValueError, KeyError, TypeError, struct.error) as error:
                    log('asset cache invalid; rebuilding: '+str(error))
                finally:
                    f.close()
            try:
                store.invalidate()
            except OSError as error:
                log('asset invalidation skipped: '+str(error))
                store.close(); store = None
        data, stats = prepare(original, config)
        require(0 < len(data) <= MAX_ASSET and digest(data) == config['output_sha256'],
                'Prepared asset identity differs')
        if store:
            try:
                encoded = json.dumps(stats, sort_keys=True, separators=(',', ':')).encode()
                require(0 < len(encoded) <= MAX_STATS, 'Asset statistics exceed cache limit')
                payload = struct.pack('<4sI', b'GXA1', len(encoded))+encoded+data
                writer = Writer(store, len(payload)+12)
                writer.append(0, payload)
                writer.commit()
            except (OSError, ValueError) as error:
                log('asset cache write skipped: '+str(error))
        return data, stats
    finally:
        if writer:
            writer.abort()
        if store:
            store.close()
