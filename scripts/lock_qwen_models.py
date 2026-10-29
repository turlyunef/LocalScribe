#!/usr/bin/env python3
"""Developer-only addition of reviewed Qwen checkpoints to the pinned catalog.
Fetches small metadata only; LFS SHA-256 values come from the immutable revision.
The installed app and worker never invoke this script.
"""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
REVISIONS = {
    'Qwen3-ASR-1.7B-bf16': 'e1f6c266914abc5a46e8756e02580f834a6cf8a7',
    'Qwen3-ForcedAligner-0.6B-bf16': '53c8c0e46733eec430e4b53dd6471d0e5dee45f8',
    'Qwen3-ASR-1.7B-8bit': 'a8379a2e2f9e313c9292cdf1af4055ab56d50d55',
    'Qwen3-ForcedAligner-0.6B-8bit': '0e1a68e91d815300c7c9754b2a7639378b23db15',
}
TOKENIZER_FILES = {'vocab.json', 'merges.txt', 'tokenizer_config.json'}
MODEL_FILES = {'config.json', 'model.safetensors', 'preprocessor_config.json', 'generation_config.json'}
POLICY = 'qwen3-pause28-context250-greedy1024-rawalign-v2'


def get(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def lock_files(repository, revision, metadata, names):
    files = []
    for item in metadata['siblings']:
        path = item['rfilename']
        if path not in names:
            continue
        size = item['size']
        digest = (item.get('lfs') or {}).get('sha256')
        if digest is None:
            if size > 10_000_000:
                raise ValueError('Missing published SHA-256 for large model file')
            content = get(f'https://huggingface.co/{repository}/resolve/{revision}/{path}')
            if len(content) != size:
                raise ValueError('Metadata size mismatch')
            digest = hashlib.sha256(content).hexdigest()
        files.append(dict(path=path, localPath=path, size=size, sha256=digest))
    if {f['path'] for f in files} != names:
        raise ValueError('Incomplete model repository')
    return sorted(files, key=lambda f: f['path'])


def profiles(variant):
    result = []
    for kind in ('ASR-1.7B', 'ForcedAligner-0.6B'):
        model = f'Qwen3-{kind}-{variant}'
        revision = REVISIONS[model]
        repository = 'mlx-community/' + model
        metadata = json.loads(get(f'https://huggingface.co/api/models/{repository}/revision/{revision}?blobs=true'))
        if metadata['sha'] != revision:
            raise ValueError('Model revision mismatch')
        is_asr = kind == 'ASR-1.7B'
        identifier = ('asr-qwen3-1.7b-' if is_asr else 'aligner-qwen3-0.6b-') + variant
        profile = dict(id=identifier, repository=repository, revision=revision, license='Apache-2.0',
                       files=lock_files(repository, revision, metadata, MODEL_FILES if is_asr else MODEL_FILES | TOKENIZER_FILES),
                       name=model, recommendedMemoryGB=16, workingMemoryGB=10 if variant == 'bf16' else 7)
        if is_asr:
            profile.update(role='asr', asrBackend='qwen3', asrPolicy=POLICY,
                           alignerID='aligner-qwen3-0.6b-' + variant, tokenizerID='tokenizer-qwen3',
                           recommendationRank=0, experimental=True,
                           profileDescription='Кандидат Qwen3-ASR + ForcedAligner. Исходный язык RU/EN, готовые записи. '
                           'Качество на встречах ещё не принято. Рабочая память включает обе модели, буферы и контекст до 30 с.')
            # Identical vocabulary and added tokens in both ASR quantizations.
            tokenizer = dict(id='tokenizer-qwen3', role='tokenizer', repository=repository, revision=revision,
                             license='Apache-2.0', name='Токенизатор Qwen3-ASR',
                             files=lock_files(repository, revision, metadata, TOKENIZER_FILES))
            result.append(tokenizer)
        result.append(profile)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variant', choices=['bf16', '8bit'], required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'Resources/models.lock.json')
    args = parser.parse_args()
    catalog = json.loads(args.output.read_text())
    additions = profiles(args.variant)
    # Preserve a previously pinned shared tokenizer revision after byte comparison.
    existing = {m['id']: m for m in catalog['models']}
    for profile in additions:
        if profile['id'] == 'tokenizer-qwen3' and profile['id'] in existing:
            if existing[profile['id']]['files'] != profile['files']:
                raise ValueError('Shared tokenizer content changed; use a new ID')
            continue
        if profile['id'] in existing:
            if existing[profile['id']] != profile:
                raise ValueError('Refusing to replace an existing pinned profile')
        else:
            catalog['models'].append(profile)
    args.output.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
