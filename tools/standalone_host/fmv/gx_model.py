# SPDX-License-Identifier: GPL-3.0-only
"""Read raw NNS model shape bounds; does not establish visibility or patch safety.

Packed command arities and signed vertex arithmetic follow the repository's
GPU3D.cpp / GPU3D.h. The model/dictionary layout also appears in ndspy.model.
Only local coordinates are reconstructed: SBC, node, animation, texture and
external geometry state are deliberately not simulated.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct


ARITY = {0: 0, **dict(zip(range(0x10, 0x1d),
                        [1, 0, 1, 1, 1, 0, 16, 12, 16, 12, 9, 3, 3])),
         **dict(zip(range(0x20, 0x2c), [1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1])),
         **dict(zip(range(0x30, 0x35), [1, 1, 1, 1, 32])),
         0x40: 1, 0x41: 0, 0x50: 1, 0x60: 1, 0x70: 3, 0x71: 2, 0x72: 1}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def signed(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def commands(data):
    """Yield (opcode byte offset, opcode, params); unknown commands fail closed."""
    require(len(data) % 4 == 0, 'Unaligned display list length')
    cursor = 0
    while cursor < len(data):
        base = cursor
        opcodes = data[cursor:cursor + 4]
        cursor += 4
        for index, opcode in enumerate(opcodes):
            require(opcode in ARITY, 'Unknown geometry opcode at %d: %#x' % (base + index, opcode))
            count = ARITY[opcode]
            require(cursor + count * 4 <= len(data), 'Truncated geometry parameters')
            params = struct.unpack_from('<%dI' % count, data, cursor)
            cursor += count * 4
            yield base + index, opcode, params


def local_geometry(data):
    counts, vertices, primitives, incomplete, matrices = Counter(), [], [], [], []
    current = [None, None, None]
    primitive = None
    outside = 0
    for offset, op, params in commands(data):
        counts[op] += 1
        if 0x10 <= op <= 0x1c:
            matrices.append(offset)
        if op == 0x40:
            require(primitive is None, 'Nested primitive BEGIN')
            primitive = {'mode': params[0] & 3, 'vertices': 0}
        elif op == 0x41:
            require(primitive is not None, 'Primitive END without BEGIN')
            primitives.append(primitive)
            primitive = None
        elif 0x23 <= op <= 0x28:
            p = params[0]
            if op == 0x23:
                current = [signed(p, 16), signed(p >> 16, 16), signed(params[1], 16)]
            elif op == 0x24:
                current = [signed(p >> shift, 10) << 6 for shift in (0, 10, 20)]
            elif op == 0x28:
                current = [None if v is None else signed(v + signed(p >> shift, 10), 16)
                           for v, shift in zip(current, (0, 10, 20))]
            else:
                axes = {0x25: (0, 1), 0x26: (0, 2), 0x27: (1, 2)}[op]
                for axis, shift in zip(axes, (0, 16)):
                    current[axis] = signed(p >> shift, 16)
            if None in current:
                incomplete.append(offset)
            vertices.append(list(current))
            if primitive is None:
                outside += 1
            else:
                primitive['vertices'] += 1
    require(primitive is None, 'Unclosed primitive')
    polygons = 0
    for item in primitives:
        n, mode = item['vertices'], item['mode']
        polygons += (n // 3, n // 4, max(0, n - 2), max(0, n // 2 - 1))[mode]
    complete = bool(vertices) and not incomplete and not outside and not matrices
    bounds = None
    if complete:
        bounds = {'min': [min(v[i] for v in vertices) for i in range(3)],
                  'max': [max(v[i] for v in vertices) for i in range(3)]}
    return {'command_counts': {hex(k): v for k, v in sorted(counts.items())},
            'vertices_submitted': len(vertices), 'assembled_polygons_before_clipping': polygons,
            'primitive_count': len(primitives), 'primitive_modes': dict(Counter(p['mode'] for p in primitives)),
            'unknown_coordinate_vertex_offsets': incomplete,
            'vertices_outside_primitives': outside, 'matrix_command_offsets': matrices,
            'local_bounds_complete': complete, 'local_bounds_fx12': bounds, 'vertices_fx12': vertices}


def shape_dictionary(model, offset, end):
    require(0 <= offset < offset + 16 <= end <= len(model), 'Dictionary header out of bounds')
    count, size = struct.unpack_from('<xBH', model, offset)
    require(size >= 16 and offset + size <= end, 'Dictionary size out of bounds')
    header_size, _, root = struct.unpack_from('<HHI', model, offset + 4)
    require(header_size == 8 and root == 0x17f, 'Unsupported dictionary tree')
    entries = offset + 12 + count * 4
    require(entries + 4 + count * 4 <= offset + size, 'Dictionary entries out of bounds')
    unit, names_offset = struct.unpack_from('<HH', model, entries)
    require(unit == 4, 'Unsupported dictionary entry size')
    names = entries + names_offset
    require(entries + 4 + count * 4 <= names and names + count * 16 <= offset + size,
            'Dictionary names out of bounds')
    result = []
    for i in range(count):
        relative, = struct.unpack_from('<I', model, entries + 4 + i * 4)
        require(size <= relative and offset + relative + 16 <= end, 'Shape descriptor out of bounds')
        name = model[names + i * 16:names + (i + 1) * 16].rstrip(b'\0').decode('latin1')
        result.append((name, offset + relative))
    return result


def inspect_model(data, offset=0, include_vertices=False):
    require(0 <= offset <= len(data) - 64, 'Model header out of bounds')
    size, sbc, material, shape, envelope = struct.unpack_from('<5I', data, offset)
    require(64 <= sbc <= material <= shape < envelope <= size <= len(data) - offset,
            'Unsupported or out-of-bounds model sections')
    model = data[offset:offset + size]
    descriptors = shape_dictionary(model, shape, envelope)
    require(len(descriptors) == model[0x19], 'Header/dictionary shape count mismatch')
    shapes = []
    for index, (name, descriptor) in enumerate(descriptors):
        tag, header_size, flags, dl_offset, dl_size = struct.unpack_from('<HHIII', model, descriptor)
        require(header_size == 16 and tag == 0, 'Unsupported shape descriptor')
        start = descriptor + dl_offset
        require(dl_offset >= header_size and start % 4 == 0 and
                start <= start + dl_size <= envelope, 'Display list out of bounds')
        dl = model[start:start + dl_size]
        stats = local_geometry(dl)
        if not include_vertices:
            del stats['vertices_fx12']
        shapes.append({'index': index, 'name': name, 'descriptor_offset': descriptor,
                       'flags': flags, 'display_list_offset': start, 'display_list_bytes': dl_size,
                       'display_list_sha256': digest(dl), **stats})
    return {'model_offset_in_input': offset, 'model_bytes': size, 'model_sha256': digest(model),
            'node_count': model[0x17], 'material_count': model[0x18], 'shape_count': len(shapes),
            'header_counts': dict(zip(('vertices', 'polygons', 'triangles', 'quads'),
                                      struct.unpack_from('<4H', model, 0x24))),
            'position_scale_words': list(struct.unpack_from('<2I', model, 0x1c)),
            'bbox_words': list(struct.unpack_from('<6h', model, 0x2c)),
            'bbox_scale_words': list(struct.unpack_from('<2I', model, 0x38)),
            'node_section_hex': model[64:sbc].hex(), 'sbc_hex': model[sbc:material].hex(),
            'shapes': shapes,
            'limits': ['Bounds are signed FX12 local vertex coordinates, not screen/world bounds.',
                       'SBC/node/base/camera/animation transforms and material side effects are not interpreted.',
                       'Counts precede clipping/culling and are not visible geometry, native cost or a speedup.',
                       'No removability decision, memory modification or runtime hook.']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--input-sha256', required=True)
    parser.add_argument('--offset', type=lambda x: int(x, 0), default=0)
    parser.add_argument('--include-vertices', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    data = args.input.read_bytes()
    require(digest(data) == args.input_sha256, 'Input SHA-256 mismatch')
    result = inspect_model(data, args.offset, args.include_vertices)
    result['pins'] = {str(args.input.resolve()): digest(data),
                      str(Path(__file__).resolve()): digest(Path(__file__).read_bytes())}
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps({k: result[k] for k in ('model_sha256', 'model_bytes', 'shape_count')}))


if __name__ == '__main__':
    main()
