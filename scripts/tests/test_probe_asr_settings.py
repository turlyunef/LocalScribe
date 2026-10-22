import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))
import probe_asr_settings as probe


class SettingsScoringTests(unittest.TestCase):
    def fixture(self, root, segments, reference):
        write = probe.matrix.write
        write(root / 'settings-evaluation.json', {'sources': [dict(id='fixture', sourceHash='sha', durationMs=1000,
            kind='test-only', referencePath=str(root / 'reference.json'))]})
        write(root / 'reference.json', dict(schemaVersion=1, sourceHash='sha', segments=[reference]))
        window = dict(sourceID='fixture', startMs=0, endMs=1000, readStartMs=0, readEndMs=1000)
        write(root / 'settings-plan.json', [window])
        write(root / 'baseline/windows/0.json', dict(window=window, segments=segments, preserved=segments))

    def interval(self, text, **extra):
        return dict(id='known', startMs=0, endMs=1000, text=text, verified=True, verifiedBy='fixture-human', **extra)

    def test_mask_resets_alignment_without_counting_unknown_speech_as_noise(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            interval = self.interval('alpha [unknown] beta', maskedScoringEligible=True, verifiedMasks=[
                dict(id='unknown', startMs=400, endMs=600, marker='[unknown]', kind='unintelligibleOverlappingSpeech',
                     verified=True, verifiedBy='fixture-human')])
            self.fixture(root, [dict(text='alpha', startMs=700, endMs=800)], interval)
            total = probe.evaluate(root, 'baseline')['fixture']['totals']
            self.assertEqual((total['substitutions'], total['deletions']), (1, 1))
            self.assertEqual(total['nonSpeechFalseWords'], 0)

    def test_sparse_retry_retains_original_outside_selected_windows(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            self.fixture(root, [dict(text='known', startMs=100, endMs=200)], self.interval('known'))
            self.assertEqual(probe.evaluate(root, 'retry'), probe.evaluate(root, 'baseline'))
            with self.assertRaises(ValueError):
                probe.evaluate(root, 'lexicon')

    def test_nonspeech_has_null_wer_and_false_words(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            self.fixture(root, [dict(text='invented term', startMs=100, endMs=300)], self.interval('', kind='nonSpeech'))
            total = probe.evaluate(root, 'baseline')['fixture']['totals']
            self.assertIsNone(total['speechWER'])
            self.assertEqual(total['nonSpeechFalseWords'], 2)

    def test_changed_plan_or_unverified_reference_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            self.fixture(root, [], dict(self.interval('known'), verifiedBy=''))
            with self.assertRaises(ValueError):
                probe.evaluate(root, 'baseline')
            self.fixture(root, [], self.interval('known'))
            probe.matrix.write(root / 'settings-plan.json', [dict(sourceID='fixture', startMs=5)])
            with self.assertRaises(ValueError):
                probe.evaluate(root, 'baseline')

    def test_placeholder_is_scored_and_truncated_word_excluded(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            self.fixture(root, [dict(text='[неразборчиво]', startMs=100, endMs=300)], self.interval('known'))
            self.assertEqual(probe.evaluate(root, 'baseline')['fixture']['totals']['substitutions'], 1)
            self.fixture(root, [], self.interval('part', wordBoundaryTruncated=True))
            total = probe.evaluate(root, 'baseline')['fixture']['totals']
            self.assertEqual(total['excludedBoundaryIntervals'], 1)
            self.assertIsNone(total['speechWER'])


if __name__ == '__main__':
    unittest.main()
