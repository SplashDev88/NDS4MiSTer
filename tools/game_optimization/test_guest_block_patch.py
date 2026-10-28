"""Mode/interworking and adversarial access-policy checks for the shared runner."""
import unittest
from unicorn import UC_MEM_READ, UC_MEM_WRITE
from check_halfword_copy_patch import run
from check_guest_block_patch import compare_accesses


class BlockTests(unittest.TestCase):
    def test_thumb_and_arm_arithmetic_match_after_both_return_modes(self):
        for value in (0, 0x7fffffff, 0xffffffff):
            for thumb_return in (0, 1):
                regs = [value] + list(range(1, 13)) + [0x03000f00, 0x02000100 | thumb_return]
                arm, _ = run(bytes.fromhex('010090e21eff2fe1'), 0x02000000,
                             bytes(4096), regs, 0x1f)
                thumb, _ = run(bytes.fromhex('01307047'), 0x02000000,
                               bytes(4096), regs, 0x3f, mode='thumb')
                self.assertEqual(arm, thumb)

    def test_wrong_start_mode_and_instruction_budget_reject(self):
        regs = [0]*13 + [0x03000f00, 0x02000101]
        for options in [dict(mode='thumb'), dict(mode='arm', instruction_limit=0)]:
            with self.assertRaises(AssertionError):
                run(bytes.fromhex('7047'), 0x02000000, bytes(4096), regs, 0x1f, **options)

    def test_only_declared_plain_reads_can_be_removed(self):
        read = (UC_MEM_READ, 0x03000010, 4, 7)
        write = (UC_MEM_WRITE, 0x03000020, 4, 9)
        other = (UC_MEM_READ, 0x03000030, 4, 11)
        self.assertEqual(compare_accesses([read, read, write, other],
                                         [read, write, other], [(0x03000010, 0x03000014)]), 1)
        for candidate, ranges in [([write, other], []), ([read, other], [(0x03000000, 0x03001000)]),
                                  ([write, read, other], [(0x03000010, 0x03000014)]),
                                  ([(UC_MEM_READ, 0x03000010, 4, 8), write, other],
                                   [(0x03000010, 0x03000014)]),
                                  ([write, other], [(0x03000010, 0x03000013)])]:
            with self.assertRaises(AssertionError):
                compare_accesses([read, write, other], candidate, ranges)
        with self.assertRaises(AssertionError):
            compare_accesses([], [], [(0x04000000, 0x04001000)])


if __name__ == '__main__':
    unittest.main()
