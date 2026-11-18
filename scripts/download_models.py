#!/usr/bin/env python3
"""Developer/bootstrap downloader; the installed app has its own Swift manager."""
import argparse
import concurrent.futures
import hashlib
import json
import pathlib
import shutil
import tempfile
import time
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as fp:
        while b := fp.read(8 * 1024 * 1024):
            h.update(b)
    return h.hexdigest()


def valid_file(path, file):
    return (path.is_file() and path.stat().st_size == file['size']
            and digest(path) == file['sha256'])


def valid_model(directory, model):
    return directory.is_dir() and all(
        valid_file(directory / file['localPath'], file) for file in model['files'])


def download(dest, item):
    model, file = item
    path = dest / (model['id'] + '.partial') / file['localPath']
    path.parent.mkdir(parents=True, exist_ok=True)
    if valid_file(path, file):
        return
    url = f"https://huggingface.co/{model['repository']}/resolve/{model['revision']}/{file['path']}"
    for attempt in range(4):
        try:
            n = path.stat().st_size if path.exists() else 0
            # A complete but corrupt file cannot be repaired with a Range request.
            if n and n >= file['size']:
                path.unlink()
                n = 0
            req = urllib.request.Request(url, headers={'Range': f'bytes={n}-'} if n else {})
            with urllib.request.urlopen(req, timeout=120) as response, path.open(
                    'ab' if n and response.status == 206 else 'wb') as fp:
                received = n if n and response.status == 206 else 0
                while data := response.read(8 * 1024 * 1024):
                    # Cap the stream: a false or missing length from the source
                    # must not fill the disk before valid_file runs after EOF.
                    received += len(data)
                    if received > file['size']:
                        path.unlink()
                        raise ValueError(
                            f"{model['id']}/{file['localPath']}: stream exceeded catalog size")
                    fp.write(data)
            if not valid_file(path, file):
                path.unlink()
                raise ValueError(f"{model['id']}/{file['localPath']}: size/SHA-256 mismatch")
            print(model['id'], file['localPath'], 'verified', flush=True)
            return
        except Exception as error:
            if attempt == 3:
                raise RuntimeError(f"Failed to download {model['id']}/{file['localPath']}: {error}") from error
            time.sleep(2)


def bootstrap(dest, catalog):
    dest.mkdir(parents=True, exist_ok=True)
    pending = [model for model in catalog['models']
               if not valid_model(dest / model['id'], model)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        list(pool.map(lambda item: download(dest, item),
                      [(model, file) for model in pending for file in model['files']]))

    # Recheck complete sets after all downloads, before replacing any final folder.
    for model in pending:
        if not valid_model(dest / (model['id'] + '.partial'), model):
            raise ValueError(f"{model['id']}: incomplete or corrupt .partial model")
    for model in pending:
        partial, final = dest / (model['id'] + '.partial'), dest / model['id']
        if final.is_symlink() or (final.exists() and not final.is_dir()):
            raise ValueError(f"{model['id']}: final path is not a regular directory")
        if final.exists():
            shutil.rmtree(final)
        partial.rename(final)

    # Publish the catalog only after every selected profile is ready.
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=dest, delete=False) as fp:
            temporary = pathlib.Path(fp.name)
            json.dump(catalog, fp, indent=2)
        temporary.replace(dest / 'catalog.json')
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', nargs='?', type=pathlib.Path, default=ROOT / 'Assets/models')
    parser.add_argument('--model', action='append', help='Profile ID; repeat to download several. Default: original four profiles.')
    args = parser.parse_args(argv)
    catalog = json.loads((ROOT / 'Resources/models.lock.json').read_text())
    ids = set(args.model or ['asr', 'diarization', 'summary', 'tokenizer'])
    unknown = ids - {model['id'] for model in catalog['models']}
    if unknown:
        parser.error('Unknown models: ' + ', '.join(sorted(unknown)))
    ids.update(model['tokenizerID'] for model in catalog['models']
               if model['id'] in ids and model.get('tokenizerID'))
    catalog['models'] = [model for model in catalog['models'] if model['id'] in ids]
    try:
        bootstrap(args.destination, catalog)
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(1, f'Bootstrap failed: {error}\n')


if __name__ == '__main__':
    main()
