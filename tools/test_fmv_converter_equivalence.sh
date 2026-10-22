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
    arm-linux-gnueabihf-as /host/fmv_castlevania_dct.S -o /tmp/dct.o
    arm-linux-gnueabihf-ld -Ttext=0x01ffd1d4 /tmp/dct.o -o /tmp/dct.elf
    arm-linux-gnueabihf-objcopy -O binary --only-section=.text \
      /tmp/dct.elf /tmp/assembled-dct.bin
    cmp /tmp/assembled-dct.bin /tmp/candidate-dct.bin
    arm-linux-gnueabihf-g++ -std=c++17 -O2 -static -mcpu=cortex-a9 \
      -mfpu=neon -mfloat-abi=hard /src/test_dct.cpp /src/test_dct.S \
      -o /tmp/test-dct
    /tmp/test-dct
    arm-linux-gnueabihf-as /host/fmv_castlevania_adpcm.S -o /tmp/adpcm.o
    arm-linux-gnueabihf-ld -Ttext=0x02059960 /tmp/adpcm.o -o /tmp/adpcm.elf
    arm-linux-gnueabihf-objcopy -O binary --only-section=.text \
      /tmp/adpcm.elf /tmp/assembled-adpcm.bin
    cmp /tmp/assembled-adpcm.bin /tmp/candidate-adpcm.bin
    arm-linux-gnueabihf-g++ -std=c++17 -O2 -static -mcpu=cortex-a9 \
      -mfpu=neon -mfloat-abi=hard /src/test_adpcm.cpp /src/test_adpcm.S \
      -o /tmp/test-adpcm
    /tmp/test-adpcm
  '
