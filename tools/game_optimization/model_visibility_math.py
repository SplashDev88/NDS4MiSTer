"""Bounded offline matrix analysis, following existing GPU3D fixed-point math.

This is not a renderer. It accepts only self-contained matrix loads/multiplies
used by an authenticated command stream, and rejects unsupported stack state
or arithmetic overflow. Camera/model lifetime must be established by callers.
"""
from itertools import product

from inspect_model_shapes import require, signed


def fixed_sum(values):
    total = sum(values)
    require(-(1 << 63) <= total < (1 << 63), '64-bit matrix intermediate overflow')
    result = total >> 12
    require(-(1 << 31) <= result < (1 << 31), '32-bit matrix result overflow')
    return result


def multiply(left, right):
    return [fixed_sum(left[row * 4 + k] * right[k * 4 + col] for k in range(4))
            for row in range(4) for col in range(4)]


def expand_4x3(params):
    return [params[row * 3 + col] if col < 3 else (4096 if row == 3 else 0)
            for row in range(4) for col in range(4)]


class Matrices:
    def __init__(self):
        self.mode = None
        self.values = {0: None, 1: None, 3: None}

    def apply(self, opcode, params):
        if not 0x10 <= opcode <= 0x1c:
            return
        if opcode == 0x10:
            require(len(params) == 1 and 0 <= params[0] <= 3, 'Invalid matrix mode')
            self.mode = 1 if params[0] == 2 else params[0]
            return
        require(self.mode is not None, 'Inherited matrix mode')
        if opcode == 0x13:
            # STORE changes a stack slot, not the current matrix. RESTORE,
            # PUSH and POP are unsupported below, so no stored state is used.
            require(len(params) == 1, 'Invalid STORE')
            return
        require(opcode in (0x16, 0x17, 0x19, 0x1b), 'Unsupported matrix operation')
        expected = {0x16: 16, 0x17: 12, 0x19: 12, 0x1b: 3}[opcode]
        require(len(params) == expected and all(0 <= x <= 0xffffffff for x in params),
                'Invalid matrix parameter list')
        p = [signed(x, 32) for x in params]
        if opcode in (0x16, 0x17):
            self.values[self.mode] = p if opcode == 0x16 else expand_4x3(p)
        else:
            matrix = self.values[self.mode]
            require(matrix is not None, 'Inherited matrix contents')
            if opcode == 0x19:
                self.values[self.mode] = multiply(expand_4x3(p), matrix)
            else:
                self.values[self.mode] = [fixed_sum([matrix[row * 4 + col] * p[row]])
                                         if row < 3 else matrix[row * 4 + col]
                                         for row in range(4) for col in range(4)]

    def clip(self):
        require(self.values[0] is not None and self.values[1] is not None,
                'Projection or position matrix has not been loaded')
        return multiply(self.values[1], self.values[0])


def transform(vertex, matrix):
    require(len(vertex) == 3 and len(matrix) == 16, 'Invalid vertex/matrix')
    v = list(vertex) + [4096]
    return [fixed_sum(v[k] * matrix[k * 4 + col] for k in range(4)) for col in range(4)]


def bounds_planes(bounds, matrix):
    """Conservative XY-plane lead, using corner extrema and a rounding margin.

    Clip x/y and w each round independently by less than one FX12 unit. Requiring
    every corner to be at least 4 units outside one plane leaves a margin for
    these rounding steps. Depth-plane behavior/material flags are not used.
    This result alone does not establish visibility, side effects or removability.
    """
    low, high = bounds['min'], bounds['max']
    require(len(low) == len(high) == 3 and all(a <= b for a, b in zip(low, high)),
            'Invalid bounds')
    corners = [transform(v, matrix) for v in product(*zip(low, high))]
    margins = {'left': max(x + w for x, y, z, w in corners),
               'right': max(w - x for x, y, z, w in corners),
               'bottom': max(y + w for x, y, z, w in corners),
               'top': max(w - y for x, y, z, w in corners)}
    return {'outside_xy_planes': [k for k, v in margins.items() if v <= -4],
            'maximum_corner_plane_values': margins, 'clip_corners': corners}
