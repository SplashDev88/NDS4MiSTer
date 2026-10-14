#!/usr/bin/env python3
"""Fail before fitting if Quartus replaced an RTC CDC pipeline with RAM."""
import argparse
import json
import re
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("report", type=Path)
ap.add_argument("--output", type=Path)
args = ap.parse_args()
report = args.report.read_text(errors="replace")
start = report.index("; Registers Protected by Synthesis ")
end = report.index("; Registers Removed During Synthesis ", start)
protected = report[start:end]
expected = {
    "nds_rtc_host_bridge:rtc_host_bridge|request_sync": 3,
    "nds_rtc_host_bridge:rtc_host_bridge|ack_sync": 3,
    "nds_rtc_host_bridge:rtc_host_bridge|snapshot_meta": 88,
    "nds_rtc_host_bridge:rtc_host_bridge|snapshot_sync": 88,
    "nds_nitro_rtc:irtc|seed_toggle_sync": 3,
    "nds_nitro_rtc:irtc|seed_meta": 56,
    "nds_nitro_rtc:irtc|seed_sync": 56,
}
result = {}
for name, width in expected.items():
    bits = set(int(bit) for bit in re.findall(re.escape(name) + r"\[(\d+)\]\s*;\s*yes", protected))
    assert bits == set(range(width)), (name, sorted(bits), width)
    result[name] = len(bits)
for line in report.splitlines():
    if "SHIFT_TAPS" not in line:
        continue
    original = line.split(";")[1]
    assert "nds_rtc_host_bridge:rtc_host_bridge|" not in original, line
    assert not ("nds_nitro_rtc:irtc|" in original and "seed_" in original), line
result = {"status": "PASS", "protected_pipeline_registers": result,
          "rtc_cdc_shift_ram": False}
if args.output:
    args.output.write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps(result, indent=2))
