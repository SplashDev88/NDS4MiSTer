#!/usr/bin/env python3
"""Make an H.264/AAC convenience copy; retain the PCM MOV for sound review."""
import argparse
import hashlib
import json
from pathlib import Path
import av


def packet_digest(path, kind='video', index=0):
    digest, packets = hashlib.sha256(), 0
    with av.open(str(path)) as container:
        stream = getattr(container.streams, kind)[index]
        for packet in container.demux(stream):
            if packet.size:
                digest.update(bytes(packet))
                packets += 1
    return digest.hexdigest(), packets


def video_digest(path):
    return packet_digest(path)


def packet_timing(path, kind, index=0):
    with av.open(str(path)) as container:
        stream = getattr(container.streams, kind)[index]
        return [(packet.pts * packet.time_base if packet.pts is not None else None,
                 packet.dts * packet.time_base if packet.dts is not None else None,
                 packet.duration * packet.time_base)
                for packet in container.demux(stream) if packet.size]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--copy-audio-track', type=int,
                        help='Copy this zero-based audio track unchanged, for native recordings')
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('Output exists')
    with av.open(str(args.source)) as source:
        with av.open(str(args.output), 'w', options={'movflags': '+faststart'}) as output:
            output.metadata.update(source.metadata)
            copy_audio = args.copy_audio_track is not None
            output.metadata['comment'] = ('Original native capture video and selected audio packets, without speed or volume changes.' if copy_audio else
                'Convenience copy with AAC audio. Use the original PCM MOV for lossless sound comparison. Not native MiSTer performance.')
            video = output.add_stream_from_template(source.streams.video[0])
            video.time_base = source.streams.video[0].time_base
            if copy_audio:
                if not 0 <= args.copy_audio_track < len(source.streams.audio):
                    raise ValueError('Audio track is outside the source')
                selected = source.streams.audio[args.copy_audio_track]
                audio = output.add_stream_from_template(selected)
                audio.time_base = selected.time_base
            else:
                audio = output.add_stream('aac', rate=48000)
                audio.layout, audio.bit_rate = 'stereo', 320000
            for packet in source.demux():
                if packet.stream.type == 'video' and packet.dts is not None:
                    packet.stream = video
                    output.mux(packet)
                elif packet.stream.type == 'audio':
                    if copy_audio:
                        if packet.stream.index == selected.index and packet.dts is not None:
                            packet.stream = audio
                            output.mux(packet)
                    else:
                        for frame in packet.decode():
                            for encoded in audio.encode(frame):
                                output.mux(encoded)
            if not copy_audio:
                for encoded in audio.encode():
                    output.mux(encoded)
    before, after = video_digest(args.source), video_digest(args.output)
    if before != after:
        raise ValueError('Encoded video changed during remux')
    audio_digest = None
    if copy_audio:
        audio_digest = packet_digest(args.source, 'audio', args.copy_audio_track)
        if audio_digest != packet_digest(args.output, 'audio'):
            raise ValueError('Encoded audio changed during remux')
        for kind, index in [('video', 0), ('audio', args.copy_audio_track)]:
            if packet_timing(args.source, kind, index) != packet_timing(args.output, kind):
                raise ValueError('Packet timing changed during remux: ' + kind)
    with av.open(str(args.output)) as output:
        audio = output.streams.audio[0]
        result = dict(state='completed_convenience_copy', source=str(args.source),
                      output=str(args.output), encoded_video_unchanged=True,
                      video_packet_sha256=after[0], video_packets=after[1],
                      audio_codec=audio.codec_context.name, audio_is_lossy=True,
                      encoded_audio_unchanged=copy_audio,
                      packet_timestamps_verified=copy_audio,
                      source_audio_track=args.copy_audio_track,
                      audio_packet_digest=audio_digest,
                      duration_seconds=output.duration / av.time_base,
                      output_sha256=hashlib.sha256(args.output.read_bytes()).hexdigest())
    with args.output.with_suffix('.mp4.json').open('x') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
