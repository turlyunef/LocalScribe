#!/usr/bin/env python3
"""Exercise bundled decoders using Core Audio or existing local codec fixtures."""
import json
import pathlib
import shutil
import subprocess
import tempfile
import wave

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'Assets/probe/mixed.wav'
CASES = [
    ('audio.aac', 'adts', 'aac'),
    ('aac.m4a', 'm4af', 'aac'),
    ('alac.m4a', 'm4af', 'alac'),
    ('audio.flac', 'flac', 'flac'),
    ('vorbis.ogg', 'Oggf', 'vorb'),
    ('opus.ogg', 'Oggf', 'opus'),
    ('audio.opus', 'Oggf', 'opus'),
    ('audio.mp3', 'MPG3', '.mp3'),
]
EXISTING_FIXTURES = {
    'vorbis.ogg': 'sample-vorbis.ogg',
    'opus.ogg': 'sample-opus.ogg',
    'audio.opus': 'sample.opus',
    'audio.mp3': 'sample.mp3',
}


def check(directory, name, container, codec):
    target = directory / name
    decoded = directory / (name + '.wav')
    row = dict(file=name, passed=False)
    try:
        try:
            subprocess.run(['/usr/bin/afconvert', '-f', container, '-d', codec,
                            str(SOURCE), str(target)], check=True, capture_output=True, text=True)
            row['fixtureCreated'] = True
        except subprocess.CalledProcessError:
            # Core Audio does not encode every supported input codec. Reuse
            # developer fixtures if present, without downloading or changing them.
            existing = ROOT / 'Assets/format-fixtures' / EXISTING_FIXTURES.get(name, name)
            if not existing.is_file():
                raise
            shutil.copyfile(existing, target)
            row.update(fixtureCreated=False, fixtureSource=str(existing.relative_to(ROOT)))
        info = json.loads(subprocess.check_output([
            str(ROOT / 'Assets/tools/ffprobe'), '-v', 'error',
            '-protocol_whitelist', 'file,pipe', '-show_streams', '-show_format',
            '-of', 'json', str(target)], text=True, stderr=subprocess.PIPE))
        audio = info['streams'][0]
        duration = float(info['format']['duration'])
        row.update(codec=audio['codec_name'], estimatedDuration=duration)
        if info['format']['format_name'] == 'aac':
            # Match Media.probe: ADTS duration must use packets, not bitrate.
            packets = subprocess.check_output([
                str(ROOT / 'Assets/tools/ffprobe'), '-v', 'error',
                '-protocol_whitelist', 'file,pipe', '-select_streams', 'a:0',
                '-read_intervals', '%10801', '-show_entries', 'packet=duration',
                '-of', 'csv=p=0', str(target)], text=True, stderr=subprocess.PIPE)
            numerator, denominator = map(int, audio['time_base'].split('/'))
            ticks = [int(value) for value in packets.splitlines()]
            if not ticks or any(value <= 0 for value in ticks):
                raise ValueError('Missing AAC packet durations')
            duration = sum(ticks) * numerator / denominator
        subprocess.run([
            str(ROOT / 'Assets/tools/ffmpeg'), '-nostdin', '-n', '-v', 'error',
            '-protocol_whitelist', 'file,pipe', '-i', str(target), '-map', '0:a:0',
            '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', str(decoded)],
            check=True, capture_output=True, text=True)
        with wave.open(str(decoded)) as output:
            decoded_duration = output.getnframes() / output.getframerate()
            row.update(duration=duration, decodedDuration=decoded_duration,
                       frames=output.getnframes(), sampleRate=output.getframerate(),
                       channels=output.getnchannels(), sampleBytes=output.getsampwidth())
        row['passed'] = (0 < duration <= 10800 and abs(decoded_duration - duration) < 0.15
                         and row['sampleRate'] == 16000 and row['channels'] == 1
                         and row['sampleBytes'] == 2 and row['frames'] > 0)
    except subprocess.CalledProcessError as error:
        row['error'] = (error.stderr or '').strip()
    except (ValueError, KeyError, wave.Error) as error:
        row['error'] = str(error)
    return row


def main():
    with tempfile.TemporaryDirectory(prefix='localscribe-formats-') as temporary:
        results = [check(pathlib.Path(temporary), *case) for case in CASES]
    report = ROOT / 'TestResults/format-checks.json'
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(results, indent=2, ensure_ascii=False))
    print(json.dumps(results, indent=2, ensure_ascii=False))
    return 0 if all(row['passed'] for row in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
