#!/usr/bin/env python3
"""Codec-only tests from FFmpeg's public sample corpus. Samples are not distributed."""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import urllib.request
import wave

ROOT = Path(__file__).resolve().parents[1]
BASE_URL = "https://samples.ffmpeg.org/A-codecs/"
SAMPLES = (
    ("sample.mp3", "MP3/ascii.mp3", 319488,
     "7c72e328ad3fe508ba244d8a20bac3d2c646ceca42341dcb7dc4fbf7bb3badeb"),
    ("sample-vorbis.ogg", "vorbis/Lumme-Badloop.ogg", 5856908,
     "ebecc57582463db3346625c1da4a51c594b6a3ec2dbebf9d94c2b9b5f1e72f44"),
    ("sample-opus.ogg", "opus/testvector12.ogg", 48232,
     "411f7a6108c72d32116143903e4042a3ea836a8e2b40a753c2ddcb836c9083fc"),
)


def verified_sample(target, url, size, digest):
    if target.is_file() and target.stat().st_size == size:
        with target.open("rb") as cached:
            data = cached.read(size + 1)
        if len(data) == size and hashlib.sha256(data).hexdigest() == digest:
            return data
    with urllib.request.urlopen(url, timeout=120) as response:
        data = response.read(size + 1)
    if len(data) != size or hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f"Size or SHA-256 mismatch for {target.name}")
    atomic_write(target, data)
    return data


def atomic_write(target, data):
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as temporary:
        path = Path(temporary.name)
        try:
            temporary.write(data)
            temporary.close()
            path.replace(target)
        finally:
            path.unlink(missing_ok=True)


def check_codec(source, url, digest):
    tools = ROOT / "Assets/tools"
    probe = subprocess.run([
        str(tools / "ffprobe"), "-v", "error", "-protocol_whitelist", "file,pipe",
        "-show_streams", "-show_format", "-of", "json", str(source),
    ], capture_output=True, text=True)
    decoded = source.with_name(source.name + ".wav")
    decoded.unlink(missing_ok=True)
    decode = subprocess.run([
        str(tools / "ffmpeg"), "-nostdin", "-n", "-v", "error",
        "-protocol_whitelist", "file,pipe", "-i", str(source), "-map", "0:a:0",
        "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(decoded),
    ], capture_output=True, text=True)
    row = dict(file=source.name, url=url, sha256=digest, probeExit=probe.returncode, decodeExit=decode.returncode)
    if probe.returncode == 0:
        info = json.loads(probe.stdout)
        row["codec"] = info["streams"][0]["codec_name"]
        row["duration"] = info["format"].get("duration")
    if decode.returncode:
        row["error"] = decode.stderr
    else:
        with wave.open(str(decoded), "rb") as audio:
            row["decodedDuration"] = audio.getnframes() / audio.getframerate()
    return row


def main():
    fixtures = ROOT / "Assets/format-fixtures"
    fixtures.mkdir(parents=True, exist_ok=True)
    results = []
    for name, relative_url, size, digest in SAMPLES:
        url = BASE_URL + relative_url
        target = fixtures / name
        data = verified_sample(target, url, size, digest)
        results.append(check_codec(target, url, digest))
        if name == "sample-opus.ogg":
            other = fixtures / "sample.opus"
            atomic_write(other, data)
            results.append(check_codec(other, url, digest))
    report = ROOT / "TestResults/external-codec-checks.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    result_json = json.dumps(results, indent=2)
    atomic_write(report, (result_json + "\n").encode())
    print(result_json)
    return int(any(row["probeExit"] or row["decodeExit"] for row in results))


if __name__ == "__main__":
    raise SystemExit(main())
