# SPDX-License-Identifier: GPL-3.0-or-later
"""Experimental sleeping-CPU pipeline ABI. Word addresses 160..171.

Changing field order changes the ABI: use a new component version. No field
crosses a word boundary. The generator checks these against the actual RTL.
"""
import re

COMMON_FIELDS = [
    ('decode_condition', 'std_logic_vector(3 downto 0)'),
    ('decode_ready', 'std_logic'),
    ('decode_PC', 'unsigned(31 downto 0)'),
    ('decode_data_1', 'std_logic_vector(31 downto 0)'),
    ('decode_functions_detail', 'tFunctions_detail'),
    ('decode_datareceivetype', 'tdatareceivetype'),
    ('decode_clearbit1', 'std_logic'),
    ('decode_rdest', 'std_logic_vector(3 downto 0)'),
    ('decode_rdest_save', 'std_logic_vector(3 downto 0)'),
    ('decode_Rn_op1', 'std_logic_vector(3 downto 0)'),
    ('decode_Rn_op1_save', 'std_logic_vector(3 downto 0)'),
    ('decode_RM_op2', 'std_logic_vector(3 downto 0)'),
    ('decode_alu_use_immi', 'std_logic'),
    ('decode_alu_use_shift', 'std_logic'),
    ('decode_immidiate', 'unsigned(31 downto 0)'),
    ('decode_shift_regbased', 'std_logic'),
    ('decode_shift_mode', 'std_logic_vector(1 downto 0)'),
    ('decode_shift_amount', 'integer range 0 to 255'),
    ('decode_shift_RRX', 'std_logic'),
    ('decode_shiftcarry', 'std_logic'),
    ('decode_useoldcarry', 'std_logic'),
    ('decode_updateflags', 'std_logic'),
    ('decode_mul_signed', 'std_logic'),
    ('decode_mul_useadd', 'std_logic'),
    ('decode_mul_long', 'std_logic'),
    ('decode_writeback', 'std_logic'),
    ('decode_switch_op', 'std_logic'),
    ('decode_set_thumbmode', 'std_logic'),
    ('decode_branch_usereg', 'std_logic'),
    ('decode_branch_link', 'std_logic'),
    ('decode_branch_long', 'std_logic'),
    ('decode_branch_immi', 'signed(25 downto 0)'),
    ('decode_datatransfer_type', 'std_logic_vector(1 downto 0)'),
    ('decode_datatransfer_preadd', 'std_logic'),
    ('decode_datatransfer_addup', 'std_logic'),
    ('decode_datatransfer_writeback', 'std_logic'),
    ('decode_datatransfer_addvalue', 'unsigned(11 downto 0)'),
    ('decode_datatransfer_shiftval', 'std_logic'),
    ('decode_datatransfer_regoffset', 'std_logic'),
    ('decode_datatransfer_swap', 'std_logic'),
    ('decode_block_usermoderegs', 'std_logic'),
    ('decode_block_switchmode', 'std_logic'),
    ('decode_block_addrmod', 'integer range -64 to 64'),
    ('decode_block_endmod', 'integer range -64 to 64'),
    ('decode_block_addrmod_baseRlist', 'integer range -64 to 64'),
    ('decode_block_reglist', 'std_logic_vector(15 downto 0)'),
    ('decode_block_emptylist', 'std_logic'),
    ('decode_psr_with_spsr', 'std_logic'),
    ('decode_leaveirp', 'std_logic'),
]
ARM9_FIELDS = [
    ('decode_sat_sub', 'std_logic'),
    ('decode_sat_double', 'std_logic'),
    ('decode_dsp_x', 'std_logic'),
    ('decode_dsp_y', 'std_logic'),
    ('decode_dsp_acc', 'std_logic'),
    ('decode_dsp_long', 'std_logic'),
    ('decode_dsp_word', 'std_logic'),
    ('decode_dsp_acchi', 'std_logic_vector(3 downto 0)'),
    ('decode_cp15_mrc', 'std_logic'),
    ('decode_cp15_crn', 'std_logic_vector(3 downto 0)'),
    ('decode_cp15_crm', 'std_logic_vector(3 downto 0)'),
    ('decode_cp15_op2', 'std_logic_vector(2 downto 0)'),
    ('decode_datatransfer_double', 'std_logic'),
    ('decode_branch_forcethumb', 'std_logic'),
    ('decode_branch_forcearm', 'std_logic'),
]


def width(kind):
    match = re.fullmatch(r'(?:std_logic_vector|unsigned|signed)\((\d+) downto 0\)', kind)
    if match:
        return int(match[1]) + 1
    return {'std_logic': 1, 'tFunctions_detail': 5, 'tdatareceivetype': 3,
            'integer range 0 to 255': 8, 'integer range -64 to 64': 8}[kind]


def layout(arm9):
    word, bit = 160, 0
    out = []
    for name, kind in COMMON_FIELDS + (ARM9_FIELDS if arm9 else []):
        size = width(kind)
        if bit + size > 32:
            word, bit = word + 1, 0
        out.append((name, kind, word, bit, size))
        bit += size
    assert word == 169
    out += [('fetch_data', 'std_logic_vector(31 downto 0)', 170, 0, 32),
            ('fetch_ready', 'std_logic', 171, 0, 1),
            ('fetch_first', 'std_logic', 171, 1, 1)]
    return out


def validate_words(words, arm9):
    """Reject reserved bits and invalid enum/range values before any restore."""
    if len(words) != 12:
        raise ValueError('Incomplete CPU pipeline state')
    masks = [0] * 12
    for name, kind, address, bit, size in layout(arm9):
        mask = (1 << size) - 1
        masks[address - 160] |= mask << bit
        value = (words[address - 160] >> bit) & mask
        if kind == 'tFunctions_detail' and value > (24 if arm9 else 19):
            raise ValueError('Invalid decoded operation')
        if kind == 'tdatareceivetype' and value > 4:
            raise ValueError('Invalid data receive type')
        if kind == 'integer range -64 to 64':
            signed = value - 256 if value >= 128 else value
            if not -64 <= signed <= 64:
                raise ValueError('Invalid block-transfer offset')
    if any(value & ~mask for value, mask in zip(words, masks)):
        raise ValueError('Reserved CPU pipeline bits are nonzero')
