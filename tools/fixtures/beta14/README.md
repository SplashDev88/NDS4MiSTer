# FMV and TATE equivalence references

These GPL source fixtures are the complete reference implementations used by
the sound-register readback and VRAM victim-cache equivalence tests. They are
not compiled into the release core. Original source comments and attribution
are preserved. See the project LICENSE.txt and vendored component licenses.

The runners load these files directly so the tests also work from a GitHub
source archive without development Git history. Production sources remain in
`third_party/Nitro_DarkSide/d2dabe/rtl/nds_sound.vhd` and
`rtl/nds_nitro_vram.vhd`.

Run from the repository root (requires the NVC Docker image documented in each
runner):

```sh
python3 tools/test_sound_readback_equivalence.py --output /tmp/nds-sound-check --negative-controls
python3 tools/test_vram_victim_equivalence.py --output /tmp/nds-vram-check
```

Use a new output directory for each invocation. These finite simulations do
not establish universal timing closure or hardware compatibility.
