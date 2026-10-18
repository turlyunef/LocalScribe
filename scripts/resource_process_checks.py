#!/usr/bin/env python3
"""Controlled parent-death regression for worker process groups and signals."""
import argparse
import hashlib
import json
import os
import pathlib
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import uuid
import wave

parser = argparse.ArgumentParser(description='Verify real worker and media child exit when a dedicated test parent is killed. All fixtures are temporary; no models or user recordings are used.')
parser.add_argument('--worker', type=pathlib.Path, required=True)
parser.add_argument('--parent', type=pathlib.Path, help=argparse.SUPPRESS)
args = parser.parse_args()

if args.parent is not None:
    root = args.parent
    command = json.loads((root / 'command.json').read_text())
    worker = subprocess.Popen([str(args.worker.resolve())], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True)
    (root / 'worker.pid').write_text(str(worker.pid))
    worker.stdin.write(json.dumps(command) + '\n'); worker.stdin.flush()
    event = json.loads(worker.stdout.readline())
    assert event['type'] == 'started', event
    deadline = time.monotonic() + 10
    while not (root / 'child.pid').exists() and time.monotonic() < deadline:
        time.sleep(.01)
    child_pid = int((root / 'child.pid').read_text())
    print(json.dumps({'worker': worker.pid, 'child': child_pid}), flush=True)
    time.sleep(60)
    raise SystemExit('Probe parent was not killed')

def running(pid):
    value = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True, check=False)
    state = value.stdout.strip()
    return bool(state) and not state.startswith('Z')

worker_path = str(args.worker.resolve())
with tempfile.TemporaryDirectory(prefix='localscribe-process-', dir='/private/tmp') as temporary:
    root = pathlib.Path(temporary)
    recording = root / str(uuid.uuid4())
    source = recording / 'source/original.wav'; source.parent.mkdir(parents=True)
    with wave.open(str(source), 'wb') as output:
        output.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        output.writeframes(b'\0' * 32000)
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    run_id = str(uuid.uuid4()); run = recording / 'runs' / run_id; run.mkdir(parents=True)
    manifest = dict(schemaVersion=1, id=recording.name, sourceType='technical-probe',
                    displayTitle='Process cleanup probe', createdAt='2026-10-18T00:00:00Z',
                    originalFilename='original.wav', originalRelativePath='source/original.wav',
                    sha256=digest, durationMs=1000, sampleRate=16000, channels=1,
                    sourceComplete=True, state='preparingAudio', pendingRunId=run_id, warnings=[])
    (recording / 'manifest.json').write_text(json.dumps(manifest))
    (run / 'run.json').write_text(json.dumps(dict(schemaVersion=1, id=run_id, sourceHash=digest,
                                                 profileHash='resource-probe', pipelineVersion='process-probe',
                                                 createdAt='2026-10-18T00:00:00Z')))
    tools = root / 'tools'; tools.mkdir()
    probe_json = json.dumps(dict(streams=[dict(codec_type='audio', codec_name='pcm_s16le',
                                              sample_rate='16000', channels=1)], format=dict(duration='1')))
    scripts = {
        'ffprobe': "#!/bin/sh\nprintf '%s' " + shlex.quote(probe_json) + '\n',
        'ffmpeg': "#!/bin/sh\nprintf '%s' \"$$\" > " + shlex.quote(str(root / 'child.pid')) + '\nexec /bin/sleep 60\n',
    }
    for name, text in scripts.items():
        path = tools / name; path.write_text(text); path.chmod(0o700)
    (root / 'command.json').write_text(json.dumps(dict(version=1, jobId=recording.name, runId=run_id,
        stage='preparingAudio', recordingPath=str(recording), modelsPath=str(root / 'models'), toolsPath=str(tools))))
    parent = subprocess.Popen([sys.executable, __file__, '--worker', worker_path, '--parent', str(root)],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    ids = {}
    try:
        if not select.select([parent.stdout], [], [], 15)[0]:
            raise RuntimeError('Timed out waiting for worker and test child')
        ids = json.loads(parent.stdout.readline())
        assert all(running(pid) for pid in ids.values()), ids
        groups = {name: os.getpgid(pid) for name, pid in ids.items()}
        assert groups['worker'] == groups['child'], groups
        started = time.monotonic()
        os.kill(parent.pid, signal.SIGKILL); parent.wait(timeout=3)
        deadline = started + 5
        while any(running(pid) for pid in ids.values()) and time.monotonic() < deadline:
            time.sleep(.025)
        gone = {name: not running(pid) for name, pid in ids.items()}
        result = dict(parentSIGKILL=True, sharedProcessGroup=True, workerStopped=gone['worker'], childStopped=gone['child'],
                      seconds=round(time.monotonic() - started, 3),
                      scope='Built LocalScribeWorker and controlled sleeping media child; no models, user archive, microphone or network')
        print(json.dumps(result, indent=2))
        assert all(gone.values()), result
    finally:
        if parent.poll() is None:
            parent.kill(); parent.wait(timeout=3)
        for name in ('worker', 'child'):
            path = root / (name + '.pid')
            if path.exists():
                pid = int(path.read_text())
                if running(pid):
                    if name == 'worker':
                        try: os.killpg(pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                    try: os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError: pass
