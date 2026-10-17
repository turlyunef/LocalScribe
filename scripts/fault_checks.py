#!/usr/bin/env python3
"""Fault injection against real worker/checkpoints; run after the ordinary smoke test."""
import argparse, hashlib, json, pathlib, subprocess, time
p=argparse.ArgumentParser()
p.add_argument('recording',type=pathlib.Path)
p.add_argument('--worker',type=pathlib.Path,required=True)
p.add_argument('--models',type=pathlib.Path,default=pathlib.Path('Assets/models'))
p.add_argument('--tools',type=pathlib.Path,default=pathlib.Path('Assets/tools'))
args=p.parse_args(); folder=args.recording.resolve()
m=json.loads((folder/'manifest.json').read_text()); run=folder/'runs'/m['pendingRunId']
def hashes():
 return {str(f.relative_to(run)):hashlib.file_digest(f.open('rb'),'sha256').hexdigest() for f in run.rglob('*.json') if f.name in ('transcript.json','asr-transcript.json','summary.json') or f.parent.name=='asr'}
def command(stage,models):
 return dict(version=1,jobId=m['id'],runId=m['pendingRunId'],stage=stage,recordingPath=str(folder),modelsPath=str(models.resolve()),toolsPath=str(args.tools.resolve()))
def launch(cmd):
 child=subprocess.Popen([str(args.worker.resolve())],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
 child.stdin.write(json.dumps(cmd)+'\n');child.stdin.flush();return child
before=hashes(); results={}
child=launch(command('transcribing',args.models))
event=json.loads(child.stdout.readline()); assert event['type']=='started'
start=time.monotonic(); child.stdin.close(); child.wait(timeout=4)
results['cancel']={'seconds':time.monotonic()-start,'exitCode':child.returncode,'checkpointsUnchanged':hashes()==before}
assert child.returncode==72 and hashes()==before
for stage in ('diarizing','summarizing'):
 child=launch(command(stage,pathlib.Path('Assets/nonexistent-models-for-fault-test')))
 events=[json.loads(line) for line in child.stdout];child.wait(timeout=10);child.stdin.close()
 assert child.returncode!=0 and any(e['type']=='failed' for e in events) and hashes()==before
 results[stage]={'exitCode':child.returncode,'failedEvent':True,'priorResultsUnchanged':True}
out=pathlib.Path('TestResults/fault-checks.json');out.parent.mkdir(exist_ok=True)
out.write_text(json.dumps(results,indent=2));print(json.dumps(results,indent=2))
