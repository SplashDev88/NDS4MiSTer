#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reproduce qualified virtual images from locally owned original cartridges.

Expected input names are the profile keys with a .nds suffix, including
NINO_EN10.nds for the exact English translation v1.0.
Only hashes and lengths are emitted. No ROM or movie output is written.
"""
import argparse
import hashlib
import json
from pathlib import Path
from prepare import ROOT, Source, assemble


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('original_dir',type=Path)
    args=parser.parse_args()
    results=[]
    for profile in json.loads((ROOT/'profiles.json').read_text())['profiles']:
        with (args.original_dir/(profile['key']+'.nds')).open('rb') as f:
            source=Source(f.fileno())
            virtual=assemble(source,profile)
            h=hashlib.sha256();length=0
            for block in virtual.blocks():h.update(block);length+=len(block)
            source.unchanged()
        if h.hexdigest()!=profile['qualified_image_sha256']:
            raise ValueError('Reconstruction differs: '+profile['key'])
        results.append(dict(game=profile['key'],bytes=length,sha256=h.hexdigest(),qualified_image_match=True))
    print(json.dumps(results,indent=2))
if __name__=='__main__':main()
