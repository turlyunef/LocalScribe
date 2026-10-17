#!/usr/bin/env python3
"""Collect observed technical checks. Does not turn them into full acceptance."""
import argparse, datetime, hashlib, json, pathlib, re, subprocess

p=argparse.ArgumentParser()
p.add_argument('--signed-result',type=pathlib.Path,required=True)
p.add_argument('--no-tasks-run',type=pathlib.Path,required=True)
args=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[1]
def read(path): return json.loads(path.read_text())
def digest(path): return hashlib.file_digest(path.open('rb'),'sha256').hexdigest()
def command(*values): return subprocess.check_output(values,text=True).strip()
catalog=read(root/'Resources/models.lock.json')
signed=read(args.signed_result); run=pathlib.Path(signed['runPath'])
assert signed['status']=='passed'
summary=read(run/'summary.json'); transcript=read(run/'transcript.json')
no_tasks=read(args.no_tasks_run/'summary.json')
assert not no_tasks['tasks'] and not no_tasks['decisions'] and no_tasks['overview']
silence_folder=pathlib.Path(read(root/'TestResults/silence/latest.json')['recordingPath'])
silence_manifest=read(silence_folder/'manifest.json')
silence_run=silence_folder/'runs'/silence_manifest['pendingRunId']
silence_transcript=read(silence_run/'transcript.json'); silence_summary=read(silence_run/'summary.json')
assert not silence_transcript['segments'] and not silence_summary['tasks'] and not silence_summary['decisions']
test_log=(root/'final-tests.log').read_text()
tests=re.findall(r'Executed (\d+) tests, with (\d+) failures',test_log)
assert tests and int(tests[-1][1])==0
app=root/'dist/LocalScribe.app'
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
binaries=['MacOS/LocalScribe','Helpers/LocalScribeWorker',
          'XPCServices/LocalScribeModelService.xpc/Contents/MacOS/LocalScribeModelService',
          'Resources/tools/ffmpeg','Resources/tools/ffprobe']
binary_reports={}
for name in binaries:
    path=app/'Contents'/name
    minimum=re.search(r'minos\s+(\S+)',command('xcrun','vtool','-show-build',str(path))).group(1)
    assert minimum=='26.0'
    binary_reports[name]=dict(sha256=digest(path),minimumMacOS=minimum)
codecs=read(root/'TestResults/media-pipeline-checks.json')
assert len(codecs)==9 and all(row['exitCode']==0 for row in codecs)
report=dict(
    generatedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
    acceptance='PRELIMINARY — full v1 acceptance not passed',
    machine=dict(model=command('sysctl','-n','hw.model'),chip=command('sysctl','-n','machdep.cpu.brand_string'),
                 memoryBytes=int(command('sysctl','-n','hw.memsize')),
                 macOSActuallyTested=command('sw_vers','-productVersion'),
                 macOSBuild=command('sw_vers','-buildVersion'),targetMacOS='26.0; runtime on 26 not tested',
                 xcode=command('xcodebuild','-version')),
    packageResolvedSHA256=digest(root/'Package.resolved'),modelCatalogSHA256=digest(root/'Resources/models.lock.json'),
    modelTotalBytes=sum(f['size'] for m in catalog['models'] for f in m['files']),
    modelProfiles=[dict(id=m['id'],repository=m['repository'],revision=m['revision'],
                        bytes=sum(f['size'] for f in m['files'])) for m in catalog['models']],
    executables=binary_reports,strictCodeSignatureVerified=True,signing='ad-hoc; no Developer ID/notarization',
    unitTests=dict(executed=int(tests[-1][0]),failures=int(tests[-1][1])),
    signedSyntheticPipeline=dict(status='all APIs completed in signed network-denied sandbox',
        pipelineVersion=read(run/'run.json')['pipelineVersion'],audioSeconds=22.2435625,
        source='local macOS TTS, RU/EN/RU; not a WER/DER benchmark',
        stages={f.stem.removeprefix('metrics-'):read(f) for f in run.glob('metrics-*.json')},
        llmAudit=read(run/'llm-audit.json'),segmentCount=len(transcript['segments']),
        speakerCount=len({s['speakerId'] for s in transcript['segments'] if s.get('speakerId')}),
        summaryLanguage=summary['language'],tasks=summary['tasks'],decisions=summary['decisions']),
    noTasksSyntheticControl=dict(tasks=len(no_tasks['tasks']),decisions=len(no_tasks['decisions']),
                                overviewItems=len(no_tasks['overview']),source='local macOS TTS'),
    digitalSilenceControl=dict(seconds=silence_manifest['durationMs']/1000,segments=len(silence_transcript['segments']),
                              tasks=len(silence_summary['tasks']),decisions=len(silence_summary['decisions']),
                              scope='exact digital zeros; not quiet-room noise'),
    codecPreparation=[dict(file=r['file'],exitCode=r['exitCode']) for r in codecs],
    publicCodecProvenance=read(root/'TestResults/external-codec-checks.json'),
    mediaFailuresAndPhase=read(root/'TestResults/media-failure-checks.json'),
    globalDiarization3Hours=dict(**read(root/'TestResults/diarization-3h.json'),
                                source='repeated synthetic speech; not a real meeting or DER/hour-absence test'),
    workerFaults=read(root/'TestResults/fault-checks.json'),parentSIGKILL=read(root/'TestResults/parent-exit-check.json'),
    notVerified=['installed macOS 26','physical microphone and TCC','visual GUI and file dialogs',
                 'real speech WER/DER and large-v3 versus Turbo','full 3-hour ASR and LLM meeting coverage',
                 'speaker returning after an hour','cold reboot with physical network disconnected',
                 'combined unified memory, swap delta, controlled thermal/power performance',
                 'disk-full and memory pressure','clean Mac without developer tools','Developer ID/notarization'])
(root/'docs/Measurements.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print('Wrote docs/Measurements.json; acceptance remains preliminary')
