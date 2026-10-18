#!/usr/bin/env python3
"""Validate an AGENTS.md candidate and print its diff; never modify files."""

import argparse
import difflib
import hashlib
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit


def validate(text, root):
    errors = []
    count = len(text.splitlines())
    if not text.strip():
        errors.append('Document is empty')
    if count > 150:
        errors.append(f'{count} lines exceeds 150')
    if re.search(r'\{\{[^}]+\}\}|\[TODO:', text):
        errors.append('Unfilled template fields')
    # Root document links resolve from root, even when the candidate lives in /tmp.
    # Fences are excluded so shell expressions are not interpreted as Markdown.
    prose = re.sub(r'(?ms)^\s*(```|~~~).*?^\s*\1\s*$', '', text)
    links = re.findall(r'!?\[[^\]\n]*\]\((<[^>\n]+>|[^\s)]+)(?:\s+"[^"\n]*")?\)', prose)
    links += re.findall(r'(?m)^\s*\[[^\]\n]+\]:\s*(<[^>\n]+>|\S+)', prose)
    for raw in links:
        target = raw.strip('<>')
        parsed = urlsplit(target)
        if parsed.scheme or parsed.netloc or not parsed.path:
            continue
        path = Path(unquote(parsed.path))
        if path.is_absolute():
            errors.append(f'Use a repository-relative link: {target}')
            continue
        resolved = (root / path).resolve()
        if not resolved.is_relative_to(root):
            errors.append(f'Link escapes repository: {target}')
        elif not resolved.exists():
            errors.append(f'Missing local path: {target}')
    return errors


def inspect(candidate, root):
    candidate, root = Path(candidate), Path(root).resolve()
    text = candidate.read_text(encoding='utf-8')
    target = root / 'AGENTS.md'
    before_bytes = target.read_bytes() if target.exists() else b''
    before = before_bytes.decode('utf-8')
    errors = validate(text, root)
    diff = ''.join(difflib.unified_diff(before.splitlines(keepends=True),
                                      text.splitlines(keepends=True),
                                      fromfile='a/AGENTS.md' if target.exists() else '/dev/null',
                                      tofile='b/AGENTS.md'))
    return errors, diff, hashlib.sha256(before_bytes).hexdigest(), len(text.splitlines())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('candidate', type=Path)
    parser.add_argument('--root', type=Path, default=Path('.'))
    args = parser.parse_args()
    try:
        errors, diff, digest, count = inspect(args.candidate, args.root)
    except (OSError, UnicodeError, ValueError) as error:
        parser.exit(1, f'{error}\n')
    print(f'Lines: {count}/150; original SHA256: {digest}', file=sys.stderr)
    for error in errors:
        print(f'ERROR: {error}', file=sys.stderr)
    print(diff, end='')
    print('No files written. Command correctness and manual-section preservation require review.', file=sys.stderr)
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
