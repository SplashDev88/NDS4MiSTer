#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Launch the paired private RC with automatic, read-only movie preparation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda:f.read(262144),b''):h.update(b)
    return h.hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rom')
    parser.add_argument('--seconds',type=int,default=0)
    parser.add_argument('--direct-video-target',choices=('retrotink','crt'))
    parser.add_argument('--validate-only',action='store_true')
    args=parser.parse_args()
    if not 0 <= args.seconds <= 86400:raise ValueError('Invalid test duration')
    kit=Path(__file__).resolve().parent
    manifest=json.loads((kit/'manifest.json').read_text())
    checks=manifest['automatic_movie_files']
    required={'nds_standalone_host','support/nds_hybrid_3d_service','NDS_Standalone.rbf',
              'supervisor.py','Kickstart.sh','auto_movies.py','fmv/stream.py','fmv/prepare.py','fmv/profiles.json',
              'fmv/stream_load.py','fmv/prepared_cache.py','fmv/load_progress.py'}
    if not required <= set(checks):raise ValueError('Incomplete automatic-movie package')
    for name,expected in checks.items():
        relative=Path(name)
        if relative.is_absolute() or '..' in relative.parts:raise ValueError('Invalid package path')
        if sha(kit/relative)!=expected:raise ValueError('Mismatched package file: '+name)
    if args.validate_only:
        print('FMV_AUTO_PACKAGE_VALIDATION_PASS');return 0
    # Supervisor performs the normal exclusive-owner, firmware, memory,
    # module, clock and recovery checks before handing over the frontend.
    env=os.environ.copy();env['NDS_FMV_AUTO']='1';env['NDS_FMV_COLOR_FAST']='1'
    command=[sys.executable,str(kit/'supervisor.py'),'--seconds',str(args.seconds)]
    if args.rom:command+=['--rom',args.rom]
    if args.direct_video_target:command+=['--direct-video-target',args.direct_video_target]
    os.execvpe(sys.executable,command,env)


if __name__=='__main__':
    try:sys.exit(main())
    except (OSError,ValueError,KeyError) as error:
        print('NDS FMV RC: '+str(error),file=sys.stderr);sys.exit(1)
