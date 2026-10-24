#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Disposable ROM-reader worker. Never writes a ROM, save or cache file."""
import errno
import json
import os
from pathlib import Path
import struct
import sys
from prepare import Source, VirtualRom, assemble, profile_for


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
    def progress(n):
        send(output_fd, struct.pack('<Qii', n, 0, 7))
    image = VirtualRom(source, source.size).finish()
    try:
        registry = json.loads((Path(__file__).parent/'profiles.json').read_text())
        if registry['version'] != 1:
            raise ValueError('unsupported profile version')
        profile = profile_for(source, registry['profiles'], progress)
        if profile:
            image = assemble(source, profile, progress=progress)
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
