#!/usr/bin/env python3
"""Developer-only pinned long-form VibeVoice-ASR catalog addition.
Run only after the local checkpoint probe passes. No weight download.
"""
import argparse
import json
from pathlib import Path
from lock_qwen_models import ROOT, get, lock_files

MODEL_REPO = 'mlx-community/VibeVoice-ASR-4bit'
MODEL_REVISION = 'a1a15cb6c7b70f76b588af7e12f6fab34d5ab654'
TOKENIZER_REPO = 'Qwen/Qwen2.5-7B'
TOKENIZER_REVISION = 'd149729398750b98c0af14eb82c78cfe92750796'


def make_profile(repository, revision, identifier, names, **metadata):
    info = json.loads(get(f'https://huggingface.co/api/models/{repository}/revision/{revision}?blobs=true'))
    if info['sha'] != revision:
        raise ValueError('Revision mismatch')
    return dict(id=identifier, repository=repository, revision=revision,
                files=lock_files(repository, revision, info, names), **metadata)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'Resources/models.lock.json')
    args = parser.parse_args()
    profiles = [
        make_profile(TOKENIZER_REPO, TOKENIZER_REVISION, 'tokenizer-vibevoice',
                     {'tokenizer.json', 'tokenizer_config.json', 'vocab.json', 'merges.txt', 'LICENSE'},
                     role='tokenizer', license='Apache-2.0', name='Токенизатор VibeVoice-ASR · Qwen2.5'),
        make_profile(MODEL_REPO, MODEL_REVISION, 'asr-vibevoice-4bit',
                     {'config.json', 'model-00001-of-00002.safetensors', 'model-00002-of-00002.safetensors', 'model.safetensors.index.json'},
                     role='asr', license='MIT', name='VibeVoice-ASR · 4-bit · экспериментальный',
                     asrBackend='vibevoice-asr', asrPolicy='vibevoice-longform-300s-greedy8192-speakerkit-v1',
                     tokenizerID='tokenizer-vibevoice', recommendedMemoryGB=32, workingMemoryGB=20,
                     maximumRecordingMs=300000, experimental=True, recommendationRank=0,
                     profileDescription='Готовые записи до 5 минут на Mac от 32 ГБ RAM. Только таймкоды сегментов; участники определяются SpeakerKit. Качество на встречах ещё не принято.')
    ]
    catalog = json.loads(args.output.read_text())
    existing = {m['id']: m for m in catalog['models']}
    for profile in profiles:
        if profile['id'] in existing:
            if existing[profile['id']] != profile:
                raise ValueError('Refusing to replace an existing pinned profile')
        else:
            catalog['models'].append(profile)
    args.output.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
