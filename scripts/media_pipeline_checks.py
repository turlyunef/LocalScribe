#!/usr/bin/env python3
"""Exercise the actual worker preparation contract on every supported codec and 3h."""
import argparse,json,pathlib,subprocess,sys
root=pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--worker', type=pathlib.Path)
worker = parser.parse_args().worker
if worker is None:
    product = subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=root, text=True).strip()
    worker = pathlib.Path(product) / 'LocalScribeWorker'
worker = worker.resolve()
if not worker.is_file():
    parser.error(f"Worker executable not found: {worker}")
files=[root/'Assets/probe/mixed.wav']+[root/'Assets/format-fixtures'/n for n in ['aac.m4a','alac.m4a','audio.flac','sample.mp3','sample-vorbis.ogg','sample-opus.ogg','sample.opus']]+[root/'Assets/probe/three-hours.wav']
results=[]
for file in files:
 output=root/'TestResults/media-pipeline'/file.name
 result=subprocess.run([sys.executable,str(root/'scripts/smoke.py'),str(file),'--worker',str(worker),'--stages','preparingAudio','--output',str(output)],capture_output=True,text=True)
 row=dict(file=file.name,exitCode=result.returncode)
 if (output/'latest.json').exists(): row['details']=json.loads((output/'latest.json').read_text())
 if result.returncode:row['error']=result.stderr+result.stdout
 results.append(row)
(root/'TestResults/media-pipeline-checks.json').write_text(json.dumps(results,indent=2));print(json.dumps([(r['file'],r['exitCode']) for r in results]))
assert all(r['exitCode']==0 for r in results)
