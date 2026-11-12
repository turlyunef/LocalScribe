#!/usr/bin/env python3
"""Explicit technical probe: local synthetic audio and models, no user archive."""
import pathlib, subprocess, json, uuid, hashlib, time, selectors, wave, re
repo = pathlib.Path(__file__).resolve().parents[1]
base = repo / 'TestResults' / ('live-capture-' + str(uuid.uuid4()))
job = str(uuid.uuid4()).upper(); runid = str(uuid.uuid4()).upper()
recording = base / job; run = recording / 'runs' / runid
capture = recording / 'capture'; capture.mkdir(parents=True); run.mkdir(parents=True)
tools = base / 'Resources' / 'tools'
tools.mkdir(parents=True)
(tools.parent / 'models.lock.json').write_bytes((repo / 'Resources/models.lock.json').read_bytes())
for name in ['ffmpeg', 'ffprobe']:
    (tools / name).symlink_to(repo / 'Assets/tools' / name)
catalog = json.loads((tools.parent / 'models.lock.json').read_text())
# Preserve ModelRole order and the fingerprint of the original four profiles.
profile_hash = hashlib.sha256(':'.join(next(m['revision'] for m in catalog['models'] if m['id'] == role)
                                     for role in ['asr', 'diarization', 'summary', 'tokenizer']).encode()).hexdigest()
binary_dir = subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=repo, text=True).strip()
worker = pathlib.Path(binary_dir) / 'LocalScribeWorker'
def write(path, data):
    tmp = path.with_suffix('.tmp'); tmp.write_text(json.dumps(data)); tmp.replace(path)
def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()
pipeline_version = re.search(r'public var pipelineVersion = "([^"]+)"', (repo/'Sources/LocalScribeCore/Contracts.swift').read_text()).group(1)
info = dict(schemaVersion=1, id=runid, sourceHash='capture:' + runid, profileHash=profile_hash, pipelineVersion=pipeline_version, createdAt='2026-10-18T00:00:00Z', liveCapture=True, modelIDs=dict(asr='asr', tokenizer='tokenizer', diarization='diarization', summary='summary'))
fingerprint = hashlib.sha256((info['sourceHash']+info['profileHash']+info['pipelineVersion']).encode()).hexdigest()
manifest = dict(schemaVersion=1, id=job, sourceType='technical-probe', displayTitle='Live technical fixture', createdAt='2026-10-18T00:00:00Z', originalFilename='original.caf', originalRelativePath='source/original.caf', sha256='', durationMs=0, sampleRate=16000, channels=1, sourceComplete=False, state='recording', pendingRunId=runid, warnings=[], captureProcessing='transcribing')
write(run/'run.json', info); write(run/'capture-run.json',info); write(recording/'manifest.json',manifest)
command=dict(version=1, jobId=job, runId=runid, stage='transcribing', recordingPath=str(recording), modelsPath=str(repo/'Assets/probe-models'), toolsPath=str(tools), liveCapture=True)
with wave.open(str(repo/'Assets/probe/mixed.wav')) as source:
    assert source.getnchannels()==1 and source.getsampwidth()==2 and source.getframerate()==16000
    pcm=source.readframes(source.getnframes())
pcm += bytes(642000*2-len(pcm))
def caf(path, start, frames):
    wav=base/'convert.wav'
    with wave.open(str(wav),'wb') as output:
        output.setnchannels(1); output.setsampwidth(2); output.setframerate(16000)
        output.writeframes(pcm[start*2:(start+frames)*2])
    subprocess.run(['/usr/bin/afconvert','-f','caff','-d','LEF32',str(wav),str(path)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
for index in range(4):
    partial=capture/f'part-{index:06d}.partial.caf'; closed=capture/f'part-{index:06d}.caf'
    caf(partial,index*160000,160000); partial.replace(closed)
def launch():
    p=subprocess.Popen([str(worker)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,bufsize=1)
    p.stdin.write(json.dumps(command)+'\n'); p.stdin.flush()
    return p
def read_until(p, wanted, timeout=240):
    events=[]; started=time.monotonic(); sel=selectors.DefaultSelector(); sel.register(p.stdout,selectors.EVENT_READ)
    while time.monotonic()-started < timeout:
        if sel.select(1):
            line=p.stdout.readline()
            if not line: raise RuntimeError('worker exited '+str(p.poll())+' events='+str([(e['type'],e.get('message','')) for e in events]))
            event=json.loads(line); events.append(event)
            if event['type']=='failed': raise RuntimeError(event['message'])
            if event['type']==wanted: return events
        if p.poll() is not None: raise RuntimeError('worker exit '+str(p.returncode))
    p.stdin.close(); p.wait(timeout=10); raise RuntimeError('probe timeout')
p=launch(); events1=read_until(p,'checkpoint')
assert not json.loads((recording/'manifest.json').read_text())['sourceComplete']
checkpoint=run/'live/part-0.json'; checkpoint_hash=digest(checkpoint)
p.stdin.close(); p.wait(timeout=10)
assert p.returncode==72, p.returncode
# Closing the last short file and publishing a seal is the explicit end-of-stream.
caf(capture/'part-000004.caf',640000,2000)
(recording/'source').mkdir()
original=recording/'source/original.caf'
caf(original,0,642000)
fragments=[]
for i,path in enumerate(sorted(capture.glob('*.caf'))):
    fragments.append(dict(index=i,frames=160000 if i<4 else 2000,sampleRate=16000,sha256=digest(path)))
manifest.update(sourceComplete=True,sha256=digest(original),durationMs=40125,state='recorded')
write(recording/'manifest.json',manifest)
write(run/'capture-seal.json',dict(schemaVersion=1,runID=runid,captureFingerprint=fingerprint,sourceHash=manifest['sha256'],fragments=fragments))
p=launch(); events2=read_until(p,'completed'); p.wait(timeout=10)
assert p.returncode==0
assert digest(checkpoint)==checkpoint_hash
parts=[json.loads(path.read_text()) for path in sorted((run/'live').glob('*.json'))]
assert [(x['part']['startMs'],x['part']['endMs']) for x in parts]==[(0,30000),(30000,40125)]
metrics=json.loads((run/'metrics-asr.json').read_text())
assert metrics['status']=='completed' and metrics['liveCapture'] is True
assert metrics['checkpointHits']==1 and metrics['checkpointAudioMs']==30000
# The first-pause policy splits a silent tail into several short cores.
# Check complete tail coverage and silence, not the historical late-pause count.
assert metrics['plannedWindows']['totalMs']==40125-30000
assert metrics['plannedWindows']['count']>=1
assert metrics['silentWindows']==metrics['plannedWindows']['count']
assert metrics['primary']['inputs']['count']==0, 'The resumed silent tail must not decode the cached speech again'
result=dict(status='passed',recordingPath=str(recording),runPath=str(run),firstCheckpointBeforeStop=True,resumedCheckpointUnchanged=True,tailEndMs=parts[-1]['part']['endMs'],firstRunEvents=[e['type'] for e in events1],resumeEvents=[e['type'] for e in events2],segments=len(json.loads((run/'live-transcript.json').read_text())['segments']),metricsStatus=metrics['status'],checkpointHits=metrics['checkpointHits'],newWindowCount=metrics['plannedWindows']['count'],newPrimaryCalls=metrics['primary']['inputs']['count'])
write(base/'probe-result.json',result)
print(json.dumps(result))
