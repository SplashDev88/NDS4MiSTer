"""Use the actual console wiring in the narrow DMA/event-gate regression."""
import pathlib
import re
import argparse
import subprocess

repo = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=pathlib.Path)
parser.add_argument('--revision', help='Local before-fix revision to reproduce')
args = parser.parse_args()
source = (subprocess.check_output(
    ['git', 'show', f'{args.revision}:rtl/nds_nitro_console_top.vhd'],
    cwd=repo, text=True) if args.revision else
    (repo / 'rtl/nds_nitro_console_top.vhd').read_text())
names = ('h3d_vram9_source_address h3d_vram9_source_data h3d_vram9_source_be '
         'h3d_vram9_source_access h3d_vram9_needed_by_h3d h3d_vram9_source_valid '
         'vr9_src_ena vr9_ena vr9_rnw vr9_addr vr9_be vr9_din vr9_wpost dma_vr_wok_safe').split()
assignments = []
for name in names:
    matches = re.findall(r'^\s*' + name + r'\s*<=.*?;', source, re.M | re.S)
    assert len(matches) == 1, (name, len(matches))
    assignments.append(matches[0])
matches = re.findall(r'^\s*p_vram9_unposted_hold\s*:.*?end process;', source, re.M | re.S)
assert len(matches) <= 1
assignments.extend(matches)
template = (repo / 'rtl/tb_nds_h3d_vram9_retirement.vhd').read_text()
args.output.write_text(template.replace('-- @PRODUCTION_VRAM9_MUX@', '\n'.join(assignments)))
