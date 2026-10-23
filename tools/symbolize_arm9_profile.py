#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Summarize native debug samples; parse symbol data without executing it."""
import argparse
from bisect import bisect_right
from collections import Counter, defaultdict
import json
from pathlib import Path
import re


def symbols(text):
    result=defaultdict(list)
    for line in text.splitlines():
        m=re.match(r'\s*([^=]+?)\s*=\s*(0x[0-9a-fA-F]+)(?:\s*\+\s*1)?;',line)
        if m:result[int(m[2],16)&~1].append(m[1].strip())
    return dict(result)


def summarize(profile, names, bounds=None):
    hist=Counter()
    states=Counter()
    pc_states=defaultdict(Counter)
    raw_values=defaultdict(Counter)
    for seconds,frame,r15,flags,seq in profile['samples']:
        states[flags]+=1
        if flags&8:continue  # No execution-address interpretation during reset.
        # ARM +8 was calibrated against the production CPU's WFI instruction.
        # Preserve raw R15 as well; a mode-switch boundary is not a precise
        # retired-instruction trace. Thumb uses the architectural +4 convention.
        pc=(r15-(4 if flags&1 else 8))&0xffffffff
        hist[pc]+=1
        pc_states[pc][flags]+=1
        raw_values[pc][r15]+=1
    starts=sorted(names)
    rows=[]
    total=sum(hist.values())
    for pc,n in hist.most_common(30):
        i=bisect_right(starts,pc)-1
        start=starts[i] if i>=0 else None
        label=' / '.join(names[start]) if start is not None else 'unmapped'
        relation='nearest preceding symbol, extent unknown'
        if bounds is not None:
            matches={(a,z,name) for a,z,name in bounds if a<=pc<a+z}
            if len(matches)==1:
                start,size,bounded_name=next(iter(matches))
                label=' / '.join(names.get(start,[bounded_name]))
                relation='within explicit function extent'
            else:
                label='unmapped / ambiguous overlay'
                start=None;relation='unresolved'
        rows.append(dict(architectural_r15={f'0x{raw:08x}':count
                                           for raw,count in raw_values[pc].items()},
                         pc=f'0x{pc:08x}',states=dict(pc_states[pc]),
                         samples=n,percent=100*n/total if total else 0,
                         symbol=label,offset=pc-start if start is not None else None,
                         mapping=relation))
    return dict(observed_samples=profile['observed_samples'],
                elapsed_seconds=profile.get('elapsed_seconds'),
                collector_cpu_seconds=profile.get('collector_cpu_seconds'),
                nonreset_samples=total,missed_sequence_minimum=profile['missed_sequence_minimum'],
                states=dict(states),top30=rows,
                limitation='Debug wall-time sampling, not FPS or retired instructions. '
                    'Idle/DMA flags are retained; sampling overhead is not subtracted. '
                    'PC residence can include memory, transport and renderer stalls. '
                    'The observed R15 is not a precise instruction retirement record.')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('profile',type=Path);p.add_argument('--symbols',type=Path,required=True)
    p.add_argument('--bounds',type=Path,
                   help='Matching region extents, e.g. nsmb/config/A2DE/arm9')
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();bounds=None
    if a.bounds:
        bounds=[]
        for path in a.bounds.rglob('symbols.txt'):
            for line in path.read_text().splitlines():
                m=re.match(r'(.+?) kind:function\((?:arm|thumb),size=(0x[0-9a-f]+)\) addr:(0x[0-9a-f]+)',line)
                if m:bounds.append((int(m[3],16),int(m[2],16),m[1]))
        if not bounds:p.error('No function extents found under --bounds')
    result=summarize(json.loads(a.profile.read_text()),symbols(a.symbols.read_text()),bounds)
    with a.output.open('x') as f:json.dump(result,f,indent=2);f.write('\n')
    for row in result['top30']:
        print(row['pc'],f"{row['percent']:6.2f}%",row['samples'],row['symbol'],row['offset'],row['mapping'])
