#!/usr/bin/env python3
"""Kill a dedicated test parent; verify that its genuine worker does not survive."""
import argparse, json, os, pathlib, signal, subprocess, sys, time

p = argparse.ArgumentParser()
p.add_argument('recording', type=pathlib.Path)
p.add_argument('--worker', type=pathlib.Path, required=True)
p.add_argument('--child', action='store_true')
args = p.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
if args.child:
    folder = args.recording.resolve()
    manifest = json.loads((folder/'manifest.json').read_text())
    command = dict(version=1, jobId=manifest['id'], runId=manifest['pendingRunId'],
                   stage='transcribing', recordingPath=str(folder),
                   modelsPath=str(root/'Assets/models'), toolsPath=str(root/'Assets/tools'))
    worker = subprocess.Popen([str(args.worker.resolve())], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    worker.stdin.write(json.dumps(command)+'\n'); worker.stdin.flush()
    event = json.loads(worker.stdout.readline())
    assert event['type'] == 'started'
    print(worker.pid, flush=True)
    time.sleep(60)
    raise SystemExit('Parent was not killed by the test')

parent = subprocess.Popen([sys.executable, __file__, str(args.recording), '--worker',
                           str(args.worker), '--child'], stdout=subprocess.PIPE, text=True)
worker_pid = int(parent.stdout.readline())
start = time.monotonic()
os.kill(parent.pid, signal.SIGKILL); parent.wait(timeout=3)
gone = False
while time.monotonic()-start < 5:
    state = subprocess.run(['ps', '-p', str(worker_pid), '-o', 'stat='],
                           capture_output=True, text=True).stdout.strip()
    if not state or state.startswith('Z'):
        gone = True; break
    time.sleep(.05)
result = dict(parentSIGKILL=True, workerNoLongerRunning=gone,
              seconds=time.monotonic()-start,
              scope='real standalone worker, parent control pipe closed by SIGKILL; GUI not tested')
(root/'TestResults/parent-exit-check.json').write_text(json.dumps(result, indent=2))
print(json.dumps(result, indent=2))
if not gone:
    os.kill(worker_pid, signal.SIGKILL)
    raise SystemExit('Orphan worker survived')
