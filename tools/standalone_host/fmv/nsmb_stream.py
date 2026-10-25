#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Disposable NSMB experiment reader, using the existing load transaction."""
import os
import struct
import sys
from prepare import Source, VirtualRom
from stream import send
from nsmb_runtime import assemble
from load_progress import LoadProgress


def main():
    source_fd, output_fd, parent = map(int, sys.argv[1:])
    if os.getppid() != parent:
        return 1
    source = Source(source_fd)
    work = LoadProgress(lambda data: send(output_fd, data))
    def progress(n):
        send(output_fd, struct.pack('<Qii', n, 0, 7))
        work.update(0, 4500, min(n, source.size), source.size)
    try:
        mode = os.environ.get('NDS_NSMB_PATCH', 'off')
        image = assemble(source, mode, progress)
        print('NSMB_RUNTIME_APPLIED '+mode+'; original cartridge and save identity retained',
              file=sys.stderr, flush=True)
    except (ValueError, KeyError, IndexError, struct.error, OSError) as error:
        image = VirtualRom(source, source.size).finish()
        print('NSMB_RUNTIME_FALLBACK '+str(error), file=sys.stderr, flush=True)
    source.unchanged()
    work.update(4500, 5000)
    send(output_fd, struct.pack('<Qii', image.size, 0, 0))
    for block in image.blocks():
        send(output_fd, block)
    source.unchanged()
    send(output_fd, struct.pack('<Qii', image.size, 0, 8))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(1)
    except Exception as error:
        print('NSMB_RUNTIME_READ_FAILED '+str(error), file=sys.stderr, flush=True)
        sys.exit(1)
