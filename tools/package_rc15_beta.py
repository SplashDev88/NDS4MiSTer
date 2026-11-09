#!/usr/bin/env python3
"""Build an isolated RC15 AA beta from the pinned public RC14 package."""
from pathlib import Path
import argparse, ast, io, json, tarfile
import package_rc11_release as common
import package_rc14_release as packaging

ROOT = Path(__file__).resolve().parents[1]
common.ROOT = ROOT
OLD = 'Scripts/.NDS_Standalone/'
PREFIX = 'Scripts/.NDS_RC15_Beta1_20261109/'
LAUNCHER = 'Scripts/NDS_RC15_Beta1.sh'
VERSION = 'v0.9.0-rc.15-beta1'
RC14_SHA = '4f20c748dd3aaea122070974736ab365ad91f3b1e1f74a1154a234c9be206d26'
SOURCE_SHA = '02b9676f8ec4ca7b085767a57e3cd6d5fc9d629b87a82a1f36912ecba5cfaa73'
sha, need, js = common.sha, common.need, common.js

def audit(files):
    for name, data in files.items():
        common.content_audit(name, data)
        if name.endswith('.py'): ast.parse(data, filename=name)
    m = json.loads(files[PREFIX+'manifest.json'])
    need(m['version'] == VERSION, 'Incorrect beta version')
    need(b'NDS4MiSTer v0.9.0-rc15-beta1\0' in files[PREFIX+'nds_standalone_host'], 'Host label mismatch')
    need(m['core_sha256'] == packaging.PINS['NDS_Standalone.rbf'], 'FPGA changed')
    for name, digest in m['automatic_movie_files'].items():
        need(sha(files[PREFIX+name]) == digest, 'Runtime mismatch: '+name)
    need(m['helper_sha256'] == sha(files[PREFIX+'support/nds_hybrid_3d_service']), 'Helper mismatch')
    need(m['host_sha256'] == sha(files[PREFIX+'nds_standalone_host']), 'Host mismatch')
    need(m['supervisor_sha256'] == sha(files[PREFIX+'supervisor.py']), 'Supervisor mismatch')
    need(m['launcher_sha256'] == sha(files[LAUNCHER]), 'Launcher mismatch')
    need(m['helper_sha256'].encode() in files[PREFIX+'supervisor.py'], 'Supervisor helper pin mismatch')
    need(files[PREFIX+'support/nds_hybrid_3d_service.sha256'].split()[0].decode() == m['helper_sha256'], 'Kickstart helper pin mismatch')
    need(sha(files[PREFIX+'fmv/guest_catalog.json']) == packaging.PINS['fmv/guest_catalog.json'], 'Guest catalog changed')
    need(not any('/gx_' in n or 'mario_kart' in n.lower() for n in files), 'Unaccepted Mario Kart patches')
    need(PREFIX+'NDS_graphics.cfg' not in files, 'Bundled user AA preference')
    need(files['SHA256SUMS'] == packaging.checksums({n:b for n,b in files.items() if n != 'SHA256SUMS'}), 'Root checksums differ')
    need(files[PREFIX+'SHA256SUMS'] == packaging.checksums({n[len(PREFIX):]:b for n,b in files.items() if n.startswith(PREFIX) and n != PREFIX+'SHA256SUMS'}), 'Kit checksums differ')
    return dict(state='passed', version=VERSION, runtime_files=len(m['automatic_movie_files']),
                source_revision=m['source_revision'], helper_sha256=m['helper_sha256'],
                host_sha256=m['host_sha256'], core_sha256=m['core_sha256'])

def build(runtime, sources, out):
    need(sha(runtime.read_bytes()) == RC14_SHA, 'Wrong RC14 runtime input')
    need(sha(sources.read_bytes()) == SOURCE_SHA, 'Wrong RC14 source input')
    need(not common.git('status','--porcelain'), 'Commit source before packaging')
    revision = common.git('rev-parse','HEAD').decode().strip()
    original, modes = common.read_zip(runtime)
    old_manifest = json.loads(original[OLD+'manifest.json'])
    files = {PREFIX+n[len(OLD):]:b for n,b in original.items() if n.startswith(OLD) and n != OLD+'SHA256SUMS'}
    modes = {PREFIX+n[len(OLD):]:v for n,v in modes.items() if n.startswith(OLD)}
    host = ROOT/'tools/standalone_host'
    files[PREFIX+'nds_standalone_host'] = (host/'nds_standalone_host').read_bytes()
    files[PREFIX+'supervisor.py'] = (host/'supervisor.py').read_bytes()
    files[PREFIX+'support/nds_hybrid_3d_service'] = (ROOT/'build-armhf/nds_hybrid_3d_service').read_bytes()
    helper_sha = sha(files[PREFIX+'support/nds_hybrid_3d_service'])
    files[PREFIX+'support/nds_hybrid_3d_service.sha256'] = (helper_sha+'  nds_hybrid_3d_service\n').encode()
    files[LAUNCHER] = original['Scripts/NDS4MiSTer.sh'].replace(OLD.encode(), PREFIX.encode()).replace(b'v0.9.0-rc.14',VERSION.encode())
    modes[LAUNCHER] = 0o755
    allowed = {'nds_standalone_host','supervisor.py','support/nds_hybrid_3d_service','support/nds_hybrid_3d_service.sha256','manifest.json','SHA256SUMS'}
    unchanged = 0
    for name,data in original.items():
        if name.startswith(OLD) and name[len(OLD):] not in allowed:
            need(files[PREFIX+name[len(OLD):]] == data, 'Unplanned runtime change: '+name)
            unchanged += 1
    m = dict(old_manifest)
    m.update(version=VERSION, menu_version='v0.9.0-rc15-beta1', release_channel='private beta',
             name='NDS4MiSTer RC15 AA Beta1', remote_kit='/media/fat/'+PREFIX.rstrip('/'),
             source_download='NDS4MiSTer_'+VERSION+'_Sources.zip',
             helper_sha256=helper_sha, host_sha256=sha(files[PREFIX+'nds_standalone_host']),
             supervisor_sha256=sha(files[PREFIX+'supervisor.py']), launcher_sha256=sha(files[LAUNCHER]),
             installation_scope='Separate beta launcher and settings; standard NDS save directory',
             validation_scope='AA pixel/native-buffer oracles, live-toggle reuse test, host persistence and launcher tests; hardware receipt supplied separately',
             graphics_options=dict(anti_aliasing_default='on', persistence='System > Save settings', applies='next rendered frame'),
             publication_authorized=False, published=False, package_revision=1,
             automatic_movie_files={n:sha(files[PREFIX+n]) for n in old_manifest['automatic_movie_files']})
    for key in ['source_revision','source_commit','host_source_revision','host_build_source_revision',
                'helper_source_revision','renderer_source_revision','supervisor_source_revision',
                'packaging_source_revision','runtime_source_revision']:
        m[key] = revision
    files[PREFIX+'manifest.json'] = js(m)
    files[PREFIX+'SHA256SUMS'] = packaging.checksums({n[len(PREFIX):]:b for n,b in files.items() if n.startswith(PREFIX)})
    files['README.txt'] = (ROOT/'docs/release/RC15_BETA1_README.txt').read_bytes()
    files['LICENSE.txt'] = (ROOT/'LICENSE.txt').read_bytes()
    files['SHA256SUMS'] = packaging.checksums(files)
    result = audit(files)
    source, _ = common.read_zip(sources)
    source = {n:b for n,b in source.items() if n.startswith('components/') and 'Regional_Renderer' not in n}
    source['NDS4MiSTer-rc15-source.tar.gz'] = common.git('archive','--format=tar.gz','HEAD')
    source['BUILD.md'] = (ROOT/'docs/release/BUILD_RC15.md').read_bytes()
    source['BUILD_PROVENANCE.json'] = js(dict(result, baseline_runtime_sha256=RC14_SHA,
        baseline_sources_sha256=SOURCE_SHA, unchanged_runtime_files=unchanged,
        fpga_source_revision=m['fpga_source_revision'], renderer_recipe='Release LTO/PGO with original 79 training files',
        static_timing_closed=False, published=False))
    source['LICENSE.txt'] = (ROOT/'LICENSE.txt').read_bytes()
    for n,b in source.items(): common.content_audit(n,b)
    source['SHA256SUMS'] = packaging.checksums(source)
    out.mkdir(parents=True,exist_ok=True)
    archive = out/('NDS4MiSTer_'+VERSION+'_Standalone.zip')
    source_archive = out/m['source_download']
    packaging.write_zip(archive,files,modes)
    packaging.write_zip(source_archive,source)
    audit(common.read_zip(archive)[0])
    result.update(archive=archive.name,sha256=sha(archive.read_bytes()),bytes=archive.stat().st_size,
                  source_archive=source_archive.name,source_sha256=sha(source_archive.read_bytes()),
                  unchanged_runtime_files=unchanged,published=False)
    (out/'PACKAGE_VALIDATION.json').write_bytes(js(result))
    (out/'README.txt').write_bytes(files['README.txt'])
    return result

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--rc14',type=Path);ap.add_argument('--sources',type=Path)
    ap.add_argument('--out',type=Path);ap.add_argument('--audit',type=Path)
    a=ap.parse_args()
    print(json.dumps(audit(common.read_zip(a.audit)[0]) if a.audit else build(a.rc14,a.sources,a.out),indent=2))
if __name__=='__main__': main()
