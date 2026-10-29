import unittest

from model_visibility_math import Matrices, bounds_planes, multiply, transform


IDENTITY = [4096 if i % 5 == 0 else 0 for i in range(16)]


class ModelVisibilityMathTest(unittest.TestCase):
    def test_load_scale_translation_and_order(self):
        m = Matrices()
        m.apply(0x10, [0])
        projection = list(IDENTITY)
        projection[0] = 2048
        m.apply(0x16, projection)
        m.apply(0x10, [2])
        m.apply(0x17, [4096, 0, 0, 0, 4096, 0, 0, 0, 4096, 40960, 0, 0])
        m.apply(0x1b, [8192] * 3)
        self.assertEqual(transform([4096, 0, 0], m.clip()), [24576, 0, 0, 4096])
        m.apply(0x19, [4096, 0, 0, 0, 4096, 0, 0, 0, 4096, 4096, 0, 0])
        self.assertEqual(transform([4096, 0, 0], m.clip()), [28672, 0, 0, 4096])

    def test_texture_matrix_and_store_do_not_change_position(self):
        m = Matrices()
        for mode in (0, 2):
            m.apply(0x10, [mode])
            m.apply(0x16, IDENTITY)
        m.apply(0x13, [0])
        m.apply(0x10, [3])
        m.apply(0x16, [0] * 16)
        self.assertEqual(m.clip(), IDENTITY)

    def test_plane_margin_and_crossing_bounds(self):
        for low, high, outside in [([4100, 0, 0], [8192, 1, 1], ['right']),
                                    ([4097, 0, 0], [8192, 1, 1], []),
                                    ([-8192, 0, 0], [8192, 1, 1], [])]:
            self.assertEqual(bounds_planes({'min': low, 'max': high}, IDENTITY)['outside_xy_planes'], outside)

    def test_inherited_unsupported_and_overflow_fail(self):
        with self.assertRaises(ValueError):
            Matrices().clip()
        for op, params in [(0x16, IDENTITY), (0x10, [4])]:
            with self.assertRaises(ValueError):
                Matrices().apply(op, params)
        for op, params in [(0x14, [0]), (0x1b, [4096] * 3), (0x16, [0])]:
            m = Matrices()
            m.apply(0x10, [2])
            with self.assertRaises(ValueError):
                m.apply(op, params)
        with self.assertRaises(ValueError):
            multiply([0x7fffffff] * 16, [0x7fffffff] * 16)


if __name__ == '__main__':
    unittest.main()
