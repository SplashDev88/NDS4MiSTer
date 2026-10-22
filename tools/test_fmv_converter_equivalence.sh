#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 1 ]]; then
  echo "Usage: bash tools/test_fmv_converter_equivalence.sh /path/to/unmodified-ACVE-rev0.nds" >&2
  exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
rom_path=$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True))' "$1")
# The caller supplies a private ROM. Only the disposable container receives the
# extracted code fixtures; those fixtures and the ROM stay outside the repo.
docker run --rm --network none \
  -v "$repo/tools/fixtures/fmv_color:/src:ro" \
  -v "$repo/tools/standalone_host:/host:ro" \
  -v "$rom_path:/input/source.nds:ro" \
  nds4mister-armhf:ubuntu-24.04 sh -c '
    set -eu
    arm-linux-gnueabihf-g++ -std=c++17 -O2 -static -mcpu=cortex-a9 \
      -mfpu=neon -mfloat-abi=hard -I/host /src/stage_converter.cpp -o /tmp/stage
    /tmp/stage /input/source.nds
    arm-linux-gnueabihf-as /host/fmv_castlevania.S -o /tmp/overlay.o
    arm-linux-gnueabihf-ld -Ttext=0x01ff9220 /tmp/overlay.o -o /tmp/overlay.elf
    arm-linux-gnueabihf-objcopy -O binary --only-section=.text \
      /tmp/overlay.elf /tmp/overlay.bin
    cmp /tmp/overlay.bin /tmp/embedded-overlay.bin
    arm-linux-gnueabihf-g++ -std=c++17 -O2 -static -mcpu=cortex-a9 \
      -mfpu=neon -mfloat-abi=hard /src/test_converter.cpp /src/test_converter.S \
      -o /tmp/test-converter
    /tmp/test-converter
  '
