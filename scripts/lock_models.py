#!/usr/bin/env python3
"""Developer-only pinned catalog generator. Existing profiles keep their revisions.
Only small metadata files are fetched; large LFS files use published SHA-256 hashes.
Never used by the installed app or ordinary builds.
"""
import concurrent.futures, hashlib, json, pathlib, time, urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / 'Resources/models.lock.json'
existing = {m['id']: m for m in json.loads(OUTPUT.read_text())['models']} if OUTPUT.exists() else {}
# id, role, display name, repository, subfolder, license, RAM GiB, working GiB, tokenizer
profiles = [
    ('asr', 'asr', 'Whisper large-v3', 'argmaxinc/whisperkit-coreml', 'openai_whisper-large-v3/', 'MIT', 16, 6, 'tokenizer'),
    ('diarization', 'diarization', 'SpeakerKit', 'argmaxinc/speakerkit-coreml', '', 'CC-BY-4.0', 8, 2, None),
    ('summary', 'summary', 'Qwen3.5 · 9B · 4-bit', 'mlx-community/Qwen3.5-9B-4bit', '', 'Apache-2.0', 16, 10, None),
    ('tokenizer', 'tokenizer', 'Токенизатор Whisper large-v3 / turbo', 'openai/whisper-large-v3', '', 'Apache-2.0', 0, 0, None),
    ('asr-small', 'asr', 'Whisper small', 'argmaxinc/whisperkit-coreml', 'openai_whisper-small/', 'MIT', 8, 2, 'tokenizer-multilingual'),
    ('asr-medium', 'asr', 'Whisper medium', 'argmaxinc/whisperkit-coreml', 'openai_whisper-medium/', 'MIT', 16, 4, 'tokenizer-multilingual'),
    ('asr-turbo', 'asr', 'Whisper large-v3-turbo', 'argmaxinc/whisperkit-coreml', 'openai_whisper-large-v3-v20240930/', 'MIT', 8, 4, 'tokenizer'),
    ('summary-4b', 'summary', 'Qwen3.5 · 4B · 4-bit', 'mlx-community/Qwen3.5-4B-4bit', '', 'Apache-2.0', 8, 5, None),
    ('summary-27b', 'summary', 'Qwen3.5 · 27B · 4-bit', 'mlx-community/Qwen3.5-27B-4bit', '', 'Apache-2.0', 32, 24, None),
    ('tokenizer-multilingual', 'tokenizer', 'Токенизатор Whisper base / small / medium', 'openai/whisper-small', '', 'Apache-2.0', 0, 0, None),
    ('asr-base', 'asr', 'Whisper base', 'argmaxinc/whisperkit-coreml', 'openai_whisper-base/', 'MIT', 8, 1, 'tokenizer-multilingual'),
    ('summary-2b', 'summary', 'Qwen3.5 · 2B · 4-bit', 'mlx-community/Qwen3.5-2B-4bit', '', 'Apache-2.0', 8, 3, None),
    ('summary-9b-8bit', 'summary', 'Qwen3.5 · 9B · 8-bit', 'mlx-community/Qwen3.5-9B-8bit', '', 'Apache-2.0', 24, 16, None),
    ('summary-27b-6bit', 'summary', 'Qwen3.5 · 27B · 6-bit', 'mlx-community/Qwen3.5-27B-6bit', '', 'Apache-2.0', 48, 32, None),
    ('summary-27b-8bit', 'summary', 'Qwen3.5 · 27B · 8-bit', 'mlx-community/Qwen3.5-27B-8bit', '', 'Apache-2.0', 64, 40, None),
    ('summary-122b', 'summary', 'Qwen3.5 · 122B-A10B · 4-bit', 'mlx-community/Qwen3.5-122B-A10B-4bit', '', 'Apache-2.0', 128, 88, None),
]
RANKS = {key: rank for keys in (
    ['asr-base', 'asr-small', 'asr-medium', 'asr-turbo', 'asr'],
    ['summary-2b', 'summary-4b', 'summary', 'summary-9b-8bit', 'summary-27b', 'summary-27b-6bit', 'summary-27b-8bit', 'summary-122b'],
) for rank, key in enumerate(keys, 1)}

CACHE = ROOT / '.build/model-metadata'
CACHE.mkdir(parents=True, exist_ok=True)
def get(url):
    cache = CACHE / hashlib.sha256(url.encode()).hexdigest()
    # Cache immutable file URLs only; repository metadata must stay current.
    immutable = '/resolve/' in url
    if immutable and cache.exists(): return cache.read_bytes()
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                data = response.read()
            if immutable: cache.write_bytes(data)
            return data
        except Exception:
            if attempt == 3: raise
            time.sleep(1 + attempt)

catalog = {'schemaVersion': 1, 'models': []}
repos = {}
for key, role, name, repo, prefix, license, ram, working, tokenizer in profiles:
    if key in existing:
        model = existing[key]
    else:
        if repo not in repos:
            repos[repo] = json.loads(get(f'https://huggingface.co/api/models/{repo}?blobs=true'))
        info = repos[repo]
        revision = info['sha']
        selected = []
        for item in info['siblings']:
            path = item['rfilename']
            if role == 'asr': include = path.startswith(prefix)
            elif role == 'diarization': include = ('W8A16' in path or 'speaker_clusterer' in path or path.lower().startswith(('license', 'readme')))
            elif role == 'summary': include = path.endswith(('.json', '.safetensors', '.jinja')) or path.lower().startswith(('license', 'readme'))
            else: include = path in ('tokenizer.json', 'tokenizer_config.json', 'special_tokens_map.json', 'added_tokens.json', 'vocab.json', 'merges.txt', 'normalizer.json')
            if include: selected.append(item)
        def lock_file(item):
            path = item['rfilename']
            lfs = item.get('lfs') or {}
            digest = lfs.get('sha256')
            if not digest:
                print('metadata', key, path, flush=True)
                data = get(f'https://huggingface.co/{repo}/resolve/{revision}/{path}')
                if len(data) != item['size']: raise ValueError(f'Wrong size: {path}')
                digest = hashlib.sha256(data).hexdigest()
            return {'path': path, 'localPath': path[len(prefix):] if prefix else path,
                    'size': item.get('size', lfs.get('size', 0)), 'sha256': digest}
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            files = list(pool.map(lock_file, selected))
        if not files: raise ValueError(f'No files for {key}')
        model = {'id': key, 'repository': repo, 'revision': revision, 'license': license, 'files': files}
    model.update(role=role, name=name, recommendedMemoryGB=ram, workingMemoryGB=working)
    if key in RANKS: model['recommendationRank'] = RANKS[key]
    if tokenizer: model['tokenizerID'] = tokenizer
    catalog['models'].append(model)
    print(key, model['revision'], len(model['files']), sum(f['size'] for f in model['files']), flush=True)
OUTPUT.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')
