#!/usr/bin/env python3
"""Real engine probe on a user-supplied file. Never inserts fixture results in the app."""
import argparse, hashlib, json, pathlib, subprocess, time, uuid, datetime, os
p = argparse.ArgumentParser()
p.add_argument('audio', type=pathlib.Path)
p.add_argument('--worker', type=pathlib.Path, required=True)
p.add_argument('--models', type=pathlib.Path, default=pathlib.Path('Assets/models'))
p.add_argument('--tools', type=pathlib.Path, default=pathlib.Path('Assets/tools'))
p.add_argument('--output', type=pathlib.Path, default=pathlib.Path('TestResults/smoke'))
p.add_argument('--stages', default='preparingAudio,transcribing,diarizing,summarizing')
p.add_argument('--resume', type=pathlib.Path)
p.add_argument('--trace', action='store_true', help='Write model output only for technical-probe records')
args = p.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
source = args.audio.resolve(); tools = args.tools.resolve()
probe = json.loads(subprocess.check_output([str(tools/'ffprobe'), '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(source)]))
audio = next(s for s in probe['streams'] if s['codec_type'] == 'audio')
duration = float(probe['format']['duration'])
assert 0 < duration <= 10800
if args.resume:
    folder = args.resume.resolve()
    manifest = json.loads((folder/'manifest.json').read_text())
    recording = manifest['id']; runid = manifest['pendingRunId']; run = folder/'runs'/runid
    duration = manifest['durationMs']/1000
else:
    recording, runid = str(uuid.uuid4()), str(uuid.uuid4())
    folder = args.output.resolve()/recording
    (folder/'source').mkdir(parents=True)
    original = folder/'source'/('original'+source.suffix)
    import shutil
    shutil.copyfile(source, original)
    digest = hashlib.file_digest(original.open('rb'), 'sha256').hexdigest()
    now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
    manifest = dict(schemaVersion=1, id=recording, sourceType='technical-probe', displayTitle='Technical probe', createdAt=now,
     originalFilename=source.name, originalRelativePath=str(original.relative_to(folder)), sha256=digest, durationMs=round(duration*1000),
     sampleRate=float(audio['sample_rate']), channels=audio['channels'], sourceComplete=True, state='queued', pendingRunId=runid, warnings=[])
    (folder/'manifest.json').write_text(json.dumps(manifest))
    run = folder/'runs'/runid; run.mkdir(parents=True)
    catalog = json.loads(pathlib.Path('Resources/models.lock.json').read_text())
    profile = hashlib.sha256(':'.join(m['revision'] for m in catalog['models']).encode()).hexdigest()
    (run/'run.json').write_text(json.dumps(dict(schemaVersion=1,id=runid,sourceHash=digest,profileHash=profile,pipelineVersion='1.0.0-audio2-asr3-summary10',createdAt=now)))
results = []
for stage in args.stages.split(','):
    command = dict(version=1, jobId=recording, runId=runid, stage=stage, recordingPath=str(folder), modelsPath=str(args.models.resolve()), toolsPath=str(tools))
    start = time.monotonic()
    with ((run/(stage+'.stderr')) if args.trace else pathlib.Path(os.devnull)).open('w') as err:
        child = subprocess.Popen([str(args.worker.resolve())] + (['--trace-model-output'] if args.trace else []), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True)
        child.stdin.write(json.dumps(command)+'\n'); child.stdin.flush()
        events = []
        for line in child.stdout:
            event = json.loads(line); events.append(event)
            print(stage, event['type'], event.get('message',''), flush=True)
        code = child.wait(); child.stdin.close()
    results.append(dict(stage=stage,seconds=time.monotonic()-start,exitCode=code,events=events))
    (args.output/'latest.json').write_text(json.dumps(dict(recordingPath=str(folder),audioDuration=duration,stages=results), indent=2))
    if code != 0: raise SystemExit(code)
print('Completed:', run, flush=True)
