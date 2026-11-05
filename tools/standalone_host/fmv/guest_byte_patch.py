# SPDX-License-Identifier: GPL-3.0-only
"""Guarded, same-size patches delivered by the existing virtual cartridge.

This extends the existing VirtualRom preparation path. It never writes a ROM
file. Supports uncompressed ARM9 main/overlay, explicitly selected compressed
overlay relocation, and pinned ARM7 WRAM autoload sections, with no scratch allocation.
Bytes follow the normal load path; lifecycle
qualification remains per-game. A mismatch falls back atomically to the original stream.
Game identities, addresses and bytes belong in the supplied manifest.
"""
import hashlib
import json
from pathlib import Path
import struct
import zlib

from ndspy import code, codeCompression, _common
from hook_guard import select_profile, verify_target
from prepare import VirtualRom, read_overlay, require, LIMIT


def append_decoded_overlays(source, header, manifest, requested, report):
    """Reuse the FMV overlay relocation path, leaving both CPU images intact.

    This explicit delivery mode accepts only pinned compressed overlay files.
    It changes their FAT extents and compression words, then appends decoded
    bodies to the virtual stream. There is no main-code reconstruction, scratch
    allocation, persistent ROM output or runtime service. Even identical-byte
    controls change load timing/metadata and require separate qualification.
    """
    require(manifest['delivery'] == 'append-decoded-overlays-v1', 'Unknown delivery mode')
    patches = {p['id']: p for p in manifest['patches']}
    require(len(patches) == len(manifest['patches']) and requested <= patches.keys(),
            'Duplicate or unknown patch IDs')
    overlays = {}
    fat, _ = struct.unpack_from('<II', header, 0x48)
    table, table_bytes = struct.unpack_from('<II', header, 0x50)
    for ident in sorted(requested):
        patch = patches[ident]
        require(patch['cpu'] == 'arm9' and patch['target'] == 'arm9.overlay',
                'Append delivery supports ARM9 overlays only')
        require(patch.get('hook') is None and patch.get('scratch_bytes', 0) == 0,
                'Hook or scratch requires a separately qualified mechanism')
        loaded = read_overlay(source, header, patch['overlay'], int(patch['overlay_ram'], 0))
        info, region = loaded['info'], loaded['decoded']
        require(type(patch['overlay_file_id']) is int and info[6] == patch['overlay_file_id'],
                'Overlay file identity differs')
        require(info[7] == (0x01000000 | len(loaded['stored'])) and len(loaded['stored']) < len(region),
                'Expected a compressed overlay with no other flags')
        require(hashlib.sha256(loaded['stored']).hexdigest() == patch['overlay_stored_sha256'] and
                hashlib.sha256(region).hexdigest() == patch['overlay_sha256'],
                'Stored or decoded overlay identity differs')
        base = info[1]
        require(base % 4 == 0 and len(region) % 4 == 0 and info[3] % 4 == 0 and
                0x02000000 <= base < base + len(region) <= base + len(region) + info[3] <= 0x02400000,
                'Overlay extent is outside canonical ARM9 RAM')
        require(all(struct.unpack('<I', source.read(row + 24, 4))[0] != info[6]
                    for row in range(table, table + table_bytes, 32) if row != loaded['row']),
                'Another overlay shares the selected file ID')
        if info[0] not in overlays:
            overlays[info[0]] = dict(loaded=loaded, output=bytearray(region), ranges=[], guards=[], applied=[])
        item = overlays[info[0]]
        mode = patch['mode']; require(mode in ('arm', 'thumb'), 'Unknown instruction mode')
        at = int(patch['addr'], 0); before, after = map(bytes.fromhex, (patch['expect'], patch['replace']))
        alignment = 4 if mode == 'arm' else 2
        first, last = at-base, at-base+len(before)
        require(at % alignment == 0 and len(before) % alignment == 0 and
                8 <= len(before) <= 4096 and len(before) == len(after), 'Invalid same-size instruction patch')
        require(0 <= first < last <= len(region) and region[first:last] == before,
                'Original instruction bytes or extent differ')
        require(all(last <= lo or first >= hi for lo, hi in item['ranges']), 'Overlapping overlay patches')
        item['ranges'].append((first, last)); item['output'][first:last] = after
        for guard in patch.get('data_guards', []):
            start = int(guard['addr'], 0)-base; value = bytes.fromhex(guard['expect'])
            require(0 < len(value) <= 4096 and 0 <= start and start+len(value) <= len(region) and
                    region[start:start+len(value)] == value, 'Original data invariant differs')
            item['guards'].append((start, value))
        item['applied'].append(dict(id=ident, address=at, relative_offset=first, bytes=len(after),
            original_sha256=hashlib.sha256(before).hexdigest(), replacement_sha256=hashlib.sha256(after).hexdigest()))
    end = (source.size+511) & ~511
    for item in overlays.values():
        require(all(item['output'][at:at+len(value)] == value for at, value in item['guards']),
                'Selected patch changes a protected data invariant')
        item['offset'] = end; end = (end+len(item['output'])+511) & ~511
    require(end <= LIMIT, 'Appended overlays exceed cartridge memory')
    image = VirtualRom(source, end)
    changed_header = bytearray(header)
    struct.pack_into('<I', changed_header, 0x80, end)
    capacity = 0
    while (128*1024 << capacity) < end:
        capacity += 1
    changed_header[0x14] = capacity
    struct.pack_into('<H', changed_header, 0x15e, _common.crc16(changed_header[:0x15e]))
    image.add(0, changed_header)
    report['overlays'] = []
    for overlay_id, item in overlays.items():
        loaded, output, first = item['loaded'], item['output'], item['offset']
        info = loaded['info']
        image.add(first, output)
        image.add(fat+info[6]*8, struct.pack('<II', first, first+len(output)))
        image.add(loaded['row']+28, struct.pack('<I', 0))
        for applied in item['applied']:
            applied['cartridge_offset'] = first+applied.pop('relative_offset'); report['applied'].append(applied)
        report['overlays'].append(dict(id=overlay_id, file_id=info[6], ram=info[1], bytes=len(output),
            cartridge_offset=first, original_sha256=hashlib.sha256(loaded['decoded']).hexdigest(),
            output_sha256=hashlib.sha256(output).hexdigest(), delivery='appended decoded overlay; normal file loading'))
    image.finish()
    # Verify the stream retains all original ARM9/ARM7 bytes, including their
    # stored compression format. Metadata collisions must fail atomically.
    for at in (0x20, 0x30):
        first, _, _, size = struct.unpack_from('<4I', header, at)
        require(b''.join(image.blocks(first, first+size)) == source.read(first, size),
                'Overlay metadata overlaps a CPU image')
    report.update(state='applied_to_virtual_image', delivery=manifest['delivery'], virtual_bytes=end,
                  header_sha256=hashlib.sha256(changed_header).hexdigest())
    return image, report


def read_arm7_autoload(source, header, manifest, target):
    """Resolve an unchanged-layout copy-table payload, not a live-memory hook.

    The explicit settings offset and complete image identity are mandatory.
    MainCodeFile remains the shared decoder, but its heuristic alone cannot
    authorize a source offset. Restrict this path to a final, contiguous copy
    table and a selected section in the last shared-WRAM alias/private WRAM.
    Actual boot copy, mapping, execution and reset are per-game replay gates.
    """
    prefix = 'arm7.bin/autoload:'
    require(isinstance(target, str) and target.startswith(prefix), 'Unsupported ARM7 target')
    index = int(target[len(prefix):], 10)
    require(target == prefix + str(index) and index > 0, 'Invalid autoload section index')
    offset, entry, address, length = struct.unpack_from('<4I', header, 0x30)
    require(length > 0 and offset >= 512, 'Invalid ARM7 image extent')
    raw = source.read(offset, length)
    require(hashlib.sha256(raw).hexdigest() == manifest['arm7_sha256'] and
            zlib.crc32(raw) == int(manifest['arm7_crc32'], 16), 'ARM7 identity differs')
    require(codeCompression.decompress(raw) == raw, 'Compressed ARM7 is unsupported by this byte-patch path')
    settings = int(manifest['arm7_code_settings_offset'], 0)
    require(settings % 4 == 0 and 0 <= settings <= len(raw)-20, 'Invalid ARM7 code settings offset')
    begin, end, payload = (value-address for value in struct.unpack_from('<3I', raw, settings))
    require(all(n % 4 == 0 for n in (begin, end, payload)) and
            settings+20 <= payload <= begin < end == len(raw) and
            (end-begin) % 12 == 0 and (end-begin)//12 <= 64,
            'Unsupported ARM7 autoload table layout')
    # Validate raw extents before invoking the shared decoder on the image.
    cursor = payload
    entries = []
    for at in range(begin, end, 12):
        base, size, bss = struct.unpack_from('<3I', raw, at)
        require(all(n % 4 == 0 for n in (base, size, bss)) and
                cursor+size <= begin and base+size+bss <= 0x100000000,
                'Invalid ARM7 autoload entry')
        entries.append((base, size, bss, cursor)); cursor += size
    require(cursor == begin and index <= len(entries), 'ARM7 payload/table mapping differs')
    arm = code.MainCodeFile(raw, address)
    require(arm.codeSettingsOffs == settings and len(arm.sections) == len(entries)+1 and
            arm.sections[0].implicit and arm.sections[0].ramAddress == address and
            bytes(arm.sections[0].data) == raw[:payload], 'ARM7 decoded settings/main mapping differs')
    for section, (base, size, bss, first) in zip(arm.sections[1:], entries):
        require(not section.implicit and section.ramAddress == base and
                len(section.data) == size and section.bssSize == bss and
                bytes(section.data) == raw[first:first+size], 'ARM7 decoded autoload mapping differs')
    base, size, bss, first = entries[index-1]
    require(0x037f8000 <= base < base+size <= base+size+bss <= 0x03810000,
            'ARM7 section is outside supported WRAM autoload range')
    return dict(index=index, base=base, size=size, bss=bss, data=raw[first:first+size],
                file_offset=offset+first, image_offset=offset, raw=raw,
                prefix_bytes=payload, table_offset=begin, settings_offset=settings)


def recompress_arm9_autoload(source, header, manifest, requested, report):
    """Patch an existing autoload payload without changing cartridge layout.

    Identical-byte controls retain the original stored image. A changed
    selected result must retain the exact compressed size, settings and copy
    table, and every decoded byte outside the declared replacements. The
    ordinary boot loader copies these bytes into their original destination;
    this is not a live write into an instruction cache or a scratch allocation.
    """
    delivery = manifest['delivery']
    require(delivery in ('recompress-arm9-autoload-v1', 'append-decoded-arm9-autoload-v1',
                        'append-decoded-arm9-sections-v1'),
            'Unknown compressed ARM9 delivery')
    offset, _, address, length = struct.unpack_from('<4I', header, 0x20)
    require(offset >= 512 and length > 0, 'Invalid ARM9 image extent')
    raw = source.read(offset, length)
    decoded = codeCompression.decompress(raw)
    require(decoded != raw, 'Expected compressed ARM9')
    arm = code.MainCodeFile(raw, address)
    settings = int(manifest['arm9_code_settings_offset'], 0)
    require(arm.codeSettingsOffs == settings and settings % 4 == 0 and
            0 <= settings <= len(decoded)-24, 'ARM9 code settings differ')
    begin, end, payload = (n-address for n in struct.unpack_from('<3I', decoded, settings))
    require(all(n % 4 == 0 for n in (begin, end, payload)) and
            settings+24 <= payload <= begin < end == len(decoded) and
            (end-begin) % 12 == 0 and (end-begin)//12 <= 64,
            'Unsupported ARM9 autoload layout')
    entries = []; cursor = payload
    for at in range(begin, end, 12):
        base, size, bss = struct.unpack_from('<3I', decoded, at)
        require(all(n % 4 == 0 for n in (base, size, bss)) and cursor+size <= begin,
                'Invalid ARM9 autoload entry')
        entries.append((base, size, bss, cursor)); cursor += size
    require(cursor == begin and len(arm.sections) == len(entries)+1 and
            arm.sections[0].implicit and bytes(arm.sections[0].data) == decoded[:payload],
            'ARM9 copy-table mapping differs')
    for section, (base, size, bss, first) in zip(arm.sections[1:], entries):
        require(not section.implicit and section.ramAddress == base and
                section.bssSize == bss and bytes(section.data) == decoded[first:first+size],
                'ARM9 decoded section differs')
    patches = {p['id']: p for p in manifest['patches']}
    require(len(patches) == len(manifest['patches']) and requested <= patches.keys(),
            'Duplicate or unknown patch IDs')
    expected = bytearray(decoded); ranges = []; guards = []
    for ident in sorted(requested):
        patch = patches[ident]; prefix = 'arm9.bin/autoload:'
        target = patch['target']
        main = target == 'arm9.bin/main'
        require(patch['cpu'] == 'arm9' and isinstance(target, str) and
                (main or target.startswith(prefix)), 'Unsupported compressed ARM9 target')
        if main:
            require(delivery == 'append-decoded-arm9-sections-v1',
                    'Main section requires explicit decoded-sections delivery')
            index = 0
        else:
            index = int(target[len(prefix):], 10)
            require(target == prefix+str(index) and 1 <= index <= len(entries), 'Invalid autoload index')
        require(patch.get('overlay') is None and patch.get('hook') is None and
                patch.get('scratch_bytes', 0) == 0, 'Overlay, hook or scratch is unsupported')
        base, size, bss, first = ((address, payload, arm.sections[0].bssSize, 0)
                                 if main else entries[index-1])
        # Only physical ITCM-sized boot sections; no RAM or hardware aliases.
        require(size > 0 and ((main and base == 0x02000000 and
                              base+size+bss <= 0x02400000) or
                (not main and (0 <= base < base+size+bss <= 0x8000 or
                 0x01ff8000 <= base < base+size+bss <= 0x02000000))),
                'Selected section is outside supported RAM ranges')
        region = decoded[first:first+size]
        require(int(patch['section_base'], 0) == base and type(patch['section_bss_bytes']) is int and
                patch['section_bss_bytes'] == bss and
                hashlib.sha256(region).hexdigest() == patch['section_sha256'],
                'ARM9 section identity differs')
        mode = patch['mode']; require(mode in ('arm', 'thumb'), 'Unknown instruction mode')
        alignment = 4 if mode == 'arm' else 2
        at = int(patch['addr'], 0)-base
        before, after = map(bytes.fromhex, (patch['expect'], patch['replace']))
        require(at % alignment == 0 and len(before) % alignment == 0 and
                8 <= len(before) <= 4096 and len(before) == len(after) and
                0 <= at < at+len(before) <= size and region[at:at+len(before)] == before,
                'Original instruction bytes, alignment or extent differ')
        lo, hi = first+at, first+at+len(before)
        if main:
            require(lo >= 0x800 and (hi <= settings or lo >= settings+24),
                    'Main patch overlaps secure area or boot settings')
        require(all(hi <= a or lo >= b for a, b in ranges), 'Overlapping autoload patches')
        ranges.append((lo, hi)); expected[lo:hi] = after
        arm.sections[index].data[at:at+len(after)] = after
        for guard in patch.get('data_guards', []):
            g = int(guard['addr'], 0)-base; value = bytes.fromhex(guard['expect'])
            require(0 < len(value) <= 4096 and 0 <= g and g+len(value) <= size and
                    region[g:g+len(value)] == value, 'Original data invariant differs')
            guards.append((first+g, value))
        report['applied'].append(dict(id=ident, address=base+at, bytes=len(after),
            section=index, original_sha256=hashlib.sha256(before).hexdigest(),
            replacement_sha256=hashlib.sha256(after).hexdigest()))
    require(all(expected[at:at+len(value)] == value for at, value in guards),
            'Selected patch changes a protected data invariant')
    if delivery in ('append-decoded-arm9-autoload-v1', 'append-decoded-arm9-sections-v1'):
        # Reuse the existing FMV preparation's uncompressed MainCodeFile boot
        # image and VirtualRom relocation. No encoder, live patch, new memory
        # region, or runtime service is involved. Even a no-op selection uses
        # this delivery and needs its own unpatched replay qualification.
        require(address == 0x02000000 and address+len(decoded) <= 0x02400000 and
                offset >= 512 and decoded[:0x800] == raw[:0x800],
                'Unsupported decoded boot extent or secure area')
        compression_word = settings+20
        require(struct.unpack_from('<I', decoded, compression_word)[0] == address+length,
                'Compressed static-end pointer differs')
        struct.pack_into('<I', expected, compression_word, 0)
        output = bytes(arm.save(compress=False))
        require(output == bytes(expected), 'Decoded boot changes undeclared bytes')
        first = (source.size+511) & ~511
        end = (first+len(output)+511) & ~511
        require(end <= LIMIT, 'Decoded boot exceeds cartridge memory')
        changed_header = bytearray(header)
        struct.pack_into('<I', changed_header, 0x20, first)
        struct.pack_into('<I', changed_header, 0x2c, len(output))
        struct.pack_into('<I', changed_header, 0x80, end)
        capacity = 0
        while (128*1024 << capacity) < end:
            capacity += 1
        changed_header[0x14] = capacity
        struct.pack_into('<H', changed_header, 0x15e, _common.crc16(changed_header[:0x15e]))
        image = VirtualRom(source, end)
        image.add(0, changed_header); image.add(first, output); image.finish()
        report.update(state='applied_to_virtual_image', delivery=delivery, virtual_bytes=end,
                      arm9_output_sha256=hashlib.sha256(output).hexdigest(),
                      arm9_cartridge_offset=first, arm9_output_bytes=len(output),
                      decoded_output_sha256=hashlib.sha256(expected).hexdigest(),
                      header_sha256=hashlib.sha256(changed_header).hexdigest(),
                      metadata_changes=['ARM9 cartridge offset/length', 'used ROM size/capacity',
                                        'header CRC16', 'ARM9 compressed-static-end word cleared'])
        return image, report
    # Avoid a redundant HPS compression pass. Complete decoded-image equality
    # below proves that the encoder changed only the selected instructions.
    # A no-op control keeps the original encoding, rather than re-encoding it.
    output = raw if expected == decoded else bytes(arm.save(compress=True))
    require(len(output) == length and codeCompression.decompress(output) == bytes(expected),
            'Recompression changed extent or undeclared decoded bytes')
    image = VirtualRom(source, source.size)
    image.add(offset, output); image.finish()
    report.update(state='applied_to_virtual_image', delivery=manifest['delivery'],
                  virtual_bytes=source.size, arm9_output_sha256=hashlib.sha256(output).hexdigest(),
                  decoded_output_sha256=hashlib.sha256(expected).hexdigest())
    return image, report


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
        if manifest.get('delivery') == 'append-decoded-arm9-gx-spans-v1':
            # One logical optimization can need code in two boot sections plus
            # a resource recipe. Never expose a partial selection or resource
            # without its helper. All guards run before the stream is returned.
            ids = [p['id'] for p in manifest['patches']]
            require(1 <= len(ids) <= 8 and len(ids) == len(set(ids)) and
                    requested == set(ids), 'Atomic code/asset selection required')
            require(('asset' in manifest) != ('assets' in manifest),
                    'Select one resource recipe or a resource recipe list')
            assets = manifest.get('assets', [manifest.get('asset')])
            require(isinstance(assets, list) and 1 <= len(assets) <= 32 and
                    all(isinstance(a, dict) and type(a.get('file_id')) is int
                        for a in assets), 'Invalid resource recipe list')
            require(len({a['file_id'] for a in assets}) == len(assets),
                    'Duplicate resource file ID')
            from gx_span_asset import append_asset
            boot_manifest = dict(manifest, delivery='append-decoded-arm9-sections-v1')
            # Keep partial preparation out of the returned report as well as
            # the cartridge stream if any later resource fails its guards.
            trial_report = dict(report, applied=[])
            image, trial_report = recompress_arm9_autoload(
                source, header, boot_manifest, requested, trial_report)
            asset_reports = []
            for asset in assets:
                image, trial_report = append_asset(source, image, trial_report, asset)
                asset_reports.append(trial_report.pop('asset'))
                # A multi-resource transform can outlast the reader's stall
                # deadline after its full-ROM check. Report completed work
                # through the existing protocol; no timer or early release.
                progress(source.size)
            trial_report['assets' if 'assets' in manifest else 'asset'] = (
                asset_reports if 'assets' in manifest else asset_reports[0])
            trial_report['delivery'] = manifest['delivery']
            return image, trial_report
        if manifest.get('delivery') is not None:
            if manifest['delivery'] in ('recompress-arm9-autoload-v1', 'append-decoded-arm9-autoload-v1',
                                        'append-decoded-arm9-sections-v1'):
                return recompress_arm9_autoload(source, header, manifest, requested, report)
            return append_decoded_overlays(source, header, manifest, requested, report)
        patches = {p['id']: p for p in manifest['patches']}
        require(len(patches) == len(manifest['patches']), 'Duplicate patch IDs')
        require(requested <= patches.keys(), 'Unknown patch ID')
        arm7_only = all(patches[ident]['cpu'] == 'arm7' and
                        isinstance(patches[ident]['target'], str) and
                        patches[ident]['target'].startswith('arm7.bin/autoload:')
                        for ident in requested)
        # An ARM7-only selection does not rewrite or map ARM9. Keep its exact
        # stored image (including compression) and all existing identity guards.
        # Mixed/ARM9 selections retain the original uncompressed-main contract.
        if not arm7_only:
            require(codeCompression.decompress(raw) == raw, 'Compressed ARM9 is unsupported by this byte-patch path')
            arm = code.MainCodeFile(raw, address)
            main = arm.sections[0]
            require(main.implicit and main.ramAddress == address and bytes(main.data) == raw[:len(main.data)],
                    'Initial main-code mapping differs')
        image = VirtualRom(source, source.size)
        data_guards = []
        overlay_files = {}
        arm7_sections = {}
        for patch_id in sorted(requested):
            patch = patches[patch_id]
            arm7 = patch['cpu'] == 'arm7' and isinstance(patch['target'], str) and patch['target'].startswith('arm7.bin/autoload:')
            require(arm7 or (patch['cpu'] == 'arm9' and patch['target'] in ('arm9.bin/main_loaded', 'arm9.overlay')),
                    'Unsupported CPU/target')
            require(patch.get('hook') is None and patch.get('scratch_bytes', 0) == 0,
                    'Hook or scratch requires a separately qualified mechanism')
            overlay = None
            if arm7:
                require(patch.get('overlay') is None, 'Overlay ID on ARM7 autoload target')
                loaded = read_arm7_autoload(source, header, manifest, patch['target'])
                require(offset+length <= loaded['image_offset'] or
                        loaded['image_offset']+len(loaded['raw']) <= offset, 'CPU source images overlap')
                require(int(patch['section_base'], 0) == loaded['base'] and
                        type(patch['section_bss_bytes']) is int and patch['section_bss_bytes'] == loaded['bss'] and
                        hashlib.sha256(loaded['data']).hexdigest() == patch['section_sha256'],
                        'ARM7 section identity differs')
                region, base, cartridge = loaded['data'], loaded['base'], loaded['file_offset']
                arm7_sections[loaded['index']] = loaded
            elif patch['target'] == 'arm9.overlay':
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
            if overlay is None and not arm7:
                guard = dict(address=at, guard_bytes=min(16, len(before)), phase='main_loaded',
                             guard_sha256=hashlib.sha256(before[:min(16, len(before))]).hexdigest())
                ok, reason = verify_target(guard, lambda a, n: raw[a-address:a-address+n])
                require(ok, reason)
            image.add(cartridge + at - base, after)
            report['applied'].append(dict(id=patch_id, address=at, cartridge_offset=cartridge+at-base,
                                          bytes=len(after), original_sha256=hashlib.sha256(before).hexdigest(),
                                          replacement_sha256=hashlib.sha256(after).hexdigest()))
        image.finish()
        if arm7_only:
            require(b''.join(image.blocks(offset, offset+length)) == raw,
                    'ARM7-only selection changed ARM9')
        for guard_offset, guard_bytes in data_guards:
            require(b''.join(image.blocks(guard_offset, guard_offset + len(guard_bytes))) == guard_bytes,
                    'Selected patch changes a protected data invariant')
        require(b''.join(image.blocks(0, 512)) == header, 'Header changed')
        if arm7_sections:
            report['arm7_autoloads'] = []
            for index, loaded in sorted(arm7_sections.items()):
                first = loaded['image_offset']
                for lo, hi in ((0, loaded['prefix_bytes']), (loaded['table_offset'], len(loaded['raw']))):
                    require(b''.join(image.blocks(first+lo, first+hi)) == loaded['raw'][lo:hi],
                            'ARM7 boot prefix or autoload metadata changed')
                output = b''.join(image.blocks(loaded['file_offset'], loaded['file_offset']+loaded['size']))
                report['arm7_autoloads'].append(dict(index=index, ram=loaded['base'], bytes=loaded['size'],
                    bss_bytes=loaded['bss'], cartridge_offset=loaded['file_offset'],
                    code_settings_offset=loaded['settings_offset'],
                    original_sha256=hashlib.sha256(loaded['data']).hexdigest(),
                    output_sha256=hashlib.sha256(output).hexdigest(),
                    delivery='unchanged-layout ARM7 autoload source; runtime qualification required'))
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


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON key')
        result[key] = value
    return result


def catalog_selection(source, catalog):
    """Select one embedded manifest; its complete admission still runs below.

    The outer file pin covers every manifest and explicit patch selection.
    Validate all entries before selecting, including ambiguity and unknown IDs.
    Header matching only routes admission; it never substitutes for ROM hashes.
    """
    require(type(catalog.get('catalog_version')) is int and catalog['catalog_version'] == 1 and
            set(catalog) == {'catalog_version', 'entries'}, 'Unknown guest catalog schema')
    entries = catalog['entries']
    require(isinstance(entries, list) and 1 <= len(entries) <= 32, 'Invalid guest catalog entries')
    seen = set(); selected = None
    header = source.read(0, 512)
    identity = (header[12:16].decode('ascii', errors='replace'), header[30],
                hashlib.sha1(header[:352]).hexdigest())
    for entry in entries:
        require(isinstance(entry, dict) and set(entry) == {'manifest', 'patch_ids'},
                'Invalid guest catalog entry')
        manifest, ids = entry['manifest'], entry['patch_ids']
        require(isinstance(manifest, dict) and type(manifest.get('schema_version')) is int and
                manifest['schema_version'] == 1 and manifest.get('header_bytes') == 352,
                'Invalid catalog manifest schema')
        game, revision, digest = (manifest[key] for key in ('game_code', 'revision', 'header_sha1'))
        require(isinstance(game, str) and len(game) == 4 and game.isascii() and
                type(revision) is int and 0 <= revision <= 255 and
                isinstance(digest, str) and len(digest) == 40 and
                all(c in '0123456789abcdef' for c in digest), 'Invalid catalog identity')
        for name, length in [('rom_sha256', 64), ('arm9_sha256', 64), ('arm9_crc32', 8)]:
            value = manifest[name]
            require(isinstance(value, str) and len(value) == length and
                    all(c in '0123456789abcdef' for c in value), 'Invalid catalog hash')
        key = (game, revision, digest)
        require(key not in seen, 'Ambiguous catalog identity'); seen.add(key)
        require(isinstance(ids, list) and ids and
                all(isinstance(p, str) and p and p.strip() == p and ',' not in p and p != '@catalog'
                    for p in ids) and len(ids) == len(set(ids)), 'Invalid catalog patch selection')
        patches = manifest['patches']
        require(isinstance(patches, list) and all(isinstance(p, dict) and
                isinstance(p.get('id'), str) for p in patches), 'Invalid catalog patch definitions')
        defined = [p['id'] for p in patches]
        require(len(defined) == len(set(defined)) and set(ids) <= set(defined),
                'Duplicate or unknown catalog patch IDs')
        if key == identity:
            selected = manifest, ids
    require(selected is not None, 'No matching guest catalog identity')
    return selected


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
        manifest = json.loads(raw, object_pairs_hook=unique_object)
        require(isinstance(manifest, dict), 'Guest manifest must be an object')
        catalog = 'catalog_version' in manifest
        require(catalog == (selection == '@catalog'), 'Catalog requires explicit @catalog selection')
        if catalog:
            manifest, patches = catalog_selection(source, manifest)
        image, report = assemble(source, manifest, patches, progress)
        report['manifest_sha256'] = expected
        if catalog:
            report['catalog_version'] = 1
            report['selected_identity'] = {key: manifest[key] for key in
                ('game_code', 'revision', 'header_sha1')}
        return image, report
    except (ValueError, KeyError, TypeError, IndexError, struct.error, OSError) as error:
        return VirtualRom(source, source.size).finish(), dict(
            state='skipped', requested=[], applied=[], reason=str(error))
