#!/usr/bin/env python3
"""Correlate retained HPS timeline events by session and LCD frame.

InputLcd timestamps observe a record after packet acquisition, not its original
FPGA scanline time. Admission-to-ready includes raster waiting, 2D work and any
interleaved replay. These intervals are not isolated raster/2D CPU costs or FPS.
"""
import argparse
import collections
import json
import struct


def read_timeline(raw):
    magic, version, size, lanes, low, high = struct.unpack_from('<6I', raw)
    if (magic, version, size, lanes) != (0x314c5443, 1, 32, 3):
        raise ValueError('unsupported timeline header')
    offset, result = 24, []
    for ident in range(lanes):
        lane, published, overwritten, raced, count = struct.unpack_from('<5I', raw, offset)
        offset += 20
        capacity = 16384 if lane == 2 else 131072
        if lane != ident or count > capacity or count > published:
            raise ValueError('invalid lane header')
        records = []
        for _ in range(count):
            row = struct.unpack_from('<Q6I', raw, offset)
            offset += size
            records.append(dict(zip(('us', 'session', 'kind', 'sequence', 'frame', 'a', 'b'), row)))
        result.append(dict(lane=lane, published=published, overwritten=overwritten,
                           raced=raced, records=records))
    if offset != len(raw):
        raise ValueError('unexpected trailing bytes')
    return result, low | (high << 32)


def distribution(values):
    values = sorted(values)
    if not values:
        return None
    def percentile(p):
        x = (len(values) - 1) * p
        lo = int(x)
        return values[lo] + (values[min(lo + 1, len(values) - 1)] - values[lo]) * (x - lo)
    return dict(count=len(values), mean_us=sum(values) / len(values),
                p50_us=percentile(.5), p95_us=percentile(.95),
                p99_us=percentile(.99), max_us=values[-1])


def analyze(lanes, start_us=0, end_us=2**64-1):
    names = {10: 'admission', 11: 'ready', 12: 'upload_begin', 13: 'upload_end'}
    frames = collections.defaultdict(dict)
    metadata = []
    for lane in lanes:
        records = lane['records']
        metadata.append({**{k: v for k, v in lane.items() if k != 'records'},
                         'retained': len(records),
                         'retained_range_us': [records[0]['us'], records[-1]['us']] if records else None})
        for r in records:
            name = 'input_line0' if r['kind'] == 6 and r['a'] == 0 else names.get(r['kind'])
            if name is None:
                continue
            key = (r['session'], r['frame'])
            if name in frames[key]:
                raise ValueError(f'duplicate {name} for session/frame {key}')
            frames[key][name] = r
    metrics = collections.defaultdict(list)
    counts = collections.Counter()
    publication_gaps = []
    upload_durations = []
    last_upload = {}
    for r in lanes[2]['records']:
        if r['kind'] != 13 or not start_us <= r['us'] <= end_us:
            continue
        previous = last_upload.get(r['session'])
        if previous is not None:
            if r['us'] < previous:
                raise ValueError('non-monotonic publication lane')
            publication_gaps.append(r['us'] - previous)
        last_upload[r['session']] = r['us']
    for events in frames.values():
        begin, end = events.get('upload_begin'), events.get('upload_end')
        if begin is not None and end is not None:
            if end['us'] < begin['us'] or begin['sequence'] != end['sequence']:
                raise ValueError('invalid upload pair')
            if start_us <= begin['us'] <= end['us'] <= end_us:
                upload_durations.append(end['us'] - begin['us'])
        admission = events.get('admission')
        if admission is None or not start_us <= admission['us'] <= end_us:
            continue
        counts['lcd_admissions'] += 1
        if not admission['a']:
            counts['not_drawn'] += 1
            continue
        counts['drawn_admissions'] += 1
        if not all(n in events for n in ('input_line0', 'ready', 'upload_begin', 'upload_end')):
            counts['incomplete_chain'] += 1
            continue
        t = {name: r['us'] for name, r in events.items()}
        order = ('input_line0', 'admission', 'ready', 'upload_begin', 'upload_end')
        if any(t[b] < t[a] for a, b in zip(order, order[1:])):
            raise ValueError('non-monotonic frame chain')
        counts['complete_chains'] += 1
        for name, a, b in (
            ('input_to_admission', 'input_line0', 'admission'),
            ('admission_to_ready', 'admission', 'ready'),
            ('ready_to_upload', 'ready', 'upload_begin'),
            ('upload', 'upload_begin', 'upload_end'),
            ('input_to_uploaded', 'input_line0', 'upload_end'),
        ):
            metrics[name].append(t[b] - t[a])
    return dict(lanes=metadata, window_us=[start_us, end_us], counts=dict(counts),
                intervals={name: distribution(values) for name, values in metrics.items()},
                publication_spacing=distribution(publication_gaps),
                upload_duration=distribution(upload_durations),
                caveats=['HPS record observation is not FPGA VBlank time',
                         'Admission-to-ready combines rendering, waits and interleaved replay',
                         'Publication count is not unique displayed FPS'])


if __name__ == '__main__':
    from pathlib import Path
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('timeline', type=Path)
    ap.add_argument('--start-ns', type=int, default=0)
    ap.add_argument('--end-ns', type=int, default=(2**64-1)*1000)
    args = ap.parse_args()
    lanes, captured = read_timeline(args.timeline.read_bytes())
    print(json.dumps(dict(captured_us=captured,
                         **analyze(lanes, args.start_ns//1000, args.end_ns//1000)), indent=2))
