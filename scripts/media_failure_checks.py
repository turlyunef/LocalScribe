#!/usr/bin/env python3
"""Real preparingAudio failures and stereo phase handling, with technical audio only."""
import hashlib, json, math, pathlib, struct, subprocess, uuid, wave
root = pathlib.Path(__file__).resolve().parents[1]
output = root/'TestResults/media-failures'; output.mkdir(parents=True, exist_ok=True)
worker = root/'.build/out/Products/Release/LocalScribeWorker'
rows = []
for case in ('damaged', 'over-three-hours', 'antiphase'):
    folder = output/str(uuid.uuid4()); (folder/'source').mkdir(parents=True)
    source = folder/'source/original.wav'
    if case == 'damaged':
        source.write_bytes(b'This is not an audio container')
    elif case == 'over-three-hours':
        frames = 10800*16000+16
        size = frames*2
        with source.open('wb') as stream:
            stream.write(struct.pack('<4sI4s4sIHHIIHH4sI',b'RIFF',size+36,b'WAVE',b'fmt ',16,1,1,16000,32000,2,16,b'data',size))
            stream.truncate(size+44)  # sparse zeros; only checks container duration
    else:
        with wave.open(str(source),'wb') as stream:
            stream.setparams((2,2,16000,0,'NONE','not compressed'))
            stream.writeframes(b''.join(struct.pack('<hh',v,-v) for i in range(32000) for v in [int(12000*math.sin(2*math.pi*440*i/16000))]))
    digest = hashlib.file_digest(source.open('rb'),'sha256').hexdigest()
    job, runid = folder.name,str(uuid.uuid4()); run = folder/'runs'/runid; run.mkdir(parents=True)
    date='2026-10-16T00:00:00Z'
    # Deliberately plausible metadata: the actual media validator must check the file.
    manifest=dict(schemaVersion=1,id=job,sourceType='technical-probe',displayTitle=case,createdAt=date,
                  originalFilename='original.wav',originalRelativePath='source/original.wav',sha256=digest,
                  durationMs=2000,sampleRate=16000,channels=2 if case=='antiphase' else 1,
                  sourceComplete=True,state='queued',pendingRunId=runid,warnings=[])
    (folder/'manifest.json').write_text(json.dumps(manifest))
    (run/'run.json').write_text(json.dumps(dict(schemaVersion=1,id=runid,sourceHash=digest,
                                              profileHash='media-validation-only',pipelineVersion='media-check',createdAt=date)))
    command=dict(version=1,jobId=job,runId=runid,stage='preparingAudio',recordingPath=str(folder),
                 modelsPath=str(root/'Assets/models'),toolsPath=str(root/'Assets/tools'))
    child=subprocess.Popen([str(worker)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
    child.stdin.write(json.dumps(command)+'\n'); child.stdin.flush()
    events=[json.loads(line) for line in child.stdout]; child.wait(timeout=10); child.stdin.close()
    unchanged=hashlib.file_digest(source.open('rb'),'sha256').hexdigest()==digest
    if case=='antiphase':
        with wave.open(str(run/'work/audio.wav'),'rb') as stream:
            pcm=stream.readframes(stream.getnframes())
        peak=max(abs(v[0]) for v in struct.iter_unpack('<h',pcm))
        assert child.returncode==0 and any(e['type']=='warning' for e in events) and peak>10000
        rows.append(dict(case=case,exitCode=0,warning=True,decodedPeak=peak,originalUnchanged=unchanged))
    else:
        assert child.returncode==1 and any(e['type']=='failed' for e in events)
        assert not (run/'work/audio.wav').exists()
        rows.append(dict(case=case,exitCode=1,failedEvent=True,noPublishedWave=True,originalUnchanged=unchanged))
    assert unchanged
(root/'TestResults/media-failure-checks.json').write_text(json.dumps(rows,indent=2))
print(json.dumps(rows,indent=2))
