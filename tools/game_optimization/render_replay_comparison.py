#!/usr/bin/env python3
"""Create a labeled replay comparison with separate, unmodified audio passes."""
import argparse
import csv
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import subprocess

import av
import numpy as np
from PIL import Image, ImageDraw, ImageFont


def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def require(value, message):
    if not value:
        raise ValueError(message)


class Capture:
    def __init__(self, path, verifier):
        self.path = Path(path)
        status = json.loads(self.path.with_name(self.path.name + '_STATUS.json').read_text())
        self.status = status
        require(status['state'] in ['passed_replay_equivalence', 'rejected_replay_mismatch'],
                'Capture did not finish its recorded comparison')
        for name in ['video_frames.bgra', 'video_frames.csv', 'frames.csv', 'audio.s16le']:
            require(sha(self.path / name) == status['outputs'][name], 'Capture digest differs: ' + name)
        subprocess.run([str(verifier), str(self.path / 'video_frames.bgra'),
                        str(self.path / 'video_frames.csv')], check=True)
        all_frames = list(csv.DictReader((self.path / 'frames.csv').open()))
        offsets, offset = [], 0
        for number, row in enumerate(all_frames):
            require(int(row['frame']) == number, 'Noncontiguous replay frames')
            offsets.append(offset)
            offset += int(row['audio_samples'])
        require((self.path / 'audio.s16le').stat().st_size == offset * 4,
                'Audio sample accounting differs')
        self.index = {}
        rows = list(csv.DictReader((self.path / 'video_frames.csv').open()))
        for number, row in enumerate(rows):
            frame = int(row['frame'])
            require(frame not in self.index and frame < len(all_frames), 'Invalid captured frame')
            require(int(row['first_audio_sample']) == offsets[frame], 'Audio offset differs')
            require(all(row[key] == all_frames[frame][key]
                        for key in ['audio_samples', 'hash_top', 'hash_bottom']),
                    'Video index differs from replay log')
            self.index[frame] = (number, int(row['first_audio_sample']), int(row['audio_samples']))
        self.frames = np.memmap(self.path / 'video_frames.bgra', dtype=np.uint8,
                                mode='r', shape=(len(rows), 384, 256, 4))
        self.audio = np.memmap(self.path / 'audio.s16le', dtype='<i2', mode='r').reshape(-1, 2)

    def pixels(self, frame):
        return Image.frombytes('RGBA', (256, 384), self.frames[self.index[frame][0]].tobytes(),
                               'raw', 'BGRA').convert('RGB').resize((512, 768), Image.Resampling.NEAREST)

    def sound(self, frame):
        _, start, count = self.index[frame]
        return self.audio[start:start + count]


def render(spec, output, verifier):
    require(not output.exists(), 'Output already exists')
    captures = {name: Capture(path, verifier) for name, path in spec['captures'].items()}
    clips = spec['clips']
    rate = 48000
    total_frames = 2 * sum(clip['last'] - clip['first'] for clip in clips)
    total_samples = sum(sum(captures[clip[arm]].index[n][2]
                            for n in range(clip['first'], clip['last']))
                        for clip in clips for arm in ['control', 'candidate'])
    regular = ImageFont.truetype(spec['font_regular'], 20)
    small = ImageFont.truetype(spec['font_regular'], 18)
    bold = ImageFont.truetype(spec['font_bold'], 28)
    output.parent.mkdir(parents=True, exist_ok=True)
    container = av.open(str(output), 'w', format='mov', options={'movflags': '+faststart'})
    container.metadata['title'] = spec['title']
    container.metadata['comment'] = 'Deterministic software replay; not native MiSTer performance. Stereo PCM audio is unchanged.'
    video = container.add_stream('libx264', rate=Fraction(rate * total_frames, total_samples))
    video.width, video.height, video.pix_fmt = 1088, 960, 'yuv420p'
    video.time_base = video.codec_context.time_base = Fraction(1, rate)
    video.options = {'crf': '10', 'preset': 'veryfast', 'bf': '0', 'threads': '4'}
    sound = container.add_stream('pcm_s16le', rate=rate)
    sound.layout = 'stereo'
    sound.time_base = Fraction(1, rate)
    position = 0
    expected_sound = hashlib.sha256()
    presentation_samples = []
    chapters = []
    for clip_number, clip in enumerate(clips, 1):
        control, candidate = captures[clip['control']], captures[clip['candidate']]
        require(control.status['mode'] == 'off' and candidate.status['mode'] == 'on' and
                control.status['job'] == candidate.status['job'] and
                control.status['oracle_sha256'] == candidate.status['oracle_sha256'] and
                control.status['virtual_image_sha256'] != candidate.status['virtual_image_sha256'],
                'Control/candidate identity, replay or oracle pairing differs')
        for arm in ['control', 'candidate']:
            active = control if arm == 'control' else candidate
            chapters.append(dict(scene=clip['label'], audio=arm, start_sample=position,
                                 first_frame=clip['first'], last_frame_exclusive=clip['last']))
            canvas = Image.new('RGB', (1088, 960), '#101820')
            draw = ImageDraw.Draw(canvas)
            draw.text((16, 12), spec['title'], font=bold, fill='white')
            audio_label = 'CONTROL' if arm == 'control' else 'PATCHED'
            draw.text((16, 52), 'Replay comparison  |  AUDIO: ' + audio_label +
                      '  |  Not a MiSTer speed test', font=regular, fill='#a6e7c6')
            draw.text((16, 88), spec['control_label'], font=regular, fill='white')
            draw.text((560, 88), spec['candidate_label'], font=regular, fill='white')
            draw.text((16, 914), str(clip_number) + '/' + str(len(clips)) + '  ' + clip['label'],
                      font=regular, fill='white')
            draw.text((16, 940), 'Each scene repeats once: control audio, then patched audio. No mixing or volume changes.',
                      font=small, fill='#bdc9d4')
            x = 16 if arm == 'control' else 560
            draw.rectangle((x-4,116,x+515,900), outline='#63e6ad', width=3)
            for number in range(clip['first'], clip['last']):
                frame_image = canvas.copy()
                for capture, x in [(control, 16), (candidate, 560)]:
                    pixels = capture.pixels(number)
                    frame_image.paste(pixels.crop((0, 0, 512, 384)), (x, 120))
                    frame_image.paste(pixels.crop((0, 384, 512, 768)), (x, 512))
                samples = np.ascontiguousarray(active.sound(number))
                expected_sound.update(samples.tobytes())
                presentation_samples.append(position)
                frame = av.VideoFrame.from_image(frame_image)
                frame.pts, frame.time_base, frame.duration = position, Fraction(1, rate), len(samples)
                for packet in video.encode(frame):
                    container.mux(packet)
                audio = av.AudioFrame.from_ndarray(samples.reshape(1, -1), format='s16', layout='stereo')
                audio.sample_rate, audio.pts, audio.time_base = rate, position, Fraction(1, rate)
                for packet in sound.encode(audio):
                    container.mux(packet)
                position += len(samples)
            chapters[-1]['end_sample'] = position
            print(json.dumps(chapters[-1]), flush=True)
    for stream in [video, sound]:
        for packet in stream.encode():
            container.mux(packet)
    container.close()
    require(position == total_samples, 'Rendered sample count differs')
    decoded_sound, decoded_samples = hashlib.sha256(), 0
    with av.open(str(output)) as container:
        for frame in container.decode(audio=0):
            data = frame.to_ndarray()
            require(frame.format.name == 's16' and frame.layout.name == 'stereo', 'Unexpected PCM output format')
            decoded_sound.update(data.tobytes())
            decoded_samples += frame.samples
    require(decoded_samples == total_samples and decoded_sound.digest() == expected_sound.digest(),
            'Rendered PCM differs from original replay audio')
    with av.open(str(output)) as container:
        decoded_frames = 0
        for frame in container.decode(video=0):
            require(decoded_frames < len(presentation_samples) and
                    frame.pts * frame.time_base == Fraction(presentation_samples[decoded_frames], rate),
                    'Rendered frame presentation time differs from original audio clock')
            decoded_frames += 1
    require(decoded_frames == total_frames, 'Rendered video frame count differs')
    return dict(state='rendered_and_verified', output=str(output), output_sha256=sha(output),
                frames=total_frames, stereo_samples=total_samples, duration_seconds=total_samples/rate,
                original_PCM_sha256=expected_sound.hexdigest(), decoded_PCM_exact=True,
                raw_frame_hashes_verified=True, presentation_times_exact=True, chapters=chapters,
                capture_status_pins={name: sha(capture.path.with_name(capture.path.name + '_STATUS.json'))
                                     for name, capture in captures.items()},
                limitations='H.264 picture is compressed after exact2x nearest-neighbor scaling. '
                            'Original full-resolution BGRA captures are retained. Audio in this MOV '
                            'is original16-bit stereo PCM, with no gain, filtering, resampling or mixing. '
                            'No native performance conclusion or patch acceptance.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--verifier', type=Path, required=True)
    args = parser.parse_args()
    result = render(json.loads(args.manifest.read_text()), args.output, args.verifier)
    result['pins'] = {str(path): sha(path) for path in [args.manifest, args.verifier, Path(__file__)]}
    receipt = args.output.with_suffix('.json')
    with receipt.open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps({key: result[key] for key in ['state', 'output', 'duration_seconds']}))


if __name__ == '__main__':
    main()
