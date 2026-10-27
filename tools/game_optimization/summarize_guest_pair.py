#!/usr/bin/env python3
"""Summarize an existing guarded replay pair; never changes or accepts a patch."""
import argparse
import csv
import hashlib
import json
from pathlib import Path

import numpy as np


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def read(path):
    return json.loads(path.read_text())


def rows(path):
    with path.open() as stream:
        return list(csv.DictReader(stream))


def audio_stats(a, b):
    sizes = [p.stat().st_size for p in (a, b)]
    assert all(size % 4 == 0 for size in sizes)
    result = dict(stereo_samples=[size // 4 for size in sizes], lengths_equal=sizes[0] == sizes[1])
    if sizes[0] != sizes[1]:
        return result  # Never truncate a changed-length recording to declare equality.
    if not sizes[0]:
        result['error'] = 'Empty audio is not usable evidence'
        return result
    av, bv = [np.memmap(p, dtype='<i2', mode='r').reshape(-1, 2) for p in (a, b)]
    count, maximum, squares, first, last = 0, 0, 0, None, None
    for start in range(0, len(av), 262144):
        delta = av[start:start+262144].astype(np.int64) - bv[start:start+262144].astype(np.int64)
        changed = np.flatnonzero(np.any(delta != 0, axis=1))
        if len(changed):
            if first is None:
                first = start + int(changed[0])
            last = start + int(changed[-1])
        count += len(changed)
        maximum = max(maximum, int(np.max(np.abs(delta))))
        squares += int(np.sum(delta * delta))
    result.update(different_stereo_samples=count, max_signed16_delta=maximum,
                  rms_delta=(squares / (len(av) * 2)) ** 0.5,
                  first_sample=first, last_sample=last,
                  scope='Same-index signed16 samples; no alignment, masking or audibility judgment')
    return result


def guard_stats(path, guards):
    expected = {}
    for guard in guards:
        base = int(guard['addr'], 0)
        for offset, value in enumerate(bytes.fromhex(guard['expect'])):
            at = base + offset
            assert at not in expected or expected[at] == value
            expected[at] = value
    writes, bad, later, observed = 0, 0, 0, set()
    for ordinal, row in enumerate(rows(path)):
        assert int(row['ordinal']) == ordinal and row['kind'] == 'write'
        at, value, width = int(row['address'], 16), int(row['value'], 16), int(row['width'])
        assert width in (8, 16, 32)
        actual = value.to_bytes(width // 8, 'little')
        assert all(at + i in expected for i in range(len(actual)))
        writes += 1
        bad += any(expected[at + i] != byte for i, byte in enumerate(actual))
        later += int(row['frame']) > 0
        observed.update(range(at, at + len(actual)))
    return dict(writes=writes, writes_not_matching_original_bytes=bad,
                writes_after_frame0=later, guarded_bytes=len(expected),
                guarded_bytes_observed=len(observed), trace_sha256=sha(path),
                scope='Captured main-RAM bus stores only; not arbitrary host/state-loader/JIT coverage')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('control', type=Path)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('input', type=Path)
    parser.add_argument('--reuse-unpatched-control', action='store_true',
                        help='Verify original-stream identity before reusing a control with a different disabled manifest')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    records = [read(p.with_name(p.name + '_STATUS.json')) for p in (args.control, args.candidate)]
    control, candidate = records
    assert control['state'] == 'passed_replay_equivalence' and control['mode'] == 'off'
    assert candidate['state'] in ('passed_replay_equivalence', 'rejected_replay_mismatch') and candidate['mode'] == 'on'
    assert control['scene'] == candidate['scene']
    inputs = read(args.input)
    manifest_path = Path(inputs['manifest'])
    assert sha(manifest_path) == candidate['manifest_sha256'] == inputs['manifest_sha256']
    manifest = read(manifest_path)
    reused = control['manifest_sha256'] != candidate['manifest_sha256']
    if reused:
        assert args.reuse_unpatched_control, 'Different control manifest needs explicit verified reuse'
        old_path = Path(control['manifest'])
        assert sha(old_path) == control['manifest_sha256']
        old = read(old_path)
        for key in ['schema_version', 'game_code', 'revision', 'header_sha1', 'header_bytes',
                    'rom_sha256', 'arm9_sha256', 'arm9_crc32']:
            assert old[key] == manifest[key], key
        assert control['admission']['state'] == 'unchanged' and not control['admission']['applied']
        assert control['virtual_image_sha256'] == manifest['rom_sha256']
        assert control['oracle_sha256'] == candidate['oracle_sha256'] == inputs['oracle_sha256']
        assert control['job'] == candidate['job']
        assert all(control['output_file_equality'].values())
        assert not any(control['differing_state_frames'].values())
        assert control['checkpoint_RAM_equal_after_exact_code_normalization']
        for filename, digest in control['outputs'].items():
            assert sha(args.control / filename) == digest, filename
    patch, = [p for p in manifest['patches'] if p['id'] == inputs['patch_id']]
    original, replacement = bytes.fromhex(patch['expect']), bytes.fromhex(patch['replace'])
    frame_rows = [rows(p / 'frames.csv') for p in (args.control, args.candidate)]
    assert len(frame_rows[0]) == len(frame_rows[1]) == control['job']['frames']
    differences = {key: [] for key in frame_rows[0][0]}
    for old, new in zip(*frame_rows):
        assert old['frame'] == new['frame']
        for key in differences:
            if old[key] != new[key]:
                differences[key].append(int(old['frame']))
    before = (args.control / 'mainram.bin').read_bytes()
    after = bytearray((args.candidate / 'mainram.bin').read_bytes())
    assert len(before) == len(after)
    at = int(patch['addr'], 0) - 0x02000000
    assert before[at:at+len(original)] == original and after[at:at+len(replacement)] == replacement
    after[at:at+len(original)] = original
    av, bv = np.frombuffer(before, '<u4'), np.frombuffer(after, '<u4')
    changed = np.flatnonzero(av != bv)
    insn = [r['instruction_totals']['arm9_insn'] for r in records]
    assert control['profile_start_actual'] == candidate['profile_start_actual']
    result = dict(state='diagnostic_comparison_complete', scene=control['scene'],
                  patch_id=patch['id'], strict_replay_state=candidate['state'],
                  frame_count=len(frame_rows[0]), frame_field_differences={k: len(v) for k, v in differences.items()},
                  different_screen_frames={k: differences[k] for k in ['hash_top', 'hash_bottom']},
                  audio=audio_stats(args.control/'audio.s16le', args.candidate/'audio.s16le'),
                  selected_profile_ARM9_instructions=dict(before=insn[0], after=insn[1],
                      reduction_percent=(insn[0]-insn[1])/insn[0]*100,
                      first_frame=control['profile_start_actual'], end_frame_exclusive=len(frame_rows[0]),
                      scope='Software executed instructions; not native cycles or speed'),
                  checkpoint_mainRAM=dict(different_words_outside_patch=len(changed),
                      first_words=[dict(address=hex(0x02000000+int(i)*4), before=hex(int(av[i])), after=hex(int(bv[i]))) for i in changed[:20]],
                      scope='Existing retained mainram.bin checkpoint; no other memory normalized'),
                  RAM_frame_differences=candidate['differing_state_frames'],
                  save_exact=sha(args.control/'save.bin') == sha(args.candidate/'save.bin') and candidate['differing_state_frames']['save'] == 0,
                  table_and_literal_write_watch={name: guard_stats(path/'ram_bus.csv',patch['data_guards'])
                      for name,path in [('control',args.control),('candidate',args.candidate)]},
                  source_manifest_sha256=inputs['manifest_sha256'], input_sha256=sha(args.input),
                  analysis_source_sha256=sha(Path(__file__)), accepted=False, native_measured=False,
                  reused_original_control=reused,
                  control_reuse_scope='Same original virtual-ROM digest, game identity, oracle, replay job and exact golden outputs; code normalization extent may differ on an unpatched control.' if reused else None,
                  inputs={str(path): sha(path) for directory in [args.control,args.candidate]
                      for path in [directory/'frames.csv',directory/'audio.s16le',directory/'state.csv',directory/'code_normalized_state.csv',directory/'mainram.bin',directory/'save.bin']})
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps({k:result[k] for k in ['scene','frame_field_differences','audio','selected_profile_ARM9_instructions','checkpoint_mainRAM','RAM_frame_differences','save_exact','table_and_literal_write_watch']}))


if __name__ == '__main__':
    main()
