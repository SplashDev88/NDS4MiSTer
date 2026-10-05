#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
docker image inspect skylyrac/blocksds:slim-latest > build/toolchain-image.json
docker run --rm --network none --entrypoint /bin/sh -v "$PWD:/work" -w /work skylyrac/blocksds:slim-latest -c '
set -eu
T=/opt/wonderful/toolchain/gcc-arm-none-eabi/bin/arm-none-eabi
N=/opt/wonderful/thirdparty/blocksds/core/tools/ndstool/ndstool
$T-gcc --version > build/compiler-version.txt
$T-gcc -mcpu=arm946e-s -marm -Os -ffreestanding -fno-builtin -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables -Wall -Wextra -Werror -nostdlib -Ibuild -Tsrc/arm9.ld -Wl,-Map,build/arm9.map src/start9.s src/diagnostic.c -o build/arm9.elf
$T-gcc -mcpu=arm7tdmi -marm -Os -ffreestanding -fno-builtin -Wall -Wextra -Werror -nostdlib -Tsrc/arm7.ld -Wl,-Map,build/arm7.map src/start7.s src/peer.c -o build/arm7.elf
$T-objcopy -O binary build/arm9.elf build/arm9.bin
$T-objcopy -O binary build/arm7.elf build/arm7.bin
$T-objdump -d build/arm9.elf > build/arm9.disassembly.txt
$T-nm -n build/arm9.elf > build/arm9.symbols.txt
$T-nm -n build/arm7.elf > build/arm7.symbols.txt
dd if=/dev/zero of=build/logo.bin bs=156 count=1 2>/dev/null
$N -c build/LidMicDiagnostic.nds -9 build/arm9.bin -7 build/arm7.bin -r9 0x02004000 -e9 0x02004000 -r7 0x02003000 -e7 0x02003000 -h 0x200 -o build/logo.bin -g LMIC 00 LIDMICBETA -nopass
$N -i build/LidMicDiagnostic.nds > build/header-info.txt
'
python3 - <<'PY'
from pathlib import Path
import struct
p=Path('build/LidMicDiagnostic.nds'); b=p.read_bytes()
end=struct.unpack_from('<I',b,0x80)[0]
if len(b)>end or end%512: raise RuntimeError('Unexpected ROM end/alignment')
# ndstool leaves the final empty FAT alignment absent; include its declared
# end so the direct loader receives a complete, sector-aligned test image.
p.write_bytes(b+bytes([255])*(end-len(b)))
PY
