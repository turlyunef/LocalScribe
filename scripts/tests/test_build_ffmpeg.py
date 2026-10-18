"""Exercise the build script with real tar/SHA tools and a tiny source fixture."""
import hashlib
import io
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
PINNED_SHA256 = '05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41'
VERSION = '8.0.1'
LICENSES = ('COPYING.LGPLv2.1', 'COPYING.LGPLv3', 'LICENSE.md')


class BuildFFmpegTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='FFmpeg build ')
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        (self.root / 'scripts').mkdir()
        (self.root / 'Vendor').mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.archive = self.root / f'Vendor/ffmpeg-{VERSION}.tar.xz'
        configure = b'''#!/bin/bash
set -euo pipefail
pwd >> "$TEST_CONFIGURE_CWDS"
printf '%s\\n' "$@" > "$TEST_CONFIGURE_ARGS"
if [ "${TEST_FAIL_CONFIGURE:-0}" = 1 ]; then exit 23; fi
cp source.txt config.h
mkdir -p ffbuild
cp source.txt ffbuild/config.log
'''
        with tarfile.open(self.archive, 'w:xz') as archive:
            for name, data in [('configure', configure), ('source.txt', b'pinned source')]:
                self.add_member(archive, name, data, 0o755 if name == 'configure' else 0o644)
            for name in LICENSES:
                self.add_member(archive, name, f'pinned {name}'.encode())
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        # Change only the pinned digest in an isolated script copy. Production has
        # no environment/CLI option that bypasses or overrides SHA verification.
        self.write_build_script(self.digest)
        self.write_command('make', f'''#!{sys.executable}
import os, pathlib, sys
with open(os.environ['TEST_MAKE_CALLS'], 'a') as log:
    log.write(' '.join(sys.argv[1:]) + '\\n')
if os.environ.get('TEST_FAIL_MAKE') == '1':
    sys.exit(24)
if sys.argv[1:] == ['-j4']:
    for name in ('ffmpeg', 'ffprobe'):
        pathlib.Path(name).write_bytes(pathlib.Path('source.txt').read_bytes())
''')
        self.write_command('curl', '''#!/bin/bash
printf '%s\\n' "$@" > "$TEST_CURL_ARGS"
if [ -z "${TEST_DOWNLOAD_ARCHIVE:-}" ]; then exit 99; fi
while [ "$1" != -o ]; do shift; done
cp "$TEST_DOWNLOAD_ARCHIVE" "$2"
''')
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        TEST_CONFIGURE_CWDS=str(self.root / 'configure-cwds'),
                        TEST_CONFIGURE_ARGS=str(self.root / 'configure-args'),
                        TEST_MAKE_CALLS=str(self.root / 'make-calls'),
                        TEST_CURL_ARGS=str(self.root / 'curl-args'))
        for name in ('TEST_FAIL_CONFIGURE', 'TEST_FAIL_MAKE', 'TEST_DOWNLOAD_ARCHIVE'):
            self.env.pop(name, None)

    def add_member(self, archive, name, data, mode=0o644):
        member = tarfile.TarInfo(f'ffmpeg-{VERSION}/{name}')
        member.size = len(data)
        member.mode = mode
        archive.addfile(member, io.BytesIO(data))

    def write_build_script(self, digest):
        script = (ROOT / 'scripts/build_ffmpeg.sh').read_text()
        self.assertEqual(script.count(PINNED_SHA256), 1)
        (self.root / 'scripts/build_ffmpeg.sh').write_text(script.replace(PINNED_SHA256, digest))

    def write_command(self, name, source):
        path = self.bin / name
        path.write_text(source)
        path.chmod(0o755)

    def run_build(self, expected=0):
        result = subprocess.run(['bash', str(self.root / 'scripts/build_ffmpeg.sh')],
                                cwd=self.root.parent, env=self.env,
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertEqual(list((self.root / 'build').glob(f'ffmpeg-{VERSION}.*')), [])
        return result

    def assert_outputs(self):
        for name in ('ffmpeg', 'ffprobe'):
            self.assertEqual((self.root / 'Assets/tools' / name).read_bytes(), b'pinned source')
        self.assertEqual((self.root / 'build/ffmpeg-config.h').read_bytes(), b'pinned source')
        self.assertEqual((self.root / 'build/ffmpeg-config.log').read_bytes(), b'pinned source')
        for name in LICENSES:
            self.assertEqual((self.root / 'build/ffmpeg-licenses' / name).read_text(),
                             f'pinned {name}')
        manifest = (self.root / 'build/ffmpeg-sha256.txt').read_text().splitlines()
        self.assertEqual(manifest[0], f'{self.digest}  Vendor/ffmpeg-{VERSION}.tar.xz')
        for name, line in zip(('ffmpeg', 'ffprobe'), manifest[1:]):
            self.assertEqual(line, f'{hashlib.sha256(b"pinned source").hexdigest()}  Assets/tools/{name}')
        self.assertEqual(len(manifest), 3)

    def assert_build_not_started(self):
        for name in ('configure-cwds', 'make-calls', 'Assets/tools/ffmpeg',
                     'build/ffmpeg-sha256.txt'):
            self.assertFalse((self.root / name).exists(), name)

    def test_modified_old_tree_is_preserved_and_each_build_uses_fresh_sources(self):
        old = self.root / f'Vendor/ffmpeg-{VERSION}'
        old.mkdir()
        (old / 'source.txt').write_text('locally modified source')
        (old / 'configure').write_text('#!/bin/bash\nexit 91\n')
        (old / 'configure').chmod(0o755)
        before = {p.name: p.read_bytes() for p in old.iterdir()}
        for _ in range(2):
            self.run_build()
            self.assert_outputs()
            self.assertEqual({p.name: p.read_bytes() for p in old.iterdir()}, before)
        cwds = (self.root / 'configure-cwds').read_text().splitlines()
        self.assertEqual(len(cwds), 2)
        self.assertNotEqual(cwds[0], cwds[1])
        for cwd in cwds:
            self.assertEqual(pathlib.Path(cwd).parent.parent, self.root / 'build')
            self.assertFalse(pathlib.Path(cwd).exists())
        self.assertFalse((self.root / 'curl-args').exists())
        args = (self.root / 'configure-args').read_text().splitlines()
        self.assertIn('--disable-network', args)
        self.assertIn('--disable-autodetect', args)
        self.assertEqual([arg for arg in args if arg.startswith('--enable-protocol=')],
                         ['--enable-protocol=file,pipe'])
        self.assertEqual((self.root / 'make-calls').read_text().splitlines(),
                         ['clean', '-j4', 'clean', '-j4'])

    def test_old_tree_symlink_does_not_modify_user_directory(self):
        user = self.root / 'user sources'
        user.mkdir()
        (user / 'source.txt').write_text('user changes')
        old = self.root / f'Vendor/ffmpeg-{VERSION}'
        old.symlink_to(user, target_is_directory=True)
        self.run_build()
        self.assert_outputs()
        self.assertTrue(old.is_symlink())
        self.assertEqual(list(user.iterdir()), [user / 'source.txt'])
        self.assertEqual((user / 'source.txt').read_text(), 'user changes')

    def test_corrupt_archive_fails_sha_before_extraction_or_build(self):
        self.archive.write_bytes(self.archive.read_bytes() + b'corruption')
        result = self.run_build(expected=1)
        self.assertIn('FAILED', result.stdout + result.stderr)
        self.assert_build_not_started()

    def test_cached_archive_change_after_verification_does_not_change_build_input(self):
        # Simulate replacement of the shared cache just as tar starts. Extraction
        # must consume the private file whose SHA has already been checked.
        real_tar = shutil.which('tar')
        self.assertIsNotNone(real_tar)
        self.write_command('tar', f'''#!/bin/bash
printf 'replaced cache' > {shlex.quote(str(self.archive))}
exec {shlex.quote(real_tar)} "$@"
''')
        self.run_build()
        self.assert_outputs()
        self.assertEqual(self.archive.read_bytes(), b'replaced cache')

    def test_downloaded_archive_is_verified_and_built(self):
        downloaded = self.root / 'download.tar.xz'
        self.archive.rename(downloaded)
        self.env['TEST_DOWNLOAD_ARCHIVE'] = str(downloaded)
        self.run_build()
        self.assert_outputs()
        self.assertEqual((self.root / 'curl-args').read_text().splitlines(),
                         ['--fail', '--location', '--retry', '3',
                          f'https://ffmpeg.org/releases/ffmpeg-{VERSION}.tar.xz',
                          '-o', f'Vendor/ffmpeg-{VERSION}.tar.xz'])

    def test_corrupt_download_is_rejected(self):
        downloaded = self.root / 'download.tar.xz'
        self.archive.rename(downloaded)
        downloaded.write_bytes(b'corrupt download')
        self.env['TEST_DOWNLOAD_ARCHIVE'] = str(downloaded)
        self.run_build(expected=1)
        self.assert_build_not_started()

    def test_extraction_failure_cleans_only_its_staging_directory(self):
        self.archive.write_bytes(b'not a tar archive')
        self.write_build_script(hashlib.sha256(self.archive.read_bytes()).hexdigest())
        build = self.root / 'build'
        build.mkdir()
        unrelated = build / f'ffmpeg-{VERSION}.user'
        unrelated.mkdir()
        (unrelated / 'keep').write_text('user data')
        result = subprocess.run(['bash', str(self.root / 'scripts/build_ffmpeg.sh')],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(build.iterdir()), [unrelated])
        self.assertEqual((unrelated / 'keep').read_text(), 'user data')
        self.assert_build_not_started()

    def test_configure_and_make_failures_clean_staging_and_preserve_outputs(self):
        tools = self.root / 'Assets/tools'
        tools.mkdir(parents=True)
        for name in ('ffmpeg', 'ffprobe'):
            (tools / name).write_text('previous build')
        for variable, code in (('TEST_FAIL_CONFIGURE', 23), ('TEST_FAIL_MAKE', 24)):
            with self.subTest(stage=variable):
                self.env[variable] = '1'
                self.run_build(expected=code)
                self.env.pop(variable)
                for name in ('ffmpeg', 'ffprobe'):
                    self.assertEqual((tools / name).read_text(), 'previous build')
                self.assertFalse((self.root / 'build/ffmpeg-sha256.txt').exists())

    def test_packaging_uses_verified_licenses_without_a_vendor_tree(self):
        self.run_build()
        shutil.copyfile(ROOT / 'scripts/licenses.py', self.root / 'scripts/licenses.py')
        (self.root / '.build/checkouts').mkdir(parents=True)
        (self.root / 'docs').mkdir()
        (self.root / 'docs/ThirdParty.md').write_text('third party fixture')
        speaker = self.root / 'ThirdParty/SpeakerKit'
        speaker.mkdir(parents=True)
        for name in ('LICENSE', 'NOTICES'):
            (speaker / name).write_text(name)
        dest = self.root / 'packaged licenses'
        subprocess.run([sys.executable, str(self.root / 'scripts/licenses.py'), str(dest)],
                       check=True, capture_output=True, text=True, timeout=30)
        for name in LICENSES:
            self.assertEqual((dest / f'ffmpeg-{name}').read_text(), f'pinned {name}')


if __name__ == '__main__':
    unittest.main()
