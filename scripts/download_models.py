#!/usr/bin/env python3
"""Developer/bootstrap downloader; the installed app has its own Swift manager."""
import argparse, concurrent.futures, hashlib, json, pathlib, urllib.request, time
root = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', nargs='?', type=pathlib.Path, default=root / 'Assets/models')
parser.add_argument('--model', action='append', help='Profile ID; repeat to download several. Default: original four profiles.')
args = parser.parse_args()
dest = args.destination
catalog = json.loads((root / 'Resources/models.lock.json').read_text())
ids = set(args.model or ['asr', 'diarization', 'summary', 'tokenizer'])
unknown = ids - {m['id'] for m in catalog['models']}
if unknown: parser.error('Unknown models: ' + ', '.join(sorted(unknown)))
ids.update(m['tokenizerID'] for m in catalog['models'] if m['id'] in ids and m.get('tokenizerID'))
catalog['models'] = [m for m in catalog['models'] if m['id'] in ids]
def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as fp:
        while b := fp.read(8 * 1024 * 1024): h.update(b)
    return h.hexdigest()
def download(item):
    model, f = item
    path = dest / (model['id'] + '.partial') / f['localPath']
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.stat().st_size == f['size'] and digest(path) == f['sha256']: return
    url = f"https://huggingface.co/{model['repository']}/resolve/{model['revision']}/{f['path']}"
    for attempt in range(4):
        try:
            n = path.stat().st_size if path.exists() else 0
            req = urllib.request.Request(url, headers={'Range': f'bytes={n}-'} if n else {})
            with urllib.request.urlopen(req, timeout=120) as r, path.open('ab' if n and r.status == 206 else 'wb') as fp:
                while data := r.read(8 * 1024 * 1024): fp.write(data)
            if path.stat().st_size != f['size'] or digest(path) != f['sha256']:
                path.unlink(); raise ValueError('checksum mismatch')
            print(model['id'], f['localPath'], 'verified', flush=True); return
        except Exception:
            if attempt == 3: raise
            time.sleep(2)
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    list(pool.map(download, [(m,f) for m in catalog['models'] if not (dest/m['id']).exists() for f in m['files']]))
for m in catalog['models']:
    partial, final = dest / (m['id']+'.partial'), dest / m['id']
    if partial.exists(): partial.rename(final)
(dest/'catalog.json').write_text(json.dumps(catalog, indent=2))
