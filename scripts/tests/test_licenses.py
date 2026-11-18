"""Offline checks of the license collection script against a synthetic package root."""
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class LicensesScriptTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='Licenses script ')
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        (self.root / 'scripts').mkdir()
        shutil.copyfile(ROOT / 'scripts/licenses.py', self.root / 'scripts/licenses.py')

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def seed_root(self):
        self.write('.build/checkouts/swift-transformers/LICENSE', 'transformers license')
        self.write('.build/checkouts/swift-transformers/README.md', 'not a license')
        self.write('.build/checkouts/mlx-swift/NOTICE', 'mlx notice')
        for name in ('COPYING.LGPLv2.1', 'COPYING.LGPLv3', 'LICENSE.md'):
            self.write(f'build/ffmpeg-licenses/{name}', f'pinned {name}')
        self.write('docs/ThirdParty.md', 'third party fixture')
        for name in ('LICENSE', 'NOTICES'):
            self.write(f'ThirdParty/SpeakerKit/{name}', name)
        self.write('Resources/Licenses/Whisper-MIT.txt', 'whisper license')

    def run_script(self, *arguments, expected=0):
        result = subprocess.run([sys.executable, str(self.root / 'scripts/licenses.py'), *arguments],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_collects_all_sections_with_prefixed_names(self):
        self.seed_root()
        dest = self.root / 'packaged licenses'
        self.run_script(str(dest))
        expected = {
            'swift-transformers-LICENSE': 'transformers license',
            'mlx-swift-NOTICE': 'mlx notice',
            'ffmpeg-COPYING.LGPLv2.1': 'pinned COPYING.LGPLv2.1',
            'ffmpeg-COPYING.LGPLv3': 'pinned COPYING.LGPLv3',
            'ffmpeg-LICENSE.md': 'pinned LICENSE.md',
            'ThirdParty.md': 'third party fixture',
            'LocalScribeSpeakerKit-LICENSE': 'LICENSE',
            'LocalScribeSpeakerKit-NOTICES': 'NOTICES',
            'Whisper-MIT.txt': 'whisper license',
        }
        self.assertEqual({path.name: path.read_text() for path in dest.iterdir()}, expected)

    def test_missing_destination_argument_fails_with_usage(self):
        result = self.run_script(expected=2)
        self.assertIn('dest', result.stderr)
        self.assertIn('required', result.stderr)

    def test_name_collision_between_sections_fails_loudly(self):
        # Only license/copying/notice files are collected from checkouts, so the
        # reachable collision is a checkout whose prefixed name matches a fixed one.
        self.seed_root()
        self.write('.build/checkouts/ffmpeg/LICENSE.md', 'checkout ffmpeg license')
        result = self.run_script(str(self.root / 'packaged licenses'), expected=1)
        self.assertIn('collision', result.stderr)
        self.assertIn('ffmpeg-LICENSE.md', result.stderr)
        self.assertIn('build/ffmpeg-licenses/LICENSE.md', result.stderr)
        self.assertIn('checkouts/ffmpeg/LICENSE.md', result.stderr)

    def test_case_only_collision_fails_loudly(self):
        self.seed_root()
        self.write('Resources/Licenses/MLX-SWIFT-notice', 'duplicate notice')
        result = self.run_script(str(self.root / 'packaged licenses'), expected=1)
        self.assertIn('collision', result.stderr)
        self.assertIn('MLX-SWIFT-notice', result.stderr)
        self.assertIn('checkouts/mlx-swift/NOTICE', result.stderr)


if __name__ == '__main__':
    unittest.main()
