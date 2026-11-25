#!/usr/bin/env python3
"""Package original commercial-game HDMI captures with an offline zoom viewer."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import shutil
import struct
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    evidence = json.loads(args.evidence.read_text())
    assert evidence['status'] == 'passed' and evidence['core_sha256']
    assert not args.out.exists(), 'Choose a new output directory'
    rows = []
    for item in evidence['screenshot_files']:
        name = item['file']
        assert Path(name).name == name and name.endswith('.png')
        path = args.evidence.parent / name
        data = path.read_bytes()
        assert data[:8] == b'\x89PNG\r\n\x1a\n'
        width, height = struct.unpack('>II', data[16:24])
        assert width >= 1280 and height >= 720, 'Use HDMI captures, not pre-grid DS framebuffers'
        rows.append(dict(item, width=width, height=height,
                         sha256=hashlib.sha256(data).hexdigest()))
    assert len(rows) >= 8
    args.out.mkdir(parents=True)
    for row in rows:
        shutil.copy2(args.evidence.parent / row['file'], args.out / row['file'])
    template = Path(__file__).with_name('pixel_grid_screenshot_viewer.html').read_text()
    encoded = json.dumps(rows).replace('<', '\\u003c')
    page = template.replace('/* CAPTURE_DATA */ []', encoded)
    page = page.replace('CORE_DIGEST', html.escape(evidence['core_sha256']))
    (args.out / 'index.html').write_text(page)
    (args.out / 'CAPTURES.json').write_text(json.dumps(dict(
        core_sha256=evidence['core_sha256'], captures=rows,
        processing='Original OBS PNG files; no resampling, sharpening or generated pixels. Viewer zoom/rotation only.'), indent=2)+'\n')
    (args.out / 'README.txt').write_text(
        'Open index.html for zoom, rotation and strength comparison. All PNGs are original HDMI captures.\n'
        'The viewer enlarges pixels without smoothing. Open an original PNG in your image viewer for unrestricted zoom.\n'
        'These are captured video frames, not photographs of a physical LCD panel.\n')
    archive = args.out.parent / (args.out.name+'.zip')
    assert not archive.exists()
    with zipfile.ZipFile(archive, 'x', zipfile.ZIP_DEFLATED) as z:
        for path in sorted(args.out.iterdir()):
            z.write(path, args.out.name+'/'+path.name)
    print(json.dumps(dict(viewer=str(args.out/'index.html'),archive=str(archive),
                         captures=len(rows),sha256=hashlib.sha256(archive.read_bytes()).hexdigest()),indent=2))


if __name__ == '__main__':
    main()
