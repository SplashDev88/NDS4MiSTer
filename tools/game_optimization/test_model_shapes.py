import re
from pathlib import Path
import struct
import unittest

from inspect_model_shapes import ARITY, commands, inspect_model, local_geometry


def packed(*items):
    result = bytearray()
    for start in range(0, len(items), 4):
        group = list(items[start:start + 4])
        group += [(0, ())] * (4 - len(group))
        result.extend(op for op, _ in group)
        for op, params in group:
            assert len(params) == ARITY[op]
            result.extend(struct.pack('<%dI' % len(params), *params))
    return bytes(result)


def minimal_model():
    dl = packed((0x40, (0,)), (0x23, (0xffff0001, 3)),
                (0x25, (0x00010002,)), (0x28, (1,)), (0x41, ()))
    # One shape, dictionary after header; empty node/SBC/material sections.
    model = bytearray(64 + 40 + 16 + len(dl))
    struct.pack_into('<5I', model, 0, len(model), 64, 64, 64, len(model))
    model[0x19] = 1
    struct.pack_into('<BBHHHI', model, 64, 0, 1, 40, 8, 12, 0x17f)
    struct.pack_into('<HHI', model, 80, 4, 8, 40)
    model[88:104] = b'test' + bytes(12)
    struct.pack_into('<HHIII', model, 104, 0, 16, 0, 16, len(dl))
    model[120:] = dl
    return model


class ModelShapesTest(unittest.TestCase):
    def test_arities_match_existing_core(self):
        path = Path(__file__).resolve().parents[2] / 'third_party/melonDS/src/GPU3D.cpp'
        body = path.read_text().split('const u8 CmdNumParams[256] =', 1)[1].split('};', 1)[0]
        body = re.sub(r'//[^\n]*', '', body)
        values = [int(s) for s in re.findall(r'\b\d+\b', body)]
        self.assertEqual(len(values), 256)
        for opcode, arity in ARITY.items():
            self.assertEqual(values[opcode], arity)

    def test_packed_parameter_group_boundaries(self):
        data = packed((0x23, (0x24242424, 0x41414141)), (0x11, ()),
                      (0x34, tuple(range(32))), (0x10, (2,)), (0x71, (12, 13)))
        result = list(commands(data))
        self.assertEqual(result[0], (0, 0x23, (0x24242424, 0x41414141)))
        self.assertEqual(result[2][2], tuple(range(32)))
        self.assertEqual(result[4][2], (12, 13))

    def test_signed_vertices_partial_axes_and_delta_wrap(self):
        data = packed((0x40, (2,)), (0x23, (0x80007fff, 0xffff)),
                      (0x28, (1 | (0x3ff << 10) | (0x200 << 20),)),
                      (0x24, (0x200 | (0x1ff << 10) | (0x3ff << 20),)),
                      (0x25, (0xfffe0001,)), (0x26, (0x00040003,)),
                      (0x27, (0xffff0005,)), (0x41, ()))
        d = local_geometry(data)
        self.assertEqual(d['vertices_fx12'], [[32767, -32768, -1], [-32768, 32767, -513],
                         [-32768, 32704, -64], [1, -2, -64], [3, -2, 4], [3, 5, -1]])
        self.assertEqual(d['assembled_polygons_before_clipping'], 4)
        self.assertTrue(d['local_bounds_complete'])

    def test_inherited_coordinates_and_matrix_state_are_flagged(self):
        for prefix in [[], [(0x15, ())]]:
            d = local_geometry(packed(*prefix, (0x40, (0,)), (0x25, (0,)),
                                      (0x23, (0, 0)), (0x41, ())))
            self.assertFalse(d['local_bounds_complete'])
            self.assertIsNone(d['local_bounds_fx12'])
        d = local_geometry(packed((0x15, ()), (0x40, (0,)), (0x23, (0, 0)), (0x41, ())))
        self.assertEqual(d['unknown_coordinate_vertex_offsets'], [])
        self.assertFalse(d['local_bounds_complete'])

    def test_all_primitive_modes(self):
        for mode, count, expected in [(0, 6, 2), (1, 8, 2), (2, 6, 4), (3, 8, 3)]:
            d = local_geometry(packed((0x40, (mode,)), *[(0x24, (0,))] * count, (0x41, ())))
            self.assertEqual(d['assembled_polygons_before_clipping'], expected)

    def test_corrupt_lists_fail_closed(self):
        for data in [b'\0', bytes([0xff, 0, 0, 0]), bytes([0x23, 0, 0, 0]),
                     packed((0x41, ())), packed((0x40, (0,))),
                     packed((0x40, (0,)), (0x40, (0,)))]:
            with self.subTest(data=data), self.assertRaises(ValueError):
                local_geometry(data)

    def test_raw_model_and_input_offset(self):
        model = minimal_model()
        d = inspect_model(b'pad!' + model, 4)
        self.assertEqual(d['shapes'][0]['local_bounds_fx12'], {'min': [1, -1, 3], 'max': [3, 1, 3]})
        self.assertEqual(d['shapes'][0]['assembled_polygons_before_clipping'], 1)

    def test_invalid_section_dictionary_and_display_list_bounds(self):
        for offset, fmt, value in [(0, '<I', 0xffffff), (12, '<I', 8), (0x19, '<B', 2),
                                   (66, '<H', 0xffff), (80, '<H', 8), (82, '<H', 1),
                                   (84, '<I', 0xffff), (112, '<I', 1), (116, '<I', 0xffff)]:
            model = minimal_model()
            struct.pack_into(fmt, model, offset, value)
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                inspect_model(model)


if __name__ == '__main__':
    unittest.main()
