#!/usr/bin/env python3
"""Public synthetic overlap fixtures: no game data.

Expected results follow melonDS DrawSpritePixel's opaque/transparent rules.
The VHDL harness exercises the real drawer with delayed VRAM replies.
"""
import struct
from pathlib import Path


def words(path, values):
    Path(path).write_text(''.join(f'{v:08X}\n' for v in values))


vram = bytearray(256 * 1024)
vram[0:128] = b'\x11' * 128
vram[256:384] = b'\x22' * 128
vram[1024:1280] = b'\x01' * 256
vram[32768:33280] = b'\x1f\x80' * 256
pal = bytearray(512)
struct.pack_into('<HH', pal, 2, 0x001F, 0x03E0)
words('gpu_obj_vram.hex', struct.unpack('<65536I', vram))
words('gpu_obj_pal.hex', struct.unpack('<128I', pal))
words('gpu_obj_extpal.hex', [0] * 2048)

# A sprite is (opaque, background priority, tile, mode, 8bpp, alpha, color).
def sprite(opaque, priority, tile=0, mode=0, high=False, alpha=0, color=0x001F):
    return opaque, priority, tile, mode, high, alpha, color


red = lambda p: sprite(True, p)
hole = lambda p: sprite(False, p, tile=4)
green = lambda p: sprite(True, p, tile=8, color=0x03E0)
cases = [
    [red(3), hole(0)],
    [red(1), hole(3)],
    [red(2), hole(2)],
    [hole(0), red(3)],
    [red(3), green(0)],
    [red(0), green(0)],
    [red(3), hole(0), green(2)],
    [hole(0), hole(3)],
    [sprite(True, 3, mode=1), hole(0)],
    [sprite(True, 3, tile=256, mode=3, alpha=8), hole(0)],
    [sprite(True, 3, tile=32, high=True), hole(0)],
    [red(3), sprite(False, 0, tile=40, high=True)],
]
vectors = [len(cases)]
for sprites in cases:
    oam = [0x00000200, 0] * 128  # disabled entries
    color, priority, settings, opaque = 0x8000, 0, 0, False
    for i, (solid, prio, tile, mode, high, alpha, pixel) in enumerate(sprites):
        attr0 = (mode << 10) | (int(high) << 13)
        attr1 = 40 | (1 << 14)  # 16x16 at x=40, y=0
        attr2 = tile | (prio << 10) | (alpha << 12)
        oam[2*i:2*i+2] = [attr0 | (attr1 << 16), attr2]
        flags = prio | (4 if mode == 1 else 0) | ((alpha << 4) | 8 if mode == 3 else 0)
        if solid and (not opaque or prio < priority):
            color, priority, settings, opaque = pixel, prio, flags, True
        elif not solid and not opaque:
            priority, settings = prio, flags
    colors = [color if 40 <= x < 56 else 0x8000 for x in range(256)]
    flags = [settings if 40 <= x < 56 else 0x100 for x in range(256)]
    # Normal 1D tiles and 1D bitmap sprites, boundary=32 bytes, no mosaic.
    vectors += [3, 3, 3, 0, 0, 0, 0, 0] + oam + colors + flags
words('gpu_obj_vectors.hex', vectors)
