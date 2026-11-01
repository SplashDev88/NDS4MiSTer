"""Measure retained replay timing offsets without rerunning or masking evidence.

Usage: python diagnose_replay_timing.py PLAN DIAGNOSTIC_SPEC
The spec supplies windows, audio windows, thumbnail frames and output suffix.
"""
from pathlib import Path
from datetime import datetime, timezone
import collections
import csv
import hashlib
import json
import sys
import numpy as np
from PIL import Image, ImageDraw

read = lambda p: json.loads(Path(p).read_text())
sha = lambda p: hashlib.sha256(Path(p).read_bytes()).hexdigest()
plan, spec = map(read, sys.argv[1:3])
P = Path(plan['directory'])
prefix = plan['prefix']
A, B = [P / (prefix + '_' + kind + '_V1') for kind in ['DELIVERY', 'CANDIDATE']]
rows = lambda p: list(csv.DictReader((p / 'frames.csv').open()))
a, b = rows(A), rows(B)
assert len(a) == len(b)
result = dict(state='reference_timing_diagnostics_pending_visual_review',
              utc=datetime.now(timezone.utc).isoformat(), windows={}, audio_windows=[])
for low, high in spec['windows']:
    assert 0 <= low < high <= len(a)
    result['windows'][f'{low}:{high}'] = window = {}
    for radius in spec['frame_radii']:
        assert 0 <= radius <= 120
        offsets = collections.Counter()
        unmatched = []
        for i in range(low, high):
            matches = [j - i for j in range(max(0, i-radius), min(len(a), i+radius+1))
                       if all(a[j][key] == b[i][key] for key in ['hash_top', 'hash_bottom'])]
            if matches:
                offsets[min(matches, key=lambda n: (abs(n), n))] += 1
            else:
                unmatched.append(i)
        window[str(radius)] = dict(matching_screen_pairs=sum(offsets.values()),
            offset_counts=dict(offsets), unmatched_count=len(unmatched), first_unmatched=unmatched[:15])
aa, bb = [np.memmap(folder / 'audio.s16le', dtype='<i2', mode='r').reshape(-1, 2)
          for folder in [A, B]]
radius, n = spec['audio_radius_samples'], spec['audio_window_samples']
assert 0 <= radius <= 48000 and 0 < n <= 262144
for start in spec['audio_starts']:
    assert radius <= start and start+n+radius <= min(len(aa), len(bb))
    x = aa[start:start+n, 0].astype(np.float64)
    y = bb[start-radius:start+n+radius, 0].astype(np.float64)
    fftn = 1 << ((len(x)+len(y)-2).bit_length())
    dot = np.fft.irfft(np.fft.rfft(y, fftn) * np.fft.rfft(x[::-1], fftn), fftn)[n-1:len(y)]
    c = np.r_[0, np.cumsum(y*y)]
    mse = (np.sum(x*x) + c[n:] - c[:-n] - 2*dot) / n
    lag = int(np.argmin(mse)) - radius
    delta = aa[start:start+n].astype(np.int32) - bb[start+lag:start+lag+n].astype(np.int32)
    result['audio_windows'].append(dict(start_stereo_sample=start, stereo_samples=n,
        candidate_offset_samples=lag, shifted_rms_signed16=float(np.sqrt(np.mean(delta.astype(np.float64)**2))),
        shifted_max_delta=int(np.max(np.abs(delta))),
        exact_stereo_samples=int(np.count_nonzero(np.all(delta == 0, axis=1)))))
frames = spec['thumbnail_frames']
assert frames and all(0 <= frame < len(a) for frame in frames)
im = Image.new('RGB', (128*len(frames), 432))
draw = ImageDraw.Draw(im)
for row, (label, folder) in enumerate([('control', A), ('candidate', B)]):
    with (folder / 'thumbs.rgb').open('rb') as f:
        for col, frame in enumerate(frames):
            f.seek(frame*64*96*3)
            picture = Image.frombytes('RGB', (64, 96), f.read(64*96*3), 'raw', 'BGR')
            im.paste(picture.resize((128, 192), Image.Resampling.NEAREST), (col*128, row*216+24))
            draw.text((col*128+2, row*216+3), label+' '+str(frame), fill='white')
suffix = spec['output_suffix']
assert suffix.replace('_', '').isalnum()
contact = P / (prefix + '_TIMING_THUMBNAILS_' + suffix + '.png')
output = P / (prefix + '_TIMING_DIAGNOSTIC_' + suffix + '.json')
assert not contact.exists() and not output.exists()
im.save(contact)
result.update(scope='Diagnostic temporal offsets only. No raw hashes or output modified; does not establish human imperceptibility.',
              contact=str(contact), contact_sha256=sha(contact),
              pins={str(Path(f)):sha(f) for f in sys.argv[1:3] + [__file__]})
with output.open('x') as f:
    json.dump(result, f, indent=2)
    f.write('\n')
print(output)
