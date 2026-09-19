#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/nds-tag-factoring.XXXXXX")"
trap 'rm -rf "$test_tmp"' EXIT
compile_run() {
    iverilog -g2012 -s tb_nds_h3d_tag_factoring -o "$test_tmp/test" \
        "$1" "$repo_dir/rtl/tb_nds_h3d_tag_factoring.sv"
    vvp "$test_tmp/test"
}
compile_run "$repo_dir/rtl/nds_h3d_plane_reader.sv"
for gate in descriptor_session_current descriptor_merge_frame_current; do
    python3 - "$repo_dir/rtl/nds_h3d_plane_reader.sv" "$test_tmp/broken.sv" "$gate" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
old='        '+sys.argv[3]+' &&'
assert text.count(old)==3
Path(sys.argv[2]).write_text(text.replace(old, "        1'b1 &&"))
PY
    if compile_run "$test_tmp/broken.sv" > "$test_tmp/negative.txt" 2>&1; then
        echo "FAIL: missing $gate was not detected" >&2; exit 1
    fi
    grep -q 'tag factoring differs from original' "$test_tmp/negative.txt"
    echo "PASS: negative control detects missing $gate"
done
