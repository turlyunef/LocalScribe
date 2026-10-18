"""Bootstrap regressions using tiny fixtures and a mocked HTTP source; no weights/network."""
import contextlib
import hashlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    'download_models', pathlib.Path(__file__).resolve().parents[1] / 'download_models.py')
bootstrap = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bootstrap)


class DownloadModelsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name)
        self.dest = self.root / 'models'
        self.contents = {'config.json': b'{"model":"fixture"}',
                         'weights/model.bin': b'tiny fixture weights'}
        self.model = {
            'id': 'summary-4b', 'repository': 'fixture/models', 'revision': 'pinned',
            'files': [{'path': name, 'localPath': name, 'size': len(data),
                       'sha256': hashlib.sha256(data).hexdigest()}
                      for name, data in self.contents.items()]}
        self.catalog = {'schemaVersion': 1, 'models': [self.model]}
        resources = self.root / 'Resources'
        resources.mkdir()
        (resources / 'models.lock.json').write_text(json.dumps(self.catalog))
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(bootstrap, 'ROOT', self.root).start()
        mock.patch.object(bootstrap.time, 'sleep').start()
        self.output = io.StringIO()
        self.enterContext(contextlib.redirect_stdout(self.output))
        self.requests = []
        self.source = mock.patch.object(bootstrap.urllib.request, 'urlopen',
                                        side_effect=self.respond).start()

    def respond(self, request, timeout):
        self.requests.append(request)
        prefix = 'https://huggingface.co/fixture/models/resolve/pinned/'
        self.assertTrue(request.full_url.startswith(prefix))
        data = self.contents[request.full_url.removeprefix(prefix)]
        offset = int(request.get_header('Range').removeprefix('bytes=').removesuffix('-')) \
            if request.has_header('Range') else 0
        response = io.BytesIO(data[offset:])
        response.status = 206 if offset else 200
        return response

    def write_model(self, directory):
        for name, data in self.contents.items():
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

    def prepare_final(self, damage):
        final = self.dest / self.model['id']
        final.mkdir(parents=True)
        if damage != 'empty':
            self.write_model(final)
            weights = final / 'weights/model.bin'
            if damage == 'missing':
                weights.unlink()
            elif damage == 'size':
                weights.write_bytes(b'x')
            elif damage == 'sha':
                weights.write_bytes(b'x' * len(self.contents['weights/model.bin']))
        return final

    def run_cli(self):
        bootstrap.main([str(self.dest), '--model', self.model['id']])

    def assert_ready(self):
        final = self.dest / self.model['id']
        for name, data in self.contents.items():
            self.assertEqual((final / name).read_bytes(), data)
        self.assertEqual(json.loads((self.dest / 'catalog.json').read_text()), self.catalog)
        self.assertFalse((self.dest / (self.model['id'] + '.partial')).exists())

    def test_repairs_empty_missing_wrong_size_and_wrong_sha_final(self):
        for damage in ('empty', 'missing', 'size', 'sha'):
            with self.subTest(damage=damage):
                self.dest = self.root / damage / 'models'
                self.prepare_final(damage)
                self.source.reset_mock()
                self.run_cli()
                self.assert_ready()
                self.assertEqual(self.source.call_count, len(self.contents))

    def test_valid_final_is_not_downloaded_or_replaced_even_with_stale_partial(self):
        final = self.prepare_final('valid')
        inode = final.stat().st_ino
        partial = self.dest / (self.model['id'] + '.partial')
        partial.mkdir()
        (partial / 'config.json').write_bytes(b'broken')
        self.run_cli()
        self.source.assert_not_called()
        self.assertEqual(final.stat().st_ino, inode)
        for name, data in self.contents.items():
            self.assertEqual((final / name).read_bytes(), data)
        self.assertEqual((partial / 'config.json').read_bytes(), b'broken')
        self.assertEqual(json.loads((self.dest / 'catalog.json').read_text()), self.catalog)

    def test_fresh_destination_installs_complete_model(self):
        self.run_cli()
        self.assert_ready()

    def test_valid_partial_repairs_final_without_network(self):
        self.prepare_final('empty')
        self.write_model(self.dest / (self.model['id'] + '.partial'))
        self.run_cli()
        self.assert_ready()
        self.source.assert_not_called()

    def test_partial_preserves_verified_files_and_resumes_short_file(self):
        self.prepare_final('sha')
        partial = self.dest / (self.model['id'] + '.partial')
        self.write_model(partial)
        weights = partial / 'weights/model.bin'
        weights.write_bytes(self.contents['weights/model.bin'][:5])
        self.run_cli()
        self.assert_ready()
        self.source.assert_called_once()
        self.assertEqual(self.requests[0].get_header('Range'), 'bytes=5-')

    def test_complete_corrupt_partial_restarts_without_range(self):
        partial = self.dest / (self.model['id'] + '.partial')
        self.write_model(partial)
        (partial / 'weights/model.bin').write_bytes(
            b'x' * len(self.contents['weights/model.bin']))
        self.run_cli()
        self.assert_ready()
        self.source.assert_called_once()
        self.assertFalse(self.requests[0].has_header('Range'))

    def test_bad_source_exits_nonzero_preserves_final_and_does_not_publish_catalog(self):
        for damage in ('empty', 'missing', 'size', 'sha'):
            with self.subTest(damage=damage):
                self.dest = self.root / damage / 'models'
                final = self.prepare_final(damage)
                before = {p.relative_to(final): p.read_bytes()
                          for p in final.rglob('*') if p.is_file()}
                self.source.side_effect = lambda *a, **kw: io.BytesIO(b'bad source')
                errors = io.StringIO()
                with contextlib.redirect_stderr(errors), self.assertRaises(SystemExit) as caught:
                    self.run_cli()
                self.assertEqual(caught.exception.code, 1)
                self.assertIn('size/SHA-256 mismatch', errors.getvalue())
                self.assertFalse((self.dest / 'catalog.json').exists())
                self.assertEqual({p.relative_to(final): p.read_bytes()
                                  for p in final.rglob('*') if p.is_file()}, before)

    def test_network_failure_keeps_existing_catalog_and_verified_partial(self):
        self.prepare_final('empty')
        catalog_path = self.dest / 'catalog.json'
        catalog_path.write_bytes(b'previous catalog')
        partial = self.dest / (self.model['id'] + '.partial')
        self.write_model(partial)
        (partial / 'weights/model.bin').unlink()
        self.source.side_effect = OSError('source unavailable')
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors), self.assertRaises(SystemExit) as caught:
            self.run_cli()
        self.assertEqual(caught.exception.code, 1)
        self.assertIn('source unavailable', errors.getvalue())
        self.assertEqual(catalog_path.read_bytes(), b'previous catalog')
        self.assertEqual((partial / 'config.json').read_bytes(), self.contents['config.json'])
        self.assertEqual(list((self.dest / self.model['id']).iterdir()), [])

    def test_rechecks_whole_partial_before_replacing_final(self):
        self.prepare_final('empty')
        partial = self.dest / (self.model['id'] + '.partial')
        self.write_model(partial)
        original_download = bootstrap.download

        def corrupt_after_download(dest, item):
            original_download(dest, item)
            if item[1]['localPath'] == 'weights/model.bin':
                (partial / 'weights/model.bin').write_bytes(
                    b'x' * len(self.contents['weights/model.bin']))

        with mock.patch.object(bootstrap, 'download', side_effect=corrupt_after_download):
            errors = io.StringIO()
            with contextlib.redirect_stderr(errors), self.assertRaises(SystemExit) as caught:
                self.run_cli()
        self.assertEqual(caught.exception.code, 1)
        self.assertIn('incomplete or corrupt .partial', errors.getvalue())
        self.assertTrue((self.dest / self.model['id']).is_dir())
        self.assertFalse((self.dest / 'catalog.json').exists())

    def test_does_not_publish_any_profile_until_all_partials_are_verified(self):
        final = self.prepare_final('empty')
        self.write_model(self.dest / (self.model['id'] + '.partial'))
        other = dict(self.model, id='other')
        catalog = dict(self.catalog, models=[self.model, other])
        self.source.side_effect = OSError('source unavailable')
        with self.assertRaisesRegex(RuntimeError, 'source unavailable'):
            bootstrap.bootstrap(self.dest, catalog)
        self.assertEqual(list(final.iterdir()), [])
        self.assertTrue((self.dest / (self.model['id'] + '.partial')).is_dir())
        self.assertFalse((self.dest / 'other').exists())
        self.assertFalse((self.dest / 'catalog.json').exists())


if __name__ == '__main__':
    unittest.main()
