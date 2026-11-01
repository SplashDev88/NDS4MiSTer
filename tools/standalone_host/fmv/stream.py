#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Disposable ROM reader. Original ROMs and saves are always read-only here."""
import errno
import json
import os
from pathlib import Path
import struct
import sys
from prepare import Source, VirtualRom, assemble, profile_for
from load_progress import LoadProgress


def send(fd, data):
    data = memoryview(data)
    while data:
        n = os.write(fd, data)
        if n <= 0:
            raise BrokenPipeError('ROM stream closed')
        data = data[n:]


def main():
    source_fd, output_fd, parent = map(int, sys.argv[1:])
    # PDEATHSIG survives exec; also close the race before Python initialized.
    if os.getppid() != parent:
        return 1
    source = Source(source_fd)
    work = None
    verification_end = 3000
    def progress(n):
        send(output_fd, struct.pack('<Qii', n, 0, 7))
        if work:
            work.update(0, verification_end, min(n, source.size), source.size)
    image = VirtualRom(source, source.size).finish()
    try:
        # Guest patches reuse this worker and the normal reset-held transfer.
        # A cumulative kit can retain ordinary FMV handling when admission
        # skips a guest patch. Never compose two modified cartridge images.
        guest = any(key in os.environ for key in
                    ('NDS_GUEST_PATCH_MANIFEST', 'NDS_GUEST_PATCH_SHA256', 'NDS_GUEST_PATCH_IDS'))
        if guest:
            from guest_byte_patch import from_environment
            work = LoadProgress(lambda data: send(output_fd, data))
            # Guest byte patches do not convert movies. Their full-ROM check
            # accounts for the preparation half of the bar; avoid the old
            # artificial 30% -> 50% step after that check finishes.
            verification_end = 5000
            image, report = from_environment(source, os.environ, progress)
            print('GUEST_PATCH_RESULT '+json.dumps(report, sort_keys=True), file=sys.stderr, flush=True)
            if (report['state'] == 'skipped' and
                    os.environ.get('NDS_GUEST_PATCH_FALLBACK_FMV') == '1'):
                guest = False
                # The host normally selects this existing experiment reader
                # before FMV dispatch. Preserve that selection in a cumulative
                # kit, where explicit guest admission takes precedence.
                from nsmb_runtime import MODES, assemble as assemble_nsmb
                header = source.read(0, 32)
                mode = os.environ.get('NDS_NSMB_PATCH', 'off')
                if (header[12:16] in (b'A2DE', b'A2DP', b'A2DJ', b'A2DK') and
                        header[30] == 0 and mode in MODES):
                    image = assemble_nsmb(source, mode, progress)
                    print('NSMB_RUNTIME_APPLIED '+mode+'; original cartridge and save identity retained',
                          file=sys.stderr, flush=True)
                    guest = True
        if not guest:
            registry = json.loads((Path(__file__).parent/'profiles.json').read_text())
            if registry['version'] != 1:
                raise ValueError('unsupported profile version')
        if not guest and os.environ.get('NDS_ROM_STREAM_PATCHES') == '1':
            from stream_load import select_plan
            from prepared_cache import cached_transfer
            plan = select_plan(source, registry['profiles'])
            if plan:
                # After metadata is sent, failures must terminate this stream;
                # never append the incompatible legacy fallback protocol.
                try:
                    cached_transfer(source, plan, lambda data: send(output_fd, data), work=work)
                except Exception as error:
                    print('FMV_STREAM_READ_FAILED '+str(error), file=sys.stderr, flush=True)
                    return 1
                return 0
        if not guest:
            verification_end = 3000
            work = work or LoadProgress(lambda data: send(output_fd, data))
            profile = profile_for(source, registry['profiles'], progress)
            if profile:
                image = assemble(source, profile, progress=progress,
                                 work=lambda n, total: work.update(3000, 5000, n, total))
                print('FMV_AUTO_APPLIED '+profile['key']+' original cartridge; save identity retained',file=sys.stderr,flush=True)
            else:
                print('FMV_AUTO_FALLBACK no qualified cartridge profile',file=sys.stderr,flush=True)
    except (ValueError, KeyError, IndexError, struct.error, OSError) as error:
        # Nothing has been published: an unknown/modified ROM keeps its normal
        # decoder. An I/O error or mid-load mutation still fails the read below.
        image = VirtualRom(source, source.size).finish()
        print('FMV_AUTO_FALLBACK '+str(error),file=sys.stderr,flush=True)
    limit = (464 if image.size > 256*1024*1024 else 252)*1024*1024
    transfer = min(limit,image.size)
    done = limit
    for block in image.blocks(transfer, image.size):
        if block != b'\xff'*len(block):
            send(output_fd,struct.pack('<Qii',image.size,errno.EINVAL,5))
            return 1
        done += len(block)
        progress(done)
    source.unchanged()
    # Keep the progress actually earned above. Unknown/unpatched cartridges
    # can skip preparation entirely; reserving 50% for that absent stage made
    # their bar jump from empty to half full before the first transfer byte.
    send(output_fd,struct.pack('<Qii',image.size,0,0))
    for block in image.blocks(0,transfer):
        send(output_fd,block)
    source.unchanged()
    send(output_fd,struct.pack('<Qii',transfer,0,8))
    return 0


if __name__=='__main__':
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(1)
    except Exception as error:
        print('FMV_AUTO_READ_FAILED '+str(error),file=sys.stderr,flush=True)
        sys.exit(1)
