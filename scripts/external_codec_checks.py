#!/usr/bin/env python3
"""Codec-only tests from FFmpeg's public sample corpus; samples are not distributed."""
import hashlib,json,pathlib,subprocess,urllib.request,wave
root=pathlib.Path(__file__).resolve().parents[1];out=root/'Assets/format-fixtures';out.mkdir(exist_ok=True)
samples=[('sample.mp3','https://samples.ffmpeg.org/A-codecs/MP3/ascii.mp3'),('sample-vorbis.ogg','https://samples.ffmpeg.org/A-codecs/vorbis/Lumme-Badloop.ogg'),('sample-opus.ogg','https://samples.ffmpeg.org/A-codecs/opus/testvector12.ogg')]
results=[]
for name,url in samples:
 target=out/name
 if not target.exists():
  with urllib.request.urlopen(url,timeout=120) as r,target.open('wb') as fp:
   while chunk:=r.read(1024*1024):fp.write(chunk)
 variants=[target]
 if 'opus' in name:
  other=out/'sample.opus';other.write_bytes(target.read_bytes());variants.append(other)
 for source in variants:
  probe=subprocess.run([str(root/'Assets/tools/ffprobe'),'-v','error','-protocol_whitelist','file,pipe','-show_streams','-show_format','-of','json',str(source)],capture_output=True,text=True)
  decoded=out/(source.name+'.wav')
  command=[str(root/'Assets/tools/ffmpeg'),'-nostdin','-n','-v','error','-protocol_whitelist','file,pipe','-i',str(source),'-map','0:a:0','-ac','1','-ar','16000','-c:a','pcm_s16le',str(decoded)]
  if decoded.exists(): decoded.unlink()
  decode=subprocess.run(command,capture_output=True,text=True)
  row=dict(file=source.name,url=url,sha256=hashlib.file_digest(source.open('rb'),'sha256').hexdigest(),probeExit=probe.returncode,decodeExit=decode.returncode)
  if probe.returncode==0:
   info=json.loads(probe.stdout);row['codec']=info['streams'][0]['codec_name'];row['duration']=info['format'].get('duration')
  if decode.returncode:row['error']=decode.stderr
  else:
   with wave.open(str(decoded),'rb') as w:row['decodedDuration']=w.getnframes()/w.getframerate()
  results.append(row)
(root/'TestResults/external-codec-checks.json').write_text(json.dumps(results,indent=2));print(json.dumps(results,indent=2))
