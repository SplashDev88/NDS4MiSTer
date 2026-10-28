# SPDX-License-Identifier: GPL-3.0-only
"""Guarded, same-size patches to uncompressed ARM9 main or overlay files.

This extends the existing VirtualRom preparation path. It never writes a ROM
file and deliberately rejects compressed/autoload targets and scratch
allocation. Overlay bytes arrive through the normal file-load path; lifecycle
qualification remains per-game. A mismatch falls back atomically to the original stream.
Game identities, addresses and bytes belong in the supplied manifest.
"""
import hashlib
import json
from pathlib import Path
import struct
import zlib

from ndspy import code, codeCompression
from hook_guard import select_profile, verify_target
from prepare import VirtualRom, read_overlay, require


def assemble(source, manifest, patch_ids=(), progress=lambda n: None):
    requested = set(patch_ids)
    report = {'state': 'unchanged', 'requested': sorted(requested), 'applied': [], 'reason': None}

    def original(reason):
        report.update(state='skipped' if requested else 'unchanged', reason=reason, applied=[])
        return VirtualRom(source, source.size).finish(), report

    if not requested:
        return original('No patch enabled')
    try:
        require(manifest['schema_version'] == 1, 'Unknown manifest schema')
        header = source.read(0, 512)
        require(manifest['header_bytes'] == 352, 'Unsupported identity header extent')
        require(hashlib.sha1(header[:352]).hexdigest() == manifest['header_sha1'], 'Header identity differs')
        require(source.sha256(progress) == manifest['rom_sha256'], 'Cartridge identity differs')
        offset, entry, address, length = struct.unpack_from('<4I', header, 0x20)
        raw = source.read(offset, length)
        require(hashlib.sha256(raw).hexdigest() == manifest['arm9_sha256'], 'ARM9 identity differs')
        registry = {'version': 1, 'profiles': [{'game_code': manifest['game_code'],
                    'revision': manifest['revision'], 'arm9_crc32': manifest['arm9_crc32']}]}
        require(select_profile(registry, header, raw) is not None, 'Game/revision/ARM9 profile differs')
        require(codeCompression.decompress(raw) == raw, 'Compressed ARM9 is unsupported by this byte-patch path')
        arm = code.MainCodeFile(raw, address)
        main = arm.sections[0]
        require(main.implicit and main.ramAddress == address and bytes(main.data) == raw[:len(main.data)],
                'Initial main-code mapping differs')
        patches = {p['id']: p for p in manifest['patches']}
        require(len(patches) == len(manifest['patches']), 'Duplicate patch IDs')
        require(requested <= patches.keys(), 'Unknown patch ID')
        image = VirtualRom(source, source.size)
        data_guards = []
        overlay_files = {}
        for patch_id in sorted(requested):
            patch = patches[patch_id]
            require(patch['cpu'] == 'arm9' and patch['target'] in ('arm9.bin/main_loaded', 'arm9.overlay'),
                    'Unsupported CPU/target')
            require(patch.get('hook') is None and patch.get('scratch_bytes', 0) == 0,
                    'Hook or scratch requires a separately qualified mechanism')
            overlay = None
            if patch['target'] == 'arm9.overlay':
                overlay = read_overlay(source, header, patch['overlay'], int(patch['overlay_ram'], 0))
                info = overlay['info']
                require(type(patch['overlay_file_id']) is int and info[6] == patch['overlay_file_id'],
                        'Overlay file identity differs')
                require(info[7] == 0 and overlay['decoded'] == overlay['stored'],
                        'Compressed or flagged overlay is unsupported by this byte-patch path')
                require(hashlib.sha256(overlay['decoded']).hexdigest() == patch['overlay_sha256'],
                        'Overlay content identity differs')
                region, base, cartridge = overlay['decoded'], info[1], overlay['file_offset']
                require(0x02000000 <= base < base + len(region) <= 0x02400000,
                        'Overlay code is outside canonical ARM9 main RAM')
                overlay_files[info[0]] = (overlay, patch['overlay_sha256'])
            else:
                require(patch.get('overlay') is None, 'Overlay ID on initial main target')
                region, base, cartridge = raw[:len(main.data)], address, offset
            mode = patch['mode']
            require(mode in ('arm', 'thumb'), 'Unknown instruction mode')
            at = int(patch['addr'], 0)
            before, after = bytes.fromhex(patch['expect']), bytes.fromhex(patch['replace'])
            alignment = 4 if mode == 'arm' else 2
            require(at % alignment == 0 and len(before) % alignment == 0, 'Unaligned instruction patch')
            require(8 <= len(before) <= 4096 and len(before) == len(after), 'Invalid same-size patch extent')
            require(base <= at and at + len(before) <= base + len(region), 'Patch is outside declared code')
            require(region[at-base:at-base+len(before)] == before, 'Original instruction bytes differ')
            for data_guard in patch.get('data_guards', []):
                guard_at = int(data_guard['addr'], 0)
                guard_bytes = bytes.fromhex(data_guard['expect'])
                require(0 < len(guard_bytes) <= 4096 and base <= guard_at and
                        guard_at + len(guard_bytes) <= base + len(region),
                        'Data invariant is outside declared code/data')
                require(region[guard_at-base:guard_at-base+len(guard_bytes)] == guard_bytes,
                        'Original data invariant differs')
                data_guards.append((cartridge + guard_at - base, guard_bytes))
            if overlay is None:
                guard = dict(address=at, guard_bytes=min(16, len(before)), phase='main_loaded',
                             guard_sha256=hashlib.sha256(before[:min(16, len(before))]).hexdigest())
                ok, reason = verify_target(guard, lambda a, n: raw[a-address:a-address+n])
                require(ok, reason)
            image.add(cartridge + at - base, after)
            report['applied'].append(dict(id=patch_id, address=at, cartridge_offset=cartridge+at-base,
                                          bytes=len(after), original_sha256=hashlib.sha256(before).hexdigest(),
                                          replacement_sha256=hashlib.sha256(after).hexdigest()))
        image.finish()
        for guard_offset, guard_bytes in data_guards:
            require(b''.join(image.blocks(guard_offset, guard_offset + len(guard_bytes))) == guard_bytes,
                    'Selected patch changes a protected data invariant')
        require(b''.join(image.blocks(0, 512)) == header, 'Header changed')
        if overlay_files:
            fat, fat_size = struct.unpack_from('<II', header, 0x48)
            oe, osize = struct.unpack_from('<II', header, 0x50)
            for first, length in ((fat, fat_size), (oe, osize)):
                require(b''.join(image.blocks(first, first + length)) == source.read(first, length),
                        'Overlay delivery metadata changed')
            report['overlays'] = []
            for overlay_id, (loaded, original_hash) in sorted(overlay_files.items()):
                first, length = loaded['file_offset'], len(loaded['stored'])
                output = b''.join(image.blocks(first, first + length))
                report['overlays'].append(dict(id=overlay_id, file_id=loaded['info'][6],
                    ram=loaded['info'][1], bytes=length, original_sha256=original_hash,
                    output_sha256=hashlib.sha256(output).hexdigest(),
                    delivery='unchanged-layout uncompressed overlay file'))
        report['state'] = 'applied_to_virtual_image'
        return image, report
    except (ValueError, KeyError, TypeError, IndexError, struct.error) as error:
        return original(str(error))


SELECTION_KEYS = ('NDS_GUEST_PATCH_MANIFEST', 'NDS_GUEST_PATCH_SHA256', 'NDS_GUEST_PATCH_IDS')


def from_environment(source, environment, progress=lambda n: None):
    """Explicit diagnostic selection; never enable a manifest by discovery.

    Pin the exact manifest in addition to its ROM/byte guards. This path may
    select disabled candidates for a private experiment, but changes no release
    defaults. It does not compose with movie preparation or its disk cache.
    """
    try:
        path, expected, selection = (environment.get(key, '') for key in SELECTION_KEYS)
        require(path and expected and selection, 'Incomplete guest patch selection')
        require(len(expected) == 64 and all(c in '0123456789abcdef' for c in expected),
                'Invalid guest manifest SHA256')
        patches = selection.split(',')
        require(all(p and p.strip() == p for p in patches) and len(patches) == len(set(patches)),
                'Invalid or duplicate guest patch IDs')
        with Path(path).open('rb') as stream:
            raw = stream.read(1024*1024+1)
        require(len(raw) <= 1024*1024, 'Guest manifest is too large')
        require(hashlib.sha256(raw).hexdigest() == expected, 'Guest manifest identity differs')
        manifest = json.loads(raw)
        require(isinstance(manifest, dict), 'Guest manifest must be an object')
        image, report = assemble(source, manifest, patches, progress)
        report['manifest_sha256'] = expected
        return image, report
    except (ValueError, KeyError, TypeError, IndexError, struct.error, OSError) as error:
        return VirtualRom(source, source.size).finish(), dict(
            state='skipped', requested=[], applied=[], reason=str(error))
