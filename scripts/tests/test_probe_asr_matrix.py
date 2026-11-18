import importlib.util
import pathlib
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("probe_asr_matrix", pathlib.Path(__file__).parents[1] / "probe_asr_matrix.py")
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


class ASRMatrixScoringTests(unittest.TestCase):
    def test_child_environment_excludes_credentials_and_existing_probe_switches(self):
        with patch.dict(probe.os.environ, {"PATH": "/usr/bin", "GITHUB_TOKEN": "fixture-secret",
                                         "LOCALSCRIBE_ASR_MATRIX_PROBE": "unexpected"}, clear=True):
            self.assertEqual(probe.process_environment(), {"PATH": "/usr/bin"})

    def test_error_counts_distinguish_lost_added_and_changed_words(self):
        self.assertEqual(probe.word_errors(["один", "два"], ["один"]),
                         dict(referenceWords=2, substitutions=0, deletions=1, insertions=0, wer=0.5))
        self.assertEqual(probe.word_errors(["проксы"], ["акции"])["substitutions"], 1)
        self.assertEqual(probe.word_errors(["один"], ["один", "два"])["insertions"], 1)
        self.assertEqual(probe.word_errors([], ["шум"])["wer"], None)

    def test_normalization_keeps_numbers_negation_and_technical_terms(self):
        self.assertEqual(probe.tokens("Ещё НЕ 42; GeoIP, code-review!"),
                         ["еще", "не", "42", "geoip", "code", "review"])
        self.assertEqual(probe.tokens("Kubernetes"), ["kubernetes"])
        self.assertNotEqual(probe.tokens("не отправили"), probe.tokens("отправили"))

    def test_only_human_reviewed_intervals_can_produce_a_score(self):
        reference = {"schemaVersion": 1, "sourceHash": "sha", "segments": [
            {"startMs": 0, "endMs": 1000, "text": "автоматический текст", "verified": False}]}
        self.assertEqual(probe.reviewed_intervals(reference, "sha", 1000), [])
        reference["segments"][0]["verified"] = True
        with self.assertRaises(ValueError):
            probe.reviewed_intervals(reference, "sha", 1000)
        reference["segments"][0]["verifiedBy"] = "reviewer"
        self.assertEqual(len(probe.reviewed_intervals(reference, "sha", 1000)), 1)
        with self.assertRaises(ValueError):
            probe.reviewed_intervals(reference, "another-source", 1000)
        reference["segments"].append(dict(reference["segments"][0]))
        with self.assertRaises(ValueError):
            probe.reviewed_intervals(reference, "sha", 1000)

    def test_noise_requires_explicit_reviewed_nonspeech_label(self):
        interval = {"id": "noise", "startMs": 0, "endMs": 1000, "text": "", "verified": True, "verifiedBy": "user"}
        reference = {"schemaVersion": 1, "sourceHash": "sha", "segments": [interval]}
        with self.assertRaises(ValueError):
            probe.reviewed_intervals(reference, "sha", 1000)
        interval["kind"] = "nonSpeech"
        self.assertEqual(probe.reviewed_intervals(reference, "sha", 1000), [interval])
        interval["text"] = "noise"
        with self.assertRaises(ValueError):
            probe.reviewed_intervals(reference, "sha", 1000)
        del interval["text"]
        with self.assertRaises(ValueError):
            probe.reviewed_intervals(reference, "sha", 1000)

    def test_nonspeech_counts_false_words_with_undefined_wer(self):
        noise = {"id": "noise", "text": "", "kind": "nonSpeech"}
        score = probe.score_interval(noise, "гендер")
        self.assertEqual(score["insertions"], 1)
        self.assertIsNone(score["wer"])
        total = probe.aggregate_scores([score])
        self.assertIsNone(total["wer"])
        self.assertIsNone(total["speechWER"])
        self.assertEqual(total["nonSpeechFalseWords"], 1)
        self.assertEqual(probe.aggregate_scores([probe.score_interval(noise, "")])["nonSpeechFalseWords"], 0)

    def test_truncated_word_is_preserved_but_excluded_from_aggregate_wer(self):
        fragment = {"id": "partial", "text": "То есть, возмож", "kind": "speech", "wordBoundaryTruncated": True}
        score = probe.score_interval(fragment, "То есть, возможно")
        self.assertEqual(score["substitutions"], 1)
        total = probe.aggregate_scores([score, probe.score_interval({"id": "full", "text": "платёжка"}, "платёжка")])
        self.assertEqual(total["referenceWords"], 1)
        self.assertEqual(total["excludedBoundaryIntervals"], 1)
        self.assertEqual(total["wer"], 0)

    def test_nonspeech_boundary_crossing_is_reported_as_possible_alignment_error(self):
        reference = {"id": "noise", "startMs": 200, "endMs": 800, "kind": "nonSpeech", "text": ""}
        transcript = {"segments": [{"text": "cross inside outside", "startMs": 100, "endMs": 1000, "words": [
            {"text": "cross", "startMs": 100, "endMs": 900},
            {"text": " inside", "startMs": 300, "endMs": 500},
            {"text": " outside", "startMs": 900, "endMs": 1000}]}]}
        score = probe.score_transcript_interval(reference, transcript)
        self.assertEqual(score["insertions"], 2)
        self.assertEqual(score["nonSpeechBoundaryCrossingWords"], 1)
        self.assertEqual(probe.aggregate_scores([score])["nonSpeechBoundaryCrossingWords"], 1)

    def test_interval_scoring_uses_original_word_midpoints_and_keeps_placeholder(self):
        transcript = {"segments": [
            {"startMs": 0, "endMs": 3000, "text": "лево центр право", "words": [
                {"startMs": 0, "endMs": 1000, "text": "лево"},
                {"startMs": 1000, "endMs": 2000, "text": " центр"},
                {"startMs": 2000, "endMs": 3000, "text": " право"}]},
            {"startMs": 3000, "endMs": 4000, "text": "[неразборчиво]", "words": []}]}
        self.assertEqual(probe.interval_text(transcript, 1000, 2000), "центр")
        self.assertEqual(probe.interval_text(transcript, 3000, 4000), "[неразборчиво]")
        self.assertEqual(probe.interval_text({"segments": [
            {"startMs": 0, "endMs": 1000, "text": "первый", "words": []},
            {"startMs": 1000, "endMs": 2000, "text": "второй", "words": []}]}, 0, 2000), "первый второй")

    def test_report_does_not_invent_wer_without_a_verified_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            with probe.wave.open(str(output / "input.wav"), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\x00\x00" * 16000)
            probe.write(output / "input.json", {"sourceHash": "sha", "waveHash": probe.digest(output / "input.wav")})
            probe.write(output / "reference.template.json", {"schemaVersion": 1, "sourceHash": "sha", "segments": []})
            probe.report(output)
            self.assertEqual(probe.read(output / "comparison.json")["qualityStatus"], "awaiting-reviewed-reference")

    def test_reference_line_breaks_cannot_inject_block_markup_into_review_markdown(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            with probe.wave.open(str(output / "input.wav"), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\x00\x00" * 16000)
            probe.write(output / "input.json", {"sourceHash": "sha", "waveHash": probe.digest(output / "input.wav")})
            probe.write(output / "reference.template.json", {"schemaVersion": 1, "sourceHash": "sha", "segments": [
                {"id": "payment\n# Подделка", "startMs": 0, "endMs": 1000,
                 "text": "речь\n\n# инъекция", "verified": True, "verifiedBy": "user"}]})
            probe.report(output)
            text = (output / "review.md").read_text(encoding="utf-8")
            self.assertIn("## payment # Подделка · 00:00:00.000–00:00:01.000", text)
            self.assertIn("**Проверенный текст:** речь # инъекция", text)
            self.assertNotIn("\n# Подделка", text)
            self.assertNotIn("\n# инъекция", text)

    def test_context_candidates_get_audio_and_separate_report_without_becoming_reference(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            with probe.wave.open(str(output / "input.wav"), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\x00\x00" * 16000)
            probe.write(output / "input.json", {"sourceHash": "sha", "waveHash": probe.digest(output / "input.wav")})
            probe.write(output / "reference.template.json", {"schemaVersion": 1, "sourceHash": "sha", "segments": []})
            probe.write(output / "E/context-reviews/window-0.json", {
                "coreStartMs": 0, "deferredTargets": 2, "unchangedContextTargets": 1, "reviews": [{
                    "request": {"startMs": 200, "endMs": 800, "contextStartMs": 0, "contextEndMs": 1000,
                                "reasons": ["uncertainText"]},
                    "original": [{"startMs": 200, "endMs": 800, "text": "исходный", "words": []}],
                    "candidate": [{"startMs": 200, "endMs": 800, "text": "альтернатива", "words": []}]}]})
            probe.report(output)
            text = (output / "context-review.md").read_text(encoding="utf-8")
            self.assertIn("исходный", text)
            self.assertIn("альтернатива", text)
            self.assertIn("отложено целей 2", text)
            with probe.wave.open(str(output / "E/context-review-audio/200-800.wav"), "rb") as audio:
                self.assertEqual(audio.getnframes(), 600 * 16)
            comparison = probe.read(output / "comparison.json")
            self.assertEqual(comparison["qualityStatus"], "awaiting-reviewed-reference")
            self.assertEqual(comparison["reviewedIntervals"], 0)

    def test_context_report_scores_human_reference_and_generates_custom_interval_audio(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory)
            with probe.wave.open(str(output / "input.wav"), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\x00\x00" * 16000)
            probe.write(output / "input.json", {"sourceHash": "sha", "waveHash": probe.digest(output / "input.wav")})
            probe.write(output / "reference.template.json", {"schemaVersion": 1, "sourceHash": "sha", "segments": [{
                "id": "custom", "startMs": 200, "endMs": 800, "text": "То есть", "verified": True, "verifiedBy": "user"}]})
            probe.write(output / "E/context-reviews/window-0.json", {
                "coreStartMs": 0, "deferredTargets": 0, "unchangedContextTargets": 0, "reviews": [{
                    "request": {"startMs": 200, "endMs": 800, "contextStartMs": 0, "contextEndMs": 1000,
                                "reasons": ["uncertainText"]},
                    "original": [{"startMs": 200, "endMs": 800, "text": "То есть", "words": []}],
                    "candidate": [], "wordRepair": {"algorithmVersion": "fixture",
                        "proposed": [{"startMs": 0, "endMs": 200, "text": "То есть", "words": []}],
                        "edits": [], "issues": ["emptyCandidate"]}}]})
            probe.report(output)
            scores = probe.read(output / "context-scores.json")
            self.assertEqual(scores["totals"]["original"]["speechWER"], 0)
            self.assertEqual(scores["totals"]["candidate"]["deletions"], 2)
            self.assertEqual(scores["totals"]["candidate"]["speechWER"], 1)
            self.assertEqual(scores["totals"]["proposed"]["speechWER"], 0)
            self.assertEqual(scores["evaluatedIntervals"], {"original": 1, "candidate": 1, "proposed": 1})
            self.assertTrue((output / "review-audio/200-800.wav").is_file())
            self.assertIn("Проверенный текст", (output / "context-review.md").read_text(encoding="utf-8"))

    def test_repair_replay_rejects_nested_or_existing_output_before_modifying_source(self):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "source"
            source.mkdir()
            marker = source / "preserved.txt"
            marker.write_text("fixture", encoding="utf-8")
            args = SimpleNamespace(repair_replay=source)
            for output in [source, source / "nested", source.parent]:
                with self.assertRaises(ValueError):
                    probe.repair_replay(args, output)
            self.assertEqual(marker.read_text(encoding="utf-8"), "fixture")
            self.assertFalse((source / "nested").exists())


class FrozenBaselineControlTests(unittest.TestCase):
    def fixture(self, root):
        with probe.wave.open(str(root / "input.wav"), "wb") as audio:
            audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            audio.writeframes(b"\x01\x00" * 16000)
        probe.write(root / "input.json", {"sourceHash": "sha"})
        probe.write(root / "frozen-plan.json", {"durationMs": 1000, "windows": [{"requests": [{"startMs": 300, "endMs": 600}]}]})
        with patch.object(probe, "CONTROL_RANGES", [("control", 100, 900)]):
            probe.frozen_reference(root, "sha")
        for label in ("A", "C"):
            probe.write(root / label / "transcript.json", {"segments": [
                {"startMs": 100, "endMs": 300, "text": "before", "words": []},
                {"startMs": 300, "endMs": 600, "text": "old", "words": []},
                {"startMs": 600, "endMs": 900, "text": "after", "words": []}]})
        probe.write(root / "E/context-reviews/window-0.json", {"reviews": [{
            "request": {"startMs": 300, "endMs": 600}, "candidate": [{"startMs": 300, "endMs": 600, "text": "new", "words": []}],
            "wordRepair": {"proposed": [{"startMs": 0, "endMs": 200, "text": "new", "words": []}]}}]})

    def test_blank_reference_partitions_exact_targets_and_preserves_audio_frames(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.fixture(root)
            reference = probe.read(root / "reference.template.json")
            self.assertEqual([(s["startMs"], s["endMs"]) for s in reference["segments"]], [(100, 300), (300, 600), (600, 900)])
            self.assertTrue(all(not s["verified"] and not s["verifiedBy"] and not s["text"] for s in reference["segments"]))
            with probe.wave.open(reference["segments"][1]["audioPath"], "rb") as audio:
                self.assertEqual(audio.getnframes(), 300 * 16)
                self.assertEqual(audio.readframes(audio.getnframes()), b"\x01\x00" * (300 * 16))
            self.assertNotIn("**C:** old", (root / "LISTEN-FIRST.md").read_text())
            probe.frozen_comparison(root)
            result = probe.read(root / "control-comparison.json")
            self.assertEqual(result["qualityStatus"], "awaiting-reviewed-reference")
            self.assertTrue(all(score["speechWER"] is None for score in result["scores"].values()))

    def test_four_variants_use_same_units_and_timing_free_proposal_keeps_target_membership(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.fixture(root)
            reference = probe.read(root / "reference.template.json")
            for segment, text in zip(reference["segments"], ["before", "new", "after"]):
                segment.update(verified=True, verifiedBy="fixture-reviewer", text=text)
            probe.write(root / "reference.template.json", reference)
            probe.frozen_comparison(root)
            result = probe.read(root / "control-comparison.json")
            self.assertEqual(result["evaluatedIntervals"], dict(A=3, C=3, repeat=3, proposed=3))
            self.assertEqual(result["scores"]["C"]["substitutions"], 1)
            self.assertEqual(result["scores"]["repeat"]["speechWER"], 0)
            self.assertEqual(result["scores"]["proposed"]["speechWER"], 0)
            self.assertEqual(result["units"][0]["texts"]["repeat"], "before")
            self.assertEqual(result["units"][2]["texts"]["proposed"], "after")

    def test_partial_target_cannot_silently_drop_words_of_a_proposal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            self.fixture(root)
            reference = probe.read(root / "reference.template.json")
            reference["segments"] = [dict(reference["segments"][1], startMs=400, verified=True, verifiedBy="fixture", text="new")]
            probe.write(root / "reference.template.json", reference)
            probe.frozen_comparison(root)
            result = probe.read(root / "control-comparison.json")
            self.assertTrue(result["units"][0]["partialTargetUnsupported"])
            self.assertEqual(result["evaluatedIntervals"], dict(A=0, C=0, repeat=0, proposed=0))

    def test_nested_output_is_rejected_before_touching_baseline(self):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory)
            with self.assertRaises(ValueError):
                probe.context_from_baseline(SimpleNamespace(context_from_baseline=source), source / "nested")
            self.assertFalse((source / "nested").exists())


if __name__ == "__main__":
    unittest.main()
