"""Shared I/O for developer tools that maintain the pinned model catalog."""

import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".build/model-metadata"


def atomic_write(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        try:
            handle.write(data)
            handle.close()
            if path.exists():
                temporary.chmod(path.stat().st_mode & 0o777)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def write_catalog(path, catalog):
    atomic_write(path, (json.dumps(catalog, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))


def get(url):
    cache = CACHE / hashlib.sha256(url.encode()).hexdigest()
    immutable = "/resolve/" in url
    if immutable and cache.is_file():
        return cache.read_bytes()

    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
            break
        except (urllib.error.URLError, TimeoutError):
            if attempt == 3:
                raise
            time.sleep(1 + attempt)
    if immutable:
        CACHE.mkdir(parents=True, exist_ok=True)
        atomic_write(cache, data)
    return data
