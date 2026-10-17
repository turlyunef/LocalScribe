#!/usr/bin/env python3
"""Developer-only lock generator. Never used by the installed app."""
import hashlib, json, pathlib, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
def get(url):
    with urllib.request.urlopen(url, timeout=120) as r:
        return r.read()

profiles = [
    ('asr', 'argmaxinc/whisperkit-coreml', 'openai_whisper-large-v3/', 'MIT'),
    ('diarization', 'argmaxinc/speakerkit-coreml', '', 'CC-BY-4.0'),
    ('summary', 'mlx-community/Qwen3.5-9B-4bit', '', 'Apache-2.0'),
    ('tokenizer', 'openai/whisper-large-v3', '', 'Apache-2.0'),
]
catalog = {'schemaVersion': 1, 'models': []}
for key, repo, prefix, license in profiles:
    info = json.loads(get(f'https://huggingface.co/api/models/{repo}?blobs=true'))
    revision = info['sha']
    files = []
    for f in info['siblings']:
        name = f['rfilename']
        if key == 'asr':
            include = name.startswith(prefix)
        elif key == 'diarization':
            include = ('W8A16' in name or 'speaker_clusterer' in name or name.lower().startswith(('license', 'readme')))
        elif key == 'summary':
            include = name.endswith(('.json', '.safetensors', '.jinja')) or name.lower().startswith(('license', 'readme'))
        else:
            include = name in ('tokenizer.json', 'tokenizer_config.json', 'special_tokens_map.json', 'added_tokens.json', 'vocab.json', 'merges.txt', 'normalizer.json')
        if not include: continue
        lfs = f.get('lfs') or {}
        digest = lfs.get('sha256')
        if not digest:
            data = get(f'https://huggingface.co/{repo}/resolve/{revision}/{name}')
            digest = hashlib.sha256(data).hexdigest()
        files.append({'path': name, 'localPath': name[len(prefix):] if prefix else name,
                      'size': f.get('size', lfs.get('size', 0)), 'sha256': digest})
    catalog['models'].append({'id': key, 'repository': repo, 'revision': revision,
                              'license': license, 'files': files})
    print(key, revision, len(files), sum(f['size'] for f in files), flush=True)
out = ROOT / 'Resources' / 'models.lock.json'
out.parent.mkdir(exist_ok=True)
out.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
