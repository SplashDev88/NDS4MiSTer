# Engine B C/D VRAM mirrors — Fire Emblem: Shadow Dragon

Fire Emblem decompresses its prologue background graphics through mirrored
Engine B addresses such as `0x06230000`. Bank C in mode 4 must repeat its
128 KiB backing throughout `0x06200000–0x063FFFFF`; bank D in mode 4 likewise
repeats throughout `0x06600000–0x067FFFFF`. The former decoder accepted only
the first 128 KiB, so CPU decompression backreferences and glyph
read-modify-write operations read zero through the remaining aliases.

The fix removes those two high-address restrictions. Bank enable, CPU owner,
region and mode checks and the physical 17-bit offset remain unchanged.
It adds no state, rendering work, pipeline stages or clock changes.
Other mapping modes are outside this change's scope.

Reference: the bundled melonDS `GPU::MapVRAM_CD` and
`GPU::ReadVRAM_BBG/BOBJ` / `WriteVRAM_BBG/BOBJ` in `GPU.cpp` and `GPU.h`.
A private controlled replay of Fire Emblem with these alias reads forced to
zero reproduced all pixels of the damaged prologue artwork and heading
captured from hardware. Private game data is excluded from this source tree.

Validation:

- `bash tools/test_vram_cd_mirrors.sh`: 40,960 aperture checks, CPU/enable/OFS
  handling, excluded modes, boundaries, bank overlaps and decompression
  backreferences. Fails at `0x06220000` on the release decoder; passes after
  the fix. To reproduce the negative control, set `SOURCE_REVISION` to the
  release commit before running the test.
- `bash tools/test_vram_hi_mirrors.sh`: 262,144 existing H/I mapping checks.
- A full FPGA build and physical-board game verification are required before
  release; simulation alone does not establish hardware acceptance.
