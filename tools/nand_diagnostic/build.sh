#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -eu
if [ "$#" -ne 1 ]; then echo "usage: $0 NEW_OUTPUT_DIRECTORY" >&2; exit 2; fi
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ ! -e "$1" ] || { echo "Output already exists; choose a fresh directory" >&2; exit 2; }
mkdir -p "$1"
out=$(CDPATH= cd -- "$1" && pwd)
image=skylyrac/blocksds:slim-latest
docker image inspect --format '{{.Id}}' "$image" > "$out/toolchain-image-id.txt"
docker run --rm --network none --entrypoint /bin/sh -v "$src:/src:ro" -v "$out:/work" -w /work "$image" -c '
set -eu
tool=/opt/wonderful/toolchain/gcc-arm-none-eabi/bin/arm-none-eabi
ndstool=/opt/wonderful/thirdparty/blocksds/core/tools/ndstool/ndstool
"$tool-gcc" --version > compiler-version.txt
"$tool-gcc" -mcpu=arm7tdmi -marm -nostdlib -T/src/arm7.ld /src/start7.s -o arm7.elf
"$tool-objcopy" -O binary arm7.elf arm7.bin
dd if=/dev/zero of=logo.bin bs=156 count=1 2>/dev/null
for size in 8 16; do
 "$tool-gcc" -mcpu=arm946e-s -marm -O2 -ffreestanding -fno-builtin -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables -Wall -Wextra -Werror -nostdlib -T/src/arm9.ld -DSAVE_BYTES="($size*1024*1024u)" /src/start9.s /src/probe.c -o "probe$size.elf"
 "$tool-objcopy" -O binary "probe$size.elf" "probe$size.bin"
 "$ndstool" -c "probe$size.nds" -9 "probe$size.bin" -7 arm7.bin -r9 0x02004000 -e9 0x02004000 -r7 0x02003000 -e7 0x02003000 -h 0x200 -o logo.bin -g UORE 00 NANDTESTV2 -nopass
done
'
python3 - "$out" "$src" <<'PY'
from pathlib import Path
import sys,struct,hashlib,json
out,src=map(Path,sys.argv[1:]);manifest={}
for size in (8,16):
 p=out/f'probe{size}.nds';b=bytearray(p.read_bytes());end=struct.unpack_from('<I',b,0x80)[0]
 assert len(b)<=end and end%512==0
 b.extend(b'\xff'*(end-len(b)));b[12:16]=b'UXBP' if size==8 else b'UORE'
 struct.pack_into('<HH',b,0x94,0x350,0x350)
 crc=0xffff
 for byte in b[:0x15e]:
  crc^=byte
  for _ in range(8):crc=(crc>>1)^(0xa001 if crc&1 else 0)
 struct.pack_into('<H',b,0x15e,crc);p.write_bytes(b)
 manifest[p.name]={'sha256':hashlib.sha256(b).hexdigest(),'bytes':len(b),'save_capacity':size*1024*1024}
manifest['sources']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(src.iterdir()) if p.is_file()}
manifest['toolchain_image_id']=(out/'toolchain-image-id.txt').read_text().strip()
(out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({k:v for k,v in manifest.items() if k.endswith('.nds')},indent=2))
PY
