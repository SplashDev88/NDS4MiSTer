#!/usr/bin/env python3
"""Bind completed FPGA output to the pixel-grid inputs and offline checks."""
from pathlib import Path
import datetime
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'build-pixel-grid'
REPORTS = ROOT / 'build-fpga3d/quartus'
OUTPUT = ROOT / 'build-fpga3d/rc15-command-output'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    inputs = json.loads((BUILD / 'BUILD_INPUTS.json').read_text())
    validation = json.loads((BUILD / 'VALIDATION.json').read_text())
    status = json.loads((REPORTS / 'status.json').read_text())
    assert all(status.get(s) == 0 for s in ['map', 'fit', 'asm']), status
    for name, digest in inputs['source_sha256'].items():
        if name == inputs.get('diagnostic_report_update', {}).get('file'):
            digest = inputs['diagnostic_report_update']['sha256']
        assert sha(ROOT / name) == digest, 'Changed build input: ' + name
    assert validation['rtl_sha256'] == inputs['source_sha256']['rtl/nds_pixel_grid.sv']
    core = OUTPUT / 'NDS4MiSTer.rbf'
    started = datetime.datetime.fromisoformat(inputs['started']).timestamp()
    assert core.stat().st_mtime >= started, 'Stale FPGA image'
    summary = (OUTPUT / 'NDS4MiSTer.fit.summary').read_text()
    assert 'Fitter Status : Successful' in summary

    def count(label):
        m = re.search(re.escape(label) + r'\s*:\s*([\d,]+)', summary)
        assert m, label
        return int(m[1].replace(',', ''))

    fit = (OUTPUT / 'NDS4MiSTer.fit.rpt').read_text(encoding='latin1')
    rows = [line for line in fit.splitlines()
            if re.search(r'^;\s*\|nds_pixel_grid:hdmi_pixel_grid\|\s*;', line)]
    assert len(rows) == 1, 'Grid hierarchy missing or ambiguous'
    cells = [cell.strip() for cell in rows[0].split(';')[1:-1]]
    number = lambda i: float(cells[i].split()[0])
    resources = dict(total_alms=count('Logic utilization (in ALMs)'),
                     total_registers=count('Total registers'),
                     ram_blocks=count('Total RAM Blocks'),
                     dsp_blocks=count('Total DSP Blocks'),
                     grid_alms=number(1), grid_placed_alms=number(2),
                     grid_aluts=int(number(6)), grid_registers=int(number(7)),
                     grid_ram_blocks=int(number(10)), grid_dsp_blocks=int(number(11)))
    top_rows = [line for line in fit.splitlines()
                if re.search(r'^;\s*\|sys_top\s*;', line)]
    assert len(top_rows) == 1, 'Top-level resource hierarchy missing or ambiguous'
    top = [cell.strip() for cell in top_rows[0].split(';')[1:-1]]
    resources.update(total_placed_alms=float(top[2].split()[0]),
                     estimated_dense_pack_recoverable_alms=float(top[3].split()[0]),
                     estimated_unavailable_alms=float(top[4].split()[0]))
    assert resources['grid_ram_blocks'] == 0
    assert 0 < resources['grid_dsp_blocks'] <= 3, resources
    slacks, global_slacks = {}, {}
    if status.get('sta') == 0:
        reports = sorted(REPORTS.glob('pixel-grid-*.txt'))
        assert len(reports) == 16, 'Grid timing reports incomplete'
        for report in reports:
            assert report.stat().st_mtime >= started, 'Stale timing report'
            m = re.search(r'Worst case slack is (-?[\d.]+)', report.read_text())
            assert m, report.name
            slacks[report.name] = float(m[1])
        for report in sorted(REPORTS.glob('global-*.txt')):
            assert report.stat().st_mtime >= started, 'Stale timing report'
            m = re.search(r'Worst case slack is (-?[\d.]+)', report.read_text())
            assert m, report.name
            global_slacks[report.name] = float(m[1])
        assert len(global_slacks) == 16, 'Global timing reports incomplete'
    validation.update(status='fpga_built_hardware_pending', hardware_qualified=False,
                      core_sha256=sha(core), fpga_source_revision=inputs['source_revision'],
                      fit=resources, stages=status, grid_timing_slacks_ns=slacks,
                      global_timing_slacks_ns=global_slacks,
                      timing_reports_complete=status.get('sta') == 0,
                      timing_interpretation='Stage exit codes describe tool completion, not timing closure; negative slack remains diagnostic',
                      acceptance_criterion='Hardware startup, gameplay and grid behavior; timing diagnostic',
                      updated=datetime.datetime.now(datetime.timezone.utc).isoformat())
    (BUILD / 'VALIDATION.json').write_text(json.dumps(validation, indent=2) + '\n')
    print(json.dumps({k: validation[k] for k in ['status', 'core_sha256', 'fit', 'stages']}, indent=2))


if __name__ == '__main__':
    main()
