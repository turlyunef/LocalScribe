#!/usr/bin/env python3
"""Make local codec fixtures with Core Audio, then exercise the bundled decoder."""
import json,pathlib,subprocess
root=pathlib.Path(__file__).resolve().parents[1]
source=root/'Assets/probe/mixed.wav';out=root/'Assets/format-fixtures';out.mkdir(exist_ok=True)
cases=[('aac.m4a','m4af','aac'),('alac.m4a','m4af','alac'),('audio.flac','flac','flac'),('vorbis.ogg','Oggf','vorb'),('opus.ogg','Oggf','opus'),('audio.opus','Oggf','opus'),('audio.mp3','MPG3','.mp3')]
results=[]
for name,container,codec in cases:
 target=out/name
 encode=subprocess.run(['/usr/bin/afconvert','-f',container,'-d',codec,str(source),str(target)],capture_output=True,text=True)
 row=dict(file=name,fixtureCreated=encode.returncode==0)
 if encode.returncode:
  row['fixtureError']=encode.stderr.strip();results.append(row);continue
 probe=subprocess.run([str(root/'Assets/tools/ffprobe'),'-v','error','-protocol_whitelist','file,pipe','-show_streams','-show_format','-of','json',str(target)],capture_output=True,text=True)
 decode=subprocess.run([str(root/'Assets/tools/ffmpeg'),'-nostdin','-n','-v','error','-protocol_whitelist','file,pipe','-i',str(target),'-map','0:a:0','-ac','1','-ar','16000','-c:a','pcm_s16le',str(out/(name+'.wav'))],capture_output=True,text=True)
 row.update(probeExit=probe.returncode,decodeExit=decode.returncode)
 if probe.returncode==0:
  info=json.loads(probe.stdout);row['codec']=info['streams'][0]['codec_name'];row['duration']=info['format'].get('duration')
 if decode.returncode: row['decodeError']=decode.stderr.strip()
 results.append(row)
(root/'TestResults/format-checks.json').write_text(json.dumps(results,indent=2,ensure_ascii=False))
print(json.dumps(results,indent=2,ensure_ascii=False))
