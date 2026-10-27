#!/usr/bin/env python3
"""Make an H.264/AAC convenience copy; retain the PCM MOV for sound review."""
import argparse
import hashlib
import json
from pathlib import Path
import av


def video_digest(path):
    digest, packets = hashlib.sha256(), 0
    with av.open(str(path)) as container:
        stream = container.streams.video[0]
        for packet in container.demux(stream):
            if packet.size:
                digest.update(bytes(packet))
                packets += 1
    return digest.hexdigest(), packets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('Output exists')
    with av.open(str(args.source)) as source:
        with av.open(str(args.output), 'w', options={'movflags': '+faststart'}) as output:
            output.metadata.update(source.metadata)
            output.metadata['comment'] = 'Convenience copy with AAC audio. Use the original PCM MOV for lossless sound comparison. Not native MiSTer performance.'
            video = output.add_stream_from_template(source.streams.video[0])
            audio = output.add_stream('aac', rate=48000)
            audio.layout, audio.bit_rate = 'stereo', 320000
            for packet in source.demux():
                if packet.stream.type == 'video' and packet.dts is not None:
                    packet.stream = video
                    output.mux(packet)
                elif packet.stream.type == 'audio':
                    for frame in packet.decode():
                        for encoded in audio.encode(frame):
                            output.mux(encoded)
            for encoded in audio.encode():
                output.mux(encoded)
    before, after = video_digest(args.source), video_digest(args.output)
    if before != after:
        raise ValueError('Encoded video changed during remux')
    with av.open(str(args.output)) as output:
        audio = output.streams.audio[0]
        result = dict(state='completed_convenience_copy', source=str(args.source),
                      output=str(args.output), encoded_video_unchanged=True,
                      video_packet_sha256=after[0], video_packets=after[1],
                      audio_codec=audio.codec_context.name, audio_is_lossy=True,
                      duration_seconds=output.duration / av.time_base,
                      output_sha256=hashlib.sha256(args.output.read_bytes()).hexdigest())
    with args.output.with_suffix('.mp4.json').open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
