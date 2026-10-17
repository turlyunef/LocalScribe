#!/usr/bin/env python3
"""Developer/bootstrap downloader; the installed app has its own Swift manager."""
import concurrent.futures, hashlib, json, pathlib, sys, urllib.request, time
root = pathlib.Path(__file__).resolve().parents[1]
dest = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'Assets/models'
catalog = json.loads((root / 'Resources/models.lock.json').read_text())
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
