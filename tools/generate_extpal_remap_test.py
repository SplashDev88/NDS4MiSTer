#!/usr/bin/env python3
"""Keep the palette refill under test byte-for-byte production RTL."""
from pathlib import Path
import argparse
import subprocess

repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
parser.add_argument('--revision', help='Optional local git revision for a before-fix reproduction')
args = parser.parse_args()
source = (subprocess.check_output(
    ['git', 'show', f'{args.revision}:rtl/nds_nitro_gpu2d.vhd'], cwd=repo, text=True)
    if args.revision else (repo / 'rtl/nds_nitro_gpu2d.vhd').read_text())
start = source.index('   process (clk)', source.index('-- ================= ext-pal shadow fill'))
end = source.index('   end process;', start) + len('   end process;')
template = (repo / 'rtl/tb_nds_extpal_remap.vhd').read_text()
assert template.count('-- PRODUCTION_REFILL_PROCESS') == 1
args.output.write_text(template.replace('-- PRODUCTION_REFILL_PROCESS', source[start:end]))
