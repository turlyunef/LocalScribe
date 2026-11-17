import copy
import pathlib
import sys
import tempfile
import unittest
import wave

sys.path.insert(0, str(pathlib.Path(__file__).parents[1]))
import probe_live_caption_comparison as probe


def phrase(text, start=0, end=1000, **extra):
    return dict(text=text, startMs=start, endMs=end, **extra)


class CaptionComparisonTests(unittest.TestCase):
    def test_missing_primary_word_is_found_even_without_uncertainty(self):
        result = probe.compare([phrase('мы сегодня обсудим новый релиз')],
                               [phrase('мы сегодня подробно обсудим новый релиз')], 1000)
        candidate, = result['differences']
        self.assertEqual(candidate['reason'], 'primaryOmissionCandidate')
        self.assertTrue(candidate['eligibleForReview'])
        self.assertFalse(candidate['automaticEdit'])

    def test_caption_omission_cannot_delete_existing_primary_words(self):
        result = probe.compare([phrase('мы сегодня подробно обсудим новый релиз')],
                               [phrase('мы сегодня обсудим новый релиз')], 1000)
        self.assertIn('captionOmissionCannotDeletePrimary', result['differences'][0]['rejectedBecause'])

    def test_edges_and_broad_rewrites_are_not_review_candidates(self):
        result = probe.compare([phrase('первый мы сегодня один два три четыре пять шесть новый релиз')],
                               [phrase('другой мы сегодня совсем новый релиз')], 1000)
        self.assertEqual(len(result['differences']), 2)
        self.assertTrue(all(not c['eligibleForReview'] for c in result['differences']))

    def test_identical_phrases_at_other_times_are_not_anchors(self):
        result = probe.compare([phrase('мы сегодня обсудим новый релиз', 0, 1000)],
                               [phrase('мы сегодня проверим новый релиз', 4000, 5000)], 5000)
        self.assertIn('timingMismatch', result['differences'][0]['rejectedBecause'])

    def test_confident_wrong_primary_word_can_be_reviewed_and_sensitive_changes_are_marked(self):
        result = probe.compare([phrase('мы сегодня удаляем все старые записи')],
                               [phrase('мы сегодня не удаляем все старые записи')], 1000)
        candidate, = result['differences']
        self.assertTrue(candidate['sensitive'])
        self.assertTrue(candidate['eligibleForReview'])

    def test_scoring_exposes_both_helpful_and_harmful_candidates_without_choosing_by_reference(self):
        a = [phrase('мы сегодня починим новый релиз и потом проверим этот модуль')]
        b = [phrase('мы сегодня сломаем новый релиз и потом запустим этот модуль')]
        result = probe.compare(a, b, 1000)
        before = copy.deepcopy(result['differences'])
        scores = probe.score(result, 'мы сегодня починим новый релиз и потом запустим этот модуль')
        self.assertEqual(scores['eligibleEffects'], dict(improved=1, worsened=1, sameErrorCount=0))
        self.assertEqual([c['eligibleForReview'] for c in before], [c['eligibleForReview'] for c in result['differences']])
        self.assertEqual(scores['primary']['wer'], scores['hypotheticalAllReviewCandidates']['wer'])

    def test_punctuation_case_and_yo_do_not_create_spurious_differences(self):
        self.assertFalse(probe.compare([phrase('Ещё один GitHub-review.')],
                                       [phrase('еще один github review')], 1000)['differences'])

    def test_forged_word_layer_and_invalid_timeline_are_rejected(self):
        with self.assertRaises(ValueError):
            probe.units([phrase('one', words=[phrase('other')])], 1000)
        for data in ([phrase('one', -1, 10)], [phrase('one', 0, 1001)],
                     [phrase('one', 500, 700), phrase('two', 0, 200)]):
            with self.assertRaises(ValueError):
                probe.units(data, 1000)

    def fixture(self, root):
        audio = root / 'source.wav'
        with wave.open(str(audio), 'wb') as file:
            file.setnchannels(1)
            file.setsampwidth(2)
            file.setframerate(16000)
            file.writeframes(b'\x00\x00' * 16000)
        transcript = root / 'primary.json'
        probe.write(transcript, dict(schemaVersion=1, segments=[phrase('мы сегодня обсудим новый релиз')]))
        source = dict(id='clip', durationMs=1000, language='mixed', audioPath=str(audio),
                      audioSHA256=probe.digest(audio), transcriptPath=str(transcript), transcriptSHA256=probe.digest(transcript))
        probe.write(root / 'input.json', dict(schemaVersion=1, speed=4, sources=[source]))
        native = dict(schemaVersion=1, source=source, speed=4, consumedFrames=16000, droppedBuffers=0,
                      elapsedSeconds=1, readyAfterSeconds=0, unfinishedPhrases=1,
                      segments=[phrase('мы сегодня подробно обсудим новый релиз')])
        probe.write(root / 'captions/clip.json', native)
        return source, native

    def test_missing_native_output_dropped_buffers_and_changed_inputs_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            source, native = self.fixture(root)
            report = probe.evaluate(root)
            self.assertNotIn('scores', report['sources'][0])
            self.assertEqual(report['sources'][0]['unfinishedPhrases'], 1)
            native['droppedBuffers'] = 1
            probe.write(root / 'captions/clip.json', native)
            with self.assertRaises(ValueError):
                probe.evaluate(root)
            (root / 'captions/clip.json').unlink()
            with self.assertRaises(FileNotFoundError):
                probe.evaluate(root)
            pathlib.Path(source['transcriptPath']).write_text('{}')
            with self.assertRaises(ValueError):
                probe.evaluate(root)

    def test_reference_must_match_audio_and_have_explicit_provenance(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            source, _ = self.fixture(root)
            ref = dict(id='clip', audioSHA256=source['audioSHA256'], text='мы сегодня обсудим новый релиз',
                       verified=True, provenance='synthetic test reference')
            report = probe.evaluate(root, dict(schemaVersion=1, sources=[ref]))
            self.assertIn('scores', report['sources'][0])
            ref['audioSHA256'] = 'other audio'
            with self.assertRaises(ValueError):
                probe.evaluate(root, dict(schemaVersion=1, sources=[ref]))

    def test_completion_rejects_partial_sets_and_changed_caption_content(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            self.fixture(root)
            input_hash = probe.digest(root / 'input.json')
            probe.write(root / 'freeze.json', dict(inputSHA256=input_hash))
            completion = dict(inputSHA256=input_hash, captions={'clip': probe.digest(root / 'captions/clip.json')})
            probe.write(root / 'completed.json', completion)
            probe.validate_completed(root)
            completion['captions'] = {}
            probe.write(root / 'completed.json', completion)
            with self.assertRaises(ValueError):
                probe.validate_completed(root)
            completion['captions'] = {'clip': 'changed'}
            probe.write(root / 'completed.json', completion)
            with self.assertRaises(ValueError):
                probe.validate_completed(root)

    def test_silence_reference_reports_false_words_without_inventing_wer(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            source, _ = self.fixture(root)
            ref = dict(id='clip', audioSHA256=source['audioSHA256'], text='', verified=True, provenance='test silence')
            report = probe.evaluate(root, dict(schemaVersion=1, sources=[ref]))
            self.assertIsNone(report['sources'][0]['scores']['primary']['wer'])
            self.assertGreater(report['sources'][0]['scores']['primary']['insertions'], 0)
            self.assertIn('нет слов в эталоне', probe.markdown(report))
            del ref['provenance']
            with self.assertRaises(ValueError):
                probe.evaluate(root, dict(schemaVersion=1, sources=[ref]))


if __name__ == '__main__':
    unittest.main()
