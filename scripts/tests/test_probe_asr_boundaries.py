import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))
import probe_asr_boundaries as probe


class BoundaryScoringTests(unittest.TestCase):
    def fixture(self, root, reference, segments):
        write = probe.matrix.write
        write(root / 'boundary-evaluation.json', {'sources': [dict(id='fixture', inferenceSourceID='pcm',
            sourceHash='sha', durationMs=1000, referencePath=str(root / 'reference.json'))]})
        write(root / 'reference.json', dict(schemaVersion=1, sourceHash='sha', segments=[reference]))
        window = dict(sourceID='pcm', startMs=0, endMs=1000)
        write(root / 'live-plan.json', [window])
        write(root / 'live/windows/0.json', dict(window=window, segments=segments))

    def reference(self, text, **extra):
        return dict(id='reviewed', startMs=0, endMs=1000, text=text,
            verified=True, verifiedBy='fixture-human', **extra)

    def test_missing_or_changed_window_fails_instead_of_scoring_partial_run(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            self.fixture(root, self.reference('word'), [])
            probe.matrix.write(root / 'live-plan.json', [dict(sourceID='pcm', startMs=1, endMs=1000)])
            with self.assertRaises(ValueError):
                probe.evaluate(root, 'live')
            (root / 'live/windows/0.json').unlink()
            with self.assertRaises(ValueError):
                probe.evaluate(root, 'live')

    def test_corpus_alias_reuses_same_pcm_without_merging_scores(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            self.fixture(root, self.reference('word'), [dict(text='word', startMs=100, endMs=200)])
            self.assertEqual(probe.evaluate(root, 'live')['fixture']['totals']['speechWER'], 0)

    def test_unknown_mask_is_not_noise_and_alignment_resets(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            ref = self.reference('alpha [unknown] beta', maskedScoringEligible=True, verifiedMasks=[dict(
                id='unknown', startMs=400, endMs=600, marker='[unknown]', kind='unintelligibleOverlappingSpeech',
                verified=True, verifiedBy='fixture-human')])
            self.fixture(root, ref, [dict(text='alpha', startMs=700, endMs=800)])
            total = probe.evaluate(root, 'live')['fixture']['totals']
            self.assertEqual((total['substitutions'], total['deletions'], total['nonSpeechFalseWords']), (1, 1, 0))

    def test_crossing_noise_word_is_reported_without_deleting_hypothesis(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            self.fixture(root, self.reference('', kind='nonSpeech'), [dict(text='word', startMs=100, endMs=1100)])
            total = probe.evaluate(root, 'live')['fixture']['totals']
            self.assertIsNone(total['speechWER'])
            self.assertEqual(total['nonSpeechFalseWords'], 1)
            self.assertEqual(total['nonSpeechBoundaryCrossingWords'], 1)
            self.assertEqual(len(probe.matrix.read(root / 'live/windows/0.json')['segments']), 1)


if __name__ == '__main__':
    unittest.main()
