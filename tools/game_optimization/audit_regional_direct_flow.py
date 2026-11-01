"""Read-only paired ARM/Thumb direct-flow audit over captured main CPU images.

Inputs select images and entry addresses. Game identities/addresses never live
in this tool. Indirect transfers, changed instructions and unresolved literals
remain explicit; this is not a runtime correctness or timing qualification.
"""
import base64
import hashlib
import json
import struct
import sys
from pathlib import Path

from capstone import Cs, CS_ARCH_ARM, CS_MODE_ARM, CS_MODE_THUMB
from capstone.arm import (ARM_CC_AL, ARM_CC_INVALID, ARM_INS_B, ARM_INS_BL,
    ARM_INS_BLX, ARM_INS_BX, ARM_INS_LDR, ARM_INS_POP, ARM_INS_LDM,
    ARM_INS_MOV, ARM_OP_IMM, ARM_OP_MEM, ARM_OP_REG, ARM_REG_PC, ARM_REG_LR)
from ndspy.code import MainCodeFile

sha = lambda b: hashlib.sha256(b).hexdigest()


class Image:
    def __init__(self, row):
        raw = base64.b64decode(row['arm9']['base64'])
        assert sha(raw) == row['arm9']['sha256']
        self.main = MainCodeFile(raw, row['arm9']['base'])
        self.sections = self.main.sections
        s = self.sections[0]
        assert self.main.codeSettingsOffs is not None
        self.bss = struct.unpack_from('<2I', s.data, self.main.codeSettingsOffs + 12)
        assert s.ramAddress + len(s.data) <= self.bss[0] <= self.bss[1] <= 0x02400000
        self.digest = row['arm9']['sha256']

    def read(self, address, size):
        for s in self.sections:
            at = address - s.ramAddress
            if 0 <= at <= len(s.data) - size:
                return bytes(s.data[at:at+size])
        raise ValueError('unmapped code/data ' + hex(address))

    def classify(self, value):
        if self.bss[0] <= value < self.bss[1]:
            return {'kind': 'static_bss', 'offset': value - self.bss[0]}
        for n, s in enumerate(self.sections):
            if s.ramAddress <= value < s.ramAddress + len(s.data):
                return {'kind': 'loaded_section', 'section': n, 'offset': value-s.ramAddress}
        if 0x04000000 <= value < 0x05000000:
            return {'kind': 'mmio', 'address': hex(value)}
        return {'kind': 'constant_or_unmapped', 'value': hex(value)}


def audit(source, candidate, roots, limit):
    decoders = {m: Cs(CS_ARCH_ARM, v) for m, v in [('arm', CS_MODE_ARM), ('thumb', CS_MODE_THUMB)]}
    for decoder in decoders.values():
        decoder.detail = True
    pending = [(int(r['reference'], 0), int(r['candidate'], 0), r['mode']) for r in roots]
    visited, mappings, inverse, literals, edges, issues = {}, {}, {}, {}, [], []
    while pending:
        a, b, mode = pending.pop()
        if (a, mode) in mappings and mappings[a, mode] != b:
            issues.append({'reference': hex(a), 'reason': 'inconsistent_address_mapping'})
            continue
        if (b, mode) in inverse and inverse[b, mode] != a:
            issues.append({'candidate': hex(b), 'reason': 'non_bijective_address_mapping'})
            continue
        mappings[a, mode], inverse[b, mode] = b, a
        if (a, b, mode) in visited:
            continue
        if len(visited) >= limit:
            issues.append({'reason': 'instruction_limit', 'limit': limit})
            break
        try:
            x = next(decoders[mode].disasm(source.read(a, 4), a, count=1))
            y = next(decoders[mode].disasm(candidate.read(b, 4), b, count=1))
        except (ValueError, StopIteration) as error:
            issues.append({'reference': hex(a), 'candidate': hex(b), 'reason': str(error)})
            continue
        row = {'reference': hex(a), 'candidate': hex(b), 'mode': mode,
               'reference_bytes': x.bytes.hex(), 'candidate_bytes': y.bytes.hex(),
               'instruction': x.mnemonic + ' ' + x.op_str}
        visited[a, b, mode] = row
        if (x.id, x.cc, x.size, len(x.operands)) != (y.id, y.cc, y.size, len(y.operands)):
            issues.append(dict(row, reason='instruction_shape_changed', candidate_instruction=y.mnemonic+' '+y.op_str))
            continue
        unconditional = x.cc in (ARM_CC_AL, ARM_CC_INVALID)
        direct = x.id in (ARM_INS_B, ARM_INS_BL, ARM_INS_BLX) and x.operands[0].type == ARM_OP_IMM
        if direct:
            if y.operands[0].type != ARM_OP_IMM:
                issues.append(dict(row, reason='candidate_control_target_not_immediate'))
                continue
            target_mode = ('thumb' if mode == 'arm' else 'arm') if x.id == ARM_INS_BLX else mode
            ta, tb = x.operands[0].imm & ~1, y.operands[0].imm & ~1
            edges.append(dict(source=hex(a), candidate_source=hex(b), target=hex(ta), candidate_target=hex(tb), mode=target_mode, kind=x.mnemonic))
            pending.append((ta, tb, target_mode))
            if x.id != ARM_INS_B or not unconditional:
                pending.append((a+x.size, b+y.size, mode))
            continue
        if bytes(x.bytes) != bytes(y.bytes):
            issues.append(dict(row, reason='non_branch_instruction_bytes_changed', candidate_instruction=y.mnemonic+' '+y.op_str))
            continue
        if x.id == ARM_INS_LDR and len(x.operands) == 2 and x.operands[1].type == ARM_OP_MEM and x.operands[1].mem.base == ARM_REG_PC:
            aa = (((a+4)&~3) if mode == 'thumb' else a+8) + x.operands[1].mem.disp
            bb = (((b+4)&~3) if mode == 'thumb' else b+8) + y.operands[1].mem.disp
            va = int.from_bytes(source.read(aa, 4), 'little')
            vb = int.from_bytes(candidate.read(bb, 4), 'little')
            ca, cb = source.classify(va), candidate.classify(vb)
            literals[aa, bb] = dict(reference_address=hex(aa), candidate_address=hex(bb), reference_value=hex(va), candidate_value=hex(vb), reference_class=ca, candidate_class=cb, exact_value=va==vb, same_bss_offset=ca['kind']==cb['kind']=='static_bss' and ca['offset']==cb['offset'])
        regs = [o.reg for o in x.operands if o.type == ARM_OP_REG]
        returns = (x.id == ARM_INS_BX and regs == [ARM_REG_LR]) or (x.id in (ARM_INS_POP, ARM_INS_LDM) and ARM_REG_PC in regs) or (x.id == ARM_INS_MOV and regs == [ARM_REG_PC, ARM_REG_LR])
        _, writes = x.regs_access()
        if ARM_REG_PC in writes and not returns:
            issues.append(dict(row, reason='unresolved_indirect_control_transfer'))
            continue
        if x.id in (ARM_INS_BLX, ARM_INS_BX) and not returns:
            issues.append(dict(row, reason='unresolved_register_branch'))
            continue
        if not returns or not unconditional:
            pending.append((a+x.size, b+y.size, mode))
    literal_rows = list(literals.values())
    unresolved_literals = [r for r in literal_rows if not r['exact_value'] and not r['same_bss_offset']]
    occupied_a = {a+i for a,b,mode in visited for i in range(len(bytes.fromhex(visited[a,b,mode]['reference_bytes'])))}
    occupied_b = {b+i for a,b,mode in visited for i in range(len(bytes.fromhex(visited[a,b,mode]['candidate_bytes'])))}
    for (aa, bb) in literals:
        if occupied_a.intersection(range(aa,aa+4)) or occupied_b.intersection(range(bb,bb+4)):
            issues.append({'reason': 'literal_overlaps_reachable_instruction', 'reference':hex(aa), 'candidate':hex(bb)})
    return dict(instructions=len(visited), direct_edges=len(edges), issues=issues,
        literal_words=literal_rows, unresolved_literals=unresolved_literals,
        reference_static_bss=[hex(n) for n in source.bss], candidate_static_bss=[hex(n) for n in candidate.bss],
        instruction_records=sorted(visited.values(), key=lambda r:(r['reference'],r['mode'])), edges=edges,
        reached_instruction_bytes_match_modulo_direct_targets=not issues,
        changed_literals_all_share_static_bss_offset=not unresolved_literals)


def main():
    definition_path, output_path = map(Path, sys.argv[1:3])
    definition = json.loads(definition_path.read_text())
    capture = Path(definition['capture'])
    rows = [json.loads(line) for line in capture.read_text().splitlines()]
    get = lambda code, rev: next(r for r in rows if r['game_code']==code and r['revision']==rev)
    reference = Image(get(definition['reference_code'], definition['reference_revision']))
    results=[]
    for entry in definition['candidates']:
        candidate=Image(get(entry['game_code'], entry['revision']))
        result=audit(reference,candidate,entry['roots'],definition.get('instruction_limit',4096))
        result.update(game_code=entry['game_code'],revision=entry['revision'],arm9_sha256=candidate.digest)
        results.append(result)
    receipt=dict(state='read_only_paired_direct_flow_audit', rows=results,
        pins={str(p):sha(p.read_bytes()) for p in [Path(__file__),definition_path,capture]},
        limits=['Direct control flow only; unknown transfers remain issues and stop that path.',
                'Equal BSS-relative pointers identify corresponding state locations, not equal runtime state or initialization.',
                'No claim about indirect callbacks, geometry results, timing, assets or runtime validation.',
                'No ROM write, patch generation or patch enablement.'])
    with output_path.open('x') as f:
        json.dump(receipt,f,indent=2);f.write('\n')
    print(json.dumps([{k:r[k] for k in ['game_code','instructions','direct_edges','issues','unresolved_literals']} for r in results],indent=2))


if __name__=='__main__':
    main()
