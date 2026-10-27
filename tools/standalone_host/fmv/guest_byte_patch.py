# SPDX-License-Identifier: GPL-3.0-only
"""Guarded, same-size patches to initially loaded, uncompressed ARM9 code.

This extends the existing VirtualRom preparation path. It never writes a ROM
file and deliberately rejects overlays, compressed/autoload targets and
scratch allocation. A mismatch falls back atomically to the original stream.
Game identities, addresses and bytes belong in the supplied manifest.
"""
import hashlib
import struct
import zlib

from ndspy import code, codeCompression
from hook_guard import select_profile, verify_target
from prepare import VirtualRom, require


def assemble(source, manifest, patch_ids=()):
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
        require(source.sha256() == manifest['rom_sha256'], 'Cartridge identity differs')
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
        for patch_id in sorted(requested):
            patch = patches[patch_id]
            require(patch['cpu'] == 'arm9' and patch['target'] == 'arm9.bin/main_loaded', 'Unsupported CPU/target')
            require(patch.get('overlay') is None and patch.get('hook') is None and patch.get('scratch_bytes', 0) == 0,
                    'Overlay, hook or scratch requires a separately qualified mechanism')
            mode = patch['mode']
            require(mode in ('arm', 'thumb'), 'Unknown instruction mode')
            at = int(patch['addr'], 0)
            before, after = bytes.fromhex(patch['expect']), bytes.fromhex(patch['replace'])
            alignment = 4 if mode == 'arm' else 2
            require(at % alignment == 0 and len(before) % alignment == 0, 'Unaligned instruction patch')
            require(8 <= len(before) <= 4096 and len(before) == len(after), 'Invalid same-size patch extent')
            require(address <= at and at + len(before) <= address + len(main.data), 'Patch is outside initial main code')
            require(raw[at-address:at-address+len(before)] == before, 'Original instruction bytes differ')
            guard = dict(address=at, guard_bytes=min(16, len(before)), phase='main_loaded',
                         guard_sha256=hashlib.sha256(before[:min(16, len(before))]).hexdigest())
            ok, reason = verify_target(guard, lambda a, n: raw[a-address:a-address+n])
            require(ok, reason)
            image.add(offset + at - address, after)
            report['applied'].append(dict(id=patch_id, address=at, cartridge_offset=offset+at-address,
                                          bytes=len(after), original_sha256=hashlib.sha256(before).hexdigest(),
                                          replacement_sha256=hashlib.sha256(after).hexdigest()))
        image.finish()
        require(b''.join(image.blocks(0, 512)) == header, 'Header changed')
        report['state'] = 'applied_to_virtual_image'
        return image, report
    except (ValueError, KeyError, TypeError, IndexError, struct.error) as error:
        return original(str(error))
