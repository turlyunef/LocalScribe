import hashlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from external_codec_checks import verified_sample


class ExternalCodecChecksTests(unittest.TestCase):
    def test_sample_is_published_only_after_hash_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "sample.ogg"
            data = b"valid fixture"
            digest = hashlib.sha256(data).hexdigest()
            args = (target, "https://example.com/fixture", len(data), digest)

            target.write_bytes(b"broken cache")
            with patch("external_codec_checks.urllib.request.urlopen", return_value=io.BytesIO(b"x" * len(data))):
                with self.assertRaisesRegex(ValueError, "SHA-256"):
                    verified_sample(*args)
            self.assertEqual(list(target.parent.iterdir()), [target])
            self.assertEqual(target.read_bytes(), b"broken cache")

            with patch("external_codec_checks.urllib.request.urlopen", return_value=io.BytesIO(data)):
                self.assertEqual(verified_sample(*args), data)
            self.assertEqual(target.read_bytes(), data)
            with patch("external_codec_checks.urllib.request.urlopen") as fetch:
                self.assertEqual(verified_sample(*args), data)
                fetch.assert_not_called()
