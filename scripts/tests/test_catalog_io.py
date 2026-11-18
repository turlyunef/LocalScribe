import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('catalog_io', Path(__file__).parents[1] / 'catalog_io.py')
catalog_io = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog_io)


class CatalogIoTests(unittest.TestCase):
    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name)
        self._cache = catalog_io.CACHE
        catalog_io.CACHE = self.root / 'cache'
        self.source = self.root / 'source.json'
        self.source.write_bytes(b'{"sha": "fixed"}')
        self.url = self.source.as_uri()

    def tearDown(self):
        catalog_io.CACHE = self._cache
        self._temporary.cleanup()

    def cache_entry(self):
        return catalog_io.CACHE / hashlib.sha256(self.url.encode()).hexdigest()

    def test_get_reads_url(self):
        self.assertEqual(catalog_io.get(self.url), b'{"sha": "fixed"}')

    def test_read_limit_raises_clear_error(self):
        with self.assertRaises(ValueError) as raised:
            catalog_io.get(self.url, max_bytes=4)
        self.assertIn('4', str(raised.exception))
        self.assertIn(self.url, str(raised.exception))
        self.assertFalse(self.cache_entry().exists())

    def test_read_limit_equal_size_passes(self):
        self.assertEqual(catalog_io.get(self.url, max_bytes=len(b'{"sha": "fixed"}')), b'{"sha": "fixed"}')

    def test_immutable_caches_and_serves_stale_copy(self):
        self.assertEqual(catalog_io.get(self.url, immutable=True), b'{"sha": "fixed"}')
        self.assertTrue(self.cache_entry().is_file())
        self.source.write_bytes(b'{"sha": "changed"}')
        self.assertEqual(catalog_io.get(self.url, immutable=True), b'{"sha": "fixed"}')

    def test_default_never_reads_or_writes_cache(self):
        self.cache_entry().parent.mkdir(parents=True)
        self.cache_entry().write_bytes(b'stale heuristic cache')
        self.source.write_bytes(b'{"sha": "changed"}')
        self.assertEqual(catalog_io.get(self.url), b'{"sha": "changed"}')
        self.assertEqual(self.cache_entry().read_bytes(), b'stale heuristic cache')


if __name__ == '__main__':
    unittest.main()
