import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('lock_qwen_models', Path(__file__).parents[1] / 'lock_qwen_models.py')
lock = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lock)


class LockQwenModelsTests(unittest.TestCase):
    def test_lfs_digest_does_not_download_weights(self):
        original = lock.get
        lock.get = lambda *_args, **_kwargs: self.fail('Weights must never be fetched by the catalog generator')
        try:
            files = lock.lock_files('fixture/local', 'fixed', {'siblings': [
                dict(rfilename='model.safetensors', size=42, lfs={'sha256': 'a' * 64})]}, {'model.safetensors'})
            self.assertEqual(files[0]['sha256'], 'a' * 64)
        finally:
            lock.get = original

    def test_incomplete_repository_fails(self):
        with self.assertRaises(ValueError):
            lock.lock_files('fixture/local', 'fixed', {'siblings': []}, {'config.json'})

    def test_large_file_without_published_hash_fails_before_download(self):
        with self.assertRaises(ValueError):
            lock.lock_files('fixture/local', 'fixed', {'siblings': [
                dict(rfilename='model.safetensors', size=10_000_001)]}, {'model.safetensors'})
