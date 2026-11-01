"""Mode/interworking and adversarial access-policy checks for the shared runner."""
import unittest
from unicorn import UC_MEM_READ, UC_MEM_WRITE
from check_halfword_copy_patch import run
from check_guest_block_patch import (compare_accesses, ordinary_ranges,
                                    compare_ordinary_effects, extra_pages_for_case)


class BlockTests(unittest.TestCase):
    def test_callee_in_existing_code_page_without_overwriting_tested_code(self):
        from unicorn.arm_const import UC_ARM_REG_R0, UC_ARM_REG_PC, UC_ARM_REG_LR
        code = bytes.fromhex('00b5014b984700bd80000002')
        regs = [7] + [0]*12 + [0x03000f00, 0x02000101]
        def callee(vm):
            self.assertEqual(bytes(vm.mem_read(0x02000000, len(code))), code)
            vm.reg_write(UC_ARM_REG_R0, 23)
            vm.reg_write(UC_ARM_REG_PC, vm.reg_read(UC_ARM_REG_LR))
        result, _ = run(code, 0x02000000, bytes(4096), regs, 0x3f,
                        mode='thumb', call_handlers={0x02000080: callee})
        self.assertEqual(result['registers'][0], 23)
        self.assertEqual(result['registers'][13], regs[13])
        for page in [0x02000000, 0x03000000]:
            with self.assertRaises(AssertionError):
                run(code, 0x02000000, bytes(4096), regs, 0x3f,
                    mode='thumb', extra_memory=[(page, bytes(4096))],
                    call_handlers={0x02000080: callee})

    def test_external_callee_model_returns_across_modes_without_replacing_target(self):
        from unicorn.arm_const import UC_ARM_REG_R0, UC_ARM_REG_PC, UC_ARM_REG_LR
        # Thumb push/ldr/blx/pop, calling a mapped ARM callee at 0x02010000.
        code = bytes.fromhex('00b5014b984700bd00000102')
        regs = [7] + [0]*12 + [0x03000f00, 0x02000101]
        seen = []
        def callee(vm):
            seen.append(vm.reg_read(UC_ARM_REG_R0))
            vm.reg_write(UC_ARM_REG_R0, 19)
            vm.reg_write(UC_ARM_REG_PC, vm.reg_read(UC_ARM_REG_LR))
        pages = [(0x02010000, bytes(4096))]
        result, _ = run(code, 0x02000000, bytes(4096), regs, 0x3f,
                        mode='thumb', extra_memory=pages,
                        call_handlers={0x02010000: callee})
        self.assertEqual(seen, [7])
        self.assertEqual(result['registers'][0], 19)
        self.assertEqual(result['registers'][13], regs[13])
        for address in [0x02000002, 0x02020000, 0x02010001]:
            with self.assertRaises(AssertionError):
                run(code, 0x02000000, bytes(4096), regs, 0x3f,
                    mode='thumb', extra_memory=pages, call_handlers={address: callee})

    def test_context_before_entry_and_end_of_page_are_executable(self):
        # Both functions share a context that extends before their entry.
        code = bytearray(4096)
        code[0x100:0x108] = bytes.fromhex('010080e21eff2fe1')
        code[0xff8:0x1000] = bytes.fromhex('010080e21eff2fe1')
        regs = [7] + [0]*12 + [0x03000f00, 0x02000108]
        for entry in [0x02000100, 0x02000ff8]:
            result, count = run(bytes(code), entry, bytes(4096), regs, 0x1f,
                                code_address=0x02000000)
            self.assertEqual(result['registers'][0], 8)
            self.assertEqual(count, 2)
        with self.assertRaises(AssertionError):
            run(bytes(code), 0x01fffffc, bytes(4096), regs, 0x1f,
                code_address=0x02000000)

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

    def test_effect_contract_requires_mapped_ram_and_identical_literals(self):
        good = dict(extra_pages=['0x02010000'],
                    ordinary_memory_effect_ranges=[['0x02010000', '0x02010004']],
                    code_literal_read_ranges=[['0x02000002', '0x02000004']])
        self.assertEqual(ordinary_ranges(good, 0x02000000, b'abcd', b'XYcd'),
                         ([(0x02010000, 0x02010004)], [(0x02000002, 0x02000004)]))
        for first, end in [('0x04000000', '0x04000004'), ('0x02020000', '0x02020004'),
                           ('0x02010fff', '0x02011001'), ('0x02010004', '0x02010000')]:
            bad = dict(good, ordinary_memory_effect_ranges=[[first, end]])
            with self.assertRaises(AssertionError):
                ordinary_ranges(bad, 0x02000000, b'abcd', b'XYcd')
        with self.assertRaises(AssertionError):
            ordinary_ranges(good, 0x02000000, b'abcd', b'XYce')
        with self.assertRaises(AssertionError):
            ordinary_ranges(dict(good, ordinary_memory_effect_ranges=[
                ['0x02010000', '0x02010004'], ['0x02010002', '0x02010006']]),
                0x02000000, b'abcd', b'XYcd')

    def test_effect_contract_cannot_hide_external_accesses_or_literal_writes(self):
        inside = (UC_MEM_WRITE, 0x03000010, 4, 7)
        outside = (UC_MEM_WRITE, 0x03000020, 4, 9)
        literal = (UC_MEM_READ, 0x02000002, 2, 11)
        effects, literals = [(0x03000010, 0x03000014)], [(0x02000002, 0x02000004)]
        compare_ordinary_effects([literal, inside, outside], [outside, literal], effects, literals)
        for candidate in [[], [(UC_MEM_WRITE, 0x03000020, 4, 8)],
                          [outside, (UC_MEM_WRITE, 0x02000002, 2, 11)],
                          [outside, (UC_MEM_READ, 0x03000012, 4, 0)]]:
            with self.assertRaises(AssertionError):
                compare_ordinary_effects([inside, outside], candidate, effects, literals)

    def test_extra_overrides_require_one_existing_page(self):
        fixture = {'extra_pages': ['0x02010000']}
        data = extra_pages_for_case(fixture, {'extra_memory_overrides': [
            {'address': '0x02010003', 'hex': 'abcd'}]})[0][1]
        self.assertEqual(data[3:5], bytes.fromhex('abcd'))
        for address, value in [('0x02020000', 'aa'), ('0x02010fff', 'aabb'), ('0x02010000', '')]:
            with self.assertRaises(AssertionError):
                extra_pages_for_case(fixture, {'extra_memory_overrides': [
                    {'address': address, 'hex': value}]})
        with self.assertRaises(AssertionError):
            extra_pages_for_case({'extra_pages': ['0x02010000', '0x02010000']}, {})


if __name__ == '__main__':
    unittest.main()
