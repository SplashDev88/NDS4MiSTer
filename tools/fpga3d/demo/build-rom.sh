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
$N -c build/nds_fpga3d_demo_20261107.nds -9 build/arm9.bin -7 build/arm7.bin -r9 0x02004000 -e9 0x02004000 -r7 0x02003000 -e7 0x02003000 -h 0x200 -o build/logo.bin -g F3DD 00 FPGA3DDEMO -nopass
$N -i build/nds_fpga3d_demo_20261107.nds > build/header-info.txt
$T-gcc -mcpu=arm946e-s -marm -Os -ffreestanding -fno-builtin -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables -Wall -Wextra -Werror -nostdlib -Tsrc/arm9.ld src/start9.s src/textured.c -o build/texture9.elf
$T-objcopy -O binary build/texture9.elf build/texture9.bin
$N -c build/nds_fpga3d_texture_20261107.nds -9 build/texture9.bin -7 build/arm7.bin -r9 0x02004000 -e9 0x02004000 -r7 0x02003000 -e7 0x02003000 -h 0x200 -o build/logo.bin -g F3DT 00 F3DTEXTURE -nopass
$N -i build/nds_fpga3d_texture_20261107.nds > build/texture-header-info.txt
'
python3 - <<'PY'
from pathlib import Path
import struct
for name in ['demo','texture']:
 p=Path('build/nds_fpga3d_'+name+'_20261107.nds'); b=p.read_bytes()
 end=struct.unpack_from('<I',b,0x80)[0]
 if len(b)>end or end%512: raise RuntimeError('Unexpected ROM end/alignment')
 # Keep a complete sector-aligned, power-of-two cartridge image.
 capacity=1 << max(16,(end-1).bit_length())
 p.write_bytes(b+bytes([255])*(capacity-len(b)))
PY
