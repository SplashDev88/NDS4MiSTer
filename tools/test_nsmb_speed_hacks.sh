#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
python3 -m unittest discover -s "$repo/tools/standalone_host/fmv" -p test_hook_guard.py
python3 "$repo/tools/test_symbolize_arm9_profile.py"
python3 "$repo/tools/test_arm9_pc_profile.py"
docker run --rm --network none -v "$repo:/src:ro" -w /src/tools/standalone_host \
  nds4mister-armhf:ubuntu-24.04 bash -c '
set -euo pipefail
gcc -std=c11 -O2 -Wall -Wextra -Werror -DPC_SAMPLE_TEST /src/tools/arm9_pc_sample.c -o /tmp/pc-sample-test
/tmp/pc-sample-test
for test in test_host_speed_hacks test_host_display_menu test_fmv_rom_reader; do
  g++ -std=c++17 -O2 -Wall -Wextra -Werror "$test.cpp" -o "/tmp/$test"
  if [[ "$test" == test_fmv_rom_reader ]]; then
    "/tmp/$test" /src/tools/standalone_host/fmv
  else
    "/tmp/$test"
  fi
done
'
