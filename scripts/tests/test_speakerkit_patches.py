"""Reverse the vendored patch series and compare every upstream source hash."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

VENDOR = Path(__file__).resolve().parents[2] / "ThirdParty/SpeakerKit"
PATCHES = (
    "tail-reflection",
    "inference-errors",
    "backpressure",
    "audio-memory",
    "model-geometry",
    "full-timeline",
    "cluster-size-option",
    "streaming-pcm",
)


class SpeakerKitPatchTests(unittest.TestCase):
    def test_patches_reverse_to_pinned_upstream(self):
        expected = json.loads((VENDOR / "upstream.json").read_text())["files"]
        self.assertEqual({f.stem for f in VENDOR.glob("*.patch")}, set(PATCHES))
        with tempfile.TemporaryDirectory(prefix="SpeakerKit patches ") as directory:
            root = Path(directory)
            shutil.copytree(VENDOR / "Sources", root / "Sources")
            for name in reversed(PATCHES):
                subprocess.run(
                    ["git", "apply", "--reverse", str(VENDOR / f"{name}.patch")],
                    check=True, cwd=root,
                )
            actual = {
                str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (root / "Sources").rglob("*.swift")
            }
            self.assertEqual(actual, expected)
