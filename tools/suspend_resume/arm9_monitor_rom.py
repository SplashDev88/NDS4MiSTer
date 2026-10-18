#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Generate the ARM9 private monitor, including 19 writable CP15 words."""
import argparse
from pathlib import Path
from arm7_monitor_rom import generate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    for path, content in zip([repo/'rtl/nds_arm9_monitor_rom.vhd',
                             repo/'tools/suspend_resume/arm9_monitor_rom.lst'], generate(arm9=True)):
        if args.check:
            if not path.exists() or path.read_text() != content:
                raise SystemExit('stale generated monitor ROM: ' + str(path))
        else:
            path.write_text(content)


if __name__ == '__main__':
    main()
