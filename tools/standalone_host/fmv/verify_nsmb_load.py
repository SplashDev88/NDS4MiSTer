#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compare NSMB load images using an owned, qualified USA revision 0 cartridge.

No ROM or derived executable is written. The reference uses the rc10 compressed
ARM9 serialization; the candidate uses the same patched sections uncompressed.
"""
import argparse
import hashlib
import json
import struct
from unittest.mock import patch
from ndspy import code
from nsmb_runtime import assemble, MODES
from prepare import Source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rom')
    args = parser.parse_args()
    save = code.MainCodeFile.save
    results = []
    with open(args.rom, 'rb') as source_file:
        source = Source(source_file.fileno())
        original = source.read(0, source.size)
        for mode in MODES:
            def reference_save(arm, **kwargs):
                return save(arm, compress=True)
            with patch.object(code.MainCodeFile, 'save', reference_save):
                reference = b''.join(assemble(source, mode).blocks())
            candidate = b''.join(assemble(source, mode).blocks())

            def executable(image):
                offset, entry, base, size = struct.unpack_from('<4I', image, 32)
                return offset, entry, base, size, code.MainCodeFile(image[offset:offset+size], base)

            old, new = executable(reference), executable(candidate)
            assert old[:3] == new[:3]
            assert len(old[4].sections) == len(new[4].sections) == 5
            assert old[4].codeSettingsOffs == new[4].codeSettingsOffs
            for index, (a, b) in enumerate(zip(old[4].sections, new[4].sections)):
                assert (a.ramAddress, a.bssSize, a.implicit) == (b.ramAddress, b.bssSize, b.implicit)
                expected = bytearray(a.data)
                if index == 0:
                    # The SDK boot routine must skip decompression for this image.
                    struct.pack_into('<I', expected, old[4].codeSettingsOffs + 0x14, 0)
                assert expected == b.data, (mode, index)
            assert reference[512:source.size] == candidate[512:source.size] == original[512:]
            source.unchanged()
            results.append(dict(mode=mode, sections_match=True, original_assets_match=True,
                                compressed_arm9_bytes=old[3], uncompressed_arm9_bytes=new[3],
                                virtual_sha256=hashlib.sha256(candidate).hexdigest()))
    print(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
